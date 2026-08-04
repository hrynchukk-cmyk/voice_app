import Foundation

/// Errors a converter can raise. Any thrown error causes the engine to fall
/// back to **bypass** and surface a visible banner (see AppState).
enum VoiceConversionError: Error {
    case notReady
    case modelUnavailable
    case backendCrashed(String)
    case timedOut
}

/// The pluggable voice-conversion engine.
///
/// Implementations must be prepared to run on a dedicated worker thread, **not**
/// the audio render callback. The engine feeds fixed-size chunks in and expects
/// converted chunks out; if a chunk isn't ready in time the engine emits dry
/// audio for that slice, so a slow/failed converter degrades to bypass rather
/// than glitching.
///
/// Concrete strategies:
/// - `PassthroughConverter` — identity (dry). Used in Phase 1 and as the
///   safe default when no model is loaded.
/// - `CoreMLConverter` — native ANE/GPU inference (ship path, Phase 3). Not
///   included in this scaffold; add when you have a Core ML model.
/// - `ExternalProcessConverter` — talks to the local Python/ONNX backend in
///   `ml/` (prototype path, Phase 3).
protocol VoiceConverter: AnyObject {
    /// Human-readable name of the currently active authorized model.
    var activeModelName: String { get }

    /// Sample rate this converter expects/produces.
    var sampleRate: Double { get }

    /// Preferred chunk size in frames. The engine will feed this many frames per
    /// `convert` call. Smaller = lower latency, more overhead.
    var preferredChunkFrames: Int { get }

    /// Load an authorized, consent-verified model. Throws if unavailable.
    func load(model: VoiceModel) throws

    /// Convert one chunk of mono PCM. `input` and `output` are the same length
    /// (`preferredChunkFrames`). Must not block indefinitely; on any failure
    /// throw `VoiceConversionError` so the engine can bypass.
    func convert(input: UnsafeBufferPointer<Float>,
                 output: UnsafeMutableBufferPointer<Float>) throws

    /// Release resources / stop any child process.
    func shutdown()
}
