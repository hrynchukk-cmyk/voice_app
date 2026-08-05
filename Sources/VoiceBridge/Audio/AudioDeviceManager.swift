import Foundation
import CoreAudio
import AVFoundation

/// A Core Audio device we can select as input or output.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    /// True for the Mac's built-in mic / speakers (best-effort heuristic).
    let isBuiltIn: Bool
}

/// Enumerates Core Audio devices, tracks the built-in mic, and notifies when
/// devices appear/disappear (hot-plug) so the engine can react and the UI can
/// show a clear error if the selected device vanishes.
@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []

    /// Called when the device list changes (add/remove). The engine subscribes
    /// to detect that its selected device disappeared.
    var onDevicesChanged: (() -> Void)?

    init() {
        refresh()
        installListener()
    }

    deinit {
        removeListener()
    }

    // MARK: Enumeration

    func refresh() {
        let all = Self.allDevices()
        inputDevices = all.filter { $0.hasInput }
        outputDevices = all.filter { $0.hasOutput }
    }

    /// The built-in microphone if present, else the system default input.
    func defaultInput() -> AudioDevice? {
        inputDevices.first(where: { $0.isBuiltIn }) ??
        Self.defaultDevice(input: true).flatMap { id in inputDevices.first { $0.id == id } } ??
        inputDevices.first
    }

    /// A reliable default output: prefer the built-in speakers (always present
    /// and always initialisable), then the system default, then anything. We
    /// avoid defaulting to the system output when it is a stale/phantom device
    /// (e.g. AirPods that appear via Find My but aren't connected for audio).
    func defaultOutput() -> AudioDevice? {
        outputDevices.first(where: { $0.isBuiltIn }) ??
        Self.defaultDevice(input: false).flatMap { id in outputDevices.first { $0.id == id } } ??
        outputDevices.first
    }

    /// The built-in microphone, used as an always-present start fallback.
    func builtInInput() -> AudioDevice? { inputDevices.first(where: { $0.isBuiltIn }) }

    /// The built-in speakers, used as an always-present start fallback.
    func builtInOutput() -> AudioDevice? { outputDevices.first(where: { $0.isBuiltIn }) }

    /// Names that identify a virtual audio device usable as a "microphone" in
    /// meeting apps (the app routes converted audio here; the meeting app then
    /// selects the same device as its mic). A user-made Multi-Output Device that
    /// includes one of these is matched too.
    static let virtualDeviceNeedles = ["BlackHole", "VoiceBridge", "VB-Cable",
                                       "VB-Audio", "Loopback", "Soundflower"]

    /// The first installed virtual output device, if any.
    func virtualOutput() -> AudioDevice? {
        for needle in Self.virtualDeviceNeedles {
            if let d = outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) {
                return d
            }
        }
        return nil
    }

    /// True when `device` looks like a virtual audio device we can route into.
    static func isVirtual(_ device: AudioDevice?) -> Bool {
        guard let name = device?.name else { return false }
        return virtualDeviceNeedles.contains { name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: Core Audio plumbing

    private static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &dataSize, &ids) == noErr
        else { return [] }

        return ids.compactMap { device(for: $0) }
    }

    private static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
        let inputCh = channelCount(id, scope: kAudioObjectPropertyScopeInput)
        let outputCh = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        let transport = transportType(id)
        let builtIn = transport == kAudioDeviceTransportTypeBuiltIn
        guard inputCh > 0 || outputCh > 0 else { return nil }
        return AudioDevice(id: id, uid: uid, name: name,
                           hasInput: inputCh > 0, hasOutput: outputCh > 0,
                           isBuiltIn: builtIn)
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        let bufList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufList) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return id
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfName) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (cfName as String) : nil
    }

    // MARK: Hot-plug listener

    // Written on the main actor (installListener), read from the nonisolated
    // deinit (removeListener). That install-once / remove-at-dealloc pattern is
    // not concurrent access, so the unchecked annotation is safe here.
    private nonisolated(unsafe) var listenerBlock: AudioObjectPropertyListenerBlock?

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
                self?.onDevicesChanged?()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private nonisolated func removeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
}
