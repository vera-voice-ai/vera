import Dispatch
import Foundation

@main
enum VeraLauncherMain {
    static func main() {
        do {
            let specs = try ProcessSpec.load()
            let supervisor = ProcessSupervisor(specs: specs)

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let shutdown = {
                supervisor.stop()
                exit(EXIT_SUCCESS)
            }
            interrupt.setEventHandler(handler: shutdown)
            terminate.setEventHandler(handler: shutdown)
            interrupt.resume()
            terminate.resume()

            try supervisor.start()
            print("[vera-launcher] Вера запущена. Для остановки нажми Ctrl+C.")
            dispatchMain()
        } catch {
            fputs("[vera-launcher] \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
