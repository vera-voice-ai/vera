import Foundation
import Observation

/// The automations that can be switched off, from the Core panel or by a voice command. Every switch is on by
/// default, so nothing changes until the owner turns one off. A switch is stored under `VeraAutomation.<id>` in the
/// given defaults; without defaults (nil) it is kept in memory only, which is what tests and a fresh agent use.
@Observable
public final class AutomationSwitches: @unchecked Sendable {
    public static let quietHours = "quiet.hours"
    public static let modeTimers = "mode.timers"
    public static let silenceOption = "silence.option"
    public static let replyWindow = "reply.window"
    public static let keyPrefix = "VeraAutomation."

    private let defaults: UserDefaults?
    private let lock = NSLock()
    /// Values set during this run. Read first, so every change is seen at once by the observing panel.
    private var values: [String: Bool] = [:]

    public init(defaults: UserDefaults? = nil) { self.defaults = defaults }

    /// True unless the owner has switched the automation off. Unknown ids are on.
    public func isOn(_ id: String) -> Bool {
        if let value = lock.withLock({ values[id] }) { return value }
        if let stored = defaults?.object(forKey: Self.keyPrefix + id) as? Bool { return stored }
        return true
    }

    public func set(_ id: String, _ on: Bool) {
        lock.withLock { values[id] = on }
        defaults?.set(on, forKey: Self.keyPrefix + id)
    }
}
