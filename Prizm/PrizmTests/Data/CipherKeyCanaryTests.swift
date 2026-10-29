import XCTest
@testable import Prizm

/// Prizm must notice a server field it does not know instead of silently dropping it.
///
/// The canary decodes captured server payloads and fails when a top-level cipher key is not in
/// `CipherKeys.classified` (modelled, preserved or a known response-only key). The classification is
/// a checked-in literal: a test must never derive it from the payload it checks, or the canary could
/// not fail. A new key therefore fails here until a person decides to model, preserve or exclude it.
@MainActor
final class CipherKeyCanaryTests: XCTestCase {

    // MARK: - Helpers

    /// `cipher-official-shaped.json` wraps its ciphers next to a `_note`, which decoding ignores.
    private struct CipherDocument: Decodable {
        let ciphers: [RawCipher]
    }

    private func officialShapedCiphers() throws -> [RawCipher] {
        try JSONDecoder().decode(CipherDocument.self, from: FixtureLoader.data(named: "cipher-official-shaped")).ciphers
    }

    private func decode(_ json: String) throws -> RawCipher {
        try JSONDecoder().decode(RawCipher.self, from: Data(json.utf8))
    }

    private func goldenCiphers() throws -> [RawCipher] {
        try JSONDecoder().decode(SyncResponse.self, from: FixtureLoader.data(named: "sync-golden-1.37.4")).ciphers
    }

    // MARK: - Canary

    func testGoldenFixture_hasNoUnclassifiedTopLevelKey() throws {
        let ciphers = try goldenCiphers()
        XCTAssertFalse(ciphers.isEmpty, "The golden fixture has no ciphers, so the canary would check nothing")
        for cipher in ciphers {
            XCTAssertEqual(cipher.unclassifiedKeys, [],
                           "Cipher \(cipher.id) carries top-level keys Prizm does not classify: \(cipher.unclassifiedKeys)")
        }
    }

    func testOfficialShapedFixture_hasNoUnclassifiedTopLevelKey() throws {
        let ciphers = try officialShapedCiphers()
        XCTAssertFalse(ciphers.isEmpty, "The official-shaped fixture has no ciphers, so the canary would check nothing")
        for cipher in ciphers {
            XCTAssertEqual(cipher.unclassifiedKeys, [],
                           "Cipher \(cipher.id) carries top-level keys Prizm does not classify: \(cipher.unclassifiedKeys)")
        }
    }

    func testOfficialShapedFixture_dataAndPartialDataAreNeverEncoded() throws {
        let raw = try JSONSerialization.jsonObject(with: FixtureLoader.data(named: "cipher-official-shaped")) as? [String: Any]
        let serverCiphers = try XCTUnwrap(raw?["ciphers"] as? [[String: Any]])
        XCTAssertTrue(serverCiphers.allSatisfy { $0["data"] != nil && $0["partialData"] != nil },
                      "The fixture must carry data and partialData for this test to mean anything")

        for cipher in try officialShapedCiphers() {
            let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(cipher)) as? [String: Any])
            XCTAssertNil(sent["data"], "Cipher \(cipher.id): the official server stores a request's data verbatim, so it must never be sent")
            XCTAssertNil(sent["partialData"], "Cipher \(cipher.id)")
        }
    }

    func testCanaryCanFail_onASyntheticFutureKey() throws {
        let cipher = try decode(#"{"id":"i","type":1,"name":"n","favorite":false,"futureKey":1}"#)

        XCTAssertEqual(cipher.unclassifiedKeys, ["futureKey"])
    }

    func testClassification_matchesTheModel() {
        XCTAssertEqual(RawCipher.codingKeyNames, CipherKeys.modelled.union(CipherKeys.preserved))
        XCTAssertTrue(CipherKeys.modelled.isDisjoint(with: CipherKeys.preserved))
        XCTAssertTrue(CipherKeys.modelled.isDisjoint(with: CipherKeys.serverDerived))
        XCTAssertTrue(CipherKeys.preserved.isDisjoint(with: CipherKeys.serverDerived))
    }

    func testUnclassifiedKeys_areNeverEncoded() throws {
        let cipher = try decode(#"{"id":"i","type":1,"name":"n","favorite":false,"futureKey":1}"#)
        XCTAssertEqual(cipher.unclassifiedKeys, ["futureKey"], "The fixture must carry an unknown key for this test to mean anything")

        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(cipher)) as? [String: Any])

        XCTAssertNil(sent["futureKey"])
        XCTAssertNil(sent["unclassifiedKeys"])
    }

    // MARK: - Log text

    func testLogText_nilForNoNames() {
        XCTAssertNil(CipherKeys.unclassifiedKeyLogText([String]()))
    }

    func testLogText_listsSortedSanitisedNames() {
        XCTAssertEqual(CipherKeys.unclassifiedKeyLogText(["b", "a_1", "x-y.z"]), "a_1, b, xyz")
    }

    func testLogText_cutsNamesAt64Characters() {
        let long = String(repeating: "a", count: 100)

        XCTAssertEqual(CipherKeys.unclassifiedKeyLogText([long]), String(repeating: "a", count: 64))
    }

    func testLogText_listsAtMost20Names() throws {
        let names = (1...25).map { String(format: "key%02d", $0) }

        let text = try XCTUnwrap(CipherKeys.unclassifiedKeyLogText(names))

        XCTAssertEqual(text, names.prefix(20).joined(separator: ", ") + " (+5 more)")
    }

    func testLogText_dropsNamesWithNoAllowedCharacter() {
        XCTAssertEqual(CipherKeys.unclassifiedKeyLogText(["--", "ok"]), "ok (+1 more)")
        XCTAssertEqual(CipherKeys.unclassifiedKeyLogText(["--"]), "(+1 more)")
    }

    func testLogText_keepsOnlyAsciiLettersDigitsAndUnderscore() {
        // An emoji, a newline and a percent sign could forge log lines or format directives.
        XCTAssertEqual(CipherKeys.unclassifiedKeyLogText(["a\u{1F600}b\nc%d_9é"]), "abcd_9")
    }

    // MARK: - Nested inventory

    /// The unknown keys Prizm keeps at each nested level of the captured payloads. A change here is a
    /// decision to take: preserve the new key (it is then listed below) or add it to the level's
    /// `excludedKeys`. The literal is written by hand from what the two fixtures hold by design.
    func testNestedInventory_matchesTheCheckedInSnapshot() throws {
        var found: [String: Set<String>] = [
            "login": [], "login.uris[]": [], "card": [], "identity": [], "sshKey": [], "fields[]": [], "secureNote": [],
        ]

        // The kitchen-sink fixture is synthetic and stays out of the snapshot.
        for name in ["sync-golden-1.37.4", "cipher-official-shaped"] {
            let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: FixtureLoader.data(named: name)) as? [String: Any])
            let serverCiphers = try XCTUnwrap(document["ciphers"] as? [[String: Any]], "\(name).json has no ciphers array")
            for serverCipher in serverCiphers {
                let cipher = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: serverCipher))
                found["login", default: []].formUnion((cipher.login?.extras ?? [:]).keys)
                for uri in cipher.login?.uris ?? [] { found["login.uris[]", default: []].formUnion(uri.extras.keys) }
                found["card", default: []].formUnion((cipher.card?.extras ?? [:]).keys)
                found["identity", default: []].formUnion((cipher.identity?.extras ?? [:]).keys)
                found["sshKey", default: []].formUnion((cipher.sshKey?.extras ?? [:]).keys)
                for field in cipher.fields ?? [] { found["fields[]", default: []].formUnion(field.extras.keys) }
                // `RawSecureNoteData` has no extras, so a new key there would be dropped on edit: read it
                // from the raw JSON to force a decision.
                if let note = serverCipher["secureNote"] as? [String: Any] {
                    found["secureNote", default: []].formUnion(note.keys.filter { $0 != "type" })
                }
            }
        }

        let inventory = found.mapValues { $0.sorted() }
        XCTAssertEqual(inventory, [
            "login": ["autofillOnPageLoad", "fido2Credentials"],
            "login.uris[]": [],
            "card": [],
            "identity": [],
            "sshKey": [],
            "fields[]": [],
            "secureNote": [],
        ])
    }
}
