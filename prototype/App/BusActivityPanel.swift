import SignalBus
import SwiftUI

struct BusActivityPanel: View {
    let monitor: BusMonitorModel
    @State private var pausedActivity: [BusSecond]?
    private let accent = Color(red: 0.25, green: 0.80, blue: 0.95)
    private let lanes: [(SignalDomain, String, Color)] = [
        (.sensors, "Sensors", Color(hex: 0x38BDF8)),
        (.scene, "Scene", Color(hex: 0xA78BFA)),
        (.core, "Core", Color(hex: 0xFACC15)),
        (.response, "Response", Color(hex: 0x4ADE80))
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activity = pausedActivity ?? monitor.activity(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                header
                metrics(activity)
                timeline(activity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.065, green: 0.067, blue: 0.095),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(accent)
            Text("vera-bus · Vera Signal Bus")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Button {
                if pausedActivity == nil {
                    pausedActivity = monitor.activity(at: .now)
                } else {
                    pausedActivity = nil
                }
            } label: {
                Label(pausedActivity == nil ? "Вживую" : "Пауза",
                      systemImage: pausedActivity == nil ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pausedActivity == nil ? .green : .orange)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(pausedActivity == nil ? "Остановить график" : "Продолжить обновление графика")
        }
    }

    private func metrics(_ activity: [BusSecond]) -> some View {
        let current = activity.last
        let traffic = activity.map(\.bytes)
        return HStack(spacing: 12) {
            metric("\(current?.messages ?? 0)", label: "сообщений/с", help: "За последнюю завершённую секунду")
            metric("\(activity.map(\.messages).max() ?? 0)", label: "пик сообщ./с", help: "Максимум за показанные 30 секунд")
            let byteRate = ByteCountFormatter.string(fromByteCount: Int64(current?.bytes ?? 0), countStyle: .decimal)
            metric("\(byteRate)/с", label: "объём JSON", help: "Сумма размеров сообщений при сериализации в JSON за последнюю завершённую секунду")
            bars(traffic, color: accent, showSinglesAsDots: false)
                .frame(width: 88, height: 26)
                .accessibilityLabel("История объёма JSON за 30 секунд")
        }
        .padding(10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ value: String, label: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    private func timeline(_ activity: [BusSecond]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Временная шкала").font(.system(size: 12, weight: .semibold))
                Text("Последние 30 с").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(lanes, id: \.0) { domain, name, color in
                let values = activity.map { $0.counts[domain, default: 0] }
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(name).font(.system(size: 10, weight: .medium))
                    }
                    .frame(width: 70, alignment: .leading)
                    bars(values, color: color, showSinglesAsDots: true)
                        .frame(height: 28)
                        .accessibilityLabel("\(name), \(values.reduce(0, +)) сообщений за 30 секунд")
                }
            }
            HStack {
                Text("−30 с")
                Spacer()
                Text("−20 с")
                Spacer()
                Text("−10 с")
                Spacer()
                Text(pausedActivity == nil ? "Сейчас" : "Пауза")
            }
            .padding(.leading, 78)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }

    private func bars(_ values: [Int], color: Color, showSinglesAsDots: Bool) -> some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            let peak = CGFloat(max(values.max() ?? 0, 2))
            let baseline = size.height - 2
            if showSinglesAsDots {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: baseline))
                grid.addLine(to: CGPoint(x: size.width, y: baseline))
                for tick in [0, 10, 20, 30] {
                    let x = min(size.width - 0.5, max(0.5, CGFloat(tick) * step))
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: baseline))
                }
                context.stroke(grid, with: .color(.white.opacity(0.09)), lineWidth: 1)
            }

            for (index, value) in values.enumerated() where value > 0 {
                let x = (CGFloat(index) + 0.5) * step
                let width = max(1, min(step * 0.68, 10))
                if showSinglesAsDots && value == 1 {
                    let diameter = min(width, 5)
                    let dot = CGRect(x: x - diameter / 2, y: baseline - diameter,
                                     width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                } else {
                    let height = max(2, baseline * CGFloat(value) / peak)
                    let bar = CGRect(x: x - width / 2, y: baseline - height, width: width, height: height)
                    context.fill(Path(roundedRect: bar, cornerRadius: min(2, width / 2)),
                                 with: .color(color.opacity(0.85)))
                }
            }
        }
    }
}
