import AppKit
import SwiftUI
import HermesBridge

/// «Настройка»: everything the owner used to do in the console — provider, key, model, gateway, data folders.
struct SetupView: View {
    @Bindable var setup: SetupModel
    var scrollable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                ModuleContour(name: "hermes/providers", title: "Провайдер", color: Theme.llm,
                              trailing: "\(setup.providers.filter(\.authenticated).count) с ключом", origin: .hermes("СПИСОК HERMES")) {
                    providerList
                }
                .frame(width: 330)
                VStack(alignment: .leading, spacing: 16) {
                    ModuleContour(name: "hermes/model", title: "Ключ и модель", color: Theme.llm, origin: .hermes("HERMES + НАШ vera-setup")) { details }
                    HStack(alignment: .top, spacing: 16) {
                        ModuleContour(name: "hermes/gateway", title: "Шлюз", color: Theme.gateway, origin: .hermes()) { gateway }
                        ModuleContour(name: "storage", title: "Данные Веры", color: Theme.memory, origin: .ours) { data }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 600)
            }
            if let m = setup.message {
                Text(m.text).font(.mono(10)).foregroundStyle(m.ok ? Theme.ok : Theme.bad)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 640, alignment: .topLeading)
        .background(Theme.background)
        .task { await setup.load() }
        .onChange(of: setup.board.gatewayState) { _, state in
            if state == .connected { Task { await setup.load() } }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)).frame(width: 31, height: 31)
                Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Text("НАСТРОЙКА HERMES").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.91))
            if let configured = setup.configured {
                Pill(text: configured ? "ПРОВАЙДЕР НАСТРОЕН" : "НУЖЕН КЛЮЧ МОДЕЛИ", color: configured ? Theme.ok : Theme.warn, strong: !configured)
            }
            Spacer()
            if setup.busy { ProgressView().controlSize(.small) }
            Button("Обновить") { Task { await setup.load() } }.buttonStyle(.plain).font(.mono(10)).foregroundStyle(Theme.accent)
        }
    }

    // MARK: Providers

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("поиск провайдера", text: $setup.filter)
                .textFieldStyle(.plain).font(.mono(10))
                .padding(7).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            MaybeScroll(scrollable: scrollable) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(setup.visibleProviders.prefix(scrollable ? 500 : 18)) { p in
                        Button { setup.selectedSlug = p.slug } label: { providerRow(p) }.buttonStyle(.plain)
                    }
                }
            }
            if setup.providers.isEmpty {
                EmptyNote(text: "Список придёт от шлюза Hermes после подключения.")
            }
        }
    }

    private func providerRow(_ p: SetupModel.Provider) -> some View {
        HStack(spacing: 7) {
            Circle().fill(p.authenticated ? Theme.ok : .white.opacity(0.18)).frame(width: 6, height: 6)
            Text(p.name).font(.system(size: 11, weight: p.isCurrent ? .semibold : .regular))
                .foregroundStyle(.white.opacity(p.takesKey || p.authenticated ? 0.85 : 0.4)).lineLimit(1)
            Spacer()
            if p.isCurrent { Text("текущий").font(.mono(8)).foregroundStyle(Theme.llm) }
            else if !p.takesKey && !p.authenticated { Text(authWord(p.authType)).font(.mono(8)).foregroundStyle(.white.opacity(0.3)) }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(setup.selectedSlug == p.slug ? Theme.llm.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func authWord(_ type: String) -> String {
        switch type {
        case "api_key": "ключ"
        case "oauth_device_code", "oauth": "вход OAuth"
        default: type
        }
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyValue(key: "сейчас", value: setup.currentModel.isEmpty ? "модель не выбрана" : "\(setup.currentModel) · \(setup.currentProvider)",
                     valueColor: setup.currentModel.isEmpty ? Theme.warn : Theme.ok)
            if let p = setup.selected {
                InnerCard(tint: Theme.llm) {
                    HStack {
                        Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        Text(p.slug).font(.mono(9)).foregroundStyle(Theme.llm.opacity(0.7))
                        Spacer()
                        Text(p.authenticated ? "ключ есть" : "ключа нет").font(.mono(9))
                            .foregroundStyle(p.authenticated ? Theme.ok : Theme.warn)
                    }
                    if p.takesKey {
                        SectionLabel(text: p.authenticated ? "заменить: \(p.keyName)" : p.keyName, color: Theme.llm)
                        HStack {
                            SecureField(p.authenticated ? "вставь новый ключ — старый заменится" : "вставь ключ", text: $setup.keyDraft)
                                .textFieldStyle(.plain).font(.mono(11))
                                .padding(7).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                .onSubmit { Task { await setup.saveKey() } }
                            Button("Сохранить") { Task { await setup.saveKey() } }
                                .disabled(setup.keyDraft.isEmpty || setup.busy)
                        }
                        Text("Хранится только в данных Hermes Веры; после сохранения не показывается.")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    } else if !p.authenticated {
                        Text("Этот провайдер входит через \(authWord(p.authType)) — в Вере пока не поддержан. Выбери провайдера с ключом.")
                            .font(.system(size: 10)).foregroundStyle(Theme.warn.opacity(0.85))
                    }
                }
                if p.authenticated {
                    InnerCard(tint: Theme.llm) {
                        SectionLabel(text: "модель по умолчанию", color: Theme.llm)
                        let models = (p.featured + p.models.filter { !p.featured.contains($0) })
                        if models.isEmpty {
                            HStack {
                                TextField("имя модели", text: $setup.selectedModel)
                                    .textFieldStyle(.plain).font(.mono(11))
                                    .padding(7).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                            }
                        } else {
                            Picker("", selection: $setup.selectedModel) {
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                        HStack {
                            Button("Сделать моделью по умолчанию") { Task { await setup.applyModel() } }
                                .disabled(setup.selectedModel.isEmpty || setup.busy)
                        }
                        if let confirm = setup.pendingConfirm {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Hermes предупреждает:").font(.mono(9, .semibold)).foregroundStyle(Theme.warn)
                                Text(confirm).font(.system(size: 10)).foregroundStyle(Theme.warn)
                                Text("«Да» — подтверждение только для Hermes: он запишет эту модель. Если провайдер требует согласия (например, OpenCode Go для моделей, обучающихся на запросах), его включают отдельно — на сайте провайдера, в организации ключа. Иначе провайдер ответит HTTP 400; ссылку на нужную страницу он присылает в ошибке, Вера покажет её в чате.")
                                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("Да, записать модель") { Task { await setup.applyModel(confirmed: true) } }
                                    Button("Нет") { setup.cancelConfirm() }
                                }
                            }
                            .padding(8).background(Theme.warn.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            } else {
                EmptyNote(text: "Выбери провайдера слева.")
            }
        }
    }

    // MARK: Gateway and data

    private var gateway: some View {
        let b = setup.board
        return VStack(alignment: .leading, spacing: 7) {
            KeyValue(key: "состояние", value: b.gatewayState.title,
                     valueColor: b.gatewayState == .connected ? Theme.ok : Theme.warn)
            KeyValue(key: "версия", value: b.install?.stableTag ?? b.install?.versionLine ?? "—")
            KeyValue(key: "плагин", value: b.pluginState)
            Button("Перезапустить шлюз") { Task { await b.restartGateway() } }
                .disabled(b.gatewayState == .attaching)
        }
    }

    private var data: some View {
        let r = setup.board.runtime
        return VStack(alignment: .leading, spacing: 7) {
            KeyValue(key: "Hermes", value: r.payloadDescription)
            KeyValue(key: "данные", value: r.dataRoot.path(percentEncoded: false))
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.dataRoot]) }
        }
    }
}
