import Foundation

/// A fixed set of things she may do to the Mac: volume, music, opening an application, a notification. Each action is a
/// ready script with a checked value in it, run without a shell, so what she says cannot become a command.
struct MacControlTool: AgentTool {
    enum Plan: Equatable { case run(String, [String]), refuse(String) }

    var definition: ToolDefinition {
        ToolDefinition(name: "mac_control", description: "Control the Mac by action: volume_set (value 0-100), volume_get, mute, unmute, media_playpause, media_next, media_previous, now_playing (app: Music or Spotify, default Music), open_app (value: app name), notify (value: short text).",
                       parametersJSON: #"{"type":"object","properties":{"action":{"type":"string"},"value":{"type":"string"},"app":{"type":"string"}},"required":["action"]}"#)
    }

    static let mediaApps: Set<String> = ["Music", "Spotify"]

    /// What an action turns into. Pure, so every refusal can be tested without touching the Mac.
    static func plan(action: String, value: String?, app: String?) -> Plan {
        let osascript = "/usr/bin/osascript"
        let player = (app?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Music"
        guard mediaApps.contains(player) else { return .refuse("музыкальное приложение: Music или Spotify") }
        switch action {
        case "volume_set":
            guard let text = value?.trimmingCharacters(in: .whitespaces), let level = Int(text), (0...100).contains(level) else { return .refuse("громкость — число от 0 до 100") }
            return .run(osascript, ["-e", "set volume output volume \(level)"])
        case "volume_get": return .run(osascript, ["-e", "output volume of (get volume settings)"])
        case "mute": return .run(osascript, ["-e", "set volume output muted true"])
        case "unmute": return .run(osascript, ["-e", "set volume output muted false"])
        case "media_playpause": return .run(osascript, ["-e", "tell application \"\(player)\" to playpause"])
        case "media_next": return .run(osascript, ["-e", "tell application \"\(player)\" to next track"])
        case "media_previous": return .run(osascript, ["-e", "tell application \"\(player)\" to previous track"])
        case "now_playing":
            return .run(osascript, ["-e", "if application \"\(player)\" is running then tell application \"\(player)\" to return (name of current track) & \" — \" & (artist of current track)", "-e", "return \"не играет\""])
        case "open_app":
            guard let name = value?.trimmingCharacters(in: .whitespaces), (1...40).contains(name.count),
                  name.allSatisfy({ $0.isLetter || $0.isNumber || " .-_".contains($0) }) else { return .refuse("название приложения: буквы, цифры, пробел, точка и дефис") }
            return .run("/usr/bin/open", ["-a", name])
        case "notify":
            let text = (value ?? "").filter { $0 != "\"" && $0 != "\\" && !$0.isNewline }.prefix(100)
            guard !text.isEmpty else { return .refuse("нужен текст уведомления") }
            return .run(osascript, ["-e", "display notification \"\(text)\" with title \"Вера\""])
        default:
            return .refuse("такого действия нет")
        }
    }

    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let action = args["action"] as? String else { return ToolResult(ok: false, text: "bad arguments: need action") }
        let value = (args["value"] as? String) ?? (args["value"] as? Int).map(String.init) ?? (args["value"] as? Double).map { String(Int($0)) }
        switch Self.plan(action: action, value: value, app: args["app"] as? String) {
        case let .refuse(reason): return ToolResult(ok: false, text: "не сделала: \(reason)")
        case let .run(path, arguments):
            let result = ShellRunner.exec(path, arguments, timeout: 10, maxOutput: 400)
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolResult(ok: result.code == 0, text: result.code == 0 ? (text.isEmpty ? "готово" : text) : "не получилось: \(text)")
        }
    }
}

public extension ToolRegistry {
    static var macTools: ToolRegistry { ToolRegistry([MacControlTool()]) }
}
