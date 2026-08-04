import SwiftUI

@main
struct VoiceBridgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(state)
                .environmentObject(state.engine)   // observe live engine state directly
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        // Keyboard shortcuts are also attached to the on-screen buttons; these
        // menu commands make them discoverable and give them global menu items.
        .commands {
            CommandMenu("Conversion") {
                Button(state.isRunning ? "Stop Conversion" : "Start Conversion") {
                    state.toggleRunning()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(state.isMuted ? "Unmute" : "Mute") { state.toggleMute() }
                    .keyboardShortcut("m", modifiers: [.command])

                Button(state.isBypassed ? "Use Converted Voice" : "Bypass (send my real voice)") {
                    state.toggleBypass()
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
        }
    }
}
