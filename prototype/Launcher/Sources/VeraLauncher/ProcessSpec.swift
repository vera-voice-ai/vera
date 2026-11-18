import Foundation

enum VeraModule: String, CaseIterable, Sendable {
    case bus
    case sensors
    case scene
    case core
    case response

    var executableName: String { "vera-\(rawValue)" }

    var environmentKey: String {
        "VERA_\(rawValue.uppercased())_EXECUTABLE"
    }
}

struct ProcessSpec: Sendable {
    let module: VeraModule
    let executableURL: URL
    let arguments: [String]

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     bundleURL: URL = Bundle.main.bundleURL) throws -> [ProcessSpec] {
        try VeraModule.allCases.map { module in
            let executableURL: URL
            if let configuredPath = environment[module.environmentKey], !configuredPath.isEmpty {
                executableURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
            } else {
                executableURL = bundleURL
                    .appending(path: "Contents/Helpers", directoryHint: .isDirectory)
                    .appending(path: module.executableName)
            }

            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw LauncherError.missingExecutable(module: module, path: executableURL.path)
            }
            return ProcessSpec(module: module, executableURL: executableURL, arguments: [])
        }
    }
}

enum LauncherError: LocalizedError {
    case missingExecutable(module: VeraModule, path: String)

    var errorDescription: String? {
        switch self {
        case let .missingExecutable(module, path):
            return "Не найден исполняемый файл \(module.executableName): \(path). Укажи путь через \(module.environmentKey)."
        }
    }
}
