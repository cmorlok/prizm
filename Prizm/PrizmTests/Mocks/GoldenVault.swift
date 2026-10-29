import Foundation
@testable import Prizm

/// The keys and ciphers of the extension-written golden fixture `sync-golden-1.37.4.json`.
///
/// The master password of the fixture account is public on purpose (`Fixtures/README.md`), so the
/// keys are derived here from it with the real `PrizmCryptoServiceImpl`, exactly as a sign-in does:
/// master key, stretched key, vault key, RSA private key, organization keys. No key material is
/// committed. PBKDF2 with 600 000 iterations is slow, so the derivation runs once per test process
/// and every caller gets fresh `Data` copies of the key bytes.
///
/// The fixture is read through `FixtureLoader`, which looks it up in the test bundle (the test host
/// is sandboxed, so never through `#filePath`).
@MainActor
enum GoldenVault {

    // MARK: - Public identifiers

    /// `00000000-0000-4000-8000-00000000000N`, N = 1 control (keyless), 2 SSH (keyed), 3 passkey
    /// login (keyed, one attachment), 4 twin (keyless), 6 organization login (keyed), 8 archived (keyed).
    static let controlId  = "00000000-0000-4000-8000-000000000001"
    static let sshId      = "00000000-0000-4000-8000-000000000002"
    static let passkeyId  = "00000000-0000-4000-8000-000000000003"
    static let twinId     = "00000000-0000-4000-8000-000000000004"
    static let orgLoginId = "00000000-0000-4000-8000-000000000006"
    static let archivedId = "00000000-0000-4000-8000-000000000008"
    static let orgId      = "00000000-0000-4000-8000-000000000007"

    /// The six cipher ids in the file.
    static let allIds = [controlId, sshId, passkeyId, twinId, orgLoginId, archivedId]

    private static let email    = "prizm-fixture@example.com"
    private static let password = "prizm-fixture-not-a-secret"

    // MARK: - Snapshot

    struct Snapshot {
        /// The fixture bytes exactly as stored, for tests that answer a real API client with them.
        let rawJSON: Data
        let response: SyncResponse
        /// Raw key bytes; `vaultKeys` and `orgKeys` build fresh `CryptoKeys` from them on each access.
        fileprivate let vaultKeyBytes: Data
        fileprivate let orgKeyBytes: [String: Data]

        var vaultKeys: CryptoKeys { CryptoKeys(data: Data(vaultKeyBytes))! }
        var orgKeys: [String: CryptoKeys] { orgKeyBytes.mapValues { CryptoKeys(data: Data($0))! } }
        var ciphers: [RawCipher] { response.ciphers }

        func cipher(id: String) -> RawCipher {
            guard let cipher = response.ciphers.first(where: { $0.id == id }) else {
                preconditionFailure("The golden fixture has no cipher \(id)")
            }
            return cipher
        }
    }

    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Loading

    private static var cached: Snapshot?

    /// The fixture and its keys, derived on first use.
    static func load() async throws -> Snapshot {
        if let cached { return cached }

        let rawJSON  = try FixtureLoader.data(named: "sync-golden-1.37.4")
        let response = try JSONDecoder().decode(SyncResponse.self, from: rawJSON)

        let crypto = PrizmCryptoServiceImpl()
        let master = try await crypto.makeMasterKey(
            password: Data(password.utf8), email: email,
            kdf: KdfParams(type: .pbkdf2, iterations: 600_000, memory: nil, parallelism: nil)
        )
        let stretched = try await crypto.stretchKey(masterKey: master)
        let vaultKeys = try await crypto.decryptSymmetricKey(encUserKey: response.profile.key, stretchedKeys: stretched)
        guard let encPrivateKey = response.profile.privateKey else {
            throw LoadError(description: "the fixture profile has no privateKey")
        }
        var rsa = try await crypto.decryptRSAPrivateKey(encPrivateKey: encPrivateKey, vaultKeys: vaultKeys)
        defer { rsa.resetBytes(in: rsa.indices) }

        var orgKeyBytes: [String: Data] = [:]
        for org in response.organizations {
            let key = try await crypto.unwrapOrgKey(encOrgKey: org.key, rsaPrivateKey: rsa)
            orgKeyBytes[org.id] = key.toData()
        }

        let snapshot = Snapshot(
            rawJSON: rawJSON, response: response,
            vaultKeyBytes: vaultKeys.toData(), orgKeyBytes: orgKeyBytes
        )
        cached = snapshot
        return snapshot
    }
}
