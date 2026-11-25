import Foundation

/// Where a typed slash command goes on a gateway-owned session — the same routing as Hermes' own client for the shared
/// gateway (`hermes_cli/gateway_chat_view.py` + `gateway_chat_commands.py`, `gateway_mutations.slash_mutation`).
///
/// The gateway's `slash.exec` runs reports and plugin/skill commands, but refuses by design what changes the session
/// (`unsupported_command`): the client turns those into `session.mutate` (model, compress, branch, rename, rewind),
/// `session.interrupt` (stop) or `config.set` (yolo). Sent as plain `slash.exec`, they all failed.
public enum GatewayCommand: Sendable, Equatable {
    /// `/stop`: interrupt the running turn.
    case interrupt
    /// `session.mutate` with this operation and payload (fenced by the session's revision; `rename` has no generation).
    /// `confirmed`: the owner already said yes to Hermes' guard (`/model … --yes`) — a guarded model switch (a large
    /// context re-read uncached, a cost or data policy) is re-sent once with Hermes' confirm token.
    case mutate(operation: String, payload: [String: JSONValue], confirmed: Bool = false)
    /// `/undo [N]` (the removed message back into the composer) and `/retry` (the last message sent again):
    /// `session.mutate` `rewind` to the N-th user turn from the end.
    case rewind(turns: Int, retry: Bool)
    /// `/yolo [on|off]`: this session's approval bypass (`config.set`, key `yolo`); nil — show it.
    case yolo(on: Bool?)
    case help
    /// `/model` without a name: the session's current model.
    case showModel
    /// Not offered in Vera — the reason, in words.
    case unavailable(String)
    /// Everything else: `slash.exec` (reports, plugin and skill commands, aliases the gateway resolves).
    case exec(String)
    case problem(String)

    /// Hermes' table of what the shared gateway runs.
    public static let parityDoc = "https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-command-parity"
    /// Operations without a generation fence (metadata), as in `gateway_mutations._METADATA`.
    public static let metadataOperations: Set<String> = ["rename"]
    /// A compression answers after its summary and commit (`COMPRESS_RPC_TIMEOUT`).
    public static let compressTimeout: Double = 660

    public static func route(_ line: String) -> GatewayCommand {
        let command = line.trimmingCharacters(in: .whitespaces).drop { $0 == "/" }
        let name = String(command.prefix { !$0.isWhitespace }).lowercased()
        let rest = String(command.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        switch name {
        case "stop": return .interrupt
        case "model": return model(rest)
        case "compress", "compact": return compress(rest)
        case "branch", "fork":
            return .unavailable("/\(name): ветка — это новая сессия, а у Веры разговор один")
        case "title": return rest.isEmpty ? .exec("title") : .mutate(operation: "rename", payload: ["title": .string(rest)])
        case "undo":
            guard rest.isEmpty || (Int(rest).map { $0 > 0 } ?? false) else { return .problem("так: /undo [N]") }
            return .rewind(turns: Int(rest) ?? 1, retry: false)
        case "retry": return .rewind(turns: 1, retry: true)
        case "yolo":
            switch rest.lowercased() {
            case "": return .yolo(on: nil)
            case "on": return .yolo(on: true)
            case "off": return .yolo(on: false)
            default: return .problem("так: /yolo [on|off]")
            }
        case "help": return .help
        case "new", "clear", "reset":
            return .unavailable("/\(name): у Веры разговор один — новая сессия не создаётся")
        case "quit", "exit":
            return .unavailable("/\(name): окно Веры не отключается командой")
        default:
            return .exec(String(command))
        }
    }

    /// `/model <model> [--provider name]` (`parse_model_flags_detailed`): `--global`, `--once`, `--refresh` are the
    /// terminal's; the gateway takes a session-scoped switch only.
    static func model(_ rest: String) -> GatewayCommand {
        var tokens = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        var provider: String?
        let confirmed = tokens.contains("--yes")
        tokens.removeAll { $0 == "--yes" }
        if let i = tokens.firstIndex(where: { $0 == "--provider" }) {
            guard i + 1 < tokens.count else { return .problem("так: /model <модель> [--provider имя]") }
            provider = tokens[i + 1]
            tokens.removeSubrange(i...(i + 1))
        } else if let i = tokens.firstIndex(where: { $0.hasPrefix("--provider=") }) {
            provider = String(tokens[i].dropFirst("--provider=".count))
            tokens.remove(at: i)
        }
        if tokens.contains(where: { $0.hasPrefix("--") }) {
            return .problem("/model: в общем шлюзе только смена модели этой сессии (без --global, --once)")
        }
        guard let model = tokens.first, tokens.count == 1 else {
            return tokens.isEmpty ? .showModel : .problem("так: /model <модель> [--provider имя]")
        }
        var payload: [String: JSONValue] = ["model": .string(model)]
        if let provider, !provider.isEmpty { payload["provider"] = .string(provider) }
        return .mutate(operation: "model", payload: payload, confirmed: confirmed)
    }

    /// `/compress [here [N] | --keep N | <focus>] [--preview]` (`parse_compress_args`); `--aggressive` is refused.
    static func compress(_ rest: String) -> GatewayCommand {
        var preview = false
        var kept: [String] = []
        for t in rest.split(whereSeparator: \.isWhitespace).map(String.init) {
            switch t.lowercased() {
            case "--preview", "--dry-run", "--dryrun": preview = true
            case "--aggressive": return .problem("/compress --aggressive: такого сжатия нет ни в одном клиенте Hermes")
            default: kept.append(t)
            }
        }
        var text = kept.joined(separator: " ")
        var lower = text.lowercased()
        if lower.hasPrefix("up to here") { text = String(text.dropFirst("up to ".count)); lower = text.lowercased() }
        let words = lower.split(separator: " ").map(String.init)
        var payload: [String: JSONValue] = [:]
        func keep(_ s: String) -> Int { min(max(Int(s) ?? 2, 1), 100) }
        if words.first == "here" {
            payload["partial"] = .bool(true); payload["keep_last"] = .number(Double(words.count > 1 ? keep(words[1]) : 2))
        } else if let h = words.first, h == "--keep" || h == "-k", words.count > 1 {
            payload["partial"] = .bool(true); payload["keep_last"] = .number(Double(keep(words[1])))
        } else if let h = words.first, h.hasPrefix("--keep=") {
            payload["partial"] = .bool(true); payload["keep_last"] = .number(Double(keep(String(h.dropFirst("--keep=".count)))))
        } else if !text.isEmpty {
            payload["focus"] = .string(text)
        }
        if preview { payload["preview"] = .bool(true) }
        return .mutate(operation: "compress", payload: payload)
    }

    /// The user turns a rewind can target (`gateway_chat_commands._user_turns`): live user rows with a durable id,
    /// typed by a person (no display-only kind other than a steer), not archived by a compression.
    public static func userTurnIds(_ snapshot: JSONValue) -> [Int] {
        (snapshot["messages"]?.array ?? []).compactMap { row in
            guard row["role"]?.string == "user", let id = row["row_id"]?.number, id == id.rounded(),
                  row["archived"]?.bool != true else { return nil }
            let kind = row["display_kind"]?.string ?? ""
            guard kind.isEmpty || kind == "steer" else { return nil }
            return Int(id)
        }
    }

    public static let helpText = """
    Команды разговора (как у клиента Hermes для общего шлюза):
    /stop — прервать ход · /model <модель> [--provider имя] [--yes] — модель этой сессии (--yes — согласие на предупреждение Hermes) · /compress [here [N] | тема] [--preview] — сжать историю
    /title [название] · /undo [N] — вернуть последнее сообщение в поле · /retry — отправить его заново
    /yolo [on|off] — разрешения без вопросов в этой сессии · /usage, /tools и остальные отчёты — выполняет шлюз.
    Новая сессия и ветка (/new, /branch) у Веры не создаются: разговор один. Что умеет общий шлюз: \(parityDoc)
    """
}
