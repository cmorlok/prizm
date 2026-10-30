import XCTest
import CryptoKit
@testable import Prizm

/// fix-encstring-validation, task 5.2: `stretchKey` is HKDF-Expand without Extract (RFC 5869 §2.3),
/// as the Bitwarden SDK's `stretch_key`. Checked against the SDK's own vector and against CryptoKit's
/// Expand-only API, so the hand-written single-block helper stays verifiably equal to both.
final class KeyStretchKATTests: XCTestCase {

    /// `test_stretch_kdf_key`, bitwarden/sdk-internal `crates/bitwarden-crypto/src/keys/utils.rs`
    /// at c1c9b9a540510f9f8b3f4eb37c0738f510f89b98.
    private static let masterKey = Data([
        31, 79, 104, 226, 150, 71, 177, 90, 194, 80, 172, 209, 17, 129, 132, 81, 138, 167,
        69, 167, 254, 149, 2, 27, 39, 197, 64, 42, 22, 195, 86, 75,
    ])
    private static let expectedEncKey = Data([
        111, 31, 178, 45, 238, 152, 37, 114, 143, 215, 124, 83, 135, 173, 195, 23, 142,
        134, 120, 249, 61, 132, 163, 182, 113, 197, 189, 204, 188, 21, 237, 96,
    ])
    private static let expectedMacKey = Data([
        221, 127, 206, 234, 101, 27, 202, 38, 86, 52, 34, 28, 78, 28, 185, 16, 48, 61, 127,
        166, 209, 247, 194, 87, 232, 26, 48, 85, 193, 249, 179, 155,
    ])

    func testStretchKey_matchesTheSDKVector() async throws {
        let stretched = try await PrizmCryptoServiceImpl().stretchKey(masterKey: Self.masterKey)

        XCTAssertEqual(stretched.encryptionKey, Self.expectedEncKey)
        XCTAssertEqual(stretched.macKey, Self.expectedMacKey)
    }

    private func expand(_ prk: Data, _ info: String) -> Data {
        HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    func testCryptoKitHKDFExpand_reproducesTheSDKVector() {
        XCTAssertEqual(expand(Self.masterKey, "enc"), Self.expectedEncKey)
        XCTAssertEqual(expand(Self.masterKey, "mac"), Self.expectedMacKey)
    }

    func testStretchKey_matchesCryptoKitHKDFExpand_forAnotherKey() async throws {
        let masterKey = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        let stretched = try await PrizmCryptoServiceImpl().stretchKey(masterKey: masterKey)

        XCTAssertEqual(stretched.encryptionKey, expand(masterKey, "enc"))
        XCTAssertEqual(stretched.macKey, expand(masterKey, "mac"))
    }
}
