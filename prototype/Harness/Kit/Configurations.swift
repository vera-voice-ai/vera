import Foundation

/// The default matrix. Every configuration is the app's settings plus one change.
public enum Configurations {
    public static let baseline = Configuration(name: "baseline")

    public static let all: [Configuration] = [
        baseline,
        Configuration(name: "noOwnerGate") { $0.requireOwnerPresent = false },
        Configuration(name: "hold8") { $0.maxHold = 8 },
        Configuration(name: "turnEndShortcut") { $0.turnEndShortcut = true },
        Configuration(name: "ownerStrict") { $0.ownerConfirmPosterior = 0.99 },
        Configuration(name: "ownerLoose") { $0.ownerConfirmPosterior = 0.90 },
        Configuration(name: "judgeRule", judge: .rule),
        Configuration(name: "judgeAlwaysComplete", judge: .alwaysComplete),
        Configuration(name: "judgeAlwaysContinue", judge: .alwaysContinue),
        Configuration(name: "noSettle") { $0.heardSettle = 0 },
        Configuration(name: "settle4") { $0.heardSettle = 4 },
        Configuration(name: "mergeWindow3") { $0.turnMergeWindow = 3 },
        Configuration(name: "mergeWindow15") { $0.turnMergeWindow = 15 }
    ]

    /// Selected configurations by name, in the given order. The baseline is always included,
    /// because every other configuration is compared with it.
    public static func named(_ names: [String]) throws -> [Configuration] {
        var selected = [baseline]
        for name in names where name != baseline.name {
            guard let configuration = all.first(where: { $0.name == name }) else {
                throw HarnessError.unknownConfiguration(name)
            }
            if !selected.contains(where: { $0.name == name }) { selected.append(configuration) }
        }
        return selected
    }
}

public enum HarnessError: Error, CustomStringConvertible {
    case unknownConfiguration(String)
    case noScenarios

    public var description: String {
        switch self {
        case let .unknownConfiguration(name): return "unknown configuration: \(name)"
        case .noScenarios: return "no scenarios to replay"
        }
    }
}
