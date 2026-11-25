import SwiftUI
import HermesBridge

/// «⚙ настроить» on the provider tile: Hermes' provider, key and model (what the separate «Настройка» window was),
/// as a sheet over the board: it stays while the owner switches to a browser to copy the key. Owns its setup model
/// while open.
struct ProviderSetup: View {
    @State private var setup: SetupModel
    var done: () -> Void
    init(board: BoardModel, done: @escaping () -> Void) { _setup = State(initialValue: SetupModel(board: board)); self.done = done }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { SetupView(setup: setup) }
            HStack { Spacer(); Button("Готово") { done() }.keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 1000, height: 680)
        .background(Theme.background)
    }
}
