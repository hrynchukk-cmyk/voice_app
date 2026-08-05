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
///   mic → AVAudioSinkNode ──▶ inputRing ──▶ worker(convert) ──▶ outputRing ──▶ AVAudioSourceNode → output
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

    // MARK: AVAudioEngine graph
    private let engine = AVAudioEngine()
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
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

    func start(inputDevice: AudioDevice?, outputDevice: AudioDevice?) {
        guard !engine.isRunning else { return }
        var lastError: Error?
        // Attempt 1 honours the user's selected devices. Attempt 2 falls back to
        // the system-default devices, which is the most compatible setup — this
        // rescues the common case where a selected device is stale or unusable
        // (e.g. an output that shows "driver not found").
        for useDefaults in [false, true] {
            do {
                try attemptStart(inputDevice: useDefaults ? nil : inputDevice,
                                 outputDevice: useDefaults ? nil : outputDevice)
                status = .running
                return
            } catch {
                lastError = error
                teardown()
            }
        }
        status = .error("Could not start audio: "
                        + (lastError?.localizedDescription ?? "unknown error"))
    }

    private func attemptStart(inputDevice: AudioDevice?, outputDevice: AudioDevice?) throws {
        try configureGraph(inputDevice: inputDevice, outputDevice: outputDevice)
        startWorker()
        try engine.start()
        startUITimer()
    }

    func stop() {
        teardown()
        if case .error = status {} else { status = .idle }
    }

    /// Tear the graph down without touching `status`, so `start` can retry.
    private func teardown() {
        engine.stop()
        stopWorker()
        uiTimer?.invalidate(); uiTimer = nil
        if let s = sinkNode { engine.detach(s) }
        if let s = sourceNode { engine.detach(s) }
        sinkNode = nil; sourceNode = nil
        inputRing.reset(); outputRing.reset()
        limiter.reset(); vad.reset()
        // Clear any device we forced this run, so the next (fallback) attempt
        // starts from the clean system-default state.
        resetDevicesToDefault()
    }

    /// Best-effort: point both AUHAL units back at the system default devices.
    private func resetDevicesToDefault() {
        if let inID = Self.defaultDeviceID(input: true) {
            try? setDevice(inID, isInput: true)
        }
        if let outID = Self.defaultDeviceID(input: false) {
            try? setDevice(outID, isInput: false)
        }
    }

    /// Called by AudioDeviceManager's hot-plug notification when the selected
    /// device may have disappeared.
    func handleDeviceChange(currentInput: AudioDevice?, available: [AudioDevice]) {
        guard engine.isRunning, let input = currentInput else { return }
        if !available.contains(where: { $0.id == input.id }) {
            status = .error("The selected microphone was disconnected.")
            stop()
        }
    }

    // MARK: - Graph configuration

    private func configureGraph(inputDevice: AudioDevice?, outputDevice: AudioDevice?) throws {
        // NOTE: driving input from one Core Audio device and output to a
        // *different* one (built-in mic → virtual mic) through a single
        // AVAudioEngine relies on the two devices staying clock-aligned. For a
        // robust release, back this with an **aggregate device** or a manual-
        // rendering AUHAL pair with sample-rate conversion (see
        // docs/ARCHITECTURE.md §5). AVAudioEngine is used here for a clear,
        // correct first version.
        // Force a specific device only when one was chosen. When nil (the
        // fallback attempt), we force nothing and let AVAudioEngine use the
        // system defaults — the canonical, most-compatible monitoring setup.
        if let dev = inputDevice { try setDevice(dev.id, isInput: true) }
        if let dev = outputDevice { try setDevice(dev.id, isInput: false) }

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        sampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 48_000

        // Mono Float32 processing format at the hardware rate.
        guard let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            throw NSError(domain: "VoiceBridge", code: -1)
        }

        // --- Input: sink node captures mic frames into inputRing. ---
        let sink = AVAudioSinkNode { [weak self] _, frameCount, ablPtr in
            self?.captureBlock(frameCount: frameCount, abl: ablPtr) ?? noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: hwFormat)
        self.sinkNode = sink

        // --- Output: source node renders outputRing to the output device. ---
        let source = AVAudioSourceNode(format: procFormat) { [weak self] silence, _, frameCount, ablPtr in
            self?.renderBlock(silence: silence, frameCount: frameCount, abl: ablPtr) ?? noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: procFormat)
        self.sourceNode = source

        engine.prepare()
    }

    /// Route the engine's input/output through a specific Core Audio device by
    /// setting kAudioOutputUnitProperty_CurrentDevice on the AUHAL unit. This is
    /// how output is pointed at the "VoiceBridge Microphone" virtual device.
    private func setDevice(_ deviceID: AudioDeviceID, isInput: Bool) throws {
        let node = isInput ? engine.inputNode : engine.outputNode
        guard let unit = node.audioUnit else { return }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
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

    // MARK: - Real-time callbacks (audio threads — no allocations/locks)

    private func captureBlock(frameCount: AVAudioFrameCount,
                              abl: UnsafePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: abl))
        guard let mData = buffers.first?.mData else { return noErr }
        let n = Int(frameCount)
        let ptr = mData.assumingMemoryBound(to: Float.self)

        // Apply input gain in place.
        if inputGain != 1.0 {
            for i in 0..<n { ptr[i] *= inputGain }
        }
        let bufPtr = UnsafeBufferPointer(start: ptr, count: n)

        // Meter the (gained) input.
        inSnapshot = meter.measure(bufPtr)

        // Publish dry frames to the worker.
        inputRing.write(bufPtr)
        workSignal.signal()
        return noErr
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
            guard let self, self.engine.isRunning else { return }
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
