import XCTest
@testable import Prizm

/// An org save sends the collections request only when the collection set changed, and handles
/// its answer (openspec change `fix-collection-assignment`, design D5).
@MainActor
final class CollectionChangeOnlyTests: XCTestCase {

    func testEditWithoutCollectionChange_sendsOnlyThePut() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg()
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)

        _ = try await rig.vault.update(StaleWriteRig.renamed(item))

        XCTAssertEqual(rig.api.callLog, ["PUT o1"])
    }

    func testSameCollectionsInAnotherOrder_isNoChange() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a", "col-b"])
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-b", "col-a"]

        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.callLog, ["PUT o1"])
    }

    func testCollectionChange_sendsTheListAfterThePut_andTakesTheAnswer() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a"])
        let collectionsRevision = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(5))
        RepositoryFixtures.answerUpdates(
            of: rig.api, withRevisionString: RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(2)),
            collectionsRevision: collectionsRevision)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a", "col-c"]

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.callLog, ["PUT o1", "collections o1"])
        XCTAssertEqual(rig.api.lastUpdatedCipherCollections?.collectionIds, ["col-a", "col-c"])
        XCTAssertEqual(saved.collectionIds, ["col-a", "col-c"])
        let stored = await rig.store.record(for: "o1")
        XCTAssertEqual(stored?.revisionDate, collectionsRevision, "The collections answer is the stored record")
    }

    /// Vaultwarden 1.37.4 refuses the whole request when a read-only collection is in the list,
    /// even an unchanged one, and keeps a read-only assignment that is left out; the official
    /// server changes only writable assignments (live rig 2026-10-30, design D2).
    func testReadOnlyAssignment_isLeftOutOfTheRequest_butKeptLocally() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a", "col-r"], readOnlyCollections: ["col-r"])
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a", "col-r", "col-c"]

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipherCollections?.collectionIds, ["col-a", "col-c"])
        XCTAssertEqual(saved.collectionIds, ["col-a", "col-r", "col-c"])
    }

    /// A collection the sync could not list (its name did not decrypt) may be writable: leaving it
    /// out would make the server remove it, so only collections known to be read-only are left out.
    func testUnknownCollection_isSentBack() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a", "col-unknown"])
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a", "col-unknown", "col-b"]

        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipherCollections?.collectionIds, ["col-a", "col-unknown", "col-b"])
    }

    func testUncheckingTheLastWritable_sendsAnEmptyList_andKeepsTheReadOnlyOne() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a", "col-r"], readOnlyCollections: ["col-r"])
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-r"]

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipherCollections?.collectionIds, [])
        XCTAssertEqual(saved.collectionIds, ["col-r"])
    }

    /// Another member adds a collection while the sheet is open, and a sync brings it in without a
    /// revision change (Vaultwarden 1.37.4, live rig 2026-10-30). A plain edit must not remove it.
    func testCollectionAddedElsewhereWhileEditing_isKeptByAPlainEdit() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a"])
        try await syncBrings(["col-a", "col-b"], for: item, into: rig)
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)

        _ = try await rig.vault.update(StaleWriteRig.renamed(item))

        XCTAssertEqual(rig.api.callLog, ["PUT o1"], "No collections request: the user changed none")
    }

    func testCollectionAddedElsewhereWhileEditing_isKeptWhenTheUserAddsAnother() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a"])
        try await syncBrings(["col-a", "col-b"], for: item, into: rig)
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a", "col-c"]

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipherCollections?.collectionIds, ["col-a", "col-b", "col-c"])
        XCTAssertEqual(saved.collectionIds, ["col-a", "col-b", "col-c"])
    }

    /// Stores the record of `item` with other collections and the same revision, as a sync does
    /// after another member changed only the item's collections.
    private func syncBrings(_ collectionIds: [String], for item: VaultItem, into rig: StaleWriteRig) async throws {
        try await RepositoryFixtures.seedRecords(for: [item.with(collectionIds: collectionIds)], in: rig.store,
                                                 vaultKeys: StaleWriteRig.vaultKeys,
                                                 orgKeys: [StaleWriteRig.orgId: StaleWriteRig.orgKeys])
    }

    func testUnavailable_removesTheItemLocally_andReportsIt() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a"])
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        rig.api.updateCipherCollectionsUnavailable = true
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-b"]

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The lost access must be reported")
        } catch VaultError.savedButAccessLost {
            // expected
        }

        let cached = try? await rig.vault.itemDetail(id: "o1")
        XCTAssertNil(cached, "The item leaves the local vault")
        let stored = await rig.store.record(for: "o1")
        XCTAssertNil(stored, "and its stored record")
    }

    func testCollectionsFailure_keepsTheOriginalCollectionsLocally() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg(collectionIds: ["col-a"])
        answerPut(of: rig.api, collectionIds: ["col-a"])
        rig.api.updateCipherCollectionsShouldThrow = APIError.httpError(statusCode: 500, body: "")
        rig.api.getCipherShouldThrow = APIError.httpError(statusCode: 500, body: "")
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a", "col-c"]

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The failed collection change must be reported")
        } catch VaultError.collectionChangeNotSaved {
            // expected
        }

        let cached = try await rig.vault.itemDetail(id: "o1")
        XCTAssertEqual(cached.name, "Renamed", "The saved fields")
        XCTAssertEqual(cached.collectionIds, ["col-a"], "with the original collections")
    }

    /// The PUT answers with the request, stamped with a revision and reporting `collectionIds`: a
    /// server's PUT answer holds the collections from before the separate collection change.
    private func answerPut(of api: MockPrizmAPIClient, collectionIds: [String]) {
        let revision = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(2))
        api.whileUpdatingCipher = { [api] in
            guard let sent = api.lastUpdatedCipher,
                  let stamped = try? RepositoryFixtures.withRevision(sent, revision),
                  let data = try? JSONEncoder().encode(stamped),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return XCTFail("answerPut: no request to answer")
            }
            json["collectionIds"] = collectionIds
            guard let body = try? JSONSerialization.data(withJSONObject: json),
                  let answer = try? JSONDecoder().decode(RawCipher.self, from: body) else {
                return XCTFail("answerPut: could not build the answer")
            }
            api.updateCipherResponse = answer
        }
    }
}
