import SwiftUI

/// The large transport controls (Start/Stop, Mute, Bypass) plus gain sliders and
/// the latency / CPU readouts. Keyboard shortcuts mirror the menu commands.
struct ControlsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: AudioEngine
    @ObservedObject var perf: PerformanceMonitor

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                bigButton(
                    title: state.isRunning ? "Stop Conversion" : "Start Conversion",
                    systemImage: state.isRunning ? "stop.fill" : "play.fill",
                    tint: state.isRunning ? .red : .green,
                    shortcut: "K"
                ) { state.toggleRunning() }
                .keyboardShortcut("k", modifiers: [.command])

                bigButton(
                    title: state.isMuted ? "Unmute" : "Mute",
                    systemImage: state.isMuted ? "mic.slash.fill" : "mic.fill",
                    tint: state.isMuted ? .orange : .gray,
                    shortcut: "M"
                ) { state.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command])
                .disabled(!state.isRunning)

                bigButton(
                    title: state.isBypassed ? "Use Converted" : "Bypass",
                    systemImage: "arrow.triangle.branch",
                    tint: state.isBypassed ? .orange : .gray,
                    shortcut: "B"
                ) { state.toggleBypass() }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(!state.isRunning)
            }

            HStack(spacing: 24) {
                gainSlider("Input gain", value: $state.inputGain)
                gainSlider("Output gain", value: $state.outputGain)
                voiceSlider
            }

            HStack(spacing: 24) {
                readout("Latency", value: String(format: "%.0f ms", engine.measuredLatencyMs))
                readout("CPU", value: String(format: "%.0f%%", perf.cpuPercent))
                readout("GPU", value: "n/a")   // see PerformanceMonitor note
                readout("Model", value: state.selectedModel?.name ?? engine.activeModelName)
                readout("Network", value: state.isUsingNetwork ? "IN USE" : "Local only")
            }
            .font(.callout)
        }
    }

    private func bigButton(title: String, systemImage: String, tint: Color,
                           shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 26))
                Text(title).font(.headline)
                Text("⌘\(shortcut)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .accessibilityLabel(title)
    }

    /// Built-in voice changer: deeper ⟷ higher.
    private var voiceSlider: some View {
        VStack(alignment: .leading) {
            Text("Voice: \(voiceLabel)")
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: $state.voicePitch, in: 0.5...1.6)
        }
    }

    private var voiceLabel: String {
        let p = state.voicePitch
        if p < 0.95 { return String(format: "deeper (%.2f×)", p) }
        if p > 1.05 { return String(format: "higher (%.2f×)", p) }
        return "natural"
    }

    private func gainSlider(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(label): \(String(format: "%.2f×", value.wrappedValue))")
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...2)
        }
    }

    private func readout(_ label: String, value: String) -> some View {
        VStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).bold()
        }
        .frame(maxWidth: .infinity)
    }
}
