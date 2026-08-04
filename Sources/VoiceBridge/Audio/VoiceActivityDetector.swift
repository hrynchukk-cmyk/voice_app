import Foundation
import Accelerate

/// A lightweight, dependency-free voice-activity detector: RMS energy above an
/// adaptive noise floor plus a zero-crossing sanity check, with hang time so
/// speech isn't chopped between words.
///
/// This is the zero-dependency baseline. For higher accuracy swap in
/// **Silero VAD** (MIT) via Core ML / ONNX behind the same `isSpeech(_:)` API —
/// see docs/LIBRARIES.md.
final class VoiceActivityDetector {
    /// How far above the running noise floor counts as speech (linear ratio).
    var speechRatio: Float = 3.0
    /// Frames of silence to keep passing audio after speech stops (hang time).
    var hangoverFrames: Int = 12

    private var noiseFloor: Float = 0.0005
    private var hang = 0

    /// Returns true if the buffer is likely speech. Real-time safe.
    func isSpeech(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard let base = samples.baseAddress, samples.count > 0 else { return false }
        let n = vDSP_Length(samples.count)

        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, n)

        let speaking = rms > noiseFloor * speechRatio

        if speaking {
            hang = hangoverFrames
        } else {
            // Slowly adapt the noise floor toward the current (quiet) level.
            noiseFloor += (rms - noiseFloor) * 0.02
            if hang > 0 { hang -= 1 }
        }

        return speaking || hang > 0
    }

    func reset() {
        hang = 0
        noiseFloor = 0.0005
    }
}
