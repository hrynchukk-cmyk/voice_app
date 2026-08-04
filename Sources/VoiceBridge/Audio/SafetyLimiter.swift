import Foundation

/// Final audio-safety stage: applies output gain, then a soft-knee limiter so a
/// sudden loud burst (or an over-hot model output) can never send full-scale or
/// clipped audio into the meeting.
///
/// Real-time safe: no allocations, operates in place, keeps a little smoothed
/// gain state between buffers to avoid zipper noise.
final class SafetyLimiter {
    /// Linear output gain applied before limiting (1.0 = unity).
    var outputGain: Float = 1.0

    /// Ceiling the output must never exceed (linear). ~ −1 dBFS.
    var ceiling: Float = 0.89

    /// Attack/release smoothing coefficients (per-sample, 0..1).
    private let attack: Float = 0.01
    private let release: Float = 0.0005
    private var envelope: Float = 1.0   // current gain-reduction multiplier

    /// Process a mono buffer in place.
    func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        let gain = outputGain
        let ceil = ceiling
        var env = envelope

        for i in 0..<buffer.count {
            var x = buffer[i] * gain

            // Desired instantaneous gain reduction to stay under the ceiling.
            let mag = abs(x)
            let target: Float = mag > ceil ? ceil / mag : 1.0

            // Smooth toward the target: fast to duck, slow to recover.
            let coeff = target < env ? attack : release
            env += (target - env) * coeff

            x *= env

            // Hard safety clamp as a final backstop.
            if x > ceil { x = ceil } else if x < -ceil { x = -ceil }
            buffer[i] = x
        }

        envelope = env
    }

    func reset() {
        envelope = 1.0
    }
}
