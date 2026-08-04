import SwiftUI

/// A horizontal level meter showing RMS (filled bar) and peak (thin line), with
/// a red clipping warning. Driven by `AudioLevel` snapshots from the engine.
struct MeterView: View {
    let title: String
    let level: AudioLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if level.clipping {
                    Label("CLIPPING", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                        .accessibilityLabel("Input clipping")
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))

                    // RMS fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillGradient)
                        .frame(width: geo.size.width * CGFloat(normalized(level.rms)))

                    // Peak indicator
                    Rectangle()
                        .fill(level.clipping ? Color.red : Color.primary.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(normalized(level.peak)) - 1)
                }
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(normalized(level.rms) * 100)) percent")
        }
    }

    /// Map linear 0…1 to a perceptual-ish 0…1 using a dB floor of −60 dBFS.
    private func normalized(_ linear: Float) -> Float {
        guard linear > 0 else { return 0 }
        let db = 20 * log10(linear)
        let floor: Float = -60
        return max(0, min(1, (db - floor) / -floor))
    }

    private var fillGradient: LinearGradient {
        LinearGradient(colors: [.green, .green, .yellow, .orange, .red],
                       startPoint: .leading, endPoint: .trailing)
    }
}
