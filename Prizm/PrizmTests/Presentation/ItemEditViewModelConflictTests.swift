import Combine
import XCTest
@testable import Prizm

/// The edit sheet after a stale-write conflict: one request per click, a conflict that keeps the
/// sheet and the user's input, Save blocked in every conflict state until the user reloads, and a
/// resync that runs through the vault browser (reached by closures, never by a use case here).
@MainActor
final class ItemEditViewModelConflictTests: XCTestCase {

    // MARK: - Test doubles

    /// Lets a test hold a suspended call until it decides to continue.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// An edit use case that answers from a queue (an empty queue succeeds with the saved draft)
    /// and can be held at the start of a call.
    private final class ScriptedEdit: EditVaultItemUseCase {
        var results: [Result<VaultItem, Error>] = []
        var gate: Gate?
        private(set) var callCount = 0

        func execute(draft: DraftVaultItem) async throws -> VaultItem {
            callCount += 1
            if let gate { await gate.wait() }
            guard !results.isEmpty else { return VaultItem(draft) }
            return try results.removeFirst().get()
        }
    }

    /// Stands in for the two vault browser services the app passes to the sheet.
    private final class Browser {
        /// One answer per resync call; the last one repeats.
        var resyncs: [ConflictResync] = [.synced]
        var resyncGate: Gate?
        var latest: LatestItem = .gone
        private(set) var resyncCallCount = 0
        private(set) var latestCallCount = 0
        private(set) var saved: [VaultItem] = []

        func resync() async -> ConflictResync {
            resyncCallCount += 1
            if let resyncGate { await resyncGate.wait() }
            return resyncs.count > 1 ? resyncs.removeFirst() : resyncs[0]
        }

        func latestItem(_ id: String) async -> LatestItem {
            latestCallCount += 1
            return latest
        }

        func didSave(_ item: VaultItem) { saved.append(item) }
    }

    private func item(name: String = "Original", revision: Date = Date(timeIntervalSince1970: 1_000),
                      editBlock: EditBlockReason? = nil) -> VaultItem {
        VaultItem(
            id: "item-1", name: name, isFavorite: false, isDeleted: false,
            creationDate: Date(timeIntervalSince1970: 500), revisionDate: revision,
            content: .login(LoginContent(username: "alice", password: "hunter2", uris: [], totp: nil,
                                         notes: nil, customFields: [])),
            editBlock: editBlock
        )
    }

    private struct Rig {
        let sut: ItemEditViewModel
        let edit: ScriptedEdit
        let browser: Browser
    }

    /// An edit sheet whose draft has been renamed, wired to scripted services.
    private func makeRig(results: [Result<VaultItem, Error>] = [], browser: Browser = Browser(),
                         wireClosures: Bool = true) -> Rig {
        let edit = ScriptedEdit()
        edit.results = results
        let sut = ItemEditViewModel(item: item(), useCase: edit)
        sut.draft.name = "Edited name"
        if wireClosures {
            sut.onConflict = { await browser.resync() }
            sut.latestItem = { await browser.latestItem($0) }
        }
        sut.onSaveSuccess = { browser.didSave($0) }
        return Rig(sut: sut, edit: edit, browser: browser)
    }

    /// Polls on the main actor until `condition` holds or `timeout` passes.
    private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Saves once with a conflict and waits until the sheet has left `.syncing`.
    private func conflicted(resyncs: [ConflictResync], latest: LatestItem) async -> Rig {
        let browser = Browser()
        browser.resyncs = resyncs
        browser.latest = latest
        let rig = makeRig(results: [.failure(VaultError.conflict)], browser: browser)
        rig.sut.save()
        let settled = await eventually { rig.sut.conflict != .none && rig.sut.conflict != .syncing }
        XCTAssertTrue(settled, "the conflict resync did not finish")
        return rig
    }

    // MARK: - One request per click

    func testSaveTwiceInOneTurn_callsTheUseCaseOnce() async {
        let rig = makeRig()
        let gate = Gate()
        rig.edit.gate = gate

        rig.sut.save()
        XCTAssertTrue(rig.sut.isSaving, "isSaving is set before the save task starts")
        XCTAssertFalse(rig.sut.canSave)
        rig.sut.save()
        gate.open()

        let dismissed = await eventually { rig.sut.isDismissed }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(rig.edit.callCount, 1)
    }

    // MARK: - Conflict

    func testConflict_keepsInputBlocksSaveAndResyncs() async {
        let browser = Browser()
        browser.latest = .available(item(name: "Changed elsewhere"))
        let rig = makeRig(results: [.failure(VaultError.conflict)], browser: browser)
        var states: [ItemEditViewModel.ConflictState] = []
        // Combine here, although new code avoids it: `conflict` is `@Published`, and `sink` records
        // each state synchronously when it is set, which is what the sequence check below needs.
        let observation = rig.sut.$conflict.sink { states.append($0) }
        defer { observation.cancel() }

        rig.sut.save()
        let synced = await eventually { rig.sut.conflict == .synced }

        XCTAssertTrue(synced)
        XCTAssertEqual(states, [.none, .syncing, .synced])
        XCTAssertEqual(rig.sut.saveError, VaultError.conflict.errorDescription)
        XCTAssertFalse(rig.sut.isDismissed, "the sheet stays open")
        XCTAssertEqual(rig.sut.draft.name, "Edited name", "the user's input stays")
        XCTAssertTrue(rig.browser.saved.isEmpty, "a conflict is not a success")
        XCTAssertEqual(rig.browser.resyncCallCount, 1)
        XCTAssertFalse(rig.sut.canSave)
    }

    func testConflictResync_runsWithSaveNotInProgress() async {
        let browser = Browser()
        let gate = Gate()
        browser.resyncGate = gate
        browser.latest = .available(item(name: "Changed elsewhere"))
        let rig = makeRig(results: [.failure(VaultError.conflict)], browser: browser)

        rig.sut.save()
        let syncing = await eventually { rig.sut.conflict == .syncing }
        XCTAssertTrue(syncing)
        XCTAssertFalse(rig.sut.isSaving, "Discard and Esc stay available, and Save keeps its normal title")
        XCTAssertFalse(rig.sut.canSave, "the conflict blocks Save, not the in-progress flag")

        gate.open()
        let synced = await eventually { rig.sut.conflict == .synced }
        XCTAssertTrue(synced)
        XCTAssertFalse(rig.sut.isSaving)
    }

    func testSaveIsIgnoredInEveryConflictState() async {
        // .syncing: the resync is held.
        let browser = Browser()
        let gate = Gate()
        browser.resyncGate = gate
        browser.latest = .available(item(name: "Changed elsewhere"))
        let rig = makeRig(results: [.failure(VaultError.conflict)], browser: browser)
        rig.sut.save()
        let syncing = await eventually { rig.sut.conflict == .syncing }
        XCTAssertTrue(syncing)
        assertSaveSendsNothing(rig, state: ".syncing")

        // .synced: the same sheet once the resync is released.
        gate.open()
        let synced = await eventually { rig.sut.conflict == .synced }
        XCTAssertTrue(synced)
        assertSaveSendsNothing(rig, state: ".synced")

        // .syncFailed and .itemGone, each from its own sheet.
        let failed = await conflicted(resyncs: [.failed("Sync failed.")], latest: .gone)
        XCTAssertEqual(failed.sut.conflict, .syncFailed("Sync failed."))
        assertSaveSendsNothing(failed, state: ".syncFailed")

        let gone = await conflicted(resyncs: [.synced], latest: .gone)
        XCTAssertEqual(gone.sut.conflict, .itemGone)
        assertSaveSendsNothing(gone, state: ".itemGone")
    }

    /// A direct `save()` is the path of Item > Save and the menu shortcut.
    private func assertSaveSendsNothing(_ rig: Rig, state: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let before = rig.edit.callCount
        XCTAssertFalse(rig.sut.canSave, "canSave in \(state)", file: file, line: line)
        rig.sut.save()
        XCTAssertEqual(rig.edit.callCount, before, "save() in \(state) sends nothing", file: file, line: line)
        XCTAssertFalse(rig.sut.isSaving, "save() in \(state) does not start", file: file, line: line)
    }

    func testConflict_failedResync_showsTheSyncError() async {
        let message = "No internet connection. Check your network connection."
        let rig = await conflicted(resyncs: [.failed(message)], latest: .gone)

        XCTAssertEqual(rig.sut.conflict, .syncFailed(message))
        XCTAssertEqual(rig.browser.latestCallCount, 0, "nothing is looked up after a failed sync")
        XCTAssertEqual(rig.sut.saveError, VaultError.conflict.errorDescription)
    }

    /// The app wires both closures for every edit sheet. A sheet without them cannot sync, so it
    /// stays blocked rather than refilling from nothing, and keeps what the user typed.
    func testConflict_withoutTheResyncClosures_staysBlockedAndKeepsTheDraft() async {
        let rig = makeRig(results: [.failure(VaultError.conflict)], wireClosures: false)

        rig.sut.save()
        let settled = await eventually { rig.sut.conflict != .none && rig.sut.conflict != .syncing }

        XCTAssertTrue(settled)
        XCTAssertEqual(rig.sut.conflict, .syncFailed(""))
        XCTAssertFalse(rig.sut.canSave, "Save stays blocked")
        XCTAssertEqual(rig.sut.draft.name, "Edited name", "the user's input stays")
        XCTAssertEqual(rig.sut.saveError, VaultError.conflict.errorDescription)
        XCTAssertFalse(rig.sut.isDismissed)
    }

    func testConflict_itemGoneAfterResync() async {
        let rig = await conflicted(resyncs: [.synced], latest: .gone)

        XCTAssertEqual(rig.sut.conflict, .itemGone)
        XCTAssertFalse(rig.sut.isDismissed, "the user closes the sheet")
    }

    // MARK: - Errors that are not conflicts

    func testErrorAfterLockDismissal_isIgnored() async {
        let rig = makeRig(results: [.failure(VaultError.vaultLocked)])
        let gate = Gate()
        rig.edit.gate = gate
        rig.sut.save()
        let started = await eventually { rig.edit.callCount == 1 }
        XCTAssertTrue(started)

        NotificationCenter.default.post(name: .vaultDidLock, object: nil)
        let dismissed = await eventually { rig.sut.isDismissed }
        XCTAssertTrue(dismissed)
        gate.open()
        let finished = await eventually { !rig.sut.isSaving }

        XCTAssertTrue(finished)
        XCTAssertNil(rig.sut.saveError, "no banner after the lock")
        XCTAssertEqual(rig.browser.resyncCallCount, 0)
    }

    func testConflictAfterLockDismissal_startsNoSync() async {
        let rig = makeRig(results: [.failure(VaultError.conflict)])
        let gate = Gate()
        rig.edit.gate = gate
        rig.sut.save()
        let started = await eventually { rig.edit.callCount == 1 }
        XCTAssertTrue(started)

        NotificationCenter.default.post(name: .vaultDidLock, object: nil)
        let dismissed = await eventually { rig.sut.isDismissed }
        XCTAssertTrue(dismissed)
        gate.open()
        let finished = await eventually { !rig.sut.isSaving }

        XCTAssertTrue(finished)
        XCTAssertNil(rig.sut.saveError)
        XCTAssertEqual(rig.sut.conflict, .none)
        XCTAssertEqual(rig.browser.resyncCallCount, 0)
    }

    func testRevisionUnavailable_isAPlainErrorWithoutResync() async {
        let rig = makeRig(results: [.failure(VaultError.itemRevisionUnavailable)])

        rig.sut.save()
        let failed = await eventually { rig.sut.saveError != nil && !rig.sut.isSaving }

        XCTAssertTrue(failed)
        XCTAssertEqual(rig.sut.saveError, VaultError.itemRevisionUnavailable.errorDescription)
        XCTAssertEqual(rig.sut.conflict, .none)
        XCTAssertEqual(rig.browser.resyncCallCount, 0)
        XCTAssertTrue(rig.sut.canSave, "Save stays available for a retry")
        XCTAssertFalse(rig.sut.isDismissed)
        XCTAssertEqual(rig.sut.draft.name, "Edited name", "the user's input stays")
    }
}
