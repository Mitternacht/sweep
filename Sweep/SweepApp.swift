import SwiftUI

@main
struct SweepApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Drive") {
                Button("Scan Again") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
                Divider()
                Button("Clean Up") { model.mode = .cleanUp }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Explore") { model.mode = .explore }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }
    }
}
