import Foundation

/// Identity converter — copies input to output unchanged.
///
/// This is the safe default: used in Phase 1 (no conversion yet), whenever no
/// authorized model is loaded, and as the concrete behavior of "bypass". Having
/// a real object here (rather than a nil converter) means the audio path is
/// always complete and the bypass/fallback logic has nothing special to case on.
final class PassthroughConverter: VoiceConverter {
    let activeModelName = "None (dry / bypass)"
    let sampleRate: Double = 48_000
    let preferredChunkFrames = 256

    func load(model: VoiceModel) throws {
        // Nothing to load; passthrough ignores the model on purpose.
    }

    func convert(input: UnsafeBufferPointer<Float>,
                 output: UnsafeMutableBufferPointer<Float>) throws {
        let n = min(input.count, output.count)
        if let src = input.baseAddress, let dst = output.baseAddress {
            dst.update(from: src, count: n)
        }
    }

    func shutdown() {}
}
