import XCTest
@testable import Prizm

/// After Prizm's own operations the stored record and the cached item's revision are the server's
/// again, so the next edit passes the revision pre-check and is not rejected as a conflict
/// (openspec change fix-cipher-edit-data-loss, task 4.4).
///
/// The mock API answers a refresh from `getCipherResponses`; an id without an entry throws, which
/// is the failed refresh every older test sees.
@MainActor
final class RevisionRefreshTests: XCTestCase {

    // Three server revisions, each a whole millisecond apart from the others by a minute.
    private static let r1 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate)
    private static let r2 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(60))
    private static let r3 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(120))

    // MARK: - Tracer: delete, restore, then edit

    func testDeleteRestoreEdit_savesWithoutConflict() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        rig.api.restoreCipherResponse = try await record("c1", in: rig, revision: Self.r3)

        try await rig.vault.deleteItem(id: "c1")
        try await rig.vault.restoreItem(id: "c1")

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r3, "The stored record is the restore answer, byte for byte")
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r3)

        var draft = DraftVaultItem(cached)
        draft.name = "Renamed after restore"
        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The edit passes the pre-check and is sent")
        XCTAssertEqual(rig.api.callLog, ["delete c1", "GET c1", "restore c1", "PUT c1"],
                       "Delete is refreshed with a fetch; the restore answer needs none")
    }

    func testSoftDelete_refreshesWithGet() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.deleteItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"], "One GET for the item")
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2, "The stored record is the GET answer")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertTrue(cached.isDeleted)
        try assertRevision(cached.revisionDate, is: Self.r2)
        let trashed = try await rig.vault.items(for: .trash)
        XCTAssertEqual(trashed.map(\.id), ["c1"], "The index shows the refreshed item")
    }

    func testRestore_usesTheResponseCipher() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        rig.api.restoreCipherResponse = try await record("c1", in: rig, revision: Self.r3)

        try await rig.vault.restoreItem(id: "c1")

        XCTAssertTrue(rig.api.getCipherCalls.isEmpty, "A restore answer that carries the cipher needs no GET")
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r3)
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertFalse(cached.isDeleted)
        try assertRevision(cached.revisionDate, is: Self.r3)
    }

    func testRestoreWithoutCipher_refreshesWithGet() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        rig.api.restoreCipherResponse = nil
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.restoreItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2)
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r2)
    }

    // MARK: - The answer must be for the item that was asked about

    /// The store and the cached items are keyed by the id the sync delivered. An answer that names
    /// the item in another case would open a second store entry and leave the record the next save
    /// reads as it was, so it is ignored like an answer for another item.
    func testRefreshAnswerWithAnIdInAnotherCase_isIgnored() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record(
            "c1", in: rig, revision: Self.r2, replacing: ["id": "C1"])

        try await rig.vault.deleteItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let upperCase = await rig.store.record(for: "C1")
        XCTAssertNil(upperCase, "No second entry under the answer's id")
        let count = await rig.store.count
        XCTAssertEqual(count, 1)
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r1, "The stored record is unchanged")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertTrue(cached.isDeleted, "The operation itself took effect")
        try assertRevision(cached.revisionDate, is: Self.r1)
    }

    // MARK: - A failed refresh never fails the operation

    func testFailedRefresh_operationSucceedsAndKeepsTheOldRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherShouldThrow = APIError.httpError(statusCode: 500, body: "secret body")

        try await rig.vault.deleteItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r1, "The stored record is unchanged")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertTrue(cached.isDeleted, "The operation itself took effect")
        try assertRevision(cached.revisionDate, is: Self.r1)
    }

    /// An answer that decodes as a cipher but carries no readable revision does not replace the
    /// stored record: the next edit would otherwise be refused for a missing revision.
    func testRefreshAnswerWithoutReadableRevision_keepsTheStoredRecord() async throws {
        let unreadable: [(label: String, value: Any)] = [
            ("missing", NSNull()), ("empty", ""), ("unparsable", "not-a-date"), ("epoch", "1970-01-01T00:00:00.000Z"),
        ]
        for revision in unreadable {
            let rig = await StaleWriteRig.make()
            let item = StaleWriteRig.login("c1").with(isDeleted: true)
            try await seed([item], in: rig)
            rig.api.restoreCipherResponse = try await record(
                "c1", in: rig, revision: Self.r2, replacing: ["revisionDate": revision.value])

            try await rig.vault.restoreItem(id: "c1")

            let stored = await rig.store.record(for: "c1")
            XCTAssertEqual(stored?.revisionDate, Self.r1, "\(revision.label): the stored record is kept")
            let cached = try await rig.vault.itemDetail(id: "c1")
            XCTAssertFalse(cached.isDeleted, "\(revision.label): the restore itself took effect")
            try assertRevision(cached.revisionDate, is: Self.r1)

            var draft = DraftVaultItem(cached)
            draft.name = "Renamed after restore"
            _ = try await rig.vault.update(draft)
            XCTAssertEqual(rig.api.updateCipherCallCount, 1, "\(revision.label): the next edit is sent")
        }
    }

    // MARK: - Lock

    func testRefreshFinishingAfterLock_writesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        let vault = rig.vault
        rig.api.whileGettingCipher = { await vault.clearVault() }

        try await rig.vault.deleteItem(id: "c1")

        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The refresh does not refill the record store after the lock")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "Nor the item list")
        let trashed = try await rig.vault.items(for: .trash)
        XCTAssertTrue(trashed.isEmpty)
    }

    /// A restore whose answer carries no cipher refreshes with a GET; a lock that lands during that
    /// GET must leave no record and no item behind. (`deleteItem` is covered above; the refreshing
    /// operations share `refreshRecord` but not its call site.)
    func testRestoreRefreshFinishingAfterLock_writesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        rig.api.restoreCipherResponse = nil
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        let vault = rig.vault
        rig.api.whileGettingCipher = { await vault.clearVault() }

        try await rig.vault.restoreItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"], "The refresh did start")
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The refresh does not refill the record store after the lock")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "Nor the item list")
    }

    func testAttachmentRefreshFinishingAfterLock_writesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        let attachment = Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10,
                                    sizeName: "10 B", url: nil, isUploadIncomplete: false)
        let vault = rig.vault
        rig.api.whileGettingCipher = { await vault.clearVault() }

        await rig.vault.updateAttachments([attachment], for: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"], "The refresh did start")
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The refresh does not refill the record store after the lock")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "Nor the item list")
    }

    // MARK: - Idempotency

    func testRefreshTwice_isIdempotent() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.deleteItem(id: "c1")
        let firstRecord = try await encodedRecord("c1", in: rig)
        let firstRevision = try await rig.vault.itemDetail(id: "c1").revisionDate
        try await rig.vault.deleteItem(id: "c1")
        let secondRecord = try await encodedRecord("c1", in: rig)
        let secondRevision = try await rig.vault.itemDetail(id: "c1").revisionDate

        XCTAssertEqual(rig.api.getCipherCalls, ["c1", "c1"])
        XCTAssertEqual(firstRecord, secondRecord, "The same answer leaves the same stored record")
        XCTAssertEqual(firstRevision, secondRevision, "and the same cached revision")
        try assertRevision(secondRevision, is: Self.r2)
    }

    // MARK: - Adjacency

    func testRestoreThenEditInTheSameSecond_storesTheRestoreRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        // Same second as the seeded revision; only the fraction differs.
        let sameSecond = RepositoryFixtures.serverRevisionString(
            for: RepositoryFixtures.revisionDate.addingTimeInterval(0.5))
        XCTAssertNotEqual(sameSecond, Self.r1)
        XCTAssertEqual(sameSecond.prefix(19), Self.r1.prefix(19), "Both revisions are in the same second")
        rig.api.restoreCipherResponse = try await record("c1", in: rig, revision: sameSecond)

        try await rig.vault.restoreItem(id: "c1")

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, sameSecond, "The restore answer's string, byte for byte; no time tolerance")
        let cached = try await rig.vault.itemDetail(id: "c1")
        var draft = DraftVaultItem(cached)
        draft.name = "Renamed in the same second"
        _ = try await rig.vault.update(draft)
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The pre-check passes and the PUT is sent")
    }

    // MARK: - An update answer that cannot be read

    /// The server saved the edit, but its answer cannot be read (a name no key opens). Nothing is
    /// stored that cannot also be cached, so the stored record and the cached item keep the same
    /// revision, and a retry from the still-open sheet is not refused locally as a change made
    /// elsewhere.
    func testUnreadableUpdateAnswer_storesNothingAndTheRetryIsSent() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.updateCipherResponse = try await record("c1", in: rig, revision: Self.r2,
                                                        replacing: ["name": "2.AAAA|BBBB|CCCC"])
        let draft = StaleWriteRig.renamed(item)

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("An answer that cannot be read fails the save")
        } catch VaultError.conflict {
            XCTFail("An unreadable answer is not a conflict")
        } catch {
            // expected: the mapping error
        }

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r1, "The unreadable answer is not stored")
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r1)
        XCTAssertEqual(cached.name, "Login", "The cache keeps the item it had")

        // The retry: the same draft, as the sheet still holds it. The mock now echoes the request.
        rig.api.updateCipherResponse = nil
        _ = try await rig.vault.update(draft)
        XCTAssertEqual(rig.api.updateCipherCallCount, 2, "The retry passes the local check and is sent")
    }

    // MARK: - A refresh never decrypts

    func testRefresh_storesAnUnreadableRecordAsReceivedAndMapsNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1", name: "Original")
        try await seed([item], in: rig)
        // A record no key can read: if the refresh decrypted or mapped it, the name would change or
        // the operation would fail.
        let unreadable = try await record("c1", in: rig, revision: Self.r2, replacing: ["name": "2.AAAA|BBBB|CCCC"])
        rig.api.getCipherResponses["c1"] = unreadable

        try await rig.vault.deleteItem(id: "c1")

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.name, "2.AAAA|BBBB|CCCC", "The record is stored as received")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertEqual(cached.name, "Original", "Nothing was mapped: the cached item keeps its decrypted name")
        // The name differs from the record the item was built from, so the revision is not taken
        // over (see testRefreshFindingChangedContent_leavesTheCachedRevisionAndTheNextSaveConflicts).
        try assertRevision(cached.revisionDate, is: Self.r1)
    }

    // MARK: - Attachments, favorite and single move

    func testAttachmentChange_refreshesAndNextEditSaves() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        // The official server bumps the revision on an attachment change; Vaultwarden does not.
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        let attachment = Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10,
                                    sizeName: "10 B", url: nil, isUploadIncomplete: false)

        await rig.vault.updateAttachments([attachment], for: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2)
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r2)
        XCTAssertEqual(cached.attachments.map(\.id), ["att-1"], "The refresh keeps the patched attachments")

        var draft = DraftVaultItem(cached)
        draft.name = "Renamed after the attachment"
        _ = try await rig.vault.update(draft)
        XCTAssertEqual(rig.api.callLog, ["GET c1", "PUT c1"], "The next edit passes the pre-check and is sent")
    }

    func testFavorite_refreshesWithGet() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        let updated = try await rig.vault.setFavorite(itemId: "c1", isFavorite: true)

        XCTAssertEqual(rig.api.callLog, ["partial c1", "GET c1"])
        XCTAssertTrue(updated.isFavorite)
        try assertRevision(updated.revisionDate, is: Self.r2)
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2)
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r2)
    }

    func testSingleMove_refreshesWithGet() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.moveItemToFolder(itemId: "c1", folderId: "work")

        XCTAssertEqual(rig.api.callLog, ["partial c1", "GET c1"])
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertEqual(cached.folderId, "work")
        try assertRevision(cached.revisionDate, is: Self.r2)
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2)
    }

    func testFolderOnlyEdit_refreshesToo() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        var draft = DraftVaultItem(item)
        draft.folderId = "work"

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.callLog, ["partial c1", "GET c1"], "A folder-only save goes through /partial, then refreshes")
        try assertRevision(saved.revisionDate, is: Self.r2)
    }

    // MARK: - Content changed elsewhere: the refresh must not hide the conflict

    /// Another client changed the item's content after the sync, then Prizm starred it. The refresh
    /// finds a record whose content is not the one Prizm holds, so it stores that record but leaves
    /// the cached revision where it was: the next save fails the local check instead of sending a
    /// request built on content the user never saw, which would overwrite the other change.
    func testRefreshFindingChangedContent_leavesTheCachedRevisionAndTheNextSaveConflicts() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record(
            "c1", in: rig, revision: Self.r2, replacing: ["name": "2.AAAA|BBBB|CCCC"])

        let starred = try await rig.vault.setFavorite(itemId: "c1", isFavorite: true)

        XCTAssertTrue(starred.isFavorite, "Prizm's own change took effect")
        try assertRevision(starred.revisionDate, is: Self.r1)
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2, "The server's record is stored as received")
        XCTAssertEqual(stored?.name, "2.AAAA|BBBB|CCCC")

        var draft = DraftVaultItem(starred)
        draft.name = "Renamed after the other client's change"
        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A save over content another client changed must be refused")
        } catch VaultError.conflict {
            // expected
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 0, "No request is sent")
    }

    /// Vaultwarden changes the revision on a soft delete and nothing else; the official server may
    /// change per-user members. Neither is a change of the item's content, so the revision is taken
    /// and the next edit is not a conflict.
    func testRefreshFindingOnlyMetadataChanged_adoptsTheRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record(
            "c1", in: rig, revision: Self.r2,
            replacing: ["deletedDate": Self.r2, "favorite": true, "folderId": "work", "collectionIds": ["col-a"]])

        try await rig.vault.deleteItem(id: "c1")

        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r2)
        var draft = DraftVaultItem(cached)
        draft.name = "Renamed after the soft delete"
        _ = try await rig.vault.update(draft)
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The edit passes the pre-check and is sent")
    }

    /// A later own operation does not repair a conflict an earlier refresh left: the cached revision
    /// is older than the stored record's, so it stays where it is however often the same content
    /// is fetched again.
    func testSecondRefreshAfterAChangedContent_keepsTheConflict() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record(
            "c1", in: rig, revision: Self.r2, replacing: ["name": "2.AAAA|BBBB|CCCC"])
        _ = try await rig.vault.setFavorite(itemId: "c1", isFavorite: true)
        rig.api.getCipherResponses["c1"] = try await record(
            "c1", in: rig, revision: Self.r3, replacing: ["name": "2.AAAA|BBBB|CCCC"])

        let unstarred = try await rig.vault.setFavorite(itemId: "c1", isFavorite: false)

        try assertRevision(unstarred.revisionDate, is: Self.r1)
        var draft = DraftVaultItem(unstarred)
        draft.name = "Renamed"
        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The conflict is still there")
        } catch VaultError.conflict {
            // expected
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    // MARK: - Bulk move: background, bounded, chained as the queue tail

    func testBulkMove_refreshesEveryItemInTheBackground() async throws {
        let rig = await StaleWriteRig.make()
        let items = ["c1", "c2", "c3"].map { StaleWriteRig.login($0) }
        try await seed(items, in: rig)
        for item in items {
            rig.api.getCipherResponses[item.id] = try await record(item.id, in: rig, revision: Self.r2)
        }
        let gate = FetchGate()
        rig.api.whileGettingCipher = { await gate.hold() }

        try await rig.vault.moveItemsToFolder(itemIds: ["c1", "c2", "c3"], folderId: "work")

        // The move has returned while no fetch has finished: the refresh runs on in the background.
        let whileHeld = await rig.vault.queuedWriteCount
        XCTAssertEqual(whileHeld, 3, "Every moved item stays queued until its fetch has finished")
        let inFolder = try await rig.vault.items(for: .folder("work"))
        XCTAssertEqual(inFolder.count, 3, "The move itself is cached before the fetches")
        let entered = await gate.waitUntilEntered(3)
        XCTAssertTrue(entered, "All three fetches start")

        await gate.open()
        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained)
        XCTAssertEqual(rig.api.getCipherCalls.sorted(), ["c1", "c2", "c3"], "Each item is fetched once")
        for item in items {
            let cached = try await rig.vault.itemDetail(id: item.id)
            try assertRevision(cached.revisionDate, is: Self.r2)
            let stored = await rig.store.record(for: item.id)
            XCTAssertEqual(stored?.revisionDate, Self.r2)
        }
    }

    func testBulkMove_atMostFourRefreshesAtOnce() async throws {
        let rig = await StaleWriteRig.make()
        let ids = ["c1", "c2", "c3", "c4", "c5", "c6"]
        let items = ids.map { StaleWriteRig.login($0) }
        try await seed(items, in: rig)
        for id in ids {
            rig.api.getCipherResponses[id] = try await record(id, in: rig, revision: Self.r2)
        }
        let gate = FetchGate()
        rig.api.whileGettingCipher = { await gate.hold() }

        try await rig.vault.moveItemsToFolder(itemIds: ids, folderId: "work")

        let four = await gate.waitUntilEntered(4)
        XCTAssertTrue(four, "Four fetches start")
        await settle()
        let whileClosed = await gate.entered
        XCTAssertEqual(whileClosed, 4, "The fifth fetch waits until one of the four has finished")

        await gate.open()
        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained)
        XCTAssertEqual(rig.api.getCipherCalls.sorted(), ids, "All six are fetched in the end")
        let peak = await gate.peak
        XCTAssertLessThanOrEqual(peak, 4, "No more than four fetches were ever in flight")
    }

    func testBulkMove_laterWriteWaitsForThatItemsRefresh() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        // The server did not bump the revision, as on Vaultwarden: the draft below still matches.
        for item in items {
            rig.api.getCipherResponses[item.id] = try await record(item.id, in: rig, revision: Self.r1)
        }
        let gate = FetchGate()
        rig.api.whileGettingCipher = { await gate.hold() }
        let vault = rig.vault

        try await vault.moveItemsToFolder(itemIds: ["c1", "c2"], folderId: "work")
        let update = Task { try await vault.update(StaleWriteRig.renamed(items[0])) }
        let fetching = await gate.waitUntilEntered(1)
        XCTAssertTrue(fetching)
        await settle()
        XCTAssertFalse(rig.api.callLog.contains("PUT c1"), "The update of a moved item waits for that item's fetch")

        await gate.open()
        _ = try await update.value
        let log = rig.api.callLog
        let get = try XCTUnwrap(log.firstIndex(of: "GET c1"))
        let put = try XCTUnwrap(log.firstIndex(of: "PUT c1"))
        XCTAssertLessThan(get, put, "Fetch first, then the update")
        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained)
    }

    /// The design and the scenario "Bulk move, then edit" say a write waits for that item's fetch,
    /// not for the whole batch: c1's own fetch has finished, c2's is still held.
    func testBulkMove_laterWriteWaitsOnlyForThatItemsFetch() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        for item in items {
            rig.api.getCipherResponses[item.id] = try await record(item.id, in: rig, revision: Self.r1)
        }
        let gate = PerItemFetchGate()
        rig.api.whileGettingCipherById = { id in await gate.hold(id) }
        let vault = rig.vault

        try await vault.moveItemsToFolder(itemIds: ["c1", "c2"], folderId: "work")
        let entered = await gate.waitUntilEntered(2)
        XCTAssertTrue(entered, "Both fetches start")

        await gate.open("c1")
        let update = Task { try await vault.update(StaleWriteRig.renamed(items[0])) }
        var sent = false
        for _ in 0..<400 where !sent {
            sent = rig.api.callLog.contains("PUT c1")
            if !sent { try? await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertTrue(sent, "The update of c1 is sent once c1's own fetch is done, while c2's is still held")

        await gate.open("c2")
        _ = try await update.value
        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained)
    }

    func testBulkMove_queueIsEmptyAfterTheRefresh() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        for item in items {
            rig.api.getCipherResponses[item.id] = try await record(item.id, in: rig, revision: Self.r2)
        }

        try await rig.vault.moveItemsToFolder(itemIds: ["c1", "c2"], folderId: "work")

        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained, "The queue keeps nothing once the background refresh has ended")
        let count = await rig.vault.queuedWriteCount
        XCTAssertEqual(count, 0)
    }

    func testBulkMoveRefreshFailure_isOnlyLogged() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        rig.api.getCipherShouldThrow = APIError.httpError(statusCode: 500, body: "secret body")

        try await rig.vault.moveItemsToFolder(itemIds: ["c1", "c2"], folderId: "work")

        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained)
        XCTAssertEqual(rig.api.getCipherCalls.sorted(), ["c1", "c2"])
        for item in items {
            let cached = try await rig.vault.itemDetail(id: item.id)
            XCTAssertEqual(cached.folderId, "work", "The move stands")
            try assertRevision(cached.revisionDate, is: Self.r1)
            let stored = await rig.store.record(for: item.id)
            XCTAssertEqual(stored?.revisionDate, Self.r1, "The stored record is unchanged")
        }
    }

    func testBulkMoveRefreshFinishingAfterLock_writesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        for item in items {
            rig.api.getCipherResponses[item.id] = try await record(item.id, in: rig, revision: Self.r2)
        }
        let vault = rig.vault
        rig.api.whileGettingCipher = { await vault.clearVault() }

        try await rig.vault.moveItemsToFolder(itemIds: ["c1", "c2"], folderId: "work")

        let drained = await waitUntilQueueIsEmpty(rig.vault)
        XCTAssertTrue(drained)
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The background refresh does not refill the store after the lock")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty)
    }

    // MARK: - Org save: the revision comes from after the collection update

    private static let orgId = "org-acme"
    private static let orgKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xAC, count: 32),
        macKey:        Data(repeating: 0xCE, count: 32)
    )

    /// The official server changes the revision on `PUT /collections`, so the revision an org save
    /// leaves behind is the collection answer's, not the item PUT's.
    func testOrgSave_takesTheRevisionFromTheCollectionsAnswer() async throws {
        let (rig, item) = try await orgRig()
        answerPut(of: rig, revision: Self.r2, collectionIds: [])
        answerFollowUps(of: rig, collectionsRevision: Self.r3)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.callLog, ["PUT o1", "collections o1"], "The collections answer carries the cipher: no GET")
        let stored = await rig.store.record(for: "o1")
        XCTAssertEqual(stored?.revisionDate, Self.r3, "The stored record is the collections answer, not the PUT answer")
        try assertRevision(saved.revisionDate, is: Self.r3)
        XCTAssertEqual(saved.collectionIds, ["col-a"], "The returned item has the draft's collections")
        XCTAssertEqual(saved.name, "Renamed")
        let cached = try await rig.vault.itemDetail(id: "o1")
        try assertRevision(cached.revisionDate, is: Self.r3)
        XCTAssertEqual(cached.collectionIds, ["col-a"])
    }

    func testOrgSaveWithoutCollectionsCipher_refreshesWithGet() async throws {
        let (rig, item) = try await orgRig()
        answerPut(of: rig, revision: Self.r2, collectionIds: [])
        rig.api.updateCipherCollectionsResponse = nil
        answerFollowUps(of: rig, getRevision: Self.r3)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]

        let saved = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.callLog, ["PUT o1", "collections o1", "GET o1"])
        let stored = await rig.store.record(for: "o1")
        XCTAssertEqual(stored?.revisionDate, Self.r3, "The stored record is the GET answer")
        try assertRevision(saved.revisionDate, is: Self.r3)
        XCTAssertEqual(saved.collectionIds, ["col-a"])
    }

    func testCollectionsFailure_throwsCollectionChangeNotSavedAndKeepsTheSave() async throws {
        let (rig, item) = try await orgRig()
        answerPut(of: rig, revision: Self.r2, collectionIds: [])
        rig.api.updateCipherCollectionsShouldThrow = APIError.httpError(statusCode: 500, body: "")
        answerFollowUps(of: rig, getRevision: Self.r3)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A failed collection update must be reported")
        } catch VaultError.collectionChangeNotSaved {
            // expected
        }

        XCTAssertEqual(rig.api.callLog, ["PUT o1", "collections o1", "GET o1"], "The saved item is refreshed")
        let stored = await rig.store.record(for: "o1")
        XCTAssertEqual(stored?.revisionDate, Self.r3, "The stored record is the refresh's answer")
        let cached = try await rig.vault.itemDetail(id: "o1")
        XCTAssertEqual(cached.name, "Renamed", "The saved edit is in the cache")
        XCTAssertEqual(cached.collectionIds, [], "The collections the PUT answer reports: the collection change did not happen")
        try assertRevision(cached.revisionDate, is: Self.r3)
    }

    func testCollectionsFailureAndFailedRefresh_keepTheSavedRecordAndItsRevision() async throws {
        let (rig, item) = try await orgRig()
        answerPut(of: rig, revision: Self.r2, collectionIds: [])
        rig.api.updateCipherCollectionsShouldThrow = APIError.httpError(statusCode: 500, body: "")
        rig.api.getCipherShouldThrow = APIError.httpError(statusCode: 500, body: "")
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A failed collection update must be reported")
        } catch VaultError.collectionChangeNotSaved {
            // expected
        }

        let stored = await rig.store.record(for: "o1")
        XCTAssertEqual(stored?.revisionDate, Self.r2, "Without a refresh the stored record is the PUT answer")
        let cached = try await rig.vault.itemDetail(id: "o1")
        XCTAssertEqual(cached.name, "Renamed")
        try assertRevision(cached.revisionDate, is: Self.r2)
    }

    /// Retry policy: the same draft again as a full PUT, with its base moved to the cached
    /// revision. The PUT is not a conflict because the save before it was Prizm's own.
    func testRetryAfterCollectionsFailure_hasNoConflict() async throws {
        let (rig, item) = try await orgRig()
        answerPut(of: rig, revision: Self.r2, collectionIds: [])
        rig.api.updateCipherCollectionsShouldThrow = APIError.httpError(statusCode: 500, body: "")
        answerFollowUps(of: rig, getRevision: Self.r3)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]
        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The first attempt must report the failed collection update")
        } catch VaultError.collectionChangeNotSaved {
            // expected
        }
        let cached = try await rig.vault.itemDetail(id: "o1")

        rig.api.updateCipherCollectionsShouldThrow = nil
        var retry = draft
        retry.revisionDate = cached.revisionDate
        let saved = try await rig.vault.update(retry)

        XCTAssertEqual(rig.api.updateCipherCallCount, 2, "The retry is sent as a full PUT, not stopped by the pre-check")
        XCTAssertEqual(rig.api.updateCipherCollectionsCallCount, 2)
        XCTAssertEqual(saved.collectionIds, ["col-a"])
    }

    /// `PUT /collections` can say "out of date" too; it is not the item PUT, so it is not a conflict.
    func testCollectionsOutOfDate_isNotAConflict() async throws {
        let (rig, item) = try await orgRig()
        answerPut(of: rig, revision: Self.r2, collectionIds: [])
        rig.api.updateCipherCollectionsShouldThrow = APIError.httpError(
            statusCode: 400,
            body: #"{"message":"The client copy of this cipher is out of date. Resync the client and try again."}"#)
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A failed collection update must be reported")
        } catch VaultError.collectionChangeNotSaved {
            // expected: the item was saved, so there is no conflict to resolve
        } catch VaultError.conflict {
            XCTFail("An out-of-date answer to /collections is not a conflict")
        }
    }

    // MARK: - Helpers

    /// A rig with one organization item cached and stored (revision `r1`), and its key available.
    private func orgRig() async throws -> (StaleWriteRig, VaultItem) {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: StaleWriteRig.vaultKeys)
        crypto.stubbedVaultKeys = StaleWriteRig.vaultKeys
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: [Self.orgId: Self.orgKeys])
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store)
        let item = VaultItem(
            id: "o1", name: "Shared", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])),
            organizationId: Self.orgId)
        try await RepositoryFixtures.seedRecords(
            for: [item], in: store, vaultKeys: StaleWriteRig.vaultKeys, orgKeys: [Self.orgId: Self.orgKeys])
        await vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        return (StaleWriteRig(api: api, store: store, vault: vault), item)
    }

    /// Makes the item PUT answer with the request it received, stamped with `revision` and reporting
    /// `collectionIds`: the official server's PUT answer holds the collections from before the
    /// separate collection update.
    private func answerPut(of rig: StaleWriteRig, revision: String, collectionIds: [String]) {
        let api = rig.api
        api.whileUpdatingCipher = { [api] in
            guard let sent = api.lastUpdatedCipher,
                  let data = try? JSONEncoder().encode(sent),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            json["revisionDate"] = revision
            json["collectionIds"] = collectionIds
            guard let body = try? JSONSerialization.data(withJSONObject: json),
                  let answer = try? JSONDecoder().decode(RawCipher.self, from: body) else { return }
            api.updateCipherResponse = answer
        }
    }

    /// Prepares the answers an organization save gets after its PUT: `/collections`, and the fetch
    /// that replaces a collections answer without a cipher. Both carry the content the PUT sent, as
    /// a server's answers do, and differ only in their revision: an answer built from the record
    /// stored before the save would hold another client's content, and a refresh that finds changed
    /// content does not take the new revision. Call it after `answerPut`; it runs once the PUT has
    /// been answered.
    private func answerFollowUps(of rig: StaleWriteRig, collectionsRevision: String? = nil, getRevision: String? = nil) {
        let api = rig.api
        let answerPut = api.whileUpdatingCipher
        api.whileUpdatingCipher = { [api] in
            await answerPut?()
            guard let sent = api.lastUpdatedCipher else { return }
            if let collectionsRevision {
                api.updateCipherCollectionsResponse = try? RepositoryFixtures.withRevision(sent, collectionsRevision)
            }
            if let getRevision {
                api.getCipherResponses[sent.id] = try? RepositoryFixtures.withRevision(sent, getRevision)
            }
        }
    }

    /// Stores and caches `items` as a sync would leave them (revision `r1` for the default login).
    private func seed(_ items: [VaultItem], in rig: StaleWriteRig) async throws {
        for item in items {
            try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        }
        await rig.vault.populate(items: items, folders: [Folder(id: "work", name: "Work")],
                                 organizations: [], collections: [], syncedAt: Date())
    }

    /// The stored record of `id` with another `revisionDate` (and optionally other top-level
    /// values), as a server answer.
    private func record(
        _ id: String, in rig: StaleWriteRig, revision: String, replacing changes: [String: Any] = [:]
    ) async throws -> RawCipher {
        let stored = await rig.store.record(for: id)
        let data = try JSONEncoder().encode(try XCTUnwrap(stored))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["revisionDate"] = revision
        for (key, value) in changes { json[key] = value }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The stored record as sorted-key JSON, to compare two states of it.
    private func encodedRecord(_ id: String, in rig: StaleWriteRig) async throws -> Data {
        let stored = await rig.store.record(for: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try XCTUnwrap(stored))
    }

    /// Lets queued work run: there is no event to wait for when the thing under test is "nothing
    /// happens while the fetch is held".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// True once no write is queued any more; gives up after about two seconds so a stuck queue
    /// fails the test instead of hanging it.
    private func waitUntilQueueIsEmpty(_ vault: VaultRepositoryImpl) async -> Bool {
        for _ in 0..<400 {
            if await vault.queuedWriteCount == 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await vault.queuedWriteCount == 0
    }

    private func assertRevision(
        _ date: Date, is revision: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(CipherMapper.parseRevisionDate(revision), file: file, line: line)
        XCTAssertTrue(CipherMapper.sameRevision(date, expected),
                      "cached revision \(date) is not \(revision)", file: file, line: line)
    }
}

/// Holds each mocked fetch until its own item is opened.
private actor PerItemFetchGate {
    private var entered: Set<String> = []
    private var opened: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func hold(_ id: String) async {
        entered.insert(id)
        if opened.contains(id) { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func open(_ id: String) {
        opened.insert(id)
        waiters.removeValue(forKey: id)?.resume()
    }

    /// True once `count` different items have a fetch started; gives up after about two seconds.
    func waitUntilEntered(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if entered.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered.count >= count
    }
}

/// Holds mocked fetches until `open()` and counts how many were started and how many were in
/// flight at once.
private actor FetchGate {
    private(set) var entered = 0
    private(set) var peak = 0
    private var inFlight = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered += 1
        inFlight += 1
        peak = max(peak, inFlight)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight -= 1
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// True once `count` fetches have started; gives up after about two seconds.
    func waitUntilEntered(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if entered >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered >= count
    }
}

// MARK: - The wire: GET one cipher, restore with and without an answer

/// `getCipher` and the cipher-returning `restoreCipher` and `updateCipherCollections` of the real
/// client, at the HTTP level.
final class RevisionRefreshWireTests: XCTestCase {

    private let base = URL(string: "https://vault.example.com")!
    private var sut: PrizmAPIClientImpl!

    private let cipherBody = Data("""
        {"id":"c1","type":1,"name":"2.x|y|z","favorite":false,
         "revisionDate":"2026-10-26T10:00:00.123456Z","deletedDate":null}
        """.utf8)

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        sut = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await sut.setBaseURL(base)
    }

    func testGetCipher_sendsGetToTheItemRouteAndDecodesTheCipher() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        let cipher = try await sut.getCipher(id: "c1")

        XCTAssertEqual(cipher.id, "c1")
        XCTAssertEqual(cipher.revisionDate, "2026-10-26T10:00:00.123456Z", "The revision string is kept as received")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://vault.example.com/api/ciphers/c1")
        XCTAssertNil(request.body)
    }

    func testGetCipher_httpErrorThrows() async {
        StubURLProtocol.responder = { _ in .status(404) }

        do {
            _ = try await sut.getCipher(id: "c1")
            XCTFail("A 404 must throw")
        } catch APIError.httpError(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("Expected httpError, got \(error)")
        }
    }

    /// The fetch runs inside the item's write queue, so a server that stops answering must free the
    /// queue well before the session's default time-out of 60 seconds.
    func testGetCipher_hasAShortTimeoutOfItsOwn() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        _ = try await sut.getCipher(id: "c1")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.timeoutInterval, PrizmAPIClientImpl.revisionRefreshTimeout)
        XCTAssertLessThanOrEqual(PrizmAPIClientImpl.revisionRefreshTimeout, 10)
    }

    func testRestoreCipher_returnsTheCipherTheServerSent() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        let restored = try await sut.restoreCipher(id: "c1")

        XCTAssertEqual(restored?.revisionDate, "2026-10-26T10:00:00.123456Z")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url?.path, "/api/ciphers/c1/restore")
        XCTAssertNil(request.body, "No body: a body with a Content-Type makes Vaultwarden answer 400")
        XCTAssertNil(request.headers["Content-Type"])
    }

    func testRestoreCipher_emptyOrUndecodableBodyGivesNilNotAnError() async throws {
        for body in [Data(), Data("not json".utf8), Data("{\"object\":\"cipher\"}".utf8)] {
            StubURLProtocol.responder = { _ in .status(200, body: body) }

            let restored = try await sut.restoreCipher(id: "c1")

            XCTAssertNil(restored, "A restore that succeeded is a success whatever the body holds")
        }
    }

    func testUpdateCipherCollections_returnsTheCipherTheServerSent() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        let answer = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a"])

        XCTAssertEqual(answer?.revisionDate, "2026-10-26T10:00:00.123456Z", "The revision string is kept as received")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url?.path, "/api/ciphers/c1/collections")
        XCTAssertEqual(request.jsonBody?["collectionIds"] as? [String], ["col-a"])
    }

    func testUpdateCipherCollections_emptyOrUndecodableBodyGivesNilNotAnError() async throws {
        for body in [Data(), Data("not json".utf8), Data("{\"object\":\"cipher\"}".utf8)] {
            StubURLProtocol.responder = { _ in .status(200, body: body) }

            let answer = try await sut.updateCipherCollections(id: "c1", collectionIds: [])

            XCTAssertNil(answer, "A collection update that succeeded is a success whatever the body holds")
        }
    }

    func testUpdateCipherCollections_httpErrorStillThrows() async {
        StubURLProtocol.responder = { _ in .status(400, body: Data(#"{"message":"out of date"}"#.utf8)) }

        do {
            _ = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a"])
            XCTFail("A 400 must throw")
        } catch APIError.httpError(let status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("Expected httpError, got \(error)")
        }
    }

    func testRestoreCipher_httpErrorStillThrows() async {
        StubURLProtocol.responder = { _ in .status(503) }

        do {
            _ = try await sut.restoreCipher(id: "c1")
            XCTFail("A 503 must throw")
        } catch APIError.httpError(let status, _) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("Expected httpError, got \(error)")
        }
    }
}
