import CoreLocation
import Foundation
import MapKit

/// A place to go: found by Google (a place id — Google routes to the place's entrance) or by Apple (a coordinate).
struct NavPlace: Codable, Hashable, Identifiable {
    var id: String { placeID ?? String(format: "%.5f,%.5f", lat ?? 0, lon ?? 0) }
    var title: String
    var subtitle: String?
    var placeID: String?
    var lat: Double?
    var lon: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    init(title: String, subtitle: String? = nil, placeID: String? = nil, coordinate: CLLocationCoordinate2D? = nil) {
        self.title = title; self.subtitle = subtitle; self.placeID = placeID
        self.lat = coordinate?.latitude; self.lon = coordinate?.longitude
    }

    init(_ item: MKMapItem) {
        self.init(title: item.name ?? "Место", subtitle: item.address?.shortAddress ?? item.address?.fullAddress,
                  coordinate: item.location.coordinate)
    }
}

/// The owner's places on this phone: home, work, favourites and the last destinations. Kept in UserDefaults, never
/// sent anywhere.
@MainActor @Observable
final class PlaceBook {
    private(set) var home: NavPlace?
    private(set) var work: NavPlace?
    private(set) var favorites: [NavPlace] = []
    private(set) var recents: [NavPlace] = []

    /// Called after any change, so the map redraws the markers.
    @ObservationIgnored var changed: (() -> Void)?

    /// «дом», «домой», «работа», «на работу» → the owner's own place (for Hermes' «поехали домой»).
    func named(_ q: String) -> NavPlace? {
        let w = q.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if ["дом", "домой", "home", "до дома"].contains(w) { return home }
        if ["работа", "на работу", "work", "до работы"].contains(w) { return work }
        return favorites.first { $0.title.lowercased() == w }
    }

    private struct Stored: Codable { var home, work: NavPlace?; var favorites, recents: [NavPlace] }
    private static let key = "vera.nav.places"
    static let keepRecents = 12

    /// The places live in a file in Documents — it survives installing a new build (the preferences on this iPhone
    /// were found wiped more than once); UserDefaults is read only once, to move old data over.
    static let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "Settings").appending(path: "places.json")

    init() {
        let data = (try? Data(contentsOf: Self.file)) ?? UserDefaults.standard.data(forKey: Self.key)
        if let data, let s = try? JSONDecoder().decode(Stored.self, from: data) {
            home = s.home; work = s.work; favorites = s.favorites; recents = s.recents
        }
        DayLog(name: "app.jsonl").write(["ev": "places", "fromFile": FileManager.default.fileExists(atPath: Self.file.path),
                                         "home": home != nil, "work": work != nil, "favorites": favorites.count, "recents": recents.count])
    }

    func setHome(_ p: NavPlace?) { home = p; save() }
    func setWork(_ p: NavPlace?) { work = p; save() }
    func isFavorite(_ p: NavPlace) -> Bool { favorites.contains { $0.id == p.id } }
    func toggleFavorite(_ p: NavPlace) {
        if isFavorite(p) { favorites.removeAll { $0.id == p.id } } else { favorites.insert(p, at: 0) }
        save()
    }
    func went(_ p: NavPlace) {
        recents.removeAll { $0.id == p.id }
        recents.insert(p, at: 0)
        if recents.count > Self.keepRecents { recents.removeLast(recents.count - Self.keepRecents) }
        save()
    }
    func forget(_ p: NavPlace) { recents.removeAll { $0.id == p.id }; save() }

    private func save() {
        let s = Stored(home: home, work: work, favorites: favorites, recents: recents)
        if let d = try? JSONEncoder().encode(s) {
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: Self.file, options: .atomic)
            UserDefaults.standard.set(d, forKey: Self.key)
        }
        changed?()
    }
}

/// Place search. Google Places (New) Autocomplete first — the same suggestions as in Google Maps, near you, in Russian;
/// it needs «Places API (New)» allowed for the owner's key. Apple's MapKit is the fallback, and the reason Google did
/// not answer is kept, so the screen can say it.
enum PlaceSearch {
    struct Result { var places: [NavPlace]; var source: String; var problem: String? }

    static func find(_ query: String, near: CLLocationCoordinate2D?, key: String?, session: String) async -> Result {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Result(places: [], source: "", problem: nil) }
        var googleProblem: String?
        if let key, !key.isEmpty {
            do {
                let found = try await google(q, near: near, key: key, session: session)
                if !found.isEmpty { return Result(places: found, source: "Google", problem: nil) }
                googleProblem = "Google ничего не нашёл"
            } catch {
                googleProblem = (error as? Failure)?.text ?? error.localizedDescription
            }
        }
        let apple = await mapKit(q, near: near)
        return Result(places: apple, source: "Apple", problem: googleProblem)
    }

    struct Failure: Error { let text: String }

    static func google(_ q: String, near: CLLocationCoordinate2D?, key: String, session: String) async throws -> [NavPlace] {
        var req = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:autocomplete")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        // The key is restricted to this app: Google checks the bundle id the request names.
        req.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        var body: [String: Any] = ["input": q, "languageCode": "ru", "sessionToken": session]
        if let near {
            body["locationBias"] = ["circle": ["center": ["latitude": near.latitude, "longitude": near.longitude], "radius": 50_000.0]]
            body["origin"] = ["latitude": near.latitude, "longitude": near.longitude]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "код \(code)"
            if code == 403 { throw Failure(text: "Google: в ключе не разрешён Places API (New) — \(message.prefix(80))") }
            throw Failure(text: "Google: \(message.prefix(100))")
        }
        let suggestions = json?["suggestions"] as? [[String: Any]] ?? []
        return suggestions.compactMap { s in
            guard let p = s["placePrediction"] as? [String: Any], let id = p["placeId"] as? String else { return nil }
            let f = p["structuredFormat"] as? [String: Any]
            let main = ((f?["mainText"] as? [String: Any])?["text"] as? String)
                ?? ((p["text"] as? [String: Any])?["text"] as? String) ?? "Место"
            let secondary = (f?["secondaryText"] as? [String: Any])?["text"] as? String
            return NavPlace(title: main, subtitle: secondary, placeID: id)
        }
    }

    static func mapKit(_ q: String, near: CLLocationCoordinate2D?) async -> [NavPlace] {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = q
        if let near { r.region = MKCoordinateRegion(center: near, latitudinalMeters: 80_000, longitudinalMeters: 80_000) }
        let items = (try? await MKLocalSearch(request: r).start().mapItems) ?? []
        return items.prefix(8).map(NavPlace.init)
    }
}
