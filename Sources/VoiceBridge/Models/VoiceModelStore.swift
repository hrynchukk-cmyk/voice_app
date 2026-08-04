import Foundation

/// Manages the on-disk catalog of authorized voice models inside the app's
/// sandbox container. Nothing here touches the network.
///
/// Layout (see docs/VOICE_MODELS.md):
///   Application Support/VoiceBridge/Models/<uuid>/{model.json,consent.json,weights,sources/}
@MainActor
final class VoiceModelStore: ObservableObject {
    @Published private(set) var models: [VoiceModel] = []
    @Published var lastError: String?

    private let fm = FileManager.default

    /// Root: .../Application Support/VoiceBridge/Models
    lazy var modelsRoot: URL = {
        let appSupport = try! fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true)
        let root = appSupport
            .appendingPathComponent("VoiceBridge", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    init() {
        reload()
    }

    /// Rescan the models folder. Only models with a valid consent record are
    /// surfaced — this is where the consent gate is enforced at the store level.
    func reload() {
        var found: [VoiceModel] = []
        let dirs = (try? fm.contentsOfDirectory(at: modelsRoot,
                                                includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let metaURL = dir.appendingPathComponent("model.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var model = try? JSONDecoder.iso.decode(VoiceModel.self, from: data)
            else { continue }
            // Folder may have moved with the container; re-anchor it.
            model.folderURL = dir
            guard ConsentManager.verifyConsent(for: model) else {
                // A model without consent is intentionally hidden, not usable.
                continue
            }
            found.append(model)
        }
        models = found.sorted { $0.createdAt > $1.createdAt }
    }

    /// Create a new empty model folder and return its URL, ready for enrollment
    /// to write consent + sources + weights into.
    func makeModelFolder(id: UUID = UUID()) throws -> URL {
        let dir = modelsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sources"),
                               withIntermediateDirectories: true)
        return dir
    }

    /// Persist metadata for a model. Consent must already be recorded in the
    /// same folder (enforced here).
    func register(_ model: VoiceModel) throws {
        guard ConsentManager.verifyConsent(for: model) else {
            throw ConsentManager.ConsentError.notAffirmed
        }
        let data = try JSONEncoder.pretty.encode(model)
        try data.write(to: model.folderURL.appendingPathComponent("model.json"),
                       options: .atomic)
        reload()
    }

    /// Delete a model and **all** its local data: weights, imported originals,
    /// and the consent record. No hidden copies are kept.
    func delete(_ model: VoiceModel) {
        do {
            try fm.removeItem(at: model.folderURL)
            reload()
        } catch {
            lastError = "Could not delete model: \(error.localizedDescription)"
        }
    }

    /// Remove every model and all associated local data (Preferences action).
    func removeAllLocalData() {
        do {
            try fm.removeItem(at: modelsRoot)
            try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            reload()
        } catch {
            lastError = "Could not remove local data: \(error.localizedDescription)"
        }
    }
}
