import Foundation
@testable import Prizm

/// Builds synthetic `RawCipher`s with real type-2 EncStrings, for tests of which key reads and
/// writes a cipher: keyed and keyless, personal and organization, and the wrong-key cases.
///
/// Real crypto on purpose (Constitution VII): a mock that returns plaintext would not notice a field
/// read with the wrong key. Only initializer arguments that exist since before the wire model are used.
enum KeyedCipherBuilder {

    /// A fresh random key pair (64 random bytes through `CryptoKeys(data:)`).
    static func randomKeys() -> CryptoKeys {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return CryptoKeys(data: Data(bytes))!
    }

    /// `plaintext` as a type-2 EncString under `keys`.
    static func encrypt(_ plaintext: String, keys: CryptoKeys) -> String {
        try! EncString.encrypt(data: Data(plaintext.utf8), keys: keys).toString()
    }

    /// A login cipher.
    ///
    /// - Parameters:
    ///   - activeKeys: the vault key (personal) or organization key; what a keyless cipher is
    ///     encrypted with, and what wraps `key` of a keyed one.
    ///   - itemKey: the cipher's own key. Non-nil makes the cipher keyed: `key` carries these 64
    ///     bytes wrapped under `wrappingKeys`.
    ///   - fieldKeys: the key the fields are encrypted with. Defaults to `itemKey`, else `activeKeys`.
    ///     A value different from the default builds a cipher whose fields do not match its key.
    ///   - wrappingKeys: the key `key` is wrapped under. Defaults to `activeKeys`; another key builds
    ///     a cipher whose `key` does not unwrap.
    ///   - wrappedKeyBytes: replaces the bytes inside `key` (for example 32 or 96 bytes instead of 64).
    static func login(
        id: String,
        name: String,
        username: String? = nil,
        password: String? = nil,
        website: String? = nil,
        organizationId: String? = nil,
        collectionIds: [String] = [],
        activeKeys: CryptoKeys,
        itemKey: CryptoKeys? = nil,
        fieldKeys: CryptoKeys? = nil,
        wrappingKeys: CryptoKeys? = nil,
        wrappedKeyBytes: Data? = nil
    ) -> RawCipher {
        let keysForFields = fieldKeys ?? itemKey ?? activeKeys
        let wrappedKey: String?
        if let wrappedKeyBytes {
            wrappedKey = try! EncString.encrypt(data: wrappedKeyBytes, keys: wrappingKeys ?? activeKeys).toString()
        } else if let itemKey {
            wrappedKey = try! EncString.encrypt(data: itemKey.toData(), keys: wrappingKeys ?? activeKeys).toString()
        } else {
            wrappedKey = nil
        }
        // With its checksum, as every current Bitwarden client writes one (uri-checksum-validation).
        let uris: [RawURI]? = website.map {
            [RawURI(uri: encrypt($0, keys: keysForFields), match: nil,
                    uriChecksum: encrypt(CipherMapper.uriChecksumPlaintext($0), keys: keysForFields))]
        }
        return RawCipher(
            id: id, organizationId: organizationId, folderId: nil, type: 1,
            name: encrypt(name, keys: keysForFields), notes: nil, favorite: false, reprompt: 0,
            deletedDate: nil, creationDate: "2026-10-26T12:00:00.000000Z", revisionDate: "2026-10-26T12:00:00.000000Z",
            login: RawLoginData(
                username: username.map { encrypt($0, keys: keysForFields) },
                password: password.map { encrypt($0, keys: keysForFields) },
                uris: uris, totp: nil
            ),
            card: nil, identity: nil, secureNote: nil, sshKey: nil, fields: nil,
            key: wrappedKey, collectionIds: collectionIds, attachments: nil
        )
    }
}
