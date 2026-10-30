import XCTest
@testable import Prizm

/// Master key and server hash as Bitwarden derives them (openspec change
/// `fix-kdf-derivation-and-validation`, design D1–D4).
///
/// Expected values were computed with independent reference implementations, Python `hashlib`
/// (PBKDF2-SHA256) and `argon2-cffi` (Argon2id, version 0x13), on the inputs of the Bitwarden SDK's
/// tests. Nothing is copied from the SDK; the server hashes come out identical to the ones it
/// publishes (design.md, "Known-answer vectors").
final class KdfKnownAnswerTests: XCTestCase {

    private let sut = PrizmCryptoServiceImpl()
    private let password = Data("67t9b5g67$%Dh89n".utf8)

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func serverHash(password: String, salt: String, kdf: KdfParams) async throws -> String {
        let masterKey = try await sut.makeMasterKey(password: Data(password.utf8), salt: salt, kdf: kdf)
        return try await sut.makeServerHash(masterKey: masterKey, password: Data(password.utf8))
    }

    // MARK: - Master keys

    func testPBKDF2_masterKey() async throws {
        let kdf = KdfParams(type: .pbkdf2, iterations: 10_000, memory: nil, parallelism: nil)
        let key = try await sut.makeMasterKey(password: password, salt: "test_key", kdf: kdf)
        XCTAssertEqual(hex(key), "1f4f68e29647b15ac250acd1118184518aa745a7fe95021b27c5402a16c3564b")
    }

    /// SHA-256 of the salt, memory in MiB (design D1).
    func testArgon2id_masterKey() async throws {
        let kdf = KdfParams(type: .argon2id, iterations: 4, memory: 32, parallelism: 2)
        let key = try await sut.makeMasterKey(password: password, salt: "test_key", kdf: kdf)
        XCTAssertEqual(hex(key), "cff0e1b1a213a34c626ab3afe00911f01493ed2ff6968db83ee183f23335e1f2")
    }

    // MARK: - Server hashes

    /// The salt is trimmed and lowercased, so all three spellings give one hash (design D3).
    func testPBKDF2_serverHash_sameForEveryEmailSpelling() async throws {
        let kdf = KdfParams(type: .pbkdf2, iterations: 100_000, memory: nil, parallelism: nil)
        for email in ["test@bitwarden.com", "TEST@bitwarden.com", " test@bitwarden.com"] {
            let hash = try await serverHash(password: "asdfasdf", salt: email, kdf: kdf)
            XCTAssertEqual(hash, "wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=", "\"\(email)\"")
        }
    }

    func testArgon2id_serverHash() async throws {
        let kdf = KdfParams(type: .argon2id, iterations: 4, memory: 32, parallelism: 2)
        let hash = try await serverHash(password: "asdfasdf", salt: "test_salt", kdf: kdf)
        XCTAssertEqual(hash, "PR6UjYmjmppTYcdyTiNbAhPJuQQOmynKbdEl1oyi/iQ=")
    }

    // MARK: - Validation before deriving (design D2, D4)

    private func refusal(_ kdf: KdfParams) async -> PrizmCryptoServiceError? {
        do {
            _ = try await sut.makeMasterKey(password: password, salt: "test_key", kdf: kdf)
            return nil
        } catch {
            return error as? PrizmCryptoServiceError
        }
    }

    func testValidator_minimums() {
        let pbkdf2 = { (n: Int) in KdfParams(type: .pbkdf2, iterations: n, memory: nil, parallelism: nil) }
        let argon = { (t: Int, m: Int?, p: Int?) in KdfParams(type: .argon2id, iterations: t, memory: m, parallelism: p) }

        XCTAssertEqual(KdfValidator.check(pbkdf2(4999)), .tooWeak)
        XCTAssertNil(KdfValidator.check(pbkdf2(5000)))
        XCTAssertEqual(KdfValidator.check(argon(1, 16, 1)), .tooWeak)
        XCTAssertEqual(KdfValidator.check(argon(2, 15, 1)), .tooWeak)
        XCTAssertNil(KdfValidator.check(argon(2, 16, 1)))
        XCTAssertNil(KdfValidator.check(argon(3, 64, 4)))
    }

    func testValidator_unusableValues() {
        let pbkdf2 = { (n: Int) in KdfParams(type: .pbkdf2, iterations: n, memory: nil, parallelism: nil) }
        let argon = { (t: Int, m: Int?, p: Int?) in KdfParams(type: .argon2id, iterations: t, memory: m, parallelism: p) }

        for kdf in [pbkdf2(0), pbkdf2(-1), pbkdf2(Int.max),
                    argon(2, 16, 0), argon(2, 16, -1), argon(-2, 16, 1), argon(2, 1025, 1), argon(2, 16, 17),
                    argon(2, nil, 1), argon(2, 16, nil), argon(Int.max, 16, 1), argon(2, Int.max, 1)] {
            XCTAssertEqual(KdfValidator.check(kdf), .invalid, "\(kdf)")
        }
        XCTAssertNil(KdfValidator.check(argon(2, 1024, 16)), "the caps themselves are allowed")
    }

    func testMakeMasterKey_refusesBeforeDeriving() async {
        let weak = await refusal(KdfParams(type: .pbkdf2, iterations: 1, memory: nil, parallelism: nil))
        XCTAssertEqual(weak, .insufficientKdfParameters)
        let invalid = await refusal(KdfParams(type: .pbkdf2, iterations: -5, memory: nil, parallelism: nil))
        XCTAssertEqual(invalid, .invalidKdfParameters, "a negative value is refused, not trapped")
    }
}
