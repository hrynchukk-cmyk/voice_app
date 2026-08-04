import Foundation

/// The recorded permission attestation stored next to every voice model.
/// Written to `consent.json`. Its presence is a hard precondition for using a
/// model — there is no flag to skip it.
struct ConsentRecord: Codable, Equatable {
    /// The exact statement the user confirmed.
    let statement: String
    /// When they confirmed it.
    let confirmedAt: Date
    /// Optional free-text note (e.g. "signed release on file").
    let note: String?
    /// App version that recorded the attestation, for auditability.
    let appVersion: String
}

/// Gatekeeper for consent. Enrollment and model use both go through here.
///
/// This is a first-class safety component, not a checkbox: `VoiceModelStore`
/// only exposes models to the converter if `ConsentManager` can verify a valid
/// record on disk.
enum ConsentManager {
    /// The canonical statement the user must affirm to enroll a voice.
    static let requiredStatement =
        "I confirm I have the permission of the person whose voice this is to " +
        "create and use a voice model from these recordings, and I will " +
        "disclose to the people I talk to that voice-converted audio is in use."

    /// Record consent for a model folder. Call this *before* importing audio or
    /// registering the model. Throws if the user didn't affirm.
    static func recordConsent(in folderURL: URL,
                              affirmed: Bool,
                              note: String?) throws {
        guard affirmed else { throw ConsentError.notAffirmed }
        let record = ConsentRecord(
            statement: requiredStatement,
            confirmedAt: Date(),
            note: note,
            appVersion: Bundle.main.shortVersion
        )
        let url = folderURL.appendingPathComponent("consent.json")
        let data = try JSONEncoder.pretty.encode(record)
        try data.write(to: url, options: .atomic)
    }

    /// Verify a model has a readable, valid consent record. Used before load.
    static func verifyConsent(for model: VoiceModel) -> Bool {
        guard let data = try? Data(contentsOf: model.consentURL),
              let record = try? JSONDecoder.iso.decode(ConsentRecord.self, from: data)
        else { return false }
        return !record.statement.isEmpty
    }

    enum ConsentError: LocalizedError {
        case notAffirmed
        var errorDescription: String? {
            switch self {
            case .notAffirmed:
                return "You must confirm you have permission to use this voice before enrolling it."
            }
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    /// Matches `JSONEncoder.pretty`'s ISO-8601 date strategy.
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
