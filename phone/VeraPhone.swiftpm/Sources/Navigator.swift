import CoreLocation
import GoogleNavigation
import MapKit
import PhoneWire
import SwiftUI
import UIKit

/// The navigator: Google's Navigation SDK inside the app — turn-by-turn on the map, traffic, rerouting, Google's voice.
/// The place is found by Google Places (Autocomplete, as in Google Maps; Apple's MapKit when Google cannot); the route
/// — with alternatives, avoiding motorways and tolls as set — and the guidance are Google's.
/// It needs the owner's Google Maps Platform key (Settings → «Карта Google»); without it the map tab uses MapKit.
@MainActor @Observable
final class Navigator: NSObject {
    enum Phase: Equatable { case idle, routing, ready, guiding, arrived, failed(String) }

    private(set) var phase: Phase = .idle { didSet { if phase != oldValue { report() } } }
    private(set) var destination: String?
    private(set) var address: String?
    /// Bumped when Hermes asked for a route: the tabs bring the map forward.
    private(set) var focus = 0
    /// The state for Vera (and Hermes' phone_route_status), on every phase change and once a minute while guiding.
    @ObservationIgnored var onState: ((PhoneNav) -> Void)?
    @ObservationIgnored private var reportedAt = Date.distantPast
    private(set) var results: [MKMapItem] = []
    /// Search results (Google or Apple), the owner's places, and where the current route goes.
    let places = PlaceBook()
    private(set) var suggestions: [NavPlace] = []
    private(set) var searchSource = ""
    private(set) var searchProblem: String?
    private(set) var target: NavPlace?
    /// A point the owner held on the map (or a marker of theirs they tapped): the card under it offers the route and
    /// «Дом» / «Работа» / «Избранное».
    private(set) var pinned: NavPlace?
    @ObservationIgnored private var pinMarker: GMSMarker?
    @ObservationIgnored private var placeMarkers: [GMSMarker] = []
    /// The route in Vera's pink, drawn over Google's blue line (the SDK has no setting for its colour).
    @ObservationIgnored private let routeLine: GMSPolyline = {
        let l = GMSPolyline()
        l.strokeColor = UIColor(red: 0.94, green: 0.13, blue: 0.61, alpha: 1)
        l.strokeWidth = 7
        l.zIndex = 10_000
        return l
    }()
    @ObservationIgnored private var routeDrawnAt = Date.distantPast

    /// The small map on the «Вера» screen: a plain Google map (navigation lives on the big one) with you, the route in
    /// pink and the camera on what matters — the whole route when it is ready, you while guiding.
    @ObservationIgnored private(set) lazy var preview: GMSMapView = {
        let m = GMSMapView(options: Self.options())
        m.isMyLocationEnabled = true
        m.settings.setAllGesturesEnabled(false)
        m.settings.compassButton = false
        return m
    }()
    @ObservationIgnored private let previewLine: GMSPolyline = {
        let l = GMSPolyline()
        l.strokeColor = UIColor(red: 0.94, green: 0.13, blue: 0.61, alpha: 1)
        l.strokeWidth = 5
        return l
    }()

    /// Moves the small map's camera (called when it appears and with every route update).
    func focusPreview() {
        guard Self.available else { return }
        let here = map.myLocation?.coordinate ?? location.location?.coordinate
        if Self.lastCamera == nil, let here { Self.lastCamera = GMSCameraPosition(target: here, zoom: 15) }
        if let path = routeLine.map != nil ? routeLine.path : nil {
            previewLine.path = path
            previewLine.map = preview
            if phase == .guiding, let here {
                preview.animate(to: GMSCameraPosition(target: here, zoom: 16))
            } else {
                preview.animate(with: GMSCameraUpdate.fit(GMSCoordinateBounds(path: path), withPadding: 24))
            }
        } else {
            previewLine.map = nil
            if let here { preview.animate(to: GMSCameraPosition(target: here, zoom: 15)) }
        }
    }
    /// Turn-by-turn prompts in Vera's voice (unless the owner chose Google's).
    @ObservationIgnored let voice = NavVoice()
    @ObservationIgnored private var session = UUID().uuidString
    /// Route preferences, kept between launches. Motorways are avoided by default: in Thailand a motorbike may not use them.
    var avoidHighways = UserDefaults.standard.object(forKey: "vera.nav.avoidHighways") as? Bool ?? true {
        didSet { UserDefaults.standard.set(avoidHighways, forKey: "vera.nav.avoidHighways"); rerouteIfReady() }
    }
    var avoidTolls = UserDefaults.standard.object(forKey: "vera.nav.avoidTolls") as? Bool ?? false {
        didSet { UserDefaults.standard.set(avoidTolls, forKey: "vera.nav.avoidTolls"); rerouteIfReady() }
    }
    private(set) var remainingSeconds: Double?
    private(set) var remainingMeters: Double?
    private(set) var nextStep: String?
    /// Whether the owner accepted Google's terms (the SDK keeps it between launches). Google wants its key before any
    /// other call: asked before `provideAPIKey`, the SDK said «no» every launch and showed the dialog again.
    private(set) var termsAccepted: Bool = {
        guard Navigator.startedKey != nil else { return false }
        return GMSNavigationServices.areTermsAndConditionsAccepted()
    }()
    var query = ""

    /// The key the SDK started with: Google reads it once per launch.
    static let startedKey: String? = {
        guard let k = Keychain.mapsKey, !k.isEmpty else { return nil }
        GMSServices.provideAPIKey(k)
        return k
    }()
    static var available: Bool { startedKey != nil }

    /// Where the map stood last time (kept between launches): the map opens there, not over Europe for a moment.
    static var lastCamera: GMSCameraPosition? {
        get {
            guard let a = UserDefaults.standard.array(forKey: "vera.nav.camera") as? [Double], a.count == 3 else { return nil }
            return GMSCameraPosition(latitude: a[0], longitude: a[1], zoom: Float(a[2]))
        }
        set {
            guard let c = newValue else { return }
            UserDefaults.standard.set([c.target.latitude, c.target.longitude, Double(c.zoom)], forKey: "vera.nav.camera")
        }
    }

    static func options() -> GMSMapViewOptions {
        let o = GMSMapViewOptions()
        if let c = lastCamera { o.camera = c }
        return o
    }

    @ObservationIgnored private(set) lazy var map: GMSMapView = {
        let m = GMSMapView(options: Self.options())
        // The map follows the app's theme (light, dark or as the system).
        m.isMyLocationEnabled = true
        m.settings.myLocationButton = true
        m.settings.compassButton = true
        m.padding = UIEdgeInsets(top: 72, left: 0, bottom: 0, right: 0)   // under the floating search
        m.delegate = self
        return m
    }()
    @ObservationIgnored private let location = CLLocationManager()

    func appear() {
        location.requestWhenInUseAuthorization()
        places.changed = { [weak self] in self?.showPlaces() }
        showPlaces()
        guard Self.startedKey != nil else { return }
        if !termsAccepted { termsAccepted = GMSNavigationServices.areTermsAndConditionsAccepted() }
        guard !termsAccepted else { enable(); return }
        let o = GMSNavigationTermsAndConditionsOptions(companyName: "Вера")
        GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: o) { [weak self] ok in
            MainActor.assumeIsolated {
                self?.termsAccepted = ok
                if ok { self?.enable() } else { self?.phase = .failed("без согласия с условиями Google навигация не включится") }
            }
        }
    }

    private func enable() {
        guard !map.isNavigationEnabled else { return }
        map.isNavigationEnabled = true
        map.travelMode = .driving        // the iOS SDK has no two-wheeler mode; driving is the closest for a motorbike
        applyVoice()
        map.navigator?.add(self)
        // Instruments as in Google Maps: speedometer, the speed limit, the trip's progress; lanes are in the header.
        map.shouldDisplaySpeedometer = true
        map.shouldDisplaySpeedLimit = true
        // Our bottom card shows the time and distance, and nothing of Google's sits under it: no footer, no trip bar
        // on the side, no «report an incident» button.
        map.settings.isNavigationTripProgressBarEnabled = false
        map.settings.isNavigationFooterEnabled = false
        map.settings.isNavigationReportIncidentButtonEnabled = false
        map.settings.isRecenterButtonEnabled = true
        map.cameraMode = .following
        // Google's guidance panel in Vera's colours: deep pink for the current step, darker for the next one.
        let pink = UIColor(red: 0.62, green: 0.07, blue: 0.40, alpha: 1), deep = UIColor(red: 0.42, green: 0.04, blue: 0.28, alpha: 1)
        map.settings.navigationHeaderPrimaryBackgroundColor = pink
        map.settings.navigationHeaderSecondaryBackgroundColor = deep
        map.settings.navigationHeaderPrimaryBackgroundColorNightMode = pink
        map.settings.navigationHeaderSecondaryBackgroundColorNightMode = deep
    }

    /// Google speaks only traffic alerts while Vera says the turns; or everything, when the owner chose Google's voice.
    func applyVoice() {
        map.navigator?.voiceGuidance = NavVoice.useVera ? .alertsOnly : .alertsAndGuidance
    }

    // MARK: Search (Apple) → route (Google)

    func search() async {
        let q = query
        let found = await PlaceSearch.find(q, near: map.myLocation?.coordinate ?? location.location?.coordinate,
                                           key: Self.startedKey, session: session)
        guard q == query else { return }   // a newer query is on its way
        suggestions = found.places
        searchSource = found.source
        searchProblem = found.problem
        results = []
    }

    func clearSearch() { query = ""; suggestions = []; searchProblem = nil }

    func route(to item: MKMapItem) { route(to: NavPlace(item)) }
    func route(to place: NavPlace) { Task { await routeNow(place) } }

    private func rerouteIfReady() {
        guard phase == .ready, let t = target else { return }
        route(to: t)
    }

    /// Builds the route (with alternatives on the map); true when it is ready.
    @discardableResult
    private func routeNow(_ place: NavPlace) async -> Bool {
        guard let navigator = map.navigator else { phase = .failed("навигация не готова"); return false }
        let wp: GMSNavigationWaypoint?
        if let id = place.placeID { wp = GMSNavigationWaypoint(placeID: id, title: place.title) }
        else if let c = place.coordinate { wp = GMSNavigationWaypoint(location: c, title: place.title) }
        else { wp = nil }
        guard let wp else { phase = .failed("у места нет адреса"); return false }
        unpin()
        suggestions = []; results = []; destination = place.title; address = place.subtitle; target = place
        phase = .routing
        navigator.avoidsHighways = avoidHighways
        navigator.avoidsTolls = avoidTolls
        let options = GMSNavigationRoutingOptions(alternateRoutesStrategy: .all)
        let status: GMSRouteStatus = await withCheckedContinuation { done in
            let once = Once()
            navigator.setDestinations([wp], routingOptions: options) { description, _ in
                let s = description?.routeStatus ?? .internalError
                if once.first() { done.resume(returning: s) }
            }
        }
        guard status == .OK else { phase = .failed(Self.describe(status)); return false }
        places.went(place)
        session = UUID().uuidString      // one Autocomplete session per chosen place
        remainingSeconds = navigator.timeToNextDestination
        remainingMeters = navigator.distanceToNextDestination
        map.cameraMode = .overview
        phase = .ready
        drawRoute()
        return true
    }

    // MARK: Hermes (plugin vera-phone, through Vera)

    /// A request from Hermes: (ok, a short sentence about what happened).
    func command(_ c: PhoneNavCommand) async -> (Bool, String) {
        guard Self.available else {
            return (false, "на iPhone нет ключа Google Maps — владелец вводит его в Настройках → «Карта Google»")
        }
        guard termsAccepted else {
            return (false, "на iPhone ещё не приняты условия навигации Google — нужно один раз открыть вкладку «Карта»")
        }
        enable()
        focus += 1
        switch c.action {
        case "route":
            let q = (c.destination ?? "").trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return (false, "не сказано, куда ехать") }
            if let own = places.named(q) {
                guard await routeNow(own) else { return (false, failure ?? "маршрут не построился") }
                if c.start { go() }
                return (true, "\(c.start ? "Ведение началось" : "Маршрут построен"): \(summary())")
            }
            query = q
            await search()
            guard let place = suggestions.first else { return (false, "не нашёл «\(q)» рядом") }
            guard await routeNow(place) else { return (false, failure ?? "маршрут не построился") }
            if c.start { go() }
            return (true, "\(c.start ? "Ведение началось" : "Маршрут построен"): \(summary())")
        case "start":
            guard phase == .ready else { return (false, "маршрута нет — сначала построй его") }
            go()
            return (true, "Ведение началось: \(summary())")
        case "stop":
            let was = destination
            stop()
            return (true, was.map { "Навигация до «\($0)» закончена" } ?? "Навигация и так не шла")
        default:
            return (false, "не знаю действия \(c.action)")
        }
    }

    private var failure: String? { if case .failed(let why) = phase { why } else { nil } }

    private func summary() -> String {
        var parts = ["«\(destination ?? "")»"]
        if let a = address { parts.append(a) }
        if let s = remainingSeconds, s > 0 {
            let m = Int((s / 60).rounded())
            parts.append(m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин")
            parts.append("приезд \(Date().addingTimeInterval(s).formatted(date: .omitted, time: .shortened))")
        }
        if let d = remainingMeters, d > 0 { parts.append(String(format: "%.1f км", d / 1000)) }
        return parts.joined(separator: ", ")
    }

    private var phaseName: String {
        switch phase {
        case .idle: "idle"
        case .routing: "routing"
        case .ready: "ready"
        case .guiding: "guiding"
        case .arrived: "arrived"
        case .failed: "failed"
        }
    }

    func report(force: Bool = true) {
        guard force || Date().timeIntervalSince(reportedAt) > 60 else { return }
        reportedAt = Date()
        onState?(PhoneNav(phase: Self.available ? phaseName : "unavailable", destination: destination, address: address,
                          remainingSeconds: remainingSeconds, remainingMeters: remainingMeters, nextStep: nextStep,
                          problem: failure, at: Date().timeIntervalSince1970))
    }

    func go() {
        guard let n = map.navigator else { return }
        voice.reset(); applyVoice()
        n.isGuidanceActive = true
        map.padding.top = 0      // no search over Google's panel while guiding
        map.cameraMode = .following
        UIApplication.shared.isIdleTimerDisabled = true
        phase = .guiding
    }

    /// The pink line along what is left of the route; redrawn on a new route and every few seconds while guiding.
    func drawRoute() {
        routeDrawnAt = Date()
        guard phase == .ready || phase == .guiding, let path = map.navigator?.currentRouteLeg?.path else { routeLine.map = nil; return }
        routeLine.path = path
        routeLine.map = map
        focusPreview()
    }

    func stop() {
        routeLine.map = nil
        defer { focusPreview() }
        map.navigator?.isGuidanceActive = false
        map.navigator?.clearDestinations()
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: "vera.keepAwake")
        destination = nil; address = nil; nextStep = nil; remainingSeconds = nil; remainingMeters = nil; target = nil
        phase = .idle
        map.cameraMode = .following
        map.padding.top = 72
    }

    // MARK: The owner's points on the map

    /// Long press on the map: a pin there, its address found by Apple (the coordinate stays exactly where the finger was).
    func pin(at c: CLLocationCoordinate2D) {
        guard phase == .idle || phase.isFailed else { return }
        if phase.isFailed { stop() }
        clearSearch()
        let place = NavPlace(title: "Точка на карте", subtitle: String(format: "%.5f, %.5f", c.latitude, c.longitude), coordinate: c)
        show(place)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)) else { return }
        Task {
            guard let item = try? await request.mapItems.first, pinned?.id == place.id else { return }
            var named = NavPlace(item)
            named.lat = c.latitude; named.lon = c.longitude
            if named.subtitle == named.title { named.subtitle = nil }
            pinned = named
            pinMarker?.title = named.title
        }
    }

    /// Shows a place under the card: the pin marker (for a new point) and the camera on it.
    private func show(_ place: NavPlace) {
        pinned = place
        pinMarker?.map = nil; pinMarker = nil
        guard let c = place.coordinate else { return }
        if !placeMarkers.contains(where: { ($0.userData as? NavPlace)?.id == place.id }) {
            let m = GMSMarker(position: c)
            m.icon = GMSMarker.markerImage(with: UIColor(Palette.vera))
            m.appearAnimation = .pop
            m.map = map
            pinMarker = m
        }
        map.animate(toLocation: c)
    }

    func unpin() {
        pinned = nil
        pinMarker?.map = nil; pinMarker = nil
    }

    /// Home, work and favourites as markers (those with a coordinate — a Google suggestion has only its place id).
    private func showPlaces() {
        placeMarkers.forEach { $0.map = nil }
        var all: [(NavPlace, String)] = []
        if let h = places.home { all.append((h, "Дом")) }
        if let w = places.work { all.append((w, "Работа")) }
        all += places.favorites.map { ($0, "★") }
        var seen = Set<String>()
        placeMarkers = all.compactMap { place, label in
            guard let c = place.coordinate, seen.insert(place.id).inserted else { return nil }
            let m = GMSMarker(position: c)
            m.title = label == "★" ? place.title : "\(label) · \(place.title)"
            m.icon = GMSMarker.markerImage(with: UIColor(label == "★" ? Palette.llm : Palette.session))
            m.userData = place
            m.map = map
            return m
        }
        // The pin became one of the owner's places: its own marker takes over.
        if let p = pinned, placeMarkers.contains(where: { ($0.userData as? NavPlace)?.id == p.id }) {
            pinMarker?.map = nil; pinMarker = nil
        }
    }

    private static func describe(_ s: GMSRouteStatus) -> String {
        switch s {
        case .noRouteFound: "маршрут не найден"
        case .networkError: "нет сети"
        case .quotaExceeded: "Google отказал: квота исчерпана"
        case .locationUnavailable: "не знаю, где ты — нужна геопозиция"
        case .apiKeyNotAuthorized: "ключ не разрешён для Navigation SDK"
        default: "маршрут не построился (код \(s.rawValue))"
        }
    }
}

extension Navigator.Phase {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

extension Navigator: GMSMapViewDelegate {
    /// The camera came to rest: remembered for the next launch.
    nonisolated func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
        let lat = position.target.latitude, lon = position.target.longitude, zoom = Double(position.zoom)
        UserDefaults.standard.set([lat, lon, zoom], forKey: "vera.nav.camera")
    }
    nonisolated func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
        MainActor.assumeIsolated { pin(at: coordinate) }
    }
    nonisolated func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        MainActor.assumeIsolated { if pinned != nil { unpin() } }
    }
    /// A tap on the owner's marker opens the same card as a held point.
    nonisolated func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        let place = marker.userData as? NavPlace
        return MainActor.assumeIsolated {
            guard phase == .idle, let place else { return false }
            show(place)
            return true
        }
    }
}

extension Navigator: GMSNavigatorListener {
    nonisolated func navigatorDidChangeRoute(_ navigator: GMSNavigator) {
        MainActor.assumeIsolated { drawRoute() }
    }
    nonisolated func navigator(_ navigator: GMSNavigator, didUpdateRemainingTime time: TimeInterval) {
        MainActor.assumeIsolated { remainingSeconds = time; report(force: false) }
    }
    nonisolated func navigator(_ navigator: GMSNavigator, didUpdateRemainingDistance distance: CLLocationDistance) {
        MainActor.assumeIsolated { remainingMeters = distance }
    }
    nonisolated func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
        let text = navInfo.currentStep?.fullInstructionText
        nonisolated(unsafe) let info = navInfo
        MainActor.assumeIsolated {
            nextStep = text
            guard phase == .guiding else { return }
            voice.update(info)
            if Date().timeIntervalSince(routeDrawnAt) > 3 { drawRoute() }
        }
    }
    nonisolated func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        MainActor.assumeIsolated {
            if phase == .guiding { voice.arrived() }
            phase = .arrived
            routeLine.map = nil
            map.navigator?.isGuidanceActive = false
            UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: "vera.keepAwake")
        }
    }
}

