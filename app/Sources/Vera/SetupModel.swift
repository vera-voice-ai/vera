import Foundation
import Observation
import HermesBridge

/// The «Настройка» window: provider and key through the gateway's own methods (`model.options`,
/// `model.save_key`, `setup.status`); the default model through `plugin.vera-setup.set_main_model` —
/// Hermes' `config.set model` works only inside a live session (4001), Desktop uses POST /api/model/set,
/// and the vera-setup plugin runs that same code path over Vera's socket.
/// The key travels over the local gateway socket only; it is never logged, printed or kept after saving.
@MainActor @Observable
final class SetupModel {
    struct Provider: Identifiable, Equatable {
        var id: String { slug }
        let slug: String
        let name: String
        let authType: String
        let keyEnv: String
        let authenticated: Bool
        let isCurrent: Bool
        let models: [String]
        let featured: [String]
        let warning: String?

        /// A key can be pasted (or replaced): key-based providers, and connected ones Hermes no longer describes
        /// (once a key is saved, `model.options` drops `auth_type`/`key_env` from the row).
        var takesKey: Bool { authType == "api_key" || (authenticated && authType.isEmpty) }
        var keyName: String { keyEnv.isEmpty ? "ключ \(name)" : keyEnv }
    }

    private(set) var providers: [Provider] = []
    private(set) var currentModel = ""
    private(set) var currentProvider = ""
    private(set) var configured: Bool?
    private(set) var busy = false
    private(set) var message: (text: String, ok: Bool)?
    private(set) var pendingConfirm: String?

    var selectedSlug: String? {
        didSet { if oldValue != selectedSlug { keyDraft = ""; selectedModel = defaultModel(for: selected) } }
    }
    var keyDraft = ""
    var selectedModel = ""
    var filter = ""

    let board: BoardModel

    init(board: BoardModel) { self.board = board }

    var selected: Provider? { providers.first { $0.slug == selectedSlug } }

    /// What the picker shows first: the model in use for the current provider, else the provider's featured one.
    private func defaultModel(for p: Provider?) -> String {
        guard let p else { return "" }
        if p.isCurrent, !currentModel.isEmpty { return currentModel }
        return p.featured.first ?? p.models.first ?? ""
    }

    var visibleProviders: [Provider] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? providers : providers.filter { $0.name.lowercased().contains(q) || $0.slug.contains(q) }
        return list.sorted { ($0.authenticated ? 0 : 1, $0.name) < ($1.authenticated ? 0 : 1, $1.name) }
    }

    func load() async {
        guard board.gatewayState == .connected else {
            message = ("Шлюз Hermes не подключён: \(board.gatewayState.title)", false)
            return
        }
        busy = true
        defer { busy = false }
        do {
            let options = try await board.call("model.options", ["include_unconfigured": .bool(true)], timeout: .seconds(30))
            providers = (options["providers"]?.array ?? []).compactMap(Self.provider)
            currentModel = options["model"]?.string ?? ""
            currentProvider = options["provider"]?.string ?? ""
            let status = try? await board.call("setup.status", [:])
            configured = status?["provider_configured"]?.bool
            if selectedSlug == nil {
                selectedSlug = (providers.first(where: \.isCurrent) ?? providers.first(where: \.authenticated))?.slug
            } else if selectedModel.isEmpty || !(selected.map { ($0.featured + $0.models).contains(selectedModel) } ?? false) {
                selectedModel = defaultModel(for: selected)
            }
        } catch {
            message = ("Не удалось прочитать провайдеров: \(error)", false)
        }
    }

    func saveKey() async {
        guard let p = selected, p.takesKey else { return }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await board.call("model.save_key", ["slug": .string(p.slug), "api_key": .string(key)], timeout: .seconds(30))
            keyDraft = ""
            message = ("Ключ \(p.keyName) сохранён в Hermes Веры", true)
            await load()
        } catch {
            // Never echo the key: the error text comes from the gateway, not from our params.
            keyDraft = ""
            message = ("Ключ не принят: \(error)", false)
        }
    }

    /// The profile default (config.yaml of Vera's Hermes), as Desktop's Settings → Models writes it.
    func applyModel(confirmed: Bool = false) async {
        guard let p = selected, !selectedModel.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await board.call("plugin.vera-setup.set_main_model", [
                "provider": .string(p.slug), "model": .string(selectedModel), "confirm": .bool(confirmed)
            ], timeout: .seconds(90))
            if result["confirm_required"]?.bool == true {
                pendingConfirm = result["confirm_message"]?.string ?? "Модель дорогая. Подтвердить?"
                return
            }
            pendingConfirm = nil
            guard result["ok"]?.bool == true else {
                message = ("Модель не применена: \(result["error"]?.string ?? result.description)", false)
                return
            }
            await load()
            let saved = currentModel == selectedModel
            message = saved ? ("Модель по умолчанию: \(selectedModel) · \(p.name)", true)
                            : ("Hermes ответил «ок», но текущая модель — «\(currentModel)». Проверь журнал шлюза.", false)
        } catch {
            message = ("Модель не применена: \(error)", false)
        }
    }

    func cancelConfirm() { pendingConfirm = nil }

    private static func provider(_ v: JSONValue) -> Provider? {
        guard let slug = v["slug"]?.string, let name = v["name"]?.string else { return nil }
        return Provider(slug: slug, name: name,
                        authType: v["auth_type"]?.string ?? "",
                        keyEnv: v["key_env"]?.string ?? "",
                        authenticated: v["authenticated"]?.bool ?? false,
                        isCurrent: v["is_current"]?.bool ?? false,
                        models: v["models"]?.array?.compactMap(\.string) ?? [],
                        featured: v["featured_models"]?.array?.compactMap(\.string) ?? [],
                        warning: v["warning"]?.string)
    }
}
