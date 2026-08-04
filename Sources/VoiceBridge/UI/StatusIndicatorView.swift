import SwiftUI

/// The mandatory, always-visible conversion status indicator: a colored dot, a
/// text label, and a running session timer. Bound directly to the engine's real
/// status so it can never falsely read "inactive" while audio flows.
struct StatusIndicatorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: AudioEngine

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 14, height: 14)
                .shadow(color: dotColor.opacity(0.6), radius: state.isRunning ? 4 : 0)
                .accessibilityHidden(true)

            Text(label)
                .font(.headline)
                .foregroundStyle(labelColor)

            if state.isRunning {
                Text(state.elapsedString)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Session time \(state.elapsedString)")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(dotColor.opacity(0.4)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch engine.status {
        case .running:
            return state.isMuted ? "MUTED — conversion active"
                 : state.isBypassed ? "BYPASS — your real voice"
                 : "Voice conversion ACTIVE"
        case .bypassFallback:
            return "BYPASS (fallback) — your real voice"
        case .error(let m):
            return "Error: \(m)"
        case .idle:
            return "Inactive"
        }
    }

    private var dotColor: Color {
        switch engine.status {
        case .running:        return state.isBypassed ? .orange : .red
        case .bypassFallback: return .orange
        case .error:          return .yellow
        case .idle:           return .secondary
        }
    }

    private var labelColor: Color {
        state.isRunning ? .primary : .secondary
    }

    private var background: Color {
        state.isRunning ? dotColor.opacity(0.12) : Color.secondary.opacity(0.08)
    }
}
