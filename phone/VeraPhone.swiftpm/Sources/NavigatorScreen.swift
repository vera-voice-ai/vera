import GoogleNavigation
import MapKit
import SwiftUI
import UIKit

/// The navigator's screen, like Google Maps: «Куда едем?» on top with suggestions as you type (Google Places), and
/// while nothing is going on — home, work, favourites and recent places as big buttons; then one bottom card for the
/// route (with «без магистралей» / «без платных»), the guidance strip, the arrival or an error.
/// Touch targets are 52 pt and up: this is used on a motorbike, in gloves.
struct NavigatorScreen: View {
    @Bindable var nav: Navigator
    @FocusState private var searching: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // The map goes under the status bar; the overlay below respects the safe area.
            MapBox(view: nav.map).ignoresSafeArea()
            VStack(spacing: 8) {
                // While guiding Google's manoeuvre panel is on top: the search steps aside.
                if nav.phase != .guiding { searchPill }
                if !nav.suggestions.isEmpty { resultsCard }
                else if let p = nav.searchProblem, !nav.query.isEmpty { problemLine(p) }
                if nav.phase == .idle, nav.termsAccepted, nav.pinned == nil, nav.suggestions.isEmpty, nav.query.isEmpty { whereTo(lists: searching) }
                Spacer(minLength: 0)   // empty space stays transparent, so the map gets the touches
                bottom
                    // Google's own buttons (recenter, speedometer) stay above our card.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        nav.map.padding.bottom = h > 0 ? h + 12 : 0
                    }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .background(Palette.background)
        .onAppear { nav.appear() }
        .onChange(of: nav.pinned) { if nav.pinned != nil { searching = false } }
    }

    // MARK: Search

    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(0.5))
            TextField("Куда едем?", text: $nav.query)
                .font(.system(size: 17))
                .focused($searching)
                .submitLabel(.search)
                .onSubmit { Task { await nav.search() } }
                .task(id: nav.query) {
                    // Suggestions as you type, like Google Maps: a short pause first, so not every letter is a request.
                    guard nav.query.count >= 2 else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await nav.search()
                }
            if searching || !nav.query.isEmpty {
                // Leaves the search: the text, the suggestions and the keyboard go.
                Button { nav.clearSearch(); searching = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Palette.ink.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Capsule().fill(Palette.card.opacity(0.94)))
        .overlay(Capsule().stroke(Palette.ink.opacity(0.08)))
    }

    /// Suggestions (Google, or Apple when Google cannot): name and address; ☆ keeps the place, long press makes it
    /// home or work.
    private var resultsCard: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(nav.suggestions.enumerated()), id: \.element.id) { index, place in
                    placeRow(place, icon: "mappin.circle")
                    if index < nav.suggestions.count - 1 { Divider().overlay(Palette.ink.opacity(0.08)) }
                }
                HStack {
                    Text("поиск: \(nav.searchSource)\(nav.searchProblem.map { " · \($0)" } ?? "")")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.4)).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .frame(maxHeight: 420)
        .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card))
    }

    private func problemLine(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.orange)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card))
    }

    /// One place: tap — route there; ☆ — favourite; long press — home / work / forget.
    private func placeRow(_ place: NavPlace, icon: String) -> some View {
        HStack(spacing: 12) {
            Button { nav.route(to: place) } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Palette.vera).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        if let a = place.subtitle {
                            Text(a).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { nav.places.toggleFavorite(place) } label: {
                Image(systemName: nav.places.isFavorite(place) ? "star.fill" : "star")
                    .font(.system(size: 18)).foregroundStyle(nav.places.isFavorite(place) ? Palette.llm : Palette.ink.opacity(0.35))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .contextMenu {
            Button("Сделать домом", systemImage: "house") { nav.places.setHome(place) }
            Button("Сделать работой", systemImage: "briefcase") { nav.places.setWork(place) }
            if nav.places.recents.contains(place) {
                Button("Убрать из недавних", systemImage: "trash", role: .destructive) { nav.places.forget(place) }
            }
        }
    }

    /// «Куда едем?» while nothing is going on: home and work as big buttons; favourites and recent places only once the
    /// search is tapped — otherwise the map stays clear.
    private func whereTo(lists: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                quick("Дом", "house.fill", nav.places.home)
                quick("Работа", "briefcase.fill", nav.places.work)
            }
            let favs = nav.places.favorites.prefix(4), recent = nav.places.recents.filter { !nav.places.isFavorite($0) }.prefix(4)
            if lists, !favs.isEmpty || !recent.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(favs), id: \.id) { placeRow($0, icon: "star.fill") }
                    ForEach(Array(recent), id: \.id) { placeRow($0, icon: "clock.arrow.circlepath") }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card.opacity(0.96)))
            }
        }
    }

    private func quick(_ title: String, _ icon: String, _ place: NavPlace?) -> some View {
        Button { if let place { nav.route(to: place) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(place?.title ?? "удерживай точку на карте или место в поиске")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card.opacity(0.96)))
            .opacity(place == nil ? 0.7 : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom card, by phase

    @ViewBuilder private var bottom: some View {
        switch nav.phase {
        case .idle:
            if let p = nav.pinned { pinCard(p) }
        case .routing:
            card {
                HStack(spacing: 12) {
                    ProgressView().tint(Palette.vera)
                    Text("строю маршрут до «\(nav.destination ?? "")»…")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink.opacity(0.7))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        case .ready:
            readyCard
        case .guiding:
            guidingStrip
        case .arrived:
            arrivedCard
        case .failed(let why):
            failedCard(why)
        }
    }

    /// A point held on the map (or a marker tapped): its address, «Маршрут сюда», and make it home, work or a favourite.
    private func pinCard(_ p: NavPlace) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(2)
                        if let a = p.subtitle { monoLine(a) }
                    }
                    Spacer(minLength: 0)
                    Button { nav.unpin() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24))
                            .foregroundStyle(Palette.ink.opacity(0.4))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Маршрут сюда") { nav.route(to: p) }
                    .buttonStyle(NavButtonStyle(fill: Palette.vera))
                HStack(spacing: 8) {
                    mark("Дом", "house", nav.places.home?.id == p.id) { nav.places.setHome(p) }
                    mark("Работа", "briefcase", nav.places.work?.id == p.id) { nav.places.setWork(p) }
                    mark("Избранное", "star", nav.places.isFavorite(p)) { nav.places.toggleFavorite(p) }
                }
            }
        }
    }

    /// One of «Дом», «Работа», «Избранное» under the pin: filled when the point already is that.
    private func mark(_ title: String, _ icon: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: on ? icon + ".fill" : icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(on ? Palette.vera : Palette.ink.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12).stroke(on ? Palette.vera.opacity(0.7) : Palette.ink.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Route is built: the destination, the big time, the arrival line and «Поехали» / «Сброс».
    private var readyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text(nav.destination ?? "")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                timeView(size: 44)
                monoLine(arrivalLine)
                HStack(spacing: 8) {
                    option("без магистралей", $nav.avoidHighways)
                    option("без платных", $nav.avoidTolls)
                }
                monoLine("другие варианты — серые линии на карте")
                HStack(spacing: 10) {
                    Button("Поехали") { nav.go() }
                        .buttonStyle(NavButtonStyle(fill: Palette.vera))
                    Button("Сброс") { nav.stop() }
                        .buttonStyle(NavButtonStyle(fill: Palette.ink.opacity(0.1)))
                }
            }
        }
    }

    /// Guidance is on: the big remaining time, the arrival line, a small next-step line and «Стоп».
    private var guidingStrip: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                if let step = nav.nextStep, !step.isEmpty {
                    // Google's own panel shows the manoeuvres; this is only a small hint.
                    Text(step)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        timeView(size: 34)
                        monoLine(arrivalLine)
                    }
                    Spacer(minLength: 8)
                    Button("Стоп") { nav.stop() }
                        .buttonStyle(NavButtonStyle(fill: Palette.ink.opacity(0.14)))
                        .frame(width: 120)
                }
            }
        }
    }

    /// Arrived: the same card, with the destination and «Сброс».
    private var arrivedCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("приехали")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                monoLine(nav.destination ?? "")
                Button("Сброс") { nav.stop() }
                    .buttonStyle(NavButtonStyle(fill: Palette.ok, text: Palette.background))
            }
        }
    }

    /// Error: the same card, the message in orange and a button to dismiss it.
    private func failedCard(_ why: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text(why)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Понятно") { nav.stop() }
                    .buttonStyle(NavButtonStyle(fill: Palette.ink.opacity(0.1)))
            }
        }
    }

    // MARK: Pieces

    /// A route preference as a capsule toggle; changing it rebuilds the route.
    private func option(_ title: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Label(title, systemImage: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on.wrappedValue ? Palette.vera : Palette.ink.opacity(0.6))
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(Capsule().stroke(on.wrappedValue ? Palette.vera.opacity(0.7) : Palette.ink.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }

    /// The shared card: Palette.card, radius 13, full width.
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card))
    }

    /// The remaining time in big monospaced digits, with its unit.
    private func timeView(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(eta.big)
                .font(.system(size: size, weight: .bold, design: .monospaced))
            if !eta.unit.isEmpty {
                Text(eta.unit)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink.opacity(0.6))
            }
        }
        .lineLimit(1)
    }

    private func monoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.ink.opacity(0.6))
            .lineLimit(1)
    }

    private var eta: (big: String, unit: String) {
        guard let s = nav.remainingSeconds, s > 0 else { return ("—", "") }
        let m = Int(s / 60)
        return m >= 60 ? ("\(m / 60):" + String(format: "%02d", m % 60), "ч") : ("\(m)", "мин")
    }

    /// «приезд HH:MM · N км», in the monospaced line.
    private var arrivalLine: String {
        var parts: [String] = []
        if let s = nav.remainingSeconds, s > 0 {
            parts.append("приезд \(Date().addingTimeInterval(s).formatted(date: .omitted, time: .shortened))")
        }
        if let d = nav.remainingMeters, d > 0 {
            parts.append(d >= 1000 ? String(format: "%.1f км", d / 1000) : "\(Int(d)) м")
        }
        return parts.joined(separator: " · ")
    }
}

/// Big capsule button for the navigator: 52 pt tall, full width in its card.
private struct NavButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct MapBox: UIViewRepresentable {
    let view: GMSMapView
    func makeUIView(context: Context) -> GMSMapView { view }
    func updateUIView(_ uiView: GMSMapView, context: Context) {}
}
