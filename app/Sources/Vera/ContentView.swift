import AppKit
import SwiftUI
import HermesBridge

/// The whole window is one board — the scheme: our parts in pink around Hermes in yellow-orange, live flows along the
/// lines, each part showing everything about itself (details of a Hermes part — its «▸»). The agent's questions come
/// as a banner over the board. Tiles are not clickable: only explicit buttons are.
struct ContentView: View {
    @Bindable var model: BoardModel
    var voice: VoiceModel? = nil
    var phone: PhoneModel? = nil
    var scrollable = true
    @Environment(\.openWindow) private var openWindow
    @State private var zoom = BoardZoom()

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if scrollable {
                    PannableBoard(zoom: zoom) { board }
                } else {
                    board
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let voice { RequestBanner(chat: voice.chat).padding(.top, 16) }
            }
            .overlay(alignment: .topTrailing) { BoardCorner(zoom: scrollable ? zoom : nil).padding(12) }
            footer
        }
        // Small enough for an iPad as the Mac's second screen (Sidecar: 1069×744 points): a minimum bigger than the
        // screen kept the green button from going full screen there. The board scrolls and is dragged anyway.
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.background.ignoresSafeArea())
        // The main conversation lives on the board now: open it with the app, re-attach after a reconnect.
        .task { await voice?.chat.openPinned() }
        .onChange(of: model.gatewayState) { _, state in
            guard state == .connected, let chat = voice?.chat else { return }
            Task { if chat.sessionId == nil { await chat.openPinned() } else { await chat.reattach() } }
        }
    }

    private var board: some View {
        OrganismBoard(model: model, voice: voice, phone: phone)
            .padding(20)
            .fixedSize()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)).frame(width: 31, height: 31)
                Image(systemName: "waveform.path").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Text("VERA v0.3 · Based on HermesAgent").veraType(.heading).foregroundStyle(Theme.textPrimary)
            // The UI kit: every shared part of the interface in its states (VeraKit, docs/ui-kit.md).
            Button { openWindow(id: "kit") } label: { Pill(text: "UI-КИТ", color: Theme.vera, strong: false) }
                .buttonStyle(.plain)
                .help("Общие детали интерфейса Веры: цвета, шрифты, рамки, плитки — VeraKit")
            Spacer()
            if let u = model.accountUsage, !u.windows.isEmpty { usageLabel(u); divider }
            if let r = model.resources { resourcesLabel(r) }
            if model.pluginSilent && !model.muted {
                Pill(text: "ПУЛЬС МОЛЧИТ", color: Theme.warn, strong: false)
                    .help("Журнал vera-pulse пуст: агент ещё ничего не делал или плагин не подключён.")
            }
            if case .failed = model.gatewayState { Pill(text: "ШЛЮЗ HERMES: \(model.gatewayState.title)", color: Theme.bad) }
            if model.lockStatus != .verified, model.lockStatus != .unknown { lockPill }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.black.opacity(0.16))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private var statusColor: Color {
        switch model.gatewayState {
        case .connected: model.pulse.stats.running.isEmpty ? .green : .orange
        case .failed: Theme.bad
        default: .gray
        }
    }

    @ViewBuilder private var lockPill: some View {
        let tag = model.lock?.tag ?? "?"
        switch model.lockStatus {
        case .verified:
            Pill(text: "HERMES \(tag) · ПРОВЕРЕН", color: Theme.ok, strong: false)
        case .unverified(let reasons):
            Pill(text: "HERMES · НЕ ПРОВЕРЕН", color: Theme.warn)
                .help(reasons.joined(separator: "\n") + "\nСм. docs/hermes-updates.md")
        case .unknown:
            Pill(text: "HERMES \(tag) · ?", color: .white.opacity(0.6), strong: false)
        }
    }

    /// As in Vera 2: the provider's plan used, window by window (5 h / week / month), green under 60 %, yellow to 85 %,
    /// red above; the hint has the windows and when they reset.
    private func usageLabel(_ u: AccountUsage) -> some View {
        HStack(spacing: 0) {
            Text(u.provider + " ").foregroundStyle(.white.opacity(0.6))
            ForEach(Array(u.windows.enumerated()), id: \.offset) { i, w in
                if i > 0 { Text("/").foregroundStyle(.white.opacity(0.6)) }
                if let used = w.usedPercent {
                    Text("\(Int(used.rounded()))%").foregroundStyle(Theme.usage(used))
                } else {
                    Text("—").foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .font(.mono(9, .semibold)).tracking(0.8)
        .help(Self.usageHelp(u))
    }

    static func usageHelp(_ u: AccountUsage) -> String {
        let lines = u.windows.map { w in
            "\(AccountUsage.shortLabel(w.label)): \(w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "нет данных")"
                + (w.resetAt.map { " · сброс \($0.formatted(.dateTime.day().month().hour().minute()))" } ?? "")
        }
        return (["Лимиты \(u.plan ?? u.provider) — читает Hermes (/usage)"] + lines + (u.unavailable.map { [$0] } ?? [])).joined(separator: "\n")
    }

    /// Memory and CPU of Vera's process tree and of Hermes' gateway tree.
    private func resourcesLabel(_ r: ProcessResources.Reading) -> some View {
        Text("\(ProcessResources.memoryText(r.memoryBytes)) · CPU \(Int(r.cpuPercent.rounded()))%")
            .font(.mono(9, .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.6))
            .help((["Процессов: \(r.processCount)"] + r.groups.map {
                "\($0.name): \(ProcessResources.memoryText($0.memoryBytes)) · CPU \(Int($0.cpuPercent.rounded()))% · процессов \($0.processCount)"
            }).joined(separator: "\n"))
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 12) }

    // MARK: Footer

    /// Only when something is wrong: the last problem, in one line.
    @ViewBuilder private var footer: some View {
        if let problem = model.lastProblem {
            HStack(spacing: 8) {
                Circle().fill(Theme.bad).frame(width: 6, height: 6)
                Text(problem).font(.mono(9)).foregroundStyle(Theme.bad.opacity(0.85)).lineLimit(1).truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Color.black.opacity(0.2))
        }
    }
}

/// The window's top-right corner over the board: the scale with «100 %» (when it is not 100 %) and the legend, which
/// folds to a button (remembered).
struct BoardCorner: View {
    var zoom: BoardZoom?
    @AppStorage("vera.board.legend") private var legend = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                if let zoom, zoom.scale != 1 {
                    Text("\(Int((zoom.scale * 100).rounded())) %").font(.mono(9, .semibold)).foregroundStyle(.white.opacity(0.7))
                    CapsuleButton(text: "100 %") { zoom.reset() }
                }
                CapsuleButton(text: legend ? "легенда ▴" : "легенда ▾", color: .white.opacity(0.7)) { legend.toggle() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Theme.background.opacity(0.85)))
            if legend { BoardLegend().fixedSize().background(Theme.background.opacity(0.95), in: RoundedRectangle(cornerRadius: 12)) }
        }
    }
}

/// The board scrolls as before (wheel, trackpad) and is also dragged like a map: press and pull — with a finger on an
/// iPad (Sidecar), a stylus or the mouse, where macOS scroll views do not move. Buttons and text fields keep their
/// clicks: the drag starts only after the pointer moved a few points.
/// Zoom: ⌘ + wheel or a trackpad pinch, around the pointer; ⌘0 — back to 100 %. Space held (as in Figma): the pointer
/// is a hand («drag the canvas»), a closed one while dragging.
struct PannableBoard<Content: View>: View {
    var zoom: BoardZoom
    @ViewBuilder let content: () -> Content

    var body: some View {
        @Bindable var zoom = zoom
        ScrollView([.horizontal, .vertical]) {
            content()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { zoom.natural = $0 }
                .scaleEffect(zoom.scale, anchor: .topLeading)
                .frame(width: zoom.natural.width * zoom.scale, height: zoom.natural.height * zoom.scale, alignment: .topLeading)
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { v in zoom.drag(v.translation) }
                    .onEnded { _ in zoom.dragEnded() })
        }
        .scrollPosition($zoom.position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, g in zoom.laidOut(g) }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { zoom.frame = $0 }
        .onContinuousHover { phase in if case .active = phase { zoom.inside = true } else { zoom.inside = false } }
        .pointerStyle((zoom.space || zoom.command) && zoom.inside || zoom.dragging ? (zoom.dragging ? .grabActive : .grabIdle) : nil)
        .onAppear { zoom.install() }
        .onDisappear { zoom.uninstall() }
    }
}

/// The board's zoom and drag: the scale, the scroll position, and the AppKit event monitors (⌘ + wheel, pinch, ⌘0,
/// space for the hand) — SwiftUI has no ⌘ + wheel of its own.
/// No flicker: wheel ticks are gathered and applied once per pass, and the scroll offset for the new scale is set in the
/// same layout pass that gives the content its new size (before, it came a frame later — a frame at the new scale with
/// the old offset, the board jumping back and forth).
@MainActor @Observable
final class BoardZoom {
    var position = ScrollPosition(x: 0, y: 0)
    var scale: CGFloat = 1
    var natural: CGSize = .zero
    var space = false
    var command = false
    /// A hand drag (space or ⌘ held): the window point where the button went down.
    @ObservationIgnored private var handFrom: CGPoint?
    var inside = false
    var dragging = false
    @ObservationIgnored var geometry: ScrollGeometry?
    /// The scroll view in window coordinates (top-left origin).
    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored private var start: CGPoint?
    @ObservationIgnored private var monitors: [Any] = []
    /// The offset wanted for the new scale, set once the content has that size.
    @ObservationIgnored private var pending: (offset: CGPoint, size: CGSize)?
    /// Wheel ticks not applied yet: the factor and the pointer.
    @ObservationIgnored private var gathered: (factor: CGFloat, at: CGPoint)?
    static let range: ClosedRange<CGFloat> = 0.3 ... 2.5

    func laidOut(_ g: ScrollGeometry) {
        geometry = g
        guard let p = pending, abs(g.contentSize.width - p.size.width) < 1, abs(g.contentSize.height - p.size.height) < 1 else { return }
        pending = nil
        scrollTo(p.offset, content: g.contentSize, container: g.containerSize)
    }

    func drag(_ t: CGSize) {
        guard let g = geometry else { return }
        dragging = true
        let from = start ?? g.contentOffset
        start = from
        scrollTo(CGPoint(x: from.x - t.width, y: from.y - t.height), content: g.contentSize, container: g.containerSize)
    }

    func dragEnded() { start = nil; dragging = false }

    private func scrollTo(_ p: CGPoint, content: CGSize, container: CGSize) {
        let maxX = max(0, content.width - container.width), maxY = max(0, content.height - container.height)
        position.scrollTo(point: CGPoint(x: min(maxX, max(0, p.x)), y: min(maxY, max(0, p.y))))
    }

    /// New scale, keeping the point of the board under `pointer` (scroll-view coordinates) where it is.
    func zoom(to wanted: CGFloat, at pointer: CGPoint) {
        guard let g = geometry else { return }
        let new = min(Self.range.upperBound, max(Self.range.lowerBound, wanted))
        guard abs(new - scale) > 0.0001 else { return }
        // From the offset already asked for, if the last step has not been laid out yet.
        let o = pending?.offset ?? g.contentOffset
        let point = CGPoint(x: (o.x + pointer.x) / scale, y: (o.y + pointer.y) / scale)
        scale = new
        let size = CGSize(width: natural.width * new, height: natural.height * new)
        pending = (CGPoint(x: point.x * new - pointer.x, y: point.y * new - pointer.y), size)
    }

    /// Gathers ticks; applied once when the run loop comes round (a fast wheel sends many per frame).
    private func gather(_ factor: CGFloat, at p: CGPoint) {
        if let g = gathered { gathered = (g.factor * factor, p); return }
        gathered = (factor, p)
        DispatchQueue.main.async { [self] in
            guard let g = gathered else { return }
            gathered = nil
            zoom(to: scale * g.factor, at: g.at)
        }
    }

    func reset() {
        guard scale != 1, let g = geometry else { return }
        zoom(to: 1, at: CGPoint(x: g.containerSize.width / 2, y: g.containerSize.height / 2))
    }

    /// A point of the window (top-left origin) in the scroll view, nil when it is outside.
    private func inView(_ p: CGPoint) -> CGPoint? {
        guard frame.contains(p) else { return nil }
        return CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
    }

    /// Zoom by `factor` at a window point; false when the point is outside (the event goes on).
    private func zoomBy(_ factor: CGFloat, window p: CGPoint) -> Bool {
        guard let at = inView(p) else { return false }
        gather(factor, at: at)
        return true
    }

    private func hand(_ type: NSEvent.EventType, at p: CGPoint, command: Bool) -> Bool {
        switch type {
        case .leftMouseDown:
            guard space || command, inView(p) != nil else { return false }
            handFrom = p
            dragging = true
            return true
        case .leftMouseDragged:
            guard let from = handFrom else { return false }
            drag(CGSize(width: p.x - from.x, height: p.y - from.y))
            return true
        default:
            guard handFrom != nil else { return false }
            handFrom = nil
            dragEnded()
            return true
        }
    }

    /// Space is the hand unless someone types: a text field (its field editor) has the keyboard.
    private static func typing(_ e: NSEvent) -> Bool { e.window?.firstResponder is NSText }

    private static func windowPoint(_ e: NSEvent) -> CGPoint? {
        guard let view = e.window?.contentView else { return nil }
        return CGPoint(x: e.locationInWindow.x, y: view.frame.height - e.locationInWindow.y)
    }

    func install() {
        guard monitors.isEmpty else { return }
        let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard e.modifierFlags.contains(.command), let self, let p = Self.windowPoint(e) else { return e }
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            let used = MainActor.assumeIsolated { self.zoomBy(exp(dy / 300), window: p) }
            return used ? nil : e
        }
        let pinch = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] e in
            guard let self, let p = Self.windowPoint(e) else { return e }
            let m = e.magnification
            let used = MainActor.assumeIsolated { self.zoomBy(1 + m, window: p) }
            return used ? nil : e
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.type == .keyDown, mods == .command, e.charactersIgnoringModifiers == "0" {
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard self.scale != 1 else { return false }
                    self.reset(); return true
                }
                return used ? nil : e
            }
            // Space: held — the hand; the key itself is kept from buttons (a focused one would be pressed).
            guard e.keyCode == 49, mods.isEmpty || e.type == .keyUp, !Self.typing(e) else { return e }
            let down = e.type == .keyDown
            MainActor.assumeIsolated { if self.space != down { self.space = down } }
            return nil
        }
        // The window loses the keyboard while space is held: no key-up comes, the hand must not stick.
        let resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.space = false }
        }
        let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let on = e.modifierFlags.contains(.command)
            MainActor.assumeIsolated { if self?.command != on { self?.command = on } }
            return e
        }
        // The hand: with space or ⌘ held the mouse drags the canvas anywhere — over tiles and buttons too, which a
        // SwiftUI drag on the board cannot (the tiles' own gestures win). These clicks never reach the tiles.
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self, let p = Self.windowPoint(e) else { return e }
            let held = e.modifierFlags.contains(.command)
            let used = MainActor.assumeIsolated { self.hand(e.type, at: p, command: held) }
            return used ? nil : e
        }
        monitors = [wheel, pinch, keys, flags, mouse].compactMap { $0 }
        observers = [resign]
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
}
