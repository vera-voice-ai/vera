import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import Network
import UIKit

/// «Для самоанализа»: the phone keeps an activity log of what it can sense — collected now, analysed later. Nothing of it goes to
/// Hermes with the conversation; the files stay on the phone (Documents/Sensors/<day>/*.jsonl) and the Mac copies them
/// to Vera's data at home (scripts/phone-sensors.sh). One JSON object per line, `t` — Unix seconds.
///
/// What and how often:
/// - places: iOS visits (arrived / left) and significant moves — always, nearly free;
/// - GPS: one point a minute while moving (iOS says walking, running, cycling or driving), none while still;
///   one a second while the navigator guides;
/// - activity (still / walking / running / cycling / automotive) and steps, floors, distance — iOS keeps them for
///   7 days, the log takes them over whenever the app wakes;
/// - the phone: battery and charging, network, audio route — on every change.
@MainActor @Observable
final class SensorLog: NSObject {
    static let minuteGap: TimeInterval = 60

    var enabled = UserDefaults.standard.object(forKey: "vera.sensors") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "vera.sensors"); enabled ? start() : stop() }
    }
    /// Lines written today, by stream — for Settings.
    private(set) var today: [String: Int] = [:]
    private(set) var moving = false
    private(set) var navigating = false
    private(set) var lastPoint: Date?
    /// The latest values, for the scheme's micro-module: what the log holds right now.
    private(set) var activityNow: String?
    private(set) var stepsToday: Int?
    private(set) var battery: (level: Float, power: String)?
    private(set) var networkNow: String?
    private(set) var speedKmh: Double?

    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private let activity = CMMotionActivityManager()
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private let net = NWPathMonitor()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastNet = ""

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Sensors")
    }

    override init() {
        super.init()
        location.delegate = self
        // Only with «location» in UIBackgroundModes (scripts/phone-deploy.sh adds it to the device build): without it
        // iOS throws here. The simulator build has none — the diary then works while the app is open.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        location.allowsBackgroundLocationUpdates = modes.contains("location")
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .otherNavigation
        countToday()
    }

    func start() {
        guard enabled, !running else { return }
        running = true
        location.requestAlwaysAuthorization()
        location.startMonitoringVisits()
        location.startMonitoringSignificantLocationChanges()
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { [weak self] a in
                guard let a else { return }
                MainActor.assumeIsolated { self?.activityChanged(a) }
            }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(deviceChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(deviceChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(woke), name: UIApplication.didBecomeActiveNotification, object: nil)
        net.pathUpdateHandler = { [weak self] p in
            let kind = p.status != .satisfied ? "нет" : p.usesInterfaceType(.wifi) ? "wifi" : p.usesInterfaceType(.cellular) ? "сотовая" : "другая"
            Task { @MainActor in self?.network(kind) }
        }
        net.start(queue: .main)
        deviceChanged()
        catchUp()
    }

    func stop() {
        running = false
        location.stopMonitoringVisits()
        location.stopMonitoringSignificantLocationChanges()
        location.stopUpdatingLocation()
        activity.stopActivityUpdates()
        net.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// The navigator guides: a point every second; when it stops, back to the minute.
    func setNavigating(_ on: Bool) {
        guard on != navigating else { return }
        navigating = on
        write("events", ["kind": on ? "nav.start" : "nav.end"])
        updateGPS()
    }

    // MARK: GPS policy

    private func activityChanged(_ a: CMMotionActivity) {
        write("activity", ["kind": Self.kind(a), "confidence": a.confidence.rawValue, "live": true])
        activityNow = Self.kind(a)
        let nowMoving = a.walking || a.running || a.cycling || a.automotive
        if nowMoving != moving { moving = nowMoving; updateGPS() }
    }

    private func updateGPS() {
        guard running else { return }
        if navigating {
            location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            location.distanceFilter = kCLDistanceFilterNone
            location.startUpdatingLocation()
        } else if moving {
            // A point a minute: GPS stays on at modest accuracy, only one fix a minute is kept.
            location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            location.distanceFilter = 20
            location.startUpdatingLocation()
        } else {
            location.stopUpdatingLocation()   // still: visits and significant moves only
        }
    }

    fileprivate func got(_ l: CLLocation) {
        if !navigating, let last = lastPoint, l.timestamp.timeIntervalSince(last) < Self.minuteGap { return }
        lastPoint = l.timestamp
        speedKmh = l.speed >= 0 ? l.speed * 3.6 : nil
        write("location", Self.point(l, why: navigating ? "nav" : moving ? "minute" : "move"), at: l.timestamp)
    }

    fileprivate func visit(_ v: CLVisit) {
        var o: [String: Any] = ["lat": v.coordinate.latitude, "lon": v.coordinate.longitude, "acc": v.horizontalAccuracy]
        if v.arrivalDate != .distantPast { o["arrived"] = v.arrivalDate.timeIntervalSince1970 }
        if v.departureDate != .distantFuture { o["left"] = v.departureDate.timeIntervalSince1970 }
        write("visits", o)
        catchUp()
    }

    // MARK: Taken over from iOS (it keeps 7 days)

    @objc private func woke() { catchUp() }

    /// Activity segments and steps since the last take-over.
    private func catchUp() {
        guard running else { return }
        let d = UserDefaults.standard
        let now = Date()
        let floor = now.addingTimeInterval(-7 * 86400 + 600)
        let fromA = max(Date(timeIntervalSince1970: d.double(forKey: "vera.sensors.activityUntil")), floor)
        if CMMotionActivityManager.isActivityAvailable(), now.timeIntervalSince(fromA) > 60 {
            activity.queryActivityStarting(from: fromA, to: now, to: .main) { [weak self] list, _ in
                MainActor.assumeIsolated {
                    guard let self, let list else { return }
                    for a in list where a.startDate > fromA {
                        self.write("activity", ["kind": Self.kind(a), "confidence": a.confidence.rawValue], at: a.startDate)
                    }
                    d.set(now.timeIntervalSince1970, forKey: "vera.sensors.activityUntil")
                }
            }
        }
        guard CMPedometer.isStepCountingAvailable() else { return }
        // CoreMotion calls back on its own queue: the handlers are @Sendable (not main-actor) and hop to the main actor.
        pedometer.queryPedometerData(from: Calendar.current.startOfDay(for: now), to: now) { @Sendable [weak self] data, _ in
            let n = data?.numberOfSteps.intValue
            Task { @MainActor in self?.stepsToday = n }
        }
        // Steps by whole hours: each finished hour once.
        var hour = max(Date(timeIntervalSince1970: d.double(forKey: "vera.sensors.stepsUntil")), floor)
        hour = Calendar.current.dateInterval(of: .hour, for: hour)?.start ?? hour
        while let next = Calendar.current.date(byAdding: .hour, value: 1, to: hour), next <= now {
            let from = hour
            pedometer.queryPedometerData(from: from, to: next) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.intValue, meters = data.distance?.doubleValue ?? 0
                let up = data.floorsAscended?.intValue ?? 0, down = data.floorsDescended?.intValue ?? 0
                guard steps > 0 else { return }
                Task { @MainActor in
                    self?.write("steps", ["from": from.timeIntervalSince1970, "to": next.timeIntervalSince1970,
                                          "steps": steps, "meters": meters, "up": up, "down": down], at: from)
                }
            }
            hour = next
        }
        d.set(hour.timeIntervalSince1970, forKey: "vera.sensors.stepsUntil")
    }

    // MARK: The phone itself

    @objc private func deviceChanged() {
        let dev = UIDevice.current
        let state: String = switch dev.batteryState {
        case .charging: "заряжается"
        case .full: "полный"
        case .unplugged: "от батареи"
        default: "?"
        }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        battery = dev.batteryLevel >= 0 ? (dev.batteryLevel, state) : nil
        write("device", ["battery": Double(dev.batteryLevel), "power": state, "route": route,
                         "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled])
    }

    private func network(_ kind: String) {
        guard kind != lastNet else { return }
        lastNet = kind
        networkNow = kind
        write("device", ["network": kind])
    }

    // MARK: Files

    private func write(_ stream: String, _ object: [String: Any], at: Date = Date()) {
        guard enabled else { return }
        var o = object
        o["t"] = (at.timeIntervalSince1970 * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        let dir = Self.root.appending(path: Self.day(at))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(stream).jsonl")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); h.write(Data([0x0A])); try? h.close()
        } else {
            try? (data + Data([0x0A])).write(to: file, options: .atomic)
        }
        if Self.day(at) == Self.day(Date()) { today[stream, default: 0] += 1 }
    }

    private func countToday() {
        let dir = Self.root.appending(path: Self.day(Date()))
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let n = (try? String(contentsOf: f, encoding: .utf8))?.split(separator: "\n").count ?? 0
            today[f.deletingPathExtension().lastPathComponent] = n
        }
    }

    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func point(_ l: CLLocation, why: String) -> [String: Any] {
        var o: [String: Any] = ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude, "acc": l.horizontalAccuracy, "why": why]
        if l.verticalAccuracy >= 0 { o["alt"] = l.altitude; o["altAcc"] = l.verticalAccuracy }
        if l.speed >= 0 { o["speed"] = l.speed; o["speedAcc"] = l.speedAccuracy }
        if l.course >= 0 { o["course"] = l.course; o["courseAcc"] = l.courseAccuracy }
        return o
    }

    static func kind(_ a: CMMotionActivity) -> String {
        if a.automotive { return "automotive" }
        if a.cycling { return "cycling" }
        if a.running { return "running" }
        if a.walking { return "walking" }
        if a.stationary { return "stationary" }
        return "unknown"
    }
}

extension SensorLog: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        nonisolated(unsafe) let ls = locations
        MainActor.assumeIsolated { for l in ls { got(l) } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        nonisolated(unsafe) let v = visit
        MainActor.assumeIsolated { self.visit(v) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
