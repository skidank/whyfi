import SwiftUI

@main
struct WhyFiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("WhyFi", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .defaultSize(width: 1450, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Export Scan Data…") { model.exportScans() }
                    .keyboardShortcut("e")
            }
            CommandMenu("Scan") {
                Button(model.isPaused ? "Resume Scanning" : "Pause Scanning") { model.isPaused.toggle() }
                    .keyboardShortcut("p")
            }
        }
    }
}
