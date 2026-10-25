import XCTest
@testable import Prizm

/// Renaming a collection keeps its access settings, and a new collection is managed by its creator
/// (openspec change fix-collection-access-on-rename).
@MainActor
final class CollectionAccessTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private let orgKeys = CryptoKeys(encryptionKey: Data(repeating: 0xAA, count: 32), macKey: Data(repeating: 0xBB, count: 32))

    /// Vaultwarden 1.37.4 `get_org_collection_detail` (`organizations.rs:734-790`,
    /// `collection.rs:69-71, 971-981`): member A manages, member B reads only, group G hides passwords.
    private let vaultwardenDetails = Data("""
        {"externalId":"ext-42","id":"col-1","organizationId":"org-1","name":"2.old|iv|mac","type":0,
         "assigned":true,"object":"collectionAccessDetails",
         "users":[{"id":"ou-a","readOnly":false,"hidePasswords":false,"manage":true},
                  {"id":"ou-b","readOnly":true,"hidePasswords":false,"manage":false}],
         "groups":[{"id":"grp-g","readOnly":false,"hidePasswords":true,"manage":false}]}
        """.utf8)

    override func setUp() async throws {
        try await super.setUp()
        mockAPI = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        await crypto.unlockWith(keys: CryptoKeys(encryptionKey: Data(repeating: 0x11, count: 32), macKey: Data(repeating: 0x22, count: 32)))
        sut = VaultRepositoryImpl(apiClient: mockAPI, crypto: crypto, orgKeyCache: orgKeyCache)
        await sut.populate(items: [], folders: [],
                           organizations: [Organization(id: "org-1", name: "Acme", role: .admin, membershipId: .known("ou-me"))],
                           collections: [OrgCollection(id: "col-1", organizationId: "org-1", name: "Old")],
                           syncedAt: Date())
    }

    private func decrypt(_ encString: String?) throws -> String? {
        let enc = try EncString(string: try XCTUnwrap(encString))
        return String(data: try enc.decrypt(keys: orgKeys), encoding: .utf8)
    }

    // MARK: - 2.1 Decoding the access details

    func testDetails_decodeVaultwardenResponse() throws {
        let details = try JSONDecoder().decode(CollectionAccessDetailsResponse.self, from: vaultwardenDetails)

        XCTAssertEqual(details.externalId, "ext-42")
        XCTAssertEqual(details.users, [
            CollectionAccessSelection(id: "ou-a", readOnly: false, hidePasswords: false, manage: true),
            CollectionAccessSelection(id: "ou-b", readOnly: true, hidePasswords: false, manage: false),
        ])
        XCTAssertEqual(details.groups, [CollectionAccessSelection(id: "grp-g", readOnly: false, hidePasswords: true, manage: false)])
    }

    func testDetails_decodePascalCaseNullExternalIdAndMissingGroups() throws {
        let json = Data("""
            {"Id":"col-1","OrganizationId":"org-1","Name":"2.n|iv|mac","ExternalId":null,
             "Users":[{"Id":"ou-a","ReadOnly":false,"HidePasswords":false,"Manage":true}]}
            """.utf8)

        let details = try JSONDecoder().decode(CollectionAccessDetailsResponse.self, from: json)

        XCTAssertNil(details.externalId)
        XCTAssertEqual(details.users?.count, 1)
        XCTAssertNil(details.groups, "A missing list must stay distinguishable from an empty one")
    }

    // MARK: - 3.1 / 3.3 Rename resends the access list

    func testRename_readsDetailsThenResendsAccessUnchanged() async throws {
        mockAPI.collectionAccessDetails = try JSONDecoder().decode(CollectionAccessDetailsResponse.self, from: vaultwardenDetails)

        let renamed = try await sut.renameCollection(id: "col-1", organizationId: "org-1", name: "Infrastructure")

        XCTAssertEqual(mockAPI.collectionCalls, ["details col-1", "rename col-1"], "Read first, then write")
        let request = try XCTUnwrap(mockAPI.lastCollectionWriteRequest)
        XCTAssertEqual(request.users, mockAPI.collectionAccessDetails?.users)
        XCTAssertEqual(request.groups, mockAPI.collectionAccessDetails?.groups)
        XCTAssertEqual(request.externalId, "ext-42")
        XCTAssertEqual(try decrypt(request.name), "Infrastructure", "The name is encrypted with the org key")
        XCTAssertEqual(renamed.name, "Infrastructure")
    }

    /// Vaultwarden 1.32.0 already returns both lists (`organizations.rs:639` at 1.32.0), but its
    /// selections have no `manage` (`SelectionReadOnly {id, readOnly, hidePasswords}`; Manage came in
    /// 1.33.0). No `type`, no `assigned`.
    func testRename_vaultwarden132StyleDetails_resentUnchanged() async throws {
        let json = Data("""
            {"externalId":null,"id":"col-1","organizationId":"org-1","name":"2.old|iv|mac","object":"collectionAccessDetails",
             "users":[{"id":"ou-a","readOnly":false,"hidePasswords":false},
                      {"id":"ou-c","readOnly":true,"hidePasswords":false}],
             "groups":[]}
            """.utf8)
        mockAPI.collectionAccessDetails = try JSONDecoder().decode(CollectionAccessDetailsResponse.self, from: json)

        _ = try await sut.renameCollection(id: "col-1", organizationId: "org-1", name: "New")

        XCTAssertEqual(mockAPI.lastCollectionWriteRequest?.users, [
            CollectionAccessSelection(id: "ou-a", readOnly: false, hidePasswords: false, manage: false),
            CollectionAccessSelection(id: "ou-c", readOnly: true, hidePasswords: false, manage: false),
        ])
        XCTAssertEqual(mockAPI.lastCollectionWriteRequest?.groups, [])
        XCTAssertNil(mockAPI.lastCollectionWriteRequest?.externalId)
    }

    // MARK: - 3.2 Fail closed

    func testRename_detailsFail_sendsNothingAndKeepsName() async throws {
        let failures: [Error] = [
            APIError.httpError(statusCode: 404, body: ""), APIError.httpError(statusCode: 403, body: ""),
            APIError.httpError(statusCode: 500, body: ""), URLError(.notConnectedToInternet),
        ]
        for failure in failures {
            mockAPI.collectionAccessDetailsError = failure
            do {
                _ = try await sut.renameCollection(id: "col-1", organizationId: "org-1", name: "New")
                XCTFail("Expected an error for \(failure)")
            } catch {
                XCTAssertEqual(error.localizedDescription,
                               "Couldn't rename the collection. Its access settings could not be read.")
            }
        }
        XCTAssertFalse(mockAPI.collectionCalls.contains("rename col-1"), "No PUT may be sent")
        let names = try await sut.collections().map(\.name)
        XCTAssertEqual(names, ["Old"])
    }

    func testRename_detailsWithoutUsers_sendsNothing() async throws {
        let json = Data(#"{"id":"col-1","organizationId":"org-1","name":"2.n|iv|mac","groups":[]}"#.utf8)
        mockAPI.collectionAccessDetails = try JSONDecoder().decode(CollectionAccessDetailsResponse.self, from: json)

        do {
            _ = try await sut.renameCollection(id: "col-1", organizationId: "org-1", name: "New")
            XCTFail("Expected an error")
        } catch {
            guard case VaultError.collectionAccessUnreadable = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertFalse(mockAPI.collectionCalls.contains("rename col-1"))
    }

    // MARK: - 4.2 – 4.4 Create

    func testCreate_assignsTheCreatorWithManage() async throws {
        _ = try await sut.createCollection(name: "Ops", organizationId: "org-1")

        let request = try XCTUnwrap(mockAPI.lastCollectionWriteRequest)
        XCTAssertEqual(request.users, [CollectionAccessSelection(id: "ou-me", readOnly: false, hidePasswords: false, manage: true)])
        XCTAssertEqual(request.groups, [])
        XCTAssertNil(request.externalId)
        XCTAssertEqual(try decrypt(request.name), "Ops")
    }

    func testCreate_unreadableMembershipId_sendsNothing() async throws {
        await sut.populate(items: [], folders: [],
                           organizations: [Organization(id: "org-1", name: "Acme", role: .admin, membershipId: .unreadable)],
                           collections: [], syncedAt: Date())

        do {
            _ = try await sut.createCollection(name: "Ops", organizationId: "org-1")
            XCTFail("Expected an error")
        } catch {}
        XCTAssertEqual(mockAPI.createCollectionCallCount, 0, "No POST with a guessed id")
    }

    /// Official servers before v2025.1.0 send no `organizationUserId`: create keeps today's body
    /// through `LegacyCollectionCreateWithoutMembership`.
    func testCreate_withoutMembershipId_usesTheLegacyBody() async throws {
        await sut.populate(items: [], folders: [],
                           organizations: [Organization(id: "org-1", name: "Acme", role: .admin, membershipId: .notSent)],
                           collections: [], syncedAt: Date())

        _ = try await sut.createCollection(name: "Ops", organizationId: "org-1")

        let request = try XCTUnwrap(mockAPI.lastCollectionWriteRequest)
        XCTAssertEqual(request.users, [])
        XCTAssertEqual(request.groups, [])
        XCTAssertNil(request.externalId)
    }
}

/// `organizationUserId` in the sync profile (task 4.1).
@MainActor
final class OrganizationMembershipIdTests: XCTestCase {

    private func decode(_ json: String) throws -> RawOrganization {
        try JSONDecoder().decode(RawOrganization.self, from: Data(json.utf8))
    }

    func testRawOrganization_decodesOrganizationUserId() throws {
        XCTAssertEqual(try decode(#"{"id":"o","name":"n","key":"k","type":2,"organizationUserId":"ou-1"}"#).organizationUserId, .known("ou-1"))
        XCTAssertEqual(try decode(#"{"Id":"o","Name":"n","Key":"k","Type":2,"OrganizationUserId":"ou-1"}"#).organizationUserId, .known("ou-1"))
    }

    func testRawOrganization_missingOrganizationUserId_isNotSent() throws {
        XCTAssertEqual(try decode(#"{"id":"o","name":"n","key":"k","type":2}"#).organizationUserId, .notSent)
    }

    func testRawOrganization_undecodableOrganizationUserId_isUnreadable() throws {
        XCTAssertEqual(try decode(#"{"id":"o","name":"n","key":"k","type":2,"organizationUserId":42}"#).organizationUserId, .unreadable)
        XCTAssertEqual(try decode(#"{"id":"o","name":"n","key":"k","type":2,"organizationUserId":null}"#).organizationUserId, .unreadable)
    }

    func testSync_carriesMembershipIdIntoOrganization() async throws {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        let vault = MockVaultRepository()
        await crypto.unlockWith(keys: CryptoKeys(encryptionKey: Data(count: 32), macKey: Data(count: 32)))
        crypto.stubbedDecryptList = []
        api.syncResponse = SyncResponse(
            profile: RawProfile(id: "pid", email: "a@example.com", name: nil, key: "2.k==", privateKey: "2.p=="),
            ciphers: [], folders: [],
            organizations: [RawOrganization(id: "org-1", name: "Acme", key: "2.ok", type: 1, organizationUserId: .known("ou-1"))],
            collections: []
        )
        let sync = SyncRepositoryImpl(apiClient: api, crypto: crypto, vaultRepository: vault,
                                      vaultKeyCache: VaultKeyCache(), orgKeyCache: OrgKeyCache())

        _ = try await sync.sync(progress: { _ in })

        XCTAssertEqual(vault.populatedOrganizations.first?.membershipId, .known("ou-1"))
    }
}

/// The request bodies on the wire (design D4): `externalId` is JSON null when absent.
final class CollectionRequestWireTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    func testRename_sendsAccessListAndNullExternalId() async throws {
        StubURLProtocol.responder = { _ in .status(200, body: Data(#"{"id":"col-1","organizationId":"org-1","name":"2.n|iv|mac"}"#.utf8)) }
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        let request = CollectionWriteRequest(
            name: "2.n|iv|mac", externalId: nil,
            users: [CollectionAccessSelection(id: "ou-a", readOnly: true, hidePasswords: false, manage: false)], groups: []
        )

        _ = try await client.renameCollection(id: "col-1", organizationId: "org-1", request: request)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.url?.path, "/api/organizations/org-1/collections/col-1")
        let body = try XCTUnwrap(sent.jsonBody)
        XCTAssertTrue(body["externalId"] is NSNull, "externalId must be sent as null")
        let users = try XCTUnwrap(body["users"] as? [[String: Any]])
        XCTAssertEqual(users.first?["id"] as? String, "ou-a")
        XCTAssertEqual(users.first?["readOnly"] as? Bool, true)
        XCTAssertEqual(users.first?["manage"] as? Bool, false)
        XCTAssertEqual((body["groups"] as? [Any])?.count, 0)
    }

    func testDetails_getsThePerCollectionEndpoint() async throws {
        StubURLProtocol.responder = { _ in .status(200, body: Data(#"{"id":"col-1","organizationId":"org-1","name":"2.n|iv|mac","users":[],"groups":[]}"#.utf8)) }
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)

        _ = try await client.getCollectionAccessDetails(organizationId: "org-1", id: "col-1")

        XCTAssertEqual(StubURLProtocol.requests.first?.method, "GET")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/organizations/org-1/collections/col-1/details")
    }
}
