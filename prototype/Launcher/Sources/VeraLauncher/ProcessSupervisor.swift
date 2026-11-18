import Foundation

final class ProcessSupervisor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vera.launcher.supervisor")
    private let specs: [ProcessSpec]
    private var processes: [VeraModule: Process] = [:]
    private var restartAttempts: [VeraModule: Int] = [:]
    private var stopping = false

    init(specs: [ProcessSpec]) {
        self.specs = specs
    }

    func start() throws {
        try queue.sync {
            guard !stopping else { return }
            // Start the bus before modules that depend on it.
            let ordered = specs.sorted { left, right in
                if left.module == .bus { return true }
                if right.module == .bus { return false }
                return VeraModule.allCases.firstIndex(of: left.module)! <
                    VeraModule.allCases.firstIndex(of: right.module)!
            }
            do {
                for spec in ordered {
                    try launch(spec)
                }
            } catch {
                stopping = true
                let running = processes.values.filter(\.isRunning)
                running.forEach { $0.terminate() }
                running.forEach { $0.waitUntilExit() }
                processes.removeAll()
                throw error
            }
        }
    }

    func stop() {
        queue.sync {
            stopping = true
            let running = processes.values.filter(\.isRunning)
            running.forEach { $0.terminate() }
            running.forEach { $0.waitUntilExit() }
            processes.removeAll()
            print("[vera-launcher] Все дочерние процессы остановлены")
        }
    }

    private func launch(_ spec: ProcessSpec) throws {
        guard !stopping else { return }
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] terminated in
            guard let supervisor = self else { return }
            let status = terminated.terminationStatus
            supervisor.queue.async { [weak supervisor] in
                supervisor?.handleTermination(of: spec, status: status)
            }
        }
        try process.run()
        processes[spec.module] = process
        print("[vera-launcher] Запущен \(spec.module.executableName), pid=\(process.processIdentifier)")
    }

    private func handleTermination(of spec: ProcessSpec, status: Int32) {
        guard !stopping else { return }
        processes[spec.module] = nil
        let attempt = (restartAttempts[spec.module] ?? 0) + 1
        restartAttempts[spec.module] = attempt
        let delay = min(pow(2.0, Double(min(attempt - 1, 5))), 30.0)
        print("[vera-launcher] \(spec.module.executableName) завершился (код \(status)); перезапуск через \(Int(delay)) с")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping else { return }
            do {
                try self.launch(spec)
            } catch {
                print("[vera-launcher] Ошибка запуска \(spec.module.executableName): \(error.localizedDescription)")
                self.handleTermination(of: spec, status: -1)
            }
        }
    }
}
