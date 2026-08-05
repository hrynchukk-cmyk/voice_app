import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var perf = PerformanceMonitor()
    @State private var showEnrollment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Mandatory ACTIVE indicator — always on top, always visible.
            StatusIndicatorView()

            StatusBanner()

            // Device + model selectors
            GroupBox("Routing") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Input device")
                        Picker("", selection: $state.selectedInput) {
                            ForEach(state.devices.inputDevices) { d in
                                Text(d.isBuiltIn ? "\(d.name) (built-in)" : d.name)
                                    .tag(Optional(d))
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Virtual microphone")
                        HStack {
                            Picker("", selection: $state.selectedOutput) {
                                ForEach(state.devices.outputDevices) { d in
                                    Text(d.name).tag(Optional(d))
                                }
                            }
                            .labelsHidden()
                            virtualStatus
                        }
                    }
                    GridRow {
                        Text("Voice model")
                        HStack {
                            Picker("", selection: $state.selectedModel) {
                                Text("None (dry)").tag(Optional<VoiceModel>.none)
                                ForEach(state.modelStore.models) { m in
                                    Text(m.name).tag(Optional(m))
                                }
                            }
                            .labelsHidden()
                            Button("Manage / Enroll…") { showEnrollment = true }
                        }
                    }
                }
                .padding(6)
            }

            // Meters (scoped subview so 30 Hz updates don't re-render the window)
            LiveMetersView()

            // Big controls + readouts
            ControlsView(perf: perf)

            Spacer(minLength: 0)

            disclosureReminder
        }
        .padding(18)
        .onAppear { perf.start() }
        .onDisappear { perf.stop() }
        .sheet(isPresented: $showEnrollment) {
            EnrollmentView().environmentObject(state)
        }
    }

    /// Live guidance for the virtual-microphone routing.
    @ViewBuilder private var virtualStatus: some View {
        if state.devices.virtualOutput() == nil {
            Label("No virtual device — install BlackHole", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .help("Install BlackHole (brew install blackhole-2ch), then pick it here "
                      + "and select it as your microphone in Zoom/Meet/Teams.")
        } else if AudioDeviceManager.isVirtual(state.selectedOutput) {
            Label("Ready — pick this device as your mic in Zoom", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Select the virtual device to send to meetings", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .help("Choose BlackHole here to route converted audio into meeting apps. "
                      + "Keep a real output to hear yourself, or use a Multi-Output Device.")
        }
    }

    /// The standing disclosure reminder required by the brief. Non-dismissible.
    private var disclosureReminder: some View {
        Label {
            Text("Tell meeting participants that voice-converted audio is in use. "
                 + "This does not reproduce anyone's real voice identically.")
        } icon: {
            Image(systemName: "megaphone.fill")
        }
        .font(.footnote)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
