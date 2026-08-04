import SwiftUI

/// Input + output meters, scoped into their own view that observes the engine
/// so the ~30 Hz level updates only invalidate this subtree — not the whole
/// window (pickers, layout, etc.).
struct LiveMetersView: View {
    @EnvironmentObject var engine: AudioEngine

    var body: some View {
        HStack(spacing: 20) {
            MeterView(title: "Input level", level: engine.inputLevel)
            MeterView(title: "Output level", level: engine.outputLevel)
        }
    }
}

/// The status/error/fallback banner, observing the engine so it reflects real
/// state. Kept separate from the pickers to avoid needless re-rendering.
struct StatusBanner: View {
    @EnvironmentObject var engine: AudioEngine

    var body: some View {
        Group {
            switch engine.status {
            case .error(let message):
                banner(message, color: .red, icon: "xmark.octagon.fill")
            case .bypassFallback(let reason):
                banner("Automatic bypass: \(reason). Your real voice is being sent.",
                       color: .orange, icon: "arrow.triangle.branch")
            default:
                EmptyView()
            }
        }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
