import SwiftUI

/// Инструменты: the strong tools Vera calls on request (codex, claude). Analyzers run on streams; a tool runs only when Core asks.
/// The panel shows what Core and the tools report on the bus, and decides nothing.
struct ToolsPanel: View {
    let model: ToolRunModel
    private let color = Color(hex: 0xFB923C)
    @State private var expanded = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ToolRunModel.knownTools, id: \.self) { tool in
                            toolSection(tool, now: context.date)
                        }
                        placeholderRow("картинки")
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                        Text("Инструменты").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                        Text("вызываются по запросу Core").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
    }

    private func toolSection(_ tool: String, now: Date) -> some View {
        let runs = model.runs.filter { $0.tool == tool }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor(model.lastState(of: tool))).frame(width: 7, height: 7)
                Text(tool).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 0)
                Text("сегодня: \(model.runsToday(tool))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            if runs.isEmpty {
                Text("ещё не запускалась").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 15)
            } else {
                ForEach(runs.prefix(4)) { run in
                    runRow(run, now: now)
                }
            }
        }
    }

    private func runRow(_ run: ToolRunModel.Run, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(run.title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(stateText(run.state))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(stateColor(run.state))
                Text(ToolRunModel.format(model.elapsed(of: run, at: now)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            let detail = run.state == .running ? run.progressLine : run.summary
            if !detail.isEmpty {
                Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.leading, 15)
    }

    private func placeholderRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.gray).frame(width: 7, height: 7)
            Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
            Text("скоро").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 6).padding(.vertical, 2).background(.white.opacity(0.05), in: Capsule())
        }
    }

    /// Amber while a run is going; otherwise the newest run decides: green done, red failed, grey idle or cancelled.
    private func dotColor(_ state: ToolRunModel.State?) -> Color {
        switch state {
        case .running: return .orange
        case .done: return .green
        case .failed: return .red
        case .cancelled, .none: return .gray
        }
    }

    private func stateText(_ state: ToolRunModel.State) -> String {
        switch state {
        case .running: return "идёт"
        case .done: return "готово"
        case .failed: return "ошибка"
        case .cancelled: return "отменено"
        }
    }

    private func stateColor(_ state: ToolRunModel.State) -> Color {
        switch state {
        case .running: return .orange
        case .done: return .green.opacity(0.85)
        case .failed: return .red
        case .cancelled: return .white.opacity(0.5)
        }
    }
}
