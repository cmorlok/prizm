import XCTest
@testable import Prizm

/// Every item Prizm creates carries its own random key, wrapped with the vault key or the
/// organization key, and every field is encrypted with it, as items the Bitwarden SDK creates since
/// sdk-internal `095bfda` (openspec change `per-item-key-on-create`).
///
/// Real crypto throughout: the request is decrypted independently of the mapper, and the answer is
/// built from the request as a server echoes it.
@MainActor
final class PerItemKeyOnCreateTests: XCTestCase {

    private struct Rig {
        let vault: VaultRepositoryImpl
        let api: MockPrizmAPIClient
        let crypto: MockPrizmCryptoService
        let cache: VaultKeyCache
        let store: RawCipherStore
        let service: VaultKeyServiceImpl
        let vaultKeys: CryptoKeys
        let orgKeys: CryptoKeys
    }

    private func makeRig() async -> Rig {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let api = MockPrizmAPIClient()
        // The server stores the request as sent and answers with it under a new id.
        api.createCipherResponder = { try RepositoryFixtures.echoCreated($0, id: "new-1") }
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys
        crypto._isUnlocked = true
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let cache = VaultKeyCache()
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store, vaultKeyCache: cache)
        let service = VaultKeyServiceImpl(cache: cache, orgKeyCache: orgKeyCache, crypto: crypto)
        return Rig(vault: vault, api: api, crypto: crypto, cache: cache, store: store, service: service,
                   vaultKeys: vaultKeys, orgKeys: orgKeys)
    }

    // MARK: - Drafts

    private func draft(_ content: ItemContent, organizationId: String? = nil) -> DraftVaultItem {
        var draft = DraftVaultItem(VaultItem(
            id: "draft", name: "Created", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(), content: content))
        draft.organizationId = organizationId
        if organizationId != nil { draft.collectionIds = ["col-a"] }
        return draft
    }

    private let field = CustomField(name: "Question", value: "Answer", type: .text, linkedId: nil)

    private func everyType() throws -> [(String, ItemContent)] {
        let ssh = try SSHKeyServiceImpl().generate()
        return [
            ("login", .login(LoginContent(username: "user", password: "pw",
                                          uris: [LoginURI(uri: "https://example.com", matchType: nil)],
                                          totp: nil, notes: "n", customFields: [field]))),
            ("card", .card(CardContent(cardholderName: "Jane", brand: "Visa", number: "4111111111111111",
                                       expMonth: "1", expYear: "2030", code: "123", notes: "n", customFields: [field]))),
            ("identity", .identity(IdentityContent(title: nil, firstName: "Jane", middleName: nil, lastName: "Doe",
                                                   address1: nil, address2: nil, address3: nil, city: "Bern",
                                                   state: nil, postalCode: nil, country: nil, company: nil,
                                                   email: "j@example.com", phone: nil, ssn: nil, username: nil,
                                                   passportNumber: nil, licenseNumber: nil, notes: "n",
                                                   customFields: [field]))),
            ("note", .secureNote(SecureNoteContent(notes: "secret note", customFields: [field]))),
            ("ssh", .sshKey(SSHKeyContent(privateKey: ssh.privateKey, publicKey: ssh.publicKey,
                                          keyFingerprint: ssh.fingerprint, notes: "n", customFields: [field]))),
        ]
    }

    // MARK: - Request checks

    /// Every EncString in the request except `key`, at any depth.
    private func encStrings(in value: Any, path: String = "", into found: inout [(String, String)]) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict where !(path.isEmpty && k == "key") {
                encStrings(in: v, path: path + "." + k, into: &found)
            }
        } else if let array = value as? [Any] {
            for (i, v) in array.enumerated() { encStrings(in: v, path: path + "[\(i)]", into: &found) }
        } else if let string = value as? String, string.hasPrefix("2.") {
            found.append((path, string))
        }
    }

    private func assertKeyed(_ request: RawCipher?, wrappedWith wrapping: CryptoKeys,
                             file: StaticString = #filePath, line: UInt = #line) throws -> CryptoKeys {
        let request = try XCTUnwrap(request, "no create request", file: file, line: line)
        let wrapped = try XCTUnwrap(request.key, "the create request has no key", file: file, line: line)
        let itemKeyData = try EncString(string: wrapped).decrypt(keys: wrapping)
        let itemKey = try XCTUnwrap(CryptoKeys(data: itemKeyData), "the item key is not 64 bytes", file: file, line: line)
        XCTAssertNotEqual(itemKeyData, wrapping.toData(), file: file, line: line)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        var found: [(String, String)] = []
        encStrings(in: json, into: &found)
        XCTAssertFalse(found.isEmpty, file: file, line: line)
        for (path, string) in found {
            let enc = try EncString(string: string)
            XCTAssertNoThrow(try enc.decrypt(keys: itemKey), "\(path) does not decrypt with the item key", file: file, line: line)
            XCTAssertThrowsError(try enc.decrypt(keys: wrapping), "\(path) decrypts with the wrapping key", file: file, line: line)
        }
        return itemKey
    }

    // MARK: - 3.1 Personal create, every type

    func testPersonalCreate_everyType_encryptsEveryFieldWithItsOwnKey() async throws {
        for (name, content) in try everyType() {
            let rig = await makeRig()
            _ = try await rig.vault.create(draft(content))
            _ = try assertKeyed(rig.api.lastCreatedCipher, wrappedWith: rig.vaultKeys)
            XCTAssertEqual(rig.api.createCipherCallCount, 1, name)
        }
    }

    func testTwoCreates_getDifferentKeys() async throws {
        let rig = await makeRig()
        let content = try everyType()[0].1
        _ = try await rig.vault.create(draft(content))
        let first = try assertKeyed(rig.api.lastCreatedCipher, wrappedWith: rig.vaultKeys)
        _ = try await rig.vault.create(draft(content))
        let second = try assertKeyed(rig.api.lastCreatedCipher, wrappedWith: rig.vaultKeys)
        XCTAssertNotEqual(first.toData(), second.toData())
    }

    // MARK: - 3.2 Org create

    func testOrgCreate_wrapsTheItemKeyWithTheOrgKey() async throws {
        let rig = await makeRig()
        _ = try await rig.vault.create(draft(try everyType()[0].1, organizationId: "org-1"))
        _ = try assertKeyed(rig.api.lastCreatedOrgCipher, wrappedWith: rig.orgKeys)
    }

    // MARK: - 1.2 / 4.1 The key is usable before the next sync

    func testKeyServiceReturnsTheGeneratedKeyRightAfterCreate() async throws {
        for orgId in [nil, "org-1"] as [String?] {
            let rig = await makeRig()
            let created = try await rig.vault.create(draft(try everyType()[0].1, organizationId: orgId))
            let request = orgId == nil ? rig.api.lastCreatedCipher : rig.api.lastCreatedOrgCipher
            let itemKey = try assertKeyed(request, wrappedWith: orgId == nil ? rig.vaultKeys : rig.orgKeys)
            let served = try await rig.service.cipherKey(for: created.id)
            XCTAssertEqual(served, itemKey.toData(), "org: \(orgId ?? "none")")
        }
    }

    // MARK: - 3.3 Nothing is sent without a key

    func testKeyGenerationFailure_sendsNothing() async throws {
        let rig = await makeRig()
        rig.crypto.symmetricKeyError = AttachmentCryptoError.keyGenerationFailed
        do {
            _ = try await rig.vault.create(draft(try everyType()[0].1))
            XCTFail("create must fail")
        } catch VaultError.itemKeyGenerationFailed {
            XCTAssertNotNil(VaultError.itemKeyGenerationFailed.errorDescription)
        }
        XCTAssertEqual(rig.api.createCipherCallCount, 0)
    }

    func testMissingOrgKey_sendsNothing() async throws {
        let rig = await makeRig()
        do {
            _ = try await rig.vault.create(draft(try everyType()[0].1, organizationId: "org-unknown"))
            XCTFail("create must fail")
        } catch VaultError.organizationKeyUnavailable {
            // expected
        }
        XCTAssertEqual(rig.api.createOrgCipherCallCount, 0)
    }

    // MARK: - 3.5 The answer must carry the generated key (design D4)

    private func assertUnconfirmed(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await rig.vault.create(draft(try everyType()[0].1))
            XCTFail("create must report the unconfirmed answer", file: file, line: line)
        } catch VaultError.createdButUnconfirmed {
            // expected
        }
        let listed = try await rig.vault.items(for: .allItems)
        XCTAssertTrue(listed.isEmpty, "nothing is listed until the next sync", file: file, line: line)
        let source = await rig.cache.source(for: "new-1")
        XCTAssertNil(source, "nothing is cached", file: file, line: line)
        let stored = await rig.store.record(for: "new-1")
        XCTAssertNil(stored, "the untrusted answer is not stored, so no edit builds on it", file: file, line: line)
    }

    func testAnswerWithoutKey_isNotUsed() async throws {
        let rig = await makeRig()
        rig.api.createCipherResponder = { try RepositoryFixtures.echoCreated($0, id: "new-1") { $0["key"] = NSNull() } }
        try await assertUnconfirmed(rig)
    }

    func testAnswerWithAnotherKey_isNotUsed() async throws {
        let rig = await makeRig()
        let other = try EncString.encrypt(data: KeyedCipherBuilder.randomKeys().toData(), keys: rig.vaultKeys).toString()
        rig.api.createCipherResponder = { try RepositoryFixtures.echoCreated($0, id: "new-1") { $0["key"] = other } }
        try await assertUnconfirmed(rig)
    }

    // Security review 2026-10-31: an answer with the right key that does not map was stored, and the
    // generic error left Save enabled, so a second Save created a duplicate.

    func testAnswerMovedToAnotherOrganization_isNotUsed() async throws {
        let rig = await makeRig()
        rig.api.createCipherResponder = { try RepositoryFixtures.echoCreated($0, id: "new-1") { $0["organizationId"] = "org-1" } }
        try await assertUnconfirmed(rig)
    }

    func testAnswerWithAFieldThatDoesNotDecrypt_isNotUsed() async throws {
        let rig = await makeRig()
        let foreign = try EncString.encrypt(data: Data("other".utf8), keys: KeyedCipherBuilder.randomKeys()).toString()
        rig.api.createCipherResponder = { try RepositoryFixtures.echoCreated($0, id: "new-1") { $0["name"] = foreign } }
        try await assertUnconfirmed(rig)
    }

    func testOrgCreateAnsweredAsPersonal_isNotUsed() async throws {
        let rig = await makeRig()
        rig.api.createCipherResponder = { try RepositoryFixtures.echoCreated($0, id: "new-1") { $0["organizationId"] = NSNull() } }
        do {
            _ = try await rig.vault.create(draft(try everyType()[0].1, organizationId: "org-1"))
            XCTFail("create must report the unconfirmed answer")
        } catch VaultError.createdButUnconfirmed {
            // expected
        }
        let stored = await rig.store.record(for: "new-1")
        XCTAssertNil(stored, "the untrusted answer is not stored")
        let listed = try await rig.vault.items(for: .allItems)
        XCTAssertTrue(listed.isEmpty)
    }
}
