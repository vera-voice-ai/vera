import CoreLocation
import MapKit
import SwiftUI

/// The last destination chosen in either map mode, stored locally on this iPhone.
struct RecentMapPlace: Codable {
    static let storageKey = "vera.map.recentPlace"

    let title: String
    let latitude: Double
    let longitude: Double

    init(_ item: MKMapItem) {
        title = item.name ?? "Выбранное место"
        latitude = item.location.coordinate.latitude
        longitude = item.location.coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
        item.name = title
        return item
    }

    static func restore(_ data: Data) -> Self? {
        guard let place = try? JSONDecoder().decode(Self.self, from: data),
              CLLocationCoordinate2DIsValid(place.coordinate) else { return nil }
        return place
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

struct MapScreen: View {
    @AppStorage(RecentMapPlace.storageKey) private var recent = Data()
    @Environment(\.openURL) private var openURL
    @State private var camera: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var search: MKLocalSearch?
    @State private var message: String?

    private var place: RecentMapPlace? { RecentMapPlace.restore(recent) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Куда едем?", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { Task { await find() } }
                Button("Найти") { Task { await find() } }
            }
            if let message { Text(message).font(.footnote) }
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                            Button {
                                let selected = RecentMapPlace(item)
                                selected.save()
                                results = []
                                show(selected)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Выбранное место")
                                    if let address = item.address?.shortAddress ?? item.address?.fullAddress {
                                        Text(address).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            Map(position: $camera) {
                if let place {
                    Marker(place.title, coordinate: place.coordinate)
                }
            }
            .onMapCameraChange { region = $0.region }
            .onAppear { if let place { show(place) } }
            HStack {
                if let place {
                    Button { show(place) } label: {
                        Label(place.title, systemImage: "clock.arrow.circlepath").lineLimit(1)
                    }
                    Spacer()
                }
                Button("Google Maps") { openGoogleMaps() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .tint(Palette.vera)
        .background(Palette.background)
        .onDisappear { search?.cancel(); search = nil }
    }

    private func show(_ place: RecentMapPlace) {
        camera = .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500))
    }

    private func find() async {
        search?.cancel()
        search = nil
        results = []
        message = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let region { request.region = region }
        let operation = MKLocalSearch(request: request)
        search = operation
        do {
            let response = try await operation.start()
            guard search === operation else { return }
            results = Array(response.mapItems.prefix(8))
            if results.isEmpty { message = "Места не найдены" }
        } catch {
            guard search === operation else { return }
            message = "Поиск не удался"
        }
        if search === operation { search = nil }
    }

    private func openGoogleMaps() {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "www.google.com"
        url.path = "/maps"
        if let place {
            url.path = "/maps/dir/"
            url.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: "\(place.latitude),\(place.longitude)"),
            ]
        }
        if let target = url.url { openURL(target) }
    }
}
