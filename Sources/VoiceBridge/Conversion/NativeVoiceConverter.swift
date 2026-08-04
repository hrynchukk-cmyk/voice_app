import Foundation

/// A native, real-time voice transformer implemented as a crossfading
/// delay-line pitch shifter. No ML model, no Python, no network — it runs
/// entirely in Swift, so pressing **Start** audibly changes your voice
/// immediately and end-to-end.
///
/// What it does: shifts pitch and (because it resamples) formants, so your voice
/// becomes clearly deeper or higher and takes on a different character.
///
/// What it does NOT do: clone a *specific* person's identity. Sounding like a
/// particular authorized speaker requires the ML path (`CoreMLConverter` /
/// `ExternalProcessConverter`) in Phase 3. This converter is honest voice
/// *transformation*, not impersonation.
final class NativeVoiceConverter: VoiceConverter {
    let activeModelName = "Built-in voice changer (pitch/formant)"
    let sampleRate: Double = 48_000
    let preferredChunkFrames = 256

    /// Pitch/formant ratio. `< 1` = deeper, `> 1` = higher, `1` = unchanged.
    /// Read on the audio worker thread; a plain `Float` write from the UI is a
    /// benign race for a single scalar.
    var pitchRatio: Float = 0.72

    // Delay line (circular, power-of-two so wrap is a mask).
    private let windowLen: Float
    private let bufSize: Int
    private let mask: Int
    private var buffer: [Float]
    private var writeIdx = 0        // kept in [0, bufSize) so Float() stays exact
    private var phase: Float = 0    // ramps through [0, windowLen)

    init(windowSamples: Int = 1024) {
        var n = 1
        while n < windowSamples * 2 { n <<= 1 }   // hold at least two windows
        bufSize = n
        mask = n - 1
        buffer = [Float](repeating: 0, count: n)
        windowLen = Float(windowSamples)
    }

    func load(model: VoiceModel) throws {
        // The native changer ignores voice models — identity conversion is Phase 3.
    }

    func convert(input: UnsafeBufferPointer<Float>,
                 output: UnsafeMutableBufferPointer<Float>) throws {
        let L = windowLen
        let halfL = L * 0.5
        let inc = 1.0 - pitchRatio          // delay ramp speed (per sample)
        let n = min(input.count, output.count)

        for i in 0..<n {
            buffer[writeIdx] = input[i]

            // Two read taps offset by half a window; triangular windows that
            // sum to 1, so one tap fades in as the other approaches its wrap.
            let p1 = phase
            var p2 = phase + halfL
            if p2 >= L { p2 -= L }

            let g1 = 1.0 - abs(2.0 * p1 / L - 1.0)
            let g2 = 1.0 - abs(2.0 * p2 / L - 1.0)

            output[i] = g1 * readInterpolated(delay: p1)
                      + g2 * readInterpolated(delay: p2)

            writeIdx = (writeIdx &+ 1) & mask
            phase += inc
            if phase >= L { phase -= L } else if phase < 0 { phase += L }
        }
    }

    /// Linear-interpolated read `delay` samples behind the write pointer.
    private func readInterpolated(delay: Float) -> Float {
        var pos = Float(writeIdx) - delay
        if pos < 0 { pos += Float(bufSize) }
        let i0 = Int(pos)
        let frac = pos - Float(i0)
        let a = buffer[i0 & mask]
        let b = buffer[(i0 + 1) & mask]
        return a * (1 - frac) + b * frac
    }

    func shutdown() {}
}
