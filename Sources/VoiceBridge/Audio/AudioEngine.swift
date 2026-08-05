import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// High-level engine state, surfaced to the UI and bound to the ACTIVE
/// indicator. The indicator is derived from `.running`/`.bypassFallback`, so it
/// cannot claim "inactive" while audio is flowing.
enum EngineStatus: Equatable {
    case idle
    case running
    case bypassFallback(reason: String)   // converted output unavailable → dry
    case error(String)

    var isLive: Bool {
        switch self {
        case .running, .bypassFallback: return true
        case .idle, .error: return false
        }
    }
}

/// The real-time audio engine.
///
/// Path (see docs/ARCHITECTURE.md §5):
///   mic → input tap ──▶ inputRing ──▶ worker(convert) ──▶ outputRing ──▶ AVAudioSourceNode → output
///
/// The two render callbacks only touch ring buffers and cheap DSP; the
/// (potentially slow) conversion runs on a dedicated worker so a slow/failed
/// converter degrades to bypass instead of glitching.
final class AudioEngine: ObservableObject {

    // MARK: Published UI state (updated on the main thread by a throttled timer)
    @Published private(set) var status: EngineStatus = .idle
    @Published private(set) var inputLevel = AudioLevel()
    @Published private(set) var outputLevel = AudioLevel()
    @Published private(set) var measuredLatencyMs: Double = 0

    // MARK: Controls
    /// Instant mute — the source callback emits silence within one buffer.
    var isMuted = false { didSet { if isMuted { outputRing.reset() } } }
    /// Bypass — send dry (unconverted) mic audio.
    var isBypassed = false
    /// Linear input gain applied at capture.
    var inputGain: Float = 1.0
    /// Output gain + limiter live in `limiter`.
    let limiter = SafetyLimiter()

    // MARK: Collaborators
    private let vad = VoiceActivityDetector()
    /// The built-in native voice changer, used by default so Start immediately
    /// transforms the voice with no model/Python/driver. Swap via setConverter.
    let nativeConverter = NativeVoiceConverter()
    private var converter: VoiceConverter

    init() {
        // Eager (non-lazy) so the worker thread and the UI never race a lazy init.
        converter = nativeConverter
    }

    // MARK: AVAudioEngine graphs
    // Two independent engines bridged by the ring buffers: one input-only
    // (captures the default mic via a tap) and one output-only (renders to the
    // default output). This sidesteps AVAudioEngine's inability to run
    // full-duplex across two different Core Audio devices — each engine uses a
    // single device — and needs no fragile device forcing.
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var tapInstalled = false
    private var sampleRate: Double = 48_000

    // MARK: Buffers shared across threads
    private let inputRing = RingBuffer(capacity: 1 << 15)   // ~0.68 s @ 48k
    private let outputRing = RingBuffer(capacity: 1 << 15)

    // MARK: Worker
    private var worker: Thread?
    private let workSignal = DispatchSemaphore(value: 0)
    private var workerRunning = false

    // MARK: Level snapshots written by audio threads, read by the UI timer
    private var inSnapshot = AudioLevel()
    private var outSnapshot = AudioLevel()
    private var lastConvertMs: Double = 0
    private var uiTimer: Timer?

    private let meter = LevelMeter()

    // MARK: - Lifecycle

    /// Swap in a real converter (Phase 3). Loading is done by the caller.
    func setConverter(_ new: VoiceConverter) {
        converter = new
    }

    func start(inputDevice: AudioDevice?, outputDevice: AudioDevice?,
               builtInInput: AudioDevice? = nil, builtInOutput: AudioDevice? = nil) {
        guard !inputEngine.isRunning, !outputEngine.isRunning else { return }
        // Input follows the macOS default input; output is routed to the chosen
        // device (e.g. the BlackHole virtual mic) so other apps can pick it up.
        // Input-device selection returns with Phase 2 in-app routing.
        _ = (inputDevice, builtInInput, builtInOutput)
        do {
            try configureAndStart(outputDevice: outputDevice)
            startWorker()
            startUITimer()
            status = .running
        } catch {
            status = .error("Could not start audio: \(error.localizedDescription)")
            stop()
        }
    }

    private func configureAndStart(outputDevice: AudioDevice?) throws {
        // --- Input engine: capture the default mic via a tap into inputRing. ---
        let inFormat = inputEngine.inputNode.outputFormat(forBus: 0)
        sampleRate = inFormat.sampleRate > 0 ? inFormat.sampleRate : 48_000
        inputEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) {
            [weak self] buffer, _ in self?.captureFromTap(buffer)
        }
        tapInstalled = true
        inputEngine.prepare()
        try inputEngine.start()

        // --- Output engine: render outputRing to the SELECTED output device so
        //     apps like Zoom can pick it up as a microphone. The mono source
        //     runs at the capture rate; the mixer resamples to the device rate.
        //     Fall back to the system default output if the chosen device fails.
        guard let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            throw NSError(domain: "VoiceBridge", code: -1)
        }
        let source = AVAudioSourceNode(format: procFormat) { [weak self] silence, _, frameCount, ablPtr in
            self?.renderBlock(silence: silence, frameCount: frameCount, abl: ablPtr) ?? noErr
        }
        outputEngine.attach(source)
        outputEngine.connect(source, to: outputEngine.mainMixerNode, format: procFormat)
        sourceNode = source

        // Try the chosen device, then the system default, then no forcing at
        // all. The first that starts wins, so a bad selection never blocks audio.
        var startError: Error?
        func tryStart(force id: AudioDeviceID?) -> Bool {
            do {
                if let id { try setOutputDevice(outputEngine, deviceID: id) }
                outputEngine.prepare()
                try outputEngine.start()
                return true
            } catch {
                startError = error
                outputEngine.stop()
                return false
            }
        }
        if tryStart(force: outputDevice?.id) { return }
        if tryStart(force: Self.defaultDeviceID(input: false)) { return }
        if tryStart(force: nil) { return }
        throw startError ?? NSError(domain: "VoiceBridge", code: -3)
    }

    /// Point an output-only engine's AUHAL unit at a specific Core Audio device.
    private func setOutputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw NSError(domain: "VoiceBridge", code: -2)
        }
        var dev = deviceID
        let st = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &dev,
                                      UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    /// The system default input/output device ID, used as a compatible fallback.
    private static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return (st == noErr && id != 0) ? id : nil
    }

    func stop() {
        teardown()
        if case .error = status {} else { status = .idle }
    }

    /// Tear both engines down without touching `status`.
    private func teardown() {
        inputEngine.stop()
        outputEngine.stop()
        stopWorker()
        uiTimer?.invalidate(); uiTimer = nil
        if tapInstalled { inputEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if let s = sourceNode { outputEngine.detach(s) }
        sourceNode = nil
        inputRing.reset(); outputRing.reset()
        limiter.reset(); vad.reset()
    }

    /// Called by AudioDeviceManager's hot-plug notification. With system-default
    /// routing, Core Audio follows the new default device, so there is nothing
    /// to reconfigure here; kept for the Phase 2 in-app routing.
    func handleDeviceChange(currentInput: AudioDevice?, available: [AudioDevice]) {}

    // MARK: - Real-time callbacks (audio threads — no allocations/locks)

    private func captureFromTap(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let ptr = channels[0]   // channel 0 (mono capture)

        // Apply input gain in place.
        if inputGain != 1.0 {
            for i in 0..<n { ptr[i] *= inputGain }
        }
        let bufPtr = UnsafeBufferPointer(start: ptr, count: n)

        // Meter the (gained) input, then publish dry frames to the worker.
        inSnapshot = meter.measure(bufPtr)
        inputRing.write(bufPtr)
        workSignal.signal()
    }

    private func renderBlock(silence: UnsafeMutablePointer<ObjCBool>,
                             frameCount: AVAudioFrameCount,
                             abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let n = Int(frameCount)

        // Instant mute: emit silence directly, bypassing the ring.
        if isMuted {
            for buffer in buffers {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            silence.pointee = true
            outSnapshot = AudioLevel()
            return noErr
        }

        // Pull converted (or dry) audio produced by the worker.
        guard let first = buffers.first?.mData else { return noErr }
        let out = first.assumingMemoryBound(to: Float.self)
        let outBuf = UnsafeMutableBufferPointer(start: out, count: n)
        outputRing.read(into: outBuf)

        outSnapshot = meter.measure(UnsafeBufferPointer(outBuf))

        // Copy channel 0 to any additional channels.
        for buffer in buffers.dropFirst() {
            if let dst = buffer.mData {
                dst.assumingMemoryBound(to: Float.self).update(from: out, count: n)
            }
        }
        return noErr
    }

    // MARK: - Worker (does conversion off the render thread)

    private func startWorker() {
        workerRunning = true
        isInFallback = false
        let t = Thread { [weak self] in self?.workerLoop() }
        t.name = "VoiceBridge.Conversion"
        t.qualityOfService = .userInteractive
        t.start()
        worker = t
    }

    private func stopWorker() {
        workerRunning = false
        workSignal.signal()   // wake it so it can exit
        worker = nil
    }

    private func workerLoop() {
        let chunk = max(64, converter.preferredChunkFrames)
        let dry = UnsafeMutableBufferPointer<Float>.allocate(capacity: chunk)
        let wet = UnsafeMutableBufferPointer<Float>.allocate(capacity: chunk)
        defer { dry.deallocate(); wet.deallocate() }

        while workerRunning {
            _ = workSignal.wait(timeout: .now() + 0.1)

            while workerRunning && inputRing.availableToRead >= chunk {
                inputRing.read(into: dry)

                if isMuted {
                    outputRing.reset()   // don't accumulate stale audio while muted
                    continue
                }

                let dryConst = UnsafeBufferPointer(dry)

                if isBypassed {
                    wet.baseAddress!.update(from: dry.baseAddress!, count: chunk)
                    reportBypassIfNeeded(active: false)
                } else {
                    let t0 = DispatchTime.now()
                    do {
                        try converter.convert(input: dryConst, output: wet)
                        lastConvertMs = Double(DispatchTime.now().uptimeNanoseconds
                                               - t0.uptimeNanoseconds) / 1_000_000
                        reportBypassIfNeeded(active: false)
                    } catch {
                        // Automatic fallback to bypass: copy dry, raise banner.
                        wet.baseAddress!.update(from: dry.baseAddress!, count: chunk)
                        reportBypassIfNeeded(active: true,
                                             reason: "Conversion unavailable: \(error)")
                    }
                }

                // Final safety stage then publish to the output ring.
                limiter.process(wet)
                outputRing.write(UnsafeBufferPointer(wet))
            }
        }
    }

    private var isInFallback = false
    private func reportBypassIfNeeded(active: Bool, reason: String = "") {
        guard active != isInFallback else { return }
        isInFallback = active
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outputEngine.isRunning else { return }
            self.status = active ? .bypassFallback(reason: reason) : .running
        }
    }

    // MARK: - UI publishing (throttled, main thread)

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.inputLevel = self.inSnapshot
            self.outputLevel = self.outSnapshot
            self.measuredLatencyMs = self.estimatedLatencyMs()
        }
    }

    /// Best-effort end-to-end latency estimate for the display. Cross-check
    /// against the offline measurement in docs/TESTING.md §2.
    private func estimatedLatencyMs() -> Double {
        let ioBufferFrames = 256.0                       // typical HAL I/O buffer
        let ioMs = (ioBufferFrames / sampleRate) * 1000.0 * 2  // in + out
        let ringMs = (Double(converter.preferredChunkFrames) / sampleRate) * 1000.0
        return ioMs + ringMs + lastConvertMs
    }

    var activeModelName: String { converter.activeModelName }
}
