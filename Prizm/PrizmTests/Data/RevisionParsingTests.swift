import XCTest
@testable import Prizm

/// One parse of the server's `revisionDate`, shared by the item's date and the stale-write check, so
/// the two cannot disagree about a revision (openspec change fix-cipher-edit-data-loss, task 4.0).
///
/// The shapes are the ones the two servers send: Vaultwarden writes six fractional digits, the
/// official server seven, and either may omit the fraction when it is zero.
@MainActor
final class RevisionParsingTests: XCTestCase {

    private let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xDE, count: 32),
        macKey:        Data(repeating: 0xAD, count: 32)
    )

    /// The parsed date as whole milliseconds since 1970, the resolution the app compares at.
    private func milliseconds(_ raw: String?) -> Int64? {
        CipherMapper.parseRevisionDate(raw).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    func testParse_vaultwardenSixDigits() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.393118Z"), 1_793_040_841_393)
    }

    func testParse_officialSevenDigits() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.3931180Z"), 1_793_040_841_393)
    }

    func testParse_threeDigits() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.393Z"), 1_793_040_841_393)
    }

    func testParse_noFraction() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01Z"), 1_793_040_841_000)
    }

    func testParse_offset() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.393118+00:00"), 1_793_040_841_393)
    }

    /// Every shape in one table: the same instant (2026-10-26 18:54:01.393 UTC) written the ways a
    /// server or a proxy may write it. A row that fails names its input.
    func testParse_sameInstantInEveryShape() {
        let instant: Int64 = 1_793_040_841_393
        let inputs = [
            "2026-10-26T18:54:01.393Z",
            "2026-10-26T18:54:01.3931Z",
            "2026-10-26T18:54:01.39311Z",
            "2026-10-26T18:54:01.393118Z",
            "2026-10-26T18:54:01.3931180Z",
            "2026-10-26T18:54:01.39311800Z",
            "2026-10-26T18:54:01.393118000Z",
            "2026-10-26T18:54:01.393118+00:00",
            "2026-10-26T18:54:01.393118-00:00",
            "2026-10-26T20:54:01.393118+02:00",
            "2026-10-26T13:24:01.393118-05:30",
            "2026-10-27T08:24:01.393118+13:30",
        ]
        for input in inputs {
            XCTAssertEqual(milliseconds(input), instant, "input: \(input)")
        }
    }

    /// One and two fractional digits are tenths and hundredths of a second, not milliseconds.
    func testParse_shortFractionsAreDecimalFractions() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.4Z"), 1_793_040_841_400)
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.39Z"), 1_793_040_841_390)
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.0Z"), 1_793_040_841_000)
    }

    /// An offset on a revision without a fraction.
    func testParse_offsetWithoutFraction() {
        XCTAssertEqual(milliseconds("2026-10-26T20:54:01+02:00"), 1_793_040_841_000)
    }

    /// Anything that is not a full date-time with a zone is not a revision: the stale-write check
    /// refuses an unreadable one instead of guessing, so the parser must not guess either.
    func testParse_notAFullDateTimeWithAZone_isNil() {
        let inputs = [
            "2026-10-26",                     // date only
            "2026-10-26T18:54:01",            // no zone
            "2026-10-26T18:54:01.393",        // fraction, no zone
            "2026-10-26 18:54:01Z",           // space instead of T
            "2026-13-01T00:00:00Z",           // month 13
            "2026-10-32T00:00:00Z",           // day 32
            "2026-10-26T25:00:00Z",           // hour 25
            "2026-10-26T18:60:00Z",           // minute 60
            "2026-10-26T18:54:01.Z",          // empty fraction
            "0",                              // a number
            "1793040841",                     // epoch seconds as text
        ]
        for input in inputs {
            XCTAssertNil(CipherMapper.parseRevisionDate(input), "input: \(input)")
        }
    }

    /// RFC 3339 section 5.6 allows a lowercase `t` and `z`, and no server Prizm talks to writes
    /// either. Pinned as `ISO8601DateFormatter` behaves, so that a change of parser shows up here: it
    /// reads a lowercase `z` and refuses a lowercase `t`.
    func testParse_lowercaseZIsRead_lowercaseTIsNot() {
        XCTAssertEqual(milliseconds("2026-10-26T18:54:01.393z"), 1_793_040_841_393)
        XCTAssertNil(CipherMapper.parseRevisionDate("2026-10-26t18:54:01.393Z"))
    }

    func testParse_emptyGarbageAndNil_areNil() {
        XCTAssertNil(CipherMapper.parseRevisionDate(nil))
        XCTAssertNil(CipherMapper.parseRevisionDate(""))
        XCTAssertNil(CipherMapper.parseRevisionDate("not-a-date"))
    }

    /// The epoch is a valid date, so the parser returns it; the stale-write check refuses it later
    /// (a stored revision of 1970 is what a missing one looks like after a fallback).
    func testParse_epochParses() {
        let epoch = CipherMapper.parseRevisionDate("1970-01-01T00:00:00.000Z")
        XCTAssertEqual(epoch?.timeIntervalSince1970, 0)
    }

    /// A revision without a fraction used to fall back to the epoch in `map`, which would make the
    /// item's date and the check read the same string two ways.
    func testMap_fractionlessRevision_isNotTheEpoch() throws {
        let item = VaultItem(
            id: "c1", name: "Login", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])))
        let record = try CipherMapper().toNewRawCipher(
            DraftVaultItem(item), encryptedWith: vaultKeys, encryptedFor: "pid")
        let stamped = try RepositoryFixtures.withRevision(record, "2026-10-26T18:54:01Z")

        let mapped = try CipherMapper().map(raw: stamped, keys: vaultKeys).item

        XCTAssertEqual(mapped.revisionDate.timeIntervalSince1970, 1_793_040_841)
    }

    func testSameRevision_millisecondResolution() {
        let base = Date(timeIntervalSince1970: 1_793_008_800.123)
        XCTAssertTrue(CipherMapper.sameRevision(base, Date(timeIntervalSince1970: 1_793_008_800.123)))
        XCTAssertFalse(CipherMapper.sameRevision(base, Date(timeIntervalSince1970: 1_793_008_800.124)),
                       "1 ms apart is another revision")
        XCTAssertTrue(CipherMapper.sameRevision(base, Date(timeIntervalSince1970: 1_793_008_800.1234)),
                      "0.4 ms rounds to the same millisecond")
    }
}
