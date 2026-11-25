import GoogleNavigation
import SwiftUI

/// The navigator on the «Вера» screen: a live small map (you, the route in pink) and the controls under it — home and
/// work while nothing goes on, «Поехали» / «Сброс» for a ready route, the next step, time and «Стоп» while guiding.
/// A tap on the map opens the «Карта» tab. Without a Google key — a hint instead of the map.
struct NavCard: View {
    let nav: Navigator
    var open: () -> Void = {}

    private var tint: Color { Palette.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(caption).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55))
                Spacer(minLength: 4)
                if let rest = remaining {
                    Text(rest).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.8))
                }
            }
            if Navigator.available {
                PreviewMap(view: nav.preview)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
                    .overlay(alignment: .bottomLeading) { stepBadge }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: open)
                    .onAppear { nav.focusPreview() }
            } else {
                Button(action: open) {
                    Text("куда едем? скажи Вере или открой карту").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.ink.opacity(0.75))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .buttonStyle(.plain)
            }
            controls
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glowCard(tint, on: nav.phase != .idle)
    }

    /// The next step over the map while guiding (or why it failed).
    @ViewBuilder private var stepBadge: some View {
        let text: String? = {
            if case .failed(let why) = nav.phase { return why }
            if nav.phase == .guiding, let s = nav.nextStep, !s.isEmpty { return s }
            if nav.phase != .idle { return title }
            return nil
        }()
        if let text {
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card.opacity(0.92)))
                .padding(6)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            switch nav.phase {
            case .idle, .failed:
                go("Дом", "house.fill", nav.places.home)
                go("Работа", "briefcase.fill", nav.places.work)
            case .routing:
                ProgressView().tint(tint)
                Text("строю маршрут…").font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.7))
                Spacer()
            case .ready:
                pill("Поехали", fill: Palette.vera) { nav.go() }
                pill("Сброс", fill: Palette.ink.opacity(0.12)) { nav.stop() }
            case .guiding:
                pill("Стоп", fill: Palette.ink.opacity(0.14)) { nav.stop() }
            case .arrived:
                pill("Сброс", fill: Palette.ok) { nav.stop() }
            }
        }
        .frame(height: 46)
    }

    /// Home or work: a route there (and the map); without it set — the map, to set it there.
    private func go(_ title: String, _ icon: String, _ place: NavPlace?) -> some View {
        Button {
            if let place { nav.route(to: place) }
            open()
        } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(place == nil ? Palette.ink.opacity(0.4) : Palette.ink.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().strokeBorder(tint.opacity(place == nil ? 0.25 : 0.7)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, fill: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        for s in [nav.destination, nav.address] {
            if let s, !s.isEmpty { return s }
        }
        return "маршрут"
    }

    private var caption: String {
        switch nav.phase {
        case .routing: return "СТРОЮ МАРШРУТ"
        case .ready: return "МАРШРУТ ГОТОВ"
        case .arrived: return "ПРИЕХАЛИ"
        case .guiding: return "ВЕДУ"
        case .failed: return "НАВИГАТОР · ОШИБКА"
        case .idle: return "НАВИГАТОР"
        }
    }

    private var remaining: String? {
        guard nav.phase == .guiding || nav.phase == .ready else { return nil }
        var parts: [String] = []
        if let s = nav.remainingSeconds { parts.append(Self.duration(s)) }
        if let m = nav.remainingMeters { parts.append(Self.distance(m)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Формат

    static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) мин" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) ч" : "\(h) ч " + (m < 10 ? "0\(m)" : "\(m)") + " мин"
    }

    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int((meters / 10).rounded()) * 10) м" }
        let km = meters / 1000
        let text = km < 10 ? String(format: "%.1f", km) : String(Int(km.rounded()))
        return text.replacingOccurrences(of: ".", with: ",") + " км"
    }
}

/// The small Google map (one instance, kept by the navigator).
private struct PreviewMap: UIViewRepresentable {
    let view: GMSMapView
    func makeUIView(context: Context) -> GMSMapView { view }
    func updateUIView(_ uiView: GMSMapView, context: Context) {}
}
