import SwiftUI

@main
struct VeraSensorPrototypeApp: App {
    @State private var model = PrototypeModel()

    var body: some Scene {
        WindowGroup("Вера · контуры системы") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1640, height: 1080)
        .windowResizability(.contentSize)
    }
}
