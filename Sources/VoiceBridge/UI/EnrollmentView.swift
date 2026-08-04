import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The consent-gated enrollment / import flow. The **Import** button stays
/// disabled until the permission attestation is checked, so a model literally
/// cannot be created without recorded consent.
struct EnrollmentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var modelName = ""
    @State private var affirmedConsent = false
    @State private var consentNote = ""
    @State private var importedFiles: [URL] = []
    @State private var progressText: String?
    @State private var errorText: String?

    // Build from extensions so we don't depend on specific UTType static members.
    private let allowedTypes: [UTType] =
        ["wav", "aiff", "aif", "m4a", "flac", "caf"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enroll an authorized voice").font(.title2.bold())

            // Consent gate — the hard precondition.
            GroupBox("Consent (required)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $affirmedConsent) {
                        Text(ConsentManager.requiredStatement).font(.callout)
                    }
                    TextField("Optional note (e.g. 'signed release on file')", text: $consentNote)
                }
                .padding(6)
            }

            GroupBox("Model") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Model name (e.g. 'Alex – authorized')", text: $modelName)
                    HStack {
                        Button("Choose recordings…", action: pickFiles)
                        Text("\(importedFiles.count) file(s)").foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            // Quality guidance
            GroupBox("Recommended training audio") {
                VStack(alignment: .leading, spacing: 4) {
                    guidance("Clean speech, one speaker")
                    guidance("Minimal music / background noise / reverb")
                    guidance("A variety of phonetic content (varied sentences)")
                    guidance("Consistent microphone distance; avoid clipping")
                    guidance("Formats: WAV, AIFF, M4A, FLAC")
                }
                .font(.callout)
                .padding(6)
            }

            if let progressText { Label(progressText, systemImage: "clock").foregroundStyle(.secondary) }
            if let errorText { Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)   // consent + name + files required
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var canImport: Bool {
        affirmedConsent && !modelName.trimmingCharacters(in: .whitespaces).isEmpty && !importedFiles.isEmpty
    }

    private func guidance(_ s: String) -> some View {
        Label(s, systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedTypes
        if panel.runModal() == .OK { importedFiles = panel.urls }
    }

    /// Import copies originals into the model folder (preserved) and records
    /// consent. Actual feature-extraction/training (Phase 4) would run here,
    /// streaming progress; the scaffold stops at copy + consent + metadata.
    private func runImport() {
        errorText = nil
        do {
            let id = UUID()
            let folder = try state.modelStore.makeModelFolder(id: id)

            // 1) Record consent BEFORE touching audio.
            try ConsentManager.recordConsent(in: folder,
                                             affirmed: affirmedConsent,
                                             note: consentNote.isEmpty ? nil : consentNote)

            // 2) Copy originals into sources/ (preserve originals on disk).
            progressText = "Copying \(importedFiles.count) file(s)…"
            let sources = folder.appendingPathComponent("sources")
            for url in importedFiles {
                let dest = sources.appendingPathComponent(url.lastPathComponent)
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    try FileManager.default.copyItem(at: url, to: dest)
                }
            }

            // 3) Write model metadata. In a real build, weights come from
            //    training/conversion; here we mark it pending.
            let model = VoiceModel(
                id: id, name: modelName, engine: .coreML, createdAt: Date(),
                folderURL: folder, weightsFileName: "weights.mlmodelc")
            try state.modelStore.register(model)

            progressText = "Done. Model enrolled (weights pending training)."
            dismiss()
        } catch {
            errorText = error.localizedDescription
            progressText = nil
        }
    }
}
