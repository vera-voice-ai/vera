import SwiftUI

/// The UI kit window: every shared part of Vera's interface — colours, type scale, frames, tiles, badges — drawn in
/// its states on sample text, without Hermes or the microphone. Opened from the header («UI-КИТ»); snapshotted with
/// `Vera --snapshot-kit <file.png>`. A part that is shared goes into VeraKit and gets a row here.
public struct KitView: View {
    var scrollable: Bool
    public init(scrollable: Bool = true) { self.scrollable = scrollable }

    public var body: some View {
        MaybeScroll(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: 26) {
                header
                section("Цвета", "Theme · цвет владельца и цвета доменов") { colors }
                section("Шрифты", "VeraType · .veraType(_:)") { type }
                section("Границы", "partFrame · сплошная — подключённый код, пунктир — наш модуль") { frames }
                section("Плитки", "Plate · ModuleContour · InnerCard") { tiles }
                section("Метки и кнопки", "Pill · OriginBadge · CapsuleButton · SectionLabel") { badges }
                section("Данные", "Stat · KeyValue · EmptyNote · Format") { data }
                section("Сфера", "ParticleSphere · покой и «говорит» с громкостью голоса") { sphere }
            }
            .padding(28)
            .frame(width: 940, alignment: .leading)
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(Theme.vera).frame(width: 8, height: 8)
                Text("UI-кит Веры").veraType(.title).foregroundStyle(Theme.textPrimary)
                OriginBadge(origin: .ours)
            }
            Text("VeraKit — общие детали интерфейса Мака и телефона. Новый цвет, шрифт или повторяющаяся деталь — сюда, не в панель.")
                .veraType(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func section<C: View>(_ title: String, _ api: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionLabel(text: title, color: Theme.vera)
                Text(api).veraType(.data).foregroundStyle(Theme.textFaint)
            }
            content()
        }
    }

    private var colors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: 4), spacing: 10) {
            ForEach(Theme.palette, id: \.name) { c in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 6).fill(c.color).frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).veraType(.data).foregroundStyle(Theme.textPrimary)
                        Text(c.meaning).veraType(.caption).foregroundStyle(Theme.textFaint).lineLimit(2)
                    }
                }
            }
        }
    }

    private var type: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(VeraType.allCases, id: \.self) { t in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("." + t.rawValue).veraType(.data).foregroundStyle(Theme.textFaint).frame(width: 70, alignment: .leading)
                    Text(t.sample).veraType(t).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var frames: some View {
        HStack(spacing: 14) {
            frameSample("Hermes", "подключённый код", Theme.hermes, dashed: false)
            frameSample("Провайдер", "подключённый код", Theme.llm, dashed: false)
            frameSample("Уши", "наш модуль", Theme.vera, dashed: true)
            frameSample("Разговоры", "наш модуль, цвет домена", Theme.session, dashed: true)
        }
    }

    private func frameSample(_ title: String, _ note: String, _ color: Color, dashed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).veraType(.title).foregroundStyle(Theme.textPrimary)
            Text(note).veraType(.caption).foregroundStyle(Theme.textFaint)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .partFrame(color, dashed: dashed)
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
            Plate(title: "Голос", color: Theme.vera, origin: .ours, lines: ["Silero baya · 48 кГц", "говорит: «Да, слышу»"],
                  footer: "озвучено за 0.4 с", state: Theme.ok, button: ("⚙ голос", {}))
                .frame(width: 284, height: 150)
            Plate(title: "Провайдер", color: Theme.llm, origin: .hermes(), lines: ["opencode-go", "deepseek-v4.1-flash"],
                  footer: "ключ задан", button: ("⚙ настроить", {}))
                .frame(width: 284, height: 150)
            Plate(title: "Telegram", color: Theme.session, origin: .hermes("HERMES · ПЛАТФОРМА"), lines: ["не подключён"],
                  footer: "", dim: true)
                .frame(width: 284, height: 150)
        }
            ModuleContour(name: "vera/ears", title: "Уши", color: Theme.vera, trailing: "GigaAM v3", origin: .ours) {
                InnerCard(tint: Theme.vera) {
                    SectionLabel(text: "Микрофон")
                    KeyValue(key: "движок", value: "GigaAM v3 · sherpa-onnx")
                    KeyValue(key: "задержка", value: Format.ms(231), valueColor: Theme.ok)
                }
            }
            .frame(width: 440, height: 150)
        }
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Pill(text: "РЕШЕНИЯ")
                Pill(text: "HERMES v0.23.3 · ПРОВЕРЕН", color: Theme.ok, strong: false)
                Pill(text: "ПУЛЬС МОЛЧИТ", color: Theme.warn, strong: false)
                Pill(text: "ШЛЮЗ HERMES: ОШИБКА", color: Theme.bad)
            }
            HStack(spacing: 10) {
                OriginBadge(origin: .ours)
                OriginBadge(origin: .hermes())
                OriginBadge(origin: .plugin("vera-pulse"))
                CapsuleButton(text: "⚙ настроить", color: Theme.llm) {}
                CapsuleButton(text: "↻ перезапустить", color: Theme.gateway) {}
                SectionLabel(text: "Инструменты")
            }
        }
    }

    private var sphere: some View {
        HStack(spacing: 18) {
            ForEach([("покой", false), ("говорит", true)], id: \.0) { name, speaking in
                VStack(spacing: 4) {
                    ParticleSphere(speaking: speaking, voiceEnergy: speaking ? 0.7 : 0, particles: 5_000).frame(width: 150, height: 150)
                    Text(name).veraType(.data).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var data: some View {
        HStack(alignment: .top, spacing: 14) {
            InnerCard {
                HStack {
                    Stat(value: Format.count(18), label: "вызовов за час", color: Theme.tool)
                    Stat(value: Format.ms(1600), label: "ответ модели", color: Theme.llm)
                    Stat(value: Format.count(12_400), label: "токенов", color: Theme.memory)
                }
            }
            .frame(width: 440)
            InnerCard {
                KeyValue(key: "сессия", value: "Разговор · 51c812e3")
                KeyValue(key: "последний шаг", value: "skill_view · 12 мс")
                EmptyNote(text: "сегодня в сессии iPhone шагов не было")
            }
        }
    }
}
