import SwiftUI
import SignalBus

@main
struct VeraSensorPrototypeApp: App {
    @State private var model = PrototypeModel()

    var body: some Scene {
        WindowGroup("Вера \(VeraRelease.version) · контуры системы") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1640, height: 1080)
        .windowResizability(.contentSize)
    }
}
