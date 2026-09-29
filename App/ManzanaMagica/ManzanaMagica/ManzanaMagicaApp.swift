// SPDX-License-Identifier: GPL-2.0-only
import MagicaCapture
import MagicaPlayback
import SwiftUI

@main
struct ManzanaMagicaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ManzanaMagica", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 480, minHeight: 360)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.applicationWillTerminate()
                }
        }
        .defaultSize(width: 960, height: 720)
        .commands {
            SidebarCommands()
            CommandMenu("Capture") {
                Picker("Input", selection: $model.input) {
                    ForEach(VideoInput.allCases) { Text($0.name).tag($0) }
                }
                Picker("Standard", selection: $model.standardChoice) {
                    ForEach(StandardChoice.allCases) { Text($0.name).tag($0) }
                }
                Picker("Deinterlace", selection: $model.deinterlace) {
                    ForEach(DeinterlaceMode.allCases) { Text($0.name).tag($0) }
                }
                Divider()
                if model.recording != nil {
                    Button("Stop Recording") { model.stopRecording() }
                        .keyboardShortcut("r")
                } else {
                    Button("Start Recording") { model.startRecording() }
                        .keyboardShortcut("r")
                        .disabled(!model.canRecord)
                }
                Button("Show Recordings") { model.showRecordings() }
                Divider()
                Button(model.showStats ? "Hide Statistics" : "Show Statistics") { model.showStats.toggle() }
                    .keyboardShortcut("i")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

extension DeinterlaceMode {
    var name: String {
        switch self {
        case .yadif: String(localized: "YADIF (best)")
        case .bob: String(localized: "Bob (lowest latency)")
        case .off: String(localized: "Off (show fields woven)")
        }
    }
}
