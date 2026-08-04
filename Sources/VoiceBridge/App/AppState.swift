import Foundation
import Combine
import SwiftUI

/// Central app state: owns the engine, devices, and model store, and exposes
/// the small set of actions the UI drives. Also runs the session timer for the
/// ACTIVE indicator.
@MainActor
final class AppState: ObservableObject {
    let engine = AudioEngine()
    let devices = AudioDeviceManager()
    let modelStore = VoiceModelStore()

    // Selections
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published var selectedModel: VoiceModel?

    // Mirrored controls (drive the engine)
    @Published var isMuted = false { didSet { engine.isMuted = isMuted } }
    @Published var isBypassed = false { didSet { engine.isBypassed = isBypassed } }
    @Published var inputGain: Double = 1.0 { didSet { engine.inputGain = Float(inputGain) } }
    @Published var outputGain: Double = 1.0 { didSet { engine.limiter.outputGain = Float(outputGain) } }

    // Session timing for the ACTIVE indicator
    @Published private(set) var sessionStart: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    private var ticker: AnyCancellable?

    /// VoiceBridge processes locally; no network client entitlement exists.
    let isUsingNetwork = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        selectedInput = devices.defaultInput()
        selectedOutput = devices.virtualOutput() ?? devices.outputDevices.first

        // React to hot-plug: if our input vanished, tell the engine.
        devices.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.engine.handleDeviceChange(currentInput: self.selectedInput,
                                           available: self.devices.inputDevices)
            if let sel = self.selectedInput,
               !self.devices.inputDevices.contains(where: { $0.id == sel.id }) {
                self.selectedInput = self.devices.defaultInput()
            }
        }

        // Keep the ACTIVE indicator honest: mirror the engine's real status.
        engine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                if status.isLive, self?.sessionStart == nil { self?.beginSession() }
                if !status.isLive { self?.endSession() }
            }
            .store(in: &cancellables)
    }

    // MARK: Actions

    var isRunning: Bool { engine.status.isLive }

    func startConversion() {
        // Load the selected authorized model into the converter (Phase 3). In
        // this scaffold we run the passthrough converter, so conversion == dry.
        engine.start(inputDevice: selectedInput, outputDevice: selectedOutput)
    }

    func stopConversion() {
        engine.stop()
    }

    func toggleRunning() { isRunning ? stopConversion() : startConversion() }
    func toggleMute() { isMuted.toggle() }
    func toggleBypass() { isBypassed.toggle() }

    // MARK: Session timer

    private func beginSession() {
        sessionStart = Date()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let start = self?.sessionStart else { return }
                self?.elapsed = Date().timeIntervalSince(start)
            }
    }

    private func endSession() {
        ticker?.cancel(); ticker = nil
        sessionStart = nil
        elapsed = 0
    }

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
