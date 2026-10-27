import XCTest
@testable import Prizm

/// The wire model keeps what other Bitwarden clients stored in a cipher and never writes back what
/// only a response carries. See `RawCipher.swift` and `JSONValue.swift`.
@MainActor
final class RawCipherWireModelTests: XCTestCase {

    private let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xDE, count: 32),
        macKey:        Data(repeating: 0xAD, count: 32)
    )

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - Helpers

    private func makeClient() async -> PrizmAPIClientImpl {
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token")
        return client
    }

    // MARK: - Characterization: the request bodies Prizm builds today

    /// Guards that a preserved field never reaches a request Prizm builds from a draft. The key
    /// sets were measured on the unchanged model before the wire model was rewritten.
    func testMapperBody_keySetsAreUnchanged() throws {
        let draft = DraftVaultItem(
            id: "c1", name: "Example", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(DraftLoginContent(LoginContent(
                username: "user", password: "secret",
                uris: [LoginURI(uri: "https://example.com", matchType: nil)],
                totp: nil, notes: nil, customFields: []
            ))),
            reprompt: 0
        )

        let raw = try CipherMapper().toRawCipher(draft, encryptedWith: vaultKeys, encryptedFor: "pid")
        let bytes = try JSONEncoder().encode(raw)
        let top = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let login = try XCTUnwrap(top["login"] as? [String: Any])
        let uris = try XCTUnwrap(login["uris"] as? [[String: Any]])

        XCTAssertEqual(Set(top.keys),
                       ["collectionIds", "encryptedFor", "favorite", "id", "login", "name", "reprompt", "type"])
        XCTAssertEqual(Set(login.keys), ["password", "uris", "username"])
        XCTAssertEqual(uris.count, 1)
        XCTAssertEqual(Set(uris[0].keys), ["uri"])
    }

    // MARK: - Tracer: a passkey login through the real client

    /// A login another Bitwarden client wrote: own key, passkey, password history, an attachment
    /// and every key only a response carries. All values are fake EncStrings.
    private let passkeyCipherJSON = #"""
    {
      "id": "00000000-0000-4000-8000-0000000000a3", "organizationId": null, "folderId": null, "type": 1,
      "name": "2.bmFtZQ==|aXY=|bWFj", "notes": null, "favorite": false, "reprompt": 0,
      "deletedDate": null, "creationDate": "2026-10-26T18:57:53.756456Z",
      "revisionDate": "2026-10-26T20:21:57.587710Z", "archivedDate": null,
      "key": "2.a2V5|aXY=|bWFj", "collectionIds": ["00000000-0000-4000-8000-0000000000c1"],
      "login": {
        "username": "2.dXNlcg==|aXY=|bWFj", "password": "2.cHdk|aXY=|bWFj", "totp": null,
        "passwordRevisionDate": "2026-10-26T20:21:57.556000Z",
        "uri": "2.dXJp|aXY=|bWFj",
        "uris": [{ "uri": "2.dXJp|aXY=|bWFj", "match": null, "uriChecksum": "2.Y2hr|aXY=|bWFj" }],
        "autofillOnPageLoad": true,
        "fido2Credentials": [{
          "credentialId": "2.Y3JlZA==|aXY=|bWFj", "keyType": "2.dHlwZQ==|aXY=|bWFj",
          "keyValue": "2.dmFs|aXY=|bWFj", "rpId": "2.cnA=|aXY=|bWFj", "counter": "2.MA==|aXY=|bWFj",
          "creationDate": "2026-10-26T18:57:53.779Z", "response": null
        }]
      },
      "card": null, "identity": null, "secureNote": null, "sshKey": null, "fields": [],
      "passwordHistory": [{ "lastUsedDate": "2026-10-26T20:21:57.556000Z", "password": "2.b2xk|aXY=|bWFj" }],
      "attachments": [{
        "id": "a0000000000000000001", "fileName": "2.ZmlsZQ==|aXY=|bWFj", "key": "2.a2V5|aXY=|bWFj",
        "size": "81", "sizeName": "81.00 bytes", "url": "https://vault.example.com/attachments/x?token=T",
        "object": "attachment"
      }],
      "object": "cipherDetails", "edit": true, "viewPassword": true,
      "permissions": { "delete": true, "restore": true }, "organizationUseTotp": true,
      "bankAccount": null, "driversLicense": null, "passport": null,
      "data": "{\"name\":\"2.bGVnYWN5|aXY=|bWFj\"}", "partialData": null
    }
    """#

    func testFetchedPasskeyLogin_sentBackThroughTheClient_keepsPreservedFieldsAndDropsResponseOnlyKeys() async throws {
        let syncBody = Data(
            (#"{"profile":{"id":"pid","email":"e@example.com","key":"2.k=="},"ciphers":["# + passkeyCipherJSON + "]}").utf8
        )
        StubURLProtocol.responder = { request in
            if request.httpMethod == "GET" { return .status(200, body: syncBody) }
            // Echo the request body, as the server answers with the stored cipher.
            return .status(200, body: StubURLProtocol.requests.last?.body ?? Data())
        }
        let client = await makeClient()

        let sync = try await client.fetchSync()
        let fetched = try XCTUnwrap(sync.ciphers.first)
        _ = try await client.updateCipher(id: fetched.id, cipher: fetched)

        let put = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(put.method, "PUT")
        let sent = try WireJSON.parse(try XCTUnwrap(put.body))
        let input = try WireJSON.parse(Data(passkeyCipherJSON.utf8))

        WireJSON.assertEqual(sent, WireJSON.expectedEncoding(of: input), "tracer PUT body")

        // The two preserved values are compared whole, so a dropped member inside them fails here
        // even though the removal rule above never looks inside them.
        XCTAssertEqual(sent["login"]?["fido2Credentials"], input["login"]?["fido2Credentials"])
        XCTAssertNotNil(input["login"]?["fido2Credentials"]?[0]?["response"], "fixture must carry the null response")
        XCTAssertEqual(sent["passwordHistory"], input["passwordHistory"])
        XCTAssertEqual(sent["login"]?["autofillOnPageLoad"], JSONValue.bool(true))

        // Each response-only key is in the input, and none of them is in the request.
        for key in CipherKeys.serverDerived.union(["attachments"]) {
            XCTAssertNotNil(input[key], "fixture must carry top-level \(key)")
            XCTAssertNil(sent[key], "\(key) must never be sent")
        }
        XCTAssertNotNil(input["login"]?["uri"], "fixture must carry login.uri")
        XCTAssertNil(sent["login"]?["uri"], "login.uri must never be sent")
    }

    // MARK: - Fixtures

    private static let loginId       = "00000000-0000-4000-8000-000000000101"
    private static let cardId        = "00000000-0000-4000-8000-000000000102"
    private static let identityId    = "00000000-0000-4000-8000-000000000103"
    private static let sshId         = "00000000-0000-4000-8000-000000000104"
    /// Carries wrong-typed new fields, including a numeric top-level `archivedDate`. Every one of
    /// them is written back as received, so it satisfies the one removal rule of `WireJSON` like the
    /// others; `testWrongTypedNewFields_...` pins the individual values.
    private static let wrongTypedId = "00000000-0000-4000-8000-000000000106"

    private struct FixtureCipher {
        let json: JSONValue
        var data: Data { get throws { try JSONEncoder().encode(json) } }
        var id: String {
            if case .string(let id)? = json["id"] { return id }
            return "?"
        }
        func decoded() throws -> RawCipher { try JSONDecoder().decode(RawCipher.self, from: data) }
    }

    private func fixtureCiphers(_ name: String) throws -> [FixtureCipher] {
        let document = try WireJSON.parse(try FixtureLoader.data(named: name))
        guard case .array(let ciphers)? = document["ciphers"] else {
            XCTFail("\(name).json has no ciphers array")
            return []
        }
        return ciphers.map(FixtureCipher.init)
    }

    private func kitchenSink(_ id: String) throws -> FixtureCipher {
        try XCTUnwrap(try fixtureCiphers("cipher-kitchen-sink").first { $0.id == id }, "No cipher \(id) in the kitchen sink")
    }

    private func encodedJSON(_ raw: RawCipher) throws -> JSONValue {
        try WireJSON.parse(try JSONEncoder().encode(raw))
    }

    // MARK: - Round trips

    func testGoldenFixture_everyCipherRoundTripsSemantically() throws {
        let ciphers = try fixtureCiphers("sync-golden-1.37.4")
        XCTAssertEqual(ciphers.count, 6)

        for cipher in ciphers {
            let sent = try encodedJSON(try cipher.decoded())
            WireJSON.assertEqual(sent, WireJSON.expectedEncoding(of: cipher.json), "golden cipher \(cipher.id)")
        }
        // The golden file really exercises the preserved data, not only plain logins.
        XCTAssertTrue(ciphers.contains { $0.json["login"]?["fido2Credentials"] != nil }, "no passkey cipher in the golden file")
        XCTAssertTrue(ciphers.contains { $0.json["passwordHistory"] != nil })
    }

    func testKitchenSink_everyCipherRoundTripsSemantically() throws {
        let ciphers = try fixtureCiphers("cipher-kitchen-sink")
        XCTAssertGreaterThanOrEqual(ciphers.count, 6)

        for cipher in ciphers {
            let sent = try encodedJSON(try cipher.decoded())
            WireJSON.assertEqual(sent, WireJSON.expectedEncoding(of: cipher.json), "kitchen-sink cipher \(cipher.id)")
        }
    }

    func testKitchenSink_nullExtrasAndNullPasswordHistorySurviveAsNull() throws {
        let card = try kitchenSink(Self.cardId)
        let rawCard = try card.decoded()
        let sentCard = try encodedJSON(rawCard)
        XCTAssertEqual(rawCard.passwordHistory, JSONValue.null, "null passwordHistory decodes as present-with-null, not nil")
        XCTAssertEqual(sentCard["passwordHistory"], JSONValue.null, "and is written back as null")
        XCTAssertEqual(rawCard.card?.extras["nullExtra"], JSONValue.null)
        XCTAssertEqual(sentCard["card"]?["nullExtra"], JSONValue.null, "a null extras member stays present")

        let identity = try kitchenSink(Self.identityId)
        XCTAssertNil(identity.json["passwordHistory"], "fixture: the identity cipher has no passwordHistory key")
        let rawIdentity = try identity.decoded()
        let sentIdentity = try encodedJSON(rawIdentity)
        XCTAssertNil(rawIdentity.passwordHistory)
        XCTAssertNil(sentIdentity["passwordHistory"], "an absent passwordHistory stays absent")
        XCTAssertEqual(sentIdentity["identity"]?["nullExtra"], JSONValue.null)
    }

    // MARK: - Exclusions

    /// Each excluded key is first shown to be present in the input at its path, so the test can
    /// fail: a fixture that stopped carrying one would otherwise pass vacuously.
    func testEncodedOutput_neverContainsExcludedOrResponseOnlyKeys() throws {
        let login = try kitchenSink(Self.loginId)
        let sentLogin = try encodedJSON(try login.decoded())

        for key in CipherKeys.serverDerived.union(["attachments"]) {
            XCTAssertNotNil(login.json[key], "fixture: top-level \(key) must be in the input")
            XCTAssertNil(sentLogin[key], "top-level \(key) must not be encoded")
        }
        XCTAssertNotNil(login.json["login"]?["uri"], "fixture: login.uri must be in the input")
        XCTAssertNil(sentLogin["login"]?["uri"], "login.uri must not be encoded")

        let card = try kitchenSink(Self.cardId)
        let identity = try kitchenSink(Self.identityId)
        let ssh = try kitchenSink(Self.sshId)
        let sentCard = try encodedJSON(try card.decoded())
        let sentIdentity = try encodedJSON(try identity.decoded())
        let sentSSH = try encodedJSON(try ssh.decoded())
        let levels: [(path: String, input: JSONValue?, output: JSONValue?)] = [
            ("login", login.json["login"], sentLogin["login"]),
            ("login.uris[0]", login.json["login"]?["uris"]?[0], sentLogin["login"]?["uris"]?[0]),
            ("fields[0]", login.json["fields"]?[0], sentLogin["fields"]?[0]),
            ("card", card.json["card"], sentCard["card"]),
            ("identity", identity.json["identity"], sentIdentity["identity"]),
            ("sshKey", ssh.json["sshKey"], sentSSH["sshKey"]),
        ]
        for level in levels {
            let input = level.input?["response"]
            XCTAssertNotNil(input, "fixture: \(level.path).response must be in the input")
            XCTAssertNotEqual(input, JSONValue.null, "fixture: \(level.path).response must be non-null")
            XCTAssertNotNil(level.output, "\(level.path) must be encoded at all")
            XCTAssertNil(level.output?["response"], "\(level.path).response must not be encoded")
        }

        // Inside an opaque value nothing is filtered: the passkey's own `response: null` is kept.
        XCTAssertNotNil(sentLogin["login"]?["fido2Credentials"]?[0]?["response"])
    }

    // MARK: - Kind of values inside extras

    func testKitchenSink_numbersAndNullsInExtrasKeepTheirKind() throws {
        let login = try kitchenSink(Self.loginId)
        let rawLogin = try login.decoded()
        let rawCard = try kitchenSink(Self.cardId).decoded()
        let rawIdentity = try kitchenSink(Self.identityId).decoded()
        let rawSSH = try kitchenSink(Self.sshId).decoded()

        // Literal expectations, not derived by decoding the input as JSONValue.
        func assertLiterals(_ cipher: RawCipher, _ context: String, line: UInt = #line) {
            XCTAssertEqual(cipher.login?.extras["futureLoginCount"], JSONValue.int(3), context, line: line)
            XCTAssertEqual(cipher.login?.extras["futureLoginRatio"], JSONValue.double(0.25), context, line: line)
            XCTAssertEqual(cipher.login?.extras["futureLoginNull"], JSONValue.null, context, line: line)
            XCTAssertEqual(cipher.login?.uris?[0].extras["futureUriBig"], JSONValue.int(9007199254740993), context, line: line)
            XCTAssertEqual(cipher.login?.uris?[0].extras["futureUriNull"], JSONValue.null, context, line: line)
            XCTAssertEqual(cipher.fields?[0].extras["futureFieldRatio"], JSONValue.double(2.5), context, line: line)
            XCTAssertEqual(cipher.fields?[0].extras["futureFieldNull"], JSONValue.null, context, line: line)
        }
        assertLiterals(rawLogin, "decoded")
        XCTAssertEqual(rawCard.card?.extras["nullExtra"], JSONValue.null)
        XCTAssertEqual(rawIdentity.identity?.extras["nullExtra"], JSONValue.null)
        XCTAssertEqual(rawSSH.sshKey?.extras["futureSshNull"], JSONValue.null)

        // The encoded bytes, read through JSONSerialization (not JSONValue): null stays present,
        // the large integer stays exact, the ratios keep their value.
        let bytes = try JSONEncoder().encode(rawLogin)
        let top = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let loginObject = try XCTUnwrap(top["login"] as? [String: Any])
        let uri0 = try XCTUnwrap((loginObject["uris"] as? [[String: Any]])?.first)
        let field0 = try XCTUnwrap((top["fields"] as? [[String: Any]])?.first)
        XCTAssertTrue(loginObject["futureLoginNull"] is NSNull, "login.futureLoginNull must be present as null")
        XCTAssertTrue(uri0["futureUriNull"] is NSNull, "uris[0].futureUriNull must be present as null")
        XCTAssertTrue(field0["futureFieldNull"] is NSNull, "fields[0].futureFieldNull must be present as null")
        XCTAssertEqual((uri0["futureUriBig"] as? NSNumber)?.int64Value, 9007199254740993)
        XCTAssertEqual((loginObject["futureLoginRatio"] as? NSNumber)?.doubleValue, 0.25)
        XCTAssertEqual((field0["futureFieldRatio"] as? NSNumber)?.doubleValue, 2.5)
        XCTAssertEqual((loginObject["futureLoginCount"] as? NSNumber)?.int64Value, 3)

        let cardTop = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rawCard)) as? [String: Any])
        XCTAssertTrue((cardTop["card"] as? [String: Any])?["nullExtra"] is NSNull)
        let identityTop = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rawIdentity)) as? [String: Any])
        XCTAssertTrue((identityTop["identity"] as? [String: Any])?["nullExtra"] is NSNull)
        let sshTop = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rawSSH)) as? [String: Any])
        XCTAssertTrue((sshTop["sshKey"] as? [String: Any])?["futureSshNull"] is NSNull)

        // And decoding what was encoded gives the same literals again.
        assertLiterals(try JSONDecoder().decode(RawCipher.self, from: bytes), "decoded again")
    }

    // MARK: - Exhaustiveness

    /// A hand-written encoder can forget a key. Every field set, the encoded key set must be the
    /// classification, minus the one key that is never sent.
    func testEveryFieldSet_encodesExactlyModelledAndPreservedKeysWithoutAttachments() throws {
        let raw = RawCipher(
            id: "c1", organizationId: "org", folderId: "f1", type: 1, name: "2.n|i|m", notes: "2.t|i|m",
            favorite: true, reprompt: 1, deletedDate: "2026-10-20T08:00:00.000000Z",
            creationDate: "2026-10-20T08:00:00.000000Z", revisionDate: "2026-10-21T08:00:00.000000Z",
            login: RawLoginData(username: "2.u|i|m", password: "2.p|i|m", uris: [RawURI(uri: "2.r|i|m", match: 0)], totp: "2.o|i|m"),
            card: RawCardData(cardholderName: nil, brand: nil, number: nil, expMonth: nil, expYear: nil, code: nil),
            identity: RawIdentityData(
                title: nil, firstName: nil, middleName: nil, lastName: nil, address1: nil, address2: nil,
                address3: nil, city: nil, state: nil, postalCode: nil, country: nil, company: nil, email: nil,
                phone: nil, ssn: nil, username: nil, passportNumber: nil, licenseNumber: nil),
            secureNote: RawSecureNoteData(type: 0),
            sshKey: RawSSHKeyData(privateKey: nil, publicKey: nil, keyFingerprint: nil),
            fields: [RawField(type: 0, name: "2.fn|i|m", value: "2.fv|i|m", linkedId: nil)],
            key: "2.k|i|m", collectionIds: ["col"],
            attachments: [AttachmentDTO(id: "a1", fileName: "2.f|i|m", key: "2.k|i|m", size: "1", sizeName: "1 byte", url: nil)],
            encryptedFor: "pid", archivedDate: .string("2026-10-22T08:00:00.000000Z"),
            passwordHistory: .array([]), lastKnownRevisionDate: "2026-10-21T08:00:00.000000Z"
        )

        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any]).keys

        XCTAssertEqual(Set(keys), CipherKeys.modelled.union(CipherKeys.preserved).subtracting(["attachments"]))
        XCTAssertEqual(RawCipher.codingKeyNames, CipherKeys.modelled.union(CipherKeys.preserved))
    }

    func testCipherKeys_classificationIsDisjointAndComplete() {
        XCTAssertEqual(CipherKeys.modelled.count, 20)
        XCTAssertEqual(CipherKeys.preserved, ["archivedDate", "passwordHistory", "encryptedFor", "lastKnownRevisionDate"])
        XCTAssertEqual(CipherKeys.serverDerived.count, 10)
        XCTAssertTrue(CipherKeys.modelled.isDisjoint(with: CipherKeys.preserved))
        XCTAssertTrue(CipherKeys.modelled.isDisjoint(with: CipherKeys.serverDerived))
        XCTAssertTrue(CipherKeys.preserved.isDisjoint(with: CipherKeys.serverDerived))
        XCTAssertEqual(CipherKeys.classified.count, 34)
    }

    // MARK: - Leniency

    /// The login cipher of the kitchen sink with one top-level key set to `value`, or removed when
    /// `value` is nil.
    private func loginCipher(setting key: String, to value: JSONValue?) throws -> RawCipher {
        guard case .object(var members) = try kitchenSink(Self.loginId).json else {
            preconditionFailure("the fixture cipher is not a JSON object")
        }
        members[key] = value
        return try JSONDecoder().decode(RawCipher.self, from: JSONEncoder().encode(JSONValue.object(members)))
    }

    /// `archivedDate` is held as received, like `passwordHistory`: a date, `null` and an absent key
    /// stay what they were, so saving an item another client archived cannot unarchive it.
    func testArchivedDate_isWrittenBackAsReceived() throws {
        let archived = try loginCipher(setting: "archivedDate", to: .string("2026-10-22T10:00:00.000000Z"))
        XCTAssertEqual(try encodedJSON(archived)["archivedDate"], JSONValue.string("2026-10-22T10:00:00.000000Z"))

        let explicitNull = try loginCipher(setting: "archivedDate", to: .null)
        XCTAssertEqual(try encodedJSON(explicitNull)["archivedDate"], JSONValue.null, "null stays present")

        let absent = try loginCipher(setting: "archivedDate", to: nil)
        XCTAssertNil(try encodedJSON(absent)["archivedDate"], "an absent key stays absent")
    }

    /// Encode-only: only a request carries it, and a later change sets it from the record's own
    /// revision. A value a server sent must not come back in a request.
    func testLastKnownRevisionDate_isNeverReadFromAServerRecord() throws {
        let raw = try loginCipher(setting: "lastKnownRevisionDate", to: .string("2026-10-21T08:00:00.000000Z"))

        XCTAssertNil(raw.lastKnownRevisionDate)
        XCTAssertNil(try encodedJSON(raw)["lastKnownRevisionDate"])
        XCTAssertTrue(raw.unclassifiedKeys.isEmpty, "the key is still classified, so it is not reported as new")
    }

    func testWrongTypedNewFields_doNotAbortDecodeAndNestedOnesAreWrittenBack() throws {
        let wrong = try kitchenSink(Self.wrongTypedId)
        XCTAssertEqual(wrong.json["archivedDate"], JSONValue.int(5), "fixture: numeric top-level archivedDate")

        let raw = try wrong.decoded()   // must not throw
        XCTAssertNil(raw.login?.passwordRevisionDate)
        XCTAssertEqual(raw.login?.extras["passwordRevisionDate"], JSONValue.int(12345))
        XCTAssertNil(raw.login?.uris?[0].uriChecksum)
        XCTAssertEqual(raw.login?.uris?[0].extras["uriChecksum"], JSONValue.int(7))

        let sent = try encodedJSON(raw)
        XCTAssertEqual(sent["login"]?["passwordRevisionDate"], JSONValue.int(12345), "written back unchanged")
        XCTAssertEqual(sent["login"]?["uris"]?[0]?["uriChecksum"], JSONValue.int(7), "written back unchanged")
        XCTAssertEqual(sent["archivedDate"], JSONValue.int(5), "a wrong-typed archivedDate is written back as received")

        // One odd cipher must not fail the whole sync, which decodes all ciphers or none.
        let body = try JSONEncoder().encode(JSONValue.object([
            "profile": .object(["id": .string("pid"), "email": .string("e@example.com"), "key": .string("2.k==")]),
            "ciphers": .array([wrong.json, try kitchenSink(Self.loginId).json]),
        ]))
        let sync = try JSONDecoder().decode(SyncResponse.self, from: body)
        XCTAssertEqual(sync.ciphers.count, 2)
    }
}

// MARK: - Semantic wire comparison

/// Compares what Prizm sends with what the server sent, as JSON, never as bytes.
///
/// `expectedEncoding(of:)` derives the expectation from a server cipher with ONE removal rule and
/// nothing else:
/// 1. top level: the keys in `CipherKeys.serverDerived`, and `attachments`;
/// 2. `login`: the legacy `uri`;
/// 3. the six rebuilt levels (`login`, each `login.uris[]`, `card`, `identity`, `sshKey`, each
///    `fields[]`): `response`;
/// 4. a key whose value is JSON null, only when that key is a typed field of its level, because a
///    typed nil is omitted on encode. A null under an extras key stays in the expectation, and so
///    do the nulls of `archivedDate` and `passwordHistory`, which are held as received.
/// The helper never looks inside a preserved value (`fido2Credentials`, `passwordHistory`, an
/// extras value), so `fido2Credentials[].response` stays. Nothing else is removed.
///
/// The nested typed-key lists are literals on purpose: they must not be read from the model's own
/// `knownKeys`, or a key forgotten in the model would be forgotten here too. The top level uses
/// `CipherKeys`, itself pinned by the exhaustiveness test.
///
/// `JSONValue` descriptions will be redacted, so failures name differing key paths, never values.
enum WireJSON {

    static let topTyped: Set<String> = CipherKeys.modelled.union(["encryptedFor", "lastKnownRevisionDate"])
    static let loginTyped: Set<String> = ["username", "password", "totp", "uris", "passwordRevisionDate"]
    static let uriTyped: Set<String> = ["uri", "match", "uriChecksum"]
    static let cardTyped: Set<String> = ["cardholderName", "brand", "number", "expMonth", "expYear", "code"]
    static let identityTyped: Set<String> = [
        "title", "firstName", "middleName", "lastName", "address1", "address2", "address3", "city", "state",
        "postalCode", "country", "company", "email", "phone", "ssn", "username", "passportNumber", "licenseNumber",
    ]
    static let sshKeyTyped: Set<String> = ["privateKey", "publicKey", "keyFingerprint"]
    static let fieldTyped: Set<String> = ["type", "name", "value", "linkedId"]

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func expectedEncoding(of serverCipher: JSONValue) -> JSONValue {
        guard case .object(var top) = serverCipher else { return serverCipher }
        for key in CipherKeys.serverDerived.union(["attachments"]) { top[key] = nil }
        top = top.filter { !($0.value == .null && topTyped.contains($0.key)) }

        if let login = top["login"] {
            var level = rebuiltLevel(login, typed: loginTyped, dropping: ["uri"])
            if case .object(var members) = level, case .array(let uris)? = members["uris"] {
                members["uris"] = .array(uris.map { rebuiltLevel($0, typed: uriTyped, dropping: []) })
                level = .object(members)
            }
            top["login"] = level
        }
        if let card = top["card"] { top["card"] = rebuiltLevel(card, typed: cardTyped, dropping: []) }
        if let identity = top["identity"] { top["identity"] = rebuiltLevel(identity, typed: identityTyped, dropping: []) }
        if let ssh = top["sshKey"] { top["sshKey"] = rebuiltLevel(ssh, typed: sshKeyTyped, dropping: []) }
        if case .array(let fields)? = top["fields"] {
            top["fields"] = .array(fields.map { rebuiltLevel($0, typed: fieldTyped, dropping: []) })
        }
        return .object(top)
    }

    /// Rules 2 to 4 for one level: drop `response` and the given keys, and null typed keys.
    private static func rebuiltLevel(_ value: JSONValue, typed: Set<String>, dropping: Set<String>) -> JSONValue {
        guard case .object(let members) = value else { return value }
        return .object(members.filter { key, member in
            if key == "response" || dropping.contains(key) { return false }
            return !(member == .null && typed.contains(key))
        })
    }

    /// Key paths where `actual` differs from `expected`, empty when they are equal.
    static func differingPaths(expected: JSONValue, actual: JSONValue, path: String = "$") -> [String] {
        switch (expected, actual) {
        case (.object(let e), .object(let a)):
            var paths: [String] = []
            for key in Set(e.keys).union(a.keys).sorted() {
                switch (e[key], a[key]) {
                case (nil, _?): paths.append("\(path).\(key) (unexpected)")
                case (_?, nil): paths.append("\(path).\(key) (missing)")
                case (let ev?, let av?): paths += differingPaths(expected: ev, actual: av, path: "\(path).\(key)")
                case (nil, nil): break
                }
            }
            return paths
        case (.array(let e), .array(let a)):
            guard e.count == a.count else { return ["\(path) (count \(e.count) vs \(a.count))"] }
            return zip(e, a).enumerated().flatMap { index, pair in
                differingPaths(expected: pair.0, actual: pair.1, path: "\(path)[\(index)]")
            }
        default:
            return expected == actual ? [] : ["\(path) (value or kind differs)"]
        }
    }

    static func assertEqual(_ actual: JSONValue, _ expected: JSONValue, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let paths = differingPaths(expected: expected, actual: actual)
        XCTAssertTrue(paths.isEmpty, "\(context): differing paths \(paths)", file: file, line: line)
    }
}

/// Reads a member or element so a test can walk a decoded cipher without unwrapping each level.
extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }
    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }
}
