import Foundation

/// The answer to a collection change of an item (`PUT /api/ciphers/{id}/collections_v2`,
/// `OptionalCipherDetailsResponseModel`; openspec change `fix-collection-assignment`, D5).
nonisolated struct CipherCollectionsResult {
    /// The user can no longer see the item after the change.
    let unavailable: Bool
    /// The item as the server holds it now; nil when the answer has none Prizm can read. The change
    /// itself succeeded then, and the caller fetches the item.
    let cipher: RawCipher?
}

/// `{ "unavailable": Bool, "cipher": CipherDetails? }`, either key casing.
nonisolated struct OptionalCipherDetailsResponse: Decodable {
    let unavailable: Bool
    let cipher: RawCipher?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable)
            ?? c.decodeIfPresent(Bool.self, forKey: .unavailableUpper) ?? false
        // An unreadable cipher is not a failed change: the caller fetches the item instead.
        cipher = (try? c.decodeIfPresent(RawCipher.self, forKey: .cipher))
            ?? (try? c.decodeIfPresent(RawCipher.self, forKey: .cipherUpper)) ?? nil
    }

    private enum Keys: String, CodingKey {
        case unavailable, unavailableUpper = "Unavailable"
        case cipher, cipherUpper = "Cipher"
    }
}
