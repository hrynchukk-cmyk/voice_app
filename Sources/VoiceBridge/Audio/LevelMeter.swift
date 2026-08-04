import Foundation
import Accelerate

/// A snapshot of signal level for one buffer, in a form the UI can render.
struct AudioLevel: Equatable {
    /// Peak magnitude, 0...1 (linear).
    var peak: Float = 0
    /// RMS magnitude, 0...1 (linear).
    var rms: Float = 0
    /// True when the buffer reached/exceeded the clipping threshold.
    var clipping: Bool = false

    /// Peak in dBFS (−∞…0). Handy for a dB-scaled meter.
    var peakDBFS: Float { peak > 0 ? 20 * log10(peak) : -Float.infinity }
    /// RMS in dBFS.
    var rmsDBFS: Float { rms > 0 ? 20 * log10(rms) : -Float.infinity }
}

/// Computes peak/RMS and detects clipping for a PCM buffer.
///
/// Uses `Accelerate`/`vDSP` so it is cheap enough to call on the audio thread,
/// though in practice we compute it in the sink/source callbacks and hand the
/// result to the UI via an atomic/throttled publish.
struct LevelMeter {
    /// Samples at or above this magnitude count as clipping.
    var clippingThreshold: Float = 0.999

    func measure(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
        guard let base = samples.baseAddress, samples.count > 0 else {
            return AudioLevel()
        }
        let n = vDSP_Length(samples.count)

        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, n)     // max magnitude

        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, n)        // root mean square

        return AudioLevel(
            peak: min(peak, 4),             // clamp absurd values
            rms: min(rms, 4),
            clipping: peak >= clippingThreshold
        )
    }
}
