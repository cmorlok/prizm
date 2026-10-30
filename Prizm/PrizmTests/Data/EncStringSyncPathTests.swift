import XCTest
@testable import Prizm

/// fix-encstring-validation, tasks 1.4 and 1.5: what a type-0 value (MAC stripped) does on each read
/// path. Real crypto; each type-0 string is a real type-2 encryption with its MAC part removed, so it
/// would decrypt to the right plaintext if Prizm accepted it.
@MainActor
final class EncStringSyncPathTests: XCTestCase {

    private let mapper = CipherMapper()
    private let vaultKeys = KeyedCipherBuilder.randomKeys()

    /// `plaintext` under `keys`, as type 0: the IV and ciphertext of a type-2 string without its MAC.
    private func type0(_ plaintext: String, keys: CryptoKeys) -> String {
        let parts = KeyedCipherBuilder.encrypt(plaintext, keys: keys).dropFirst(2).split(separator: "|")
        return "0.\(parts[0])|\(parts[1])"
    }

    private func json(_ raw: RawCipher) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> RawCipher {
        try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// A login whose password is type 0, encrypted with `keys`.
    private func loginWithType0Password(id: String, organizationId: String? = nil, keys: CryptoKeys) throws -> RawCipher {
        var object = try json(KeyedCipherBuilder.login(id: id, name: "Type 0", username: "u", password: "p",
                                                       organizationId: organizationId, activeKeys: keys))
        var login = try XCTUnwrap(object["login"] as? [String: Any])
        login["password"] = type0("p", keys: keys)
        object["login"] = login
        return try decode(object)
    }

    private func attachment(id: String, fileName: String, key: String) -> [String: Any] {
        ["id": id, "fileName": fileName, "key": key, "size": "80", "sizeName": "80 Bytes"]
    }

    // MARK: - Item fields

    func testPersonalItemWithAType0Field_isExcludedAndCounted() async throws {
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: vaultKeys)
        let good = KeyedCipherBuilder.login(id: "good", name: "Good", activeKeys: vaultKeys)
        let bad = try loginWithType0Password(id: "bad", keys: vaultKeys)

        let result = try await crypto.decryptList(ciphers: [good, bad])

        XCTAssertEqual(result.items.map(\.id), ["good"])
        XCTAssertEqual(result.failedCount, 1)
    }

    func testOrgItemWithAType0Field_failsToMap() throws {
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let bad = try loginWithType0Password(id: "org-bad", organizationId: "org-1", keys: orgKeys)

        XCTAssertThrowsError(try mapper.map(raw: bad, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]))
    }

    // MARK: - Attachment names

    func testAttachmentWithAType0Name_dropsOnlyThatAttachment() throws {
        let attachmentKey = KeyedCipherBuilder.encrypt(String(repeating: "k", count: 64), keys: vaultKeys)
        var object = try json(KeyedCipherBuilder.login(id: "item", name: "Item", activeKeys: vaultKeys))
        object["attachments"] = [
            attachment(id: "good", fileName: KeyedCipherBuilder.encrypt("a.txt", keys: vaultKeys), key: attachmentKey),
            attachment(id: "bad", fileName: type0("b.txt", keys: vaultKeys), key: attachmentKey),
        ]

        let mapped = try mapper.map(raw: try decode(object), vaultKeys: vaultKeys)

        XCTAssertEqual(mapped.item.attachments.map(\.id), ["good"])
    }

    func testOrgAttachmentWithAType0Name_isNotRescuedByThePersonalKey() throws {
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let attachmentKey = KeyedCipherBuilder.encrypt(String(repeating: "k", count: 64), keys: orgKeys)
        var object = try json(KeyedCipherBuilder.login(id: "org-item", name: "Item", organizationId: "org-1",
                                                       activeKeys: orgKeys))
        // Type 0 under the personal key: the personal-key retry for org attachments must refuse it too.
        object["attachments"] = [attachment(id: "bad", fileName: type0("b.txt", keys: vaultKeys), key: attachmentKey)]

        let mapped = try mapper.map(raw: try decode(object), vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys])

        XCTAssertEqual(mapped.item.attachments.map(\.id), [])
    }

    // MARK: - Folder names

    func testFolderWithAType0Name_isDroppedAndCounted() async throws {
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: vaultKeys)
        let folders = [
            RawFolder(id: "good", name: KeyedCipherBuilder.encrypt("Work", keys: vaultKeys), revisionDate: nil),
            RawFolder(id: "bad", name: type0("Home", keys: vaultKeys), revisionDate: nil),
        ]

        let result = try await crypto.decryptFolders(folders: folders)

        XCTAssertEqual(result.folders.map(\.id), ["good"])
        XCTAssertEqual(result.failedCount, 1)
    }

    // MARK: - User key

    func testUserKeyOfType0_isRefusedAsInvalid() async throws {
        let stretched = KeyedCipherBuilder.randomKeys()
        let userKey = KeyedCipherBuilder.randomKeys().toData().base64EncodedString()
        let parts = KeyedCipherBuilder.encrypt(userKey, keys: stretched).dropFirst(2).split(separator: "|")

        do {
            _ = try await PrizmCryptoServiceImpl().decryptSymmetricKey(
                encUserKey: "0.\(parts[0])|\(parts[1])", stretchedKeys: stretched)
            XCTFail("a type-0 user key must be refused")
        } catch {
            XCTAssertEqual(error as? PrizmCryptoServiceError, .invalidEncUserKey)
        }
    }

    // MARK: - Task 1.5: attachment keys

    func testAttachmentKeyOfType0_isNeverUnwrapped() throws {
        let crypto = PrizmCryptoServiceImpl()
        let wrapped = type0(String(repeating: "k", count: 64), keys: vaultKeys)

        XCTAssertThrowsError(try crypto.decryptAttachmentKey(wrapped, cipherKey: vaultKeys)) { error in
            XCTAssertEqual(error as? EncStringError, .unsupportedEncType)
        }
    }
}
