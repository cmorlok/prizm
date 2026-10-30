import Foundation

/// A coding key that matches a JSON key whatever the case of its first letter, so `Kdf` and `kdf`
/// both match `"kdf"` (openspec change `fix-kdf-derivation-and-validation`, design D5).
///
/// Vaultwarden answers PascalCase inside `UserDecryptionOptions` and camelCase in prelogin; the
/// official server's casing has changed between versions. The TS clients
/// (`BaseResponse.getResponseProperty`) and the iOS app (`pascalOrSnakeCaseDecoder`) accept both,
/// so Prizm does too, for the two login responses only.
nonisolated struct FirstLetterCaseInsensitiveKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// `stringValue` with its first letter lowercased: the form every lookup uses.
    var normalized: String { stringValue.prefix(1).lowercased() + stringValue.dropFirst() }
}

nonisolated extension KeyedDecodingContainer where K == FirstLetterCaseInsensitiveKey {

    /// The key in the JSON object that matches `name` (given in camelCase), if any.
    func key(_ name: String) -> K? {
        allKeys.first { $0.normalized == name }
    }

    /// Like `decodeIfPresent(_:forKey:)`: nil when the key is absent or null; throws when the value
    /// has the wrong type.
    func decodeIfPresent<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        guard let key = key(name) else { return nil }
        return try decodeIfPresent(type, forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let key = key(name) else {
            throw DecodingError.keyNotFound(K(stringValue: name), .init(codingPath: codingPath,
                                            debugDescription: "No value for \(name)"))
        }
        return try decode(type, forKey: key)
    }

    func nestedContainer(_ name: String) throws -> KeyedDecodingContainer<K>? {
        guard let key = key(name), try !decodeNil(forKey: key) else { return nil }
        return try nestedContainer(keyedBy: K.self, forKey: key)
    }
}
