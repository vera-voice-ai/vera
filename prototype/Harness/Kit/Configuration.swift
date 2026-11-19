import Foundation
import Scene

/// One variant of the scene's settings, replayed against the same scenario.
public struct Configuration: Sendable {
    public typealias Tweak = @Sendable (inout SceneTTL) -> Void

    public let name: String
    /// nil means the scenario default: `.recorded` when the recording has verdicts, otherwise `.none`.
    public let judge: Judge?
    public let tweak: Tweak

    public init(name: String, judge: Judge? = nil, _ tweak: @escaping Tweak = { _ in }) {
        self.name = name
        self.judge = judge
        self.tweak = tweak
    }

    /// The app's settings, with this configuration's change applied on top.
    public func ttl() -> SceneTTL {
        var ttl = Configuration.appSettings()
        ttl.initialCoreMode = "silent"   // recordings predate modes: only the activation phrase addresses her
        tweak(&ttl)
        return ttl
    }

    public func resolvedJudge(for scenario: Scenario) -> Judge {
        if let judge { return judge }
        return scenario.hasVerdicts ? .recorded : Judge.none
    }

    /// The same settings the app uses (see App/PrototypeModel.swift).
    public static func appSettings() -> SceneTTL { SceneTTL.app }
}
