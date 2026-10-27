import XCTest
@testable import Prizm

/// The 400 Vaultwarden and the official server send for an update based on an outdated copy becomes
/// `VaultError.conflict` with a plain message, and nothing else is mapped (openspec change
/// fix-cipher-edit-data-loss, task 4.3, and server-error-texts "Out-of-date item update").
///
/// The Vaultwarden text comes from a real 1.37.4 answer (`stale-put-400-1.37.4.json`); the official
/// server's is hand-written from its source and has never been captured (`official-out-of-date-400.json`).
@MainActor
final class ConflictDetectionTests: XCTestCase {

    private let vaultwardenText = "The client copy of this cipher is out of date. Resync the client and try again."
    private let officialText = "The item cannot be saved because it is out of date. To edit this item, first sync your vault, or log out and back in."

    // MARK: - Helpers

    private func fixtureBody(_ name: String) throws -> String {
        try XCTUnwrap(String(data: FixtureLoader.data(named: name), encoding: .utf8))
    }

    private func badRequest(_ body: String, status: Int = 400) -> APIError {
        .httpError(statusCode: status, body: body)
    }

    /// A rig whose update PUT fails with `error`, over a stored record that matches the draft, so
    /// the local check passes and only the server's answer decides.
    private func rigFailingUpdate(with error: Error) async throws -> (rig: StaleWriteRig, draft: DraftVaultItem, revision: String) {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        let revision = RepositoryFixtures.serverRevisionString(for: item.revisionDate)
        try await rig.storeRecord(of: item, revision: revision)
        rig.api.updateCipherShouldThrow = error
        return (rig, StaleWriteRig.renamed(item), revision)
    }

    private func assertMapsToConflict(_ error: APIError, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (rig, draft, revision) = try await rigFailingUpdate(with: error)
        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The update must fail", file: file, line: line)
        } catch VaultError.conflict {
            // expected
        } catch {
            XCTFail("Expected VaultError.conflict, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "Rejected once and not retried", file: file, line: line)
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, revision, "The stored record is untouched", file: file, line: line)
    }

    private func assertStaysTheServersError(_ error: APIError, shows message: String,
                                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let (rig, draft, _) = try await rigFailingUpdate(with: error)
        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The update must fail", file: file, line: line)
        } catch let thrown as APIError {
            XCTAssertEqual(thrown, error, file: file, line: line)
            XCTAssertEqual(thrown.localizedDescription, message, file: file, line: line)
        } catch {
            XCTFail("Expected the APIError to reach the caller, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Vaultwarden and official server texts

    func testVaultwardenFixture_mapsToConflict() async throws {
        try await assertMapsToConflict(badRequest(try fixtureBody("stale-put-400-1.37.4")))
    }

    func testOfficialFixture_mapsToConflict() async throws {
        try await assertMapsToConflict(badRequest(try fixtureBody("official-out-of-date-400")))
    }

    func testPascalCaseAndUpperCase_mapToConflict() async throws {
        try await assertMapsToConflict(badRequest(#"{"Message":"\#(officialText)"}"#))
        try await assertMapsToConflict(badRequest(#"{"message":"\#(officialText.uppercased())"}"#))
    }

    // MARK: - Nothing else is a conflict

    func test400WithoutThePhrase_keepsTheServerMessage() async throws {
        try await assertStaysTheServersError(
            badRequest(#"{"message":"The model state is invalid."}"#), shows: "The model state is invalid.")
    }

    func test409And500WithThePhrase_doNotMap() async throws {
        let body = try fixtureBody("stale-put-400-1.37.4")
        try await assertStaysTheServersError(badRequest(body, status: 409), shows: vaultwardenText)
        try await assertStaysTheServersError(badRequest(body, status: 500), shows: vaultwardenText)
    }

    func test400EmptyOrHTML_showsTheStatus() async throws {
        try await assertStaysTheServersError(badRequest(""), shows: "Server error 400.")
        try await assertStaysTheServersError(badRequest("<html><body>Bad Request</body></html>"), shows: "Server error 400.")
    }

    /// Only the update PUT is mapped: the same answer to /partial or to a create is the server's own
    /// error, because those calls carry no last-known revision and the message would be wrong.
    func testPartialAndCreate_areNotMapped() async throws {
        let body = try fixtureBody("stale-put-400-1.37.4")

        let partial = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await partial.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        await partial.cache(item)
        partial.api.updateCipherPartialShouldThrow = badRequest(body)
        var folderOnly = DraftVaultItem(item)
        folderOnly.folderId = "work"
        do {
            _ = try await partial.vault.update(folderOnly)
            XCTFail("The partial update must fail")
        } catch is APIError {
            // expected: the server's error, not a conflict
        }

        let create = await StaleWriteRig.make()
        create.api.createCipherShouldThrow = badRequest(body)
        do {
            _ = try await create.vault.create(DraftVaultItem(StaleWriteRig.login("n1")))
            XCTFail("The create must fail")
        } catch is APIError {
            // expected
        }
    }

    // MARK: - The texts and the matcher

    func testConflictMessages_matchTheCopy() throws {
        let conflict = try XCTUnwrap(VaultError.conflict.errorDescription)
        XCTAssertEqual(
            conflict,
            "This item was changed on another device. Your changes were not saved. Reload to see the latest version, then make your changes again.")
        XCTAssertEqual(
            VaultError.collectionChangeNotSaved.errorDescription,
            "Your changes were saved, but the collection change failed. Try again.")
        // The user never sees the server's wording or the technical terms.
        for term in ["out of date", "revision", "conflict"] {
            XCTAssertFalse(conflict.localizedCaseInsensitiveContains(term), "The message must not say \"\(term)\"")
        }
    }

    func testIsOutOfDateRejection_cases() throws {
        XCTAssertTrue(badRequest(try fixtureBody("stale-put-400-1.37.4")).isOutOfDateRejection)
        XCTAssertTrue(badRequest(try fixtureBody("official-out-of-date-400")).isOutOfDateRejection)
        XCTAssertFalse(badRequest(#"{"message":"The model state is invalid."}"#).isOutOfDateRejection)
        XCTAssertFalse(badRequest(try fixtureBody("stale-put-400-1.37.4"), status: 409).isOutOfDateRejection)
        XCTAssertFalse(APIError.decodingFailed.isOutOfDateRejection)
    }
}
