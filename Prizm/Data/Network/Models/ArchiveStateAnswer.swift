import Foundation

/// The two members Prizm takes from an archive or unarchive answer (archived-items, design D3).
/// Vaultwarden answers with the full cipher; the official server may answer with a smaller model,
/// so nothing else is read from it.
nonisolated struct ArchiveStateAnswer: Decodable, Equatable, Sendable {
    /// The `archivedDate` member as received; nil when the answer has no such key, `.null` for an
    /// unarchived item.
    let archivedDate: JSONValue?
    let revisionDate: String?

    private enum CodingKeys: String, CodingKey { case archivedDate, revisionDate }

    init(archivedDate: JSONValue?, revisionDate: String?) {
        self.archivedDate = archivedDate
        self.revisionDate = revisionDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `contains` + `decode`, not `decodeIfPresent`: `null` (unarchived) must stay distinct from
        // an absent key (an answer that says nothing).
        archivedDate = c.contains(.archivedDate) ? try? c.decode(JSONValue.self, forKey: .archivedDate) : nil
        revisionDate = try? c.decodeIfPresent(String.self, forKey: .revisionDate)
    }
}
