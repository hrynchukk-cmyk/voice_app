import Foundation

/// Prototype converter that offloads inference to the local Python/ONNX backend
/// in `ml/` over a **localhost-only** connection.
///
/// This is a scaffold: the transport is sketched, not production-hardened. It
/// exists to show *where* the boundary is and how failures convert into a
/// bypass fallback. For a shipping build, replace this with `CoreMLConverter`
/// (native, no IPC, no Python) — see docs/ARCHITECTURE.md §4.
///
/// Design intent:
/// - The backend is a child process the app launches and supervises; it never
///   reaches the network.
/// - Audio frames go over a Unix domain socket / shared memory, not TCP to the
///   outside world.
/// - Any read/write/timeout error throws `VoiceConversionError.backendCrashed`,
///   which the engine turns into automatic bypass.
final class ExternalProcessConverter: VoiceConverter {
    private(set) var activeModelName = "None"
    let sampleRate: Double = 48_000
    let preferredChunkFrames = 512   // larger chunk: IPC has more overhead

    private var process: Process?
    private var isReady = false

    /// Round-trip deadline; if the backend is slower, we bypass this chunk.
    var chunkDeadline: TimeInterval = 0.030

    func load(model: VoiceModel) throws {
        // TODO(Phase 3): launch `ml/server.py` as a child process pinned to
        // localhost/UDS, hand it the model path, and wait for a "ready" line.
        // Pseudocode of the safe supervision pattern:
        //
        //   let proc = Process()
        //   proc.executableURL = pythonURL
        //   proc.arguments = [serverScript, "--model", model.weightsURL.path,
        //                     "--socket", socketPath]  // no network flags
        //   proc.terminationHandler = { [weak self] _ in self?.isReady = false }
        //   try proc.run()
        //   self.process = proc
        //
        // Then connect to the UDS and block until the handshake completes.
        activeModelName = model.name
        throw VoiceConversionError.notReady   // not implemented in the scaffold
    }

    func convert(input: UnsafeBufferPointer<Float>,
                 output: UnsafeMutableBufferPointer<Float>) throws {
        guard isReady else { throw VoiceConversionError.notReady }
        // TODO(Phase 3): write `input` frames to the socket, read converted
        // frames back into `output` within `chunkDeadline`. On any error:
        //   throw VoiceConversionError.backendCrashed("...")
        // On timeout:
        //   throw VoiceConversionError.timedOut
        throw VoiceConversionError.notReady
    }

    func shutdown() {
        process?.terminate()
        process = nil
        isReady = false
    }
}
