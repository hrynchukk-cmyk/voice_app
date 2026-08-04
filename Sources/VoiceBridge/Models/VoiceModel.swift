import Foundation

/// The engine format a model's weights are in.
enum VoiceModelEngine: String, Codable {
    case coreML        // .mlmodelc — native ANE/GPU (ship path)
    case onnx          // .onnx — via the ml/ backend (prototype)
    case pytorch       // .pth/.ckpt — training/prototype only
}

/// Metadata describing one locally stored, authorized voice model.
///
/// The actual weights and the imported source recordings live on disk in the
/// model's folder (see docs/VOICE_MODELS.md). This struct is what the UI and
/// converter pass around.
struct VoiceModel: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var engine: VoiceModelEngine
    var createdAt: Date

    /// Folder containing model.json, consent.json, weights, and sources/.
    var folderURL: URL

    /// Resolved path to the weights file inside `folderURL`.
    var weightsFileName: String

    var weightsURL: URL { folderURL.appendingPathComponent(weightsFileName) }
    var consentURL: URL { folderURL.appendingPathComponent("consent.json") }

    /// Whether a valid consent attestation exists on disk. The converter must
    /// refuse to load a model where this is false.
    var hasConsentOnDisk: Bool {
        FileManager.default.fileExists(atPath: consentURL.path)
    }
}
