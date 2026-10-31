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
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            continuations.forEach { $0.resume() }
            continuations = []
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
        /// Holds every lookup of the synced item until the test opens it.
        var latestGate: Gate?
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
            if let latestGate { await latestGate.wait() }
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

    /// Lets main-actor work that is already scheduled run: a fixed number of turns, not wall-clock
    /// time, so "nothing else happened" is checked after the work a regression would have started.
    private func yieldMainActor(turns: Int = 25) async {
        for _ in 0..<turns { await Task.yield() }
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

    // MARK: - Reload in place

    func testReload_refillsDraftAndOriginal() async {
        let synced = item(name: "Changed elsewhere", revision: Date(timeIntervalSince1970: 2_000))
        let rig = await conflicted(resyncs: [.synced], latest: .available(synced))
        XCTAssertEqual(rig.sut.conflict, .synced)

        rig.sut.performConflictAction()
        let reloaded = await eventually { rig.sut.conflict == .none }

        XCTAssertTrue(reloaded)
        XCTAssertEqual(rig.sut.draft, DraftVaultItem(synced))
        XCTAssertFalse(rig.sut.hasChanges, "original was replaced too")
        XCTAssertNil(rig.sut.saveError)
        XCTAssertTrue(rig.sut.canSave)
        XCTAssertEqual(rig.sut.reloadCount, 1)
        XCTAssertFalse(rig.sut.isDismissed, "the sheet stays open")
    }

    /// The sheet may stay open for a while after the sync, so the item can go before the press.
    func testReload_whenTheItemWentMeanwhile_endsInItemGoneAndKeepsTheDraft() async {
        let rig = await conflicted(resyncs: [.synced],
                                   latest: .available(item(name: "Changed elsewhere")))
        XCTAssertEqual(rig.sut.conflict, .synced)
        rig.browser.latest = .gone

        rig.sut.performConflictAction()
        let gone = await eventually { rig.sut.conflict == .itemGone }

        XCTAssertTrue(gone)
        XCTAssertEqual(rig.sut.draft.name, "Edited name", "nothing is refilled")
        XCTAssertEqual(rig.sut.reloadCount, 0)
        XCTAssertFalse(rig.sut.isDismissed, "the user closes the sheet")
    }

    func testReloadAfterFailedSync_syncsAgainFirst() async {
        let synced = item(name: "Changed elsewhere", revision: Date(timeIntervalSince1970: 2_000))
        let rig = await conflicted(resyncs: [.failed("Sync failed."), .synced], latest: .available(synced))
        XCTAssertEqual(rig.sut.conflict, .syncFailed("Sync failed."))
        let gate = Gate()
        rig.browser.resyncGate = gate

        rig.sut.performConflictAction()

        XCTAssertEqual(rig.sut.conflict, .syncing, "a press starts the new sync at once")
        let called = await eventually { rig.browser.resyncCallCount == 2 }
        XCTAssertTrue(called)
        XCTAssertFalse(rig.sut.isSaving, "a resync is not a save")
        XCTAssertEqual(rig.sut.draft.name, "Edited name", "nothing is refilled from a failed sync")

        gate.open()
        let synced2 = await eventually { rig.sut.conflict == .synced }
        XCTAssertTrue(synced2)
        XCTAssertEqual(rig.sut.draft.name, "Edited name", "the draft changes only on a further press")
        XCTAssertEqual(rig.sut.reloadCount, 0)
    }

    func testReloadTwice_actsOnce() async {
        let synced = item(name: "Changed elsewhere", revision: Date(timeIntervalSince1970: 2_000))
        let rig = await conflicted(resyncs: [.synced], latest: .available(synced))
        let lookupsBefore = rig.browser.latestCallCount
        let gate = Gate()
        rig.browser.latestGate = gate

        rig.sut.performConflictAction()
        rig.sut.performConflictAction()  // while the first lookup is held: must not start another
        let entered = await eventually { rig.browser.latestCallCount > lookupsBefore }
        XCTAssertTrue(entered, "the first press looks the item up")
        await yieldMainActor()  // a second lookup, if a press started one, has reached the gate by now
        XCTAssertEqual(rig.browser.latestCallCount, lookupsBefore + 1, "one lookup for two presses")

        gate.open()
        let reloaded = await eventually { rig.sut.conflict == .none }
        XCTAssertTrue(reloaded)
        rig.sut.performConflictAction()  // no conflict any more: nothing to do
        await yieldMainActor()

        XCTAssertEqual(rig.browser.latestCallCount, lookupsBefore + 1, "one lookup for one refill")
        XCTAssertEqual(rig.sut.reloadCount, 1)
        XCTAssertEqual(rig.browser.resyncCallCount, 1)
    }

    func testPressWhileSyncing_doesNothing() async {
        let browser = Browser()
        let gate = Gate()
        browser.resyncGate = gate
        browser.latest = .available(item(name: "Changed elsewhere"))
        let rig = makeRig(results: [.failure(VaultError.conflict)], browser: browser)
        rig.sut.save()
        let syncing = await eventually { rig.sut.conflict == .syncing }
        XCTAssertTrue(syncing)

        rig.sut.performConflictAction()
        await yieldMainActor()  // a second resync, if the press started one, has started by now

        XCTAssertEqual(rig.browser.resyncCallCount, 1)
        XCTAssertEqual(rig.sut.conflict, .syncing)
        gate.open()
        _ = await eventually { rig.sut.conflict == .synced }
    }

    func testClose_inItemGone_dismissesAndClears() async {
        let rig = await conflicted(resyncs: [.synced], latest: .gone)
        XCTAssertEqual(rig.sut.conflict, .itemGone)

        rig.sut.performConflictAction()

        XCTAssertTrue(rig.sut.isDismissed)
        XCTAssertEqual(rig.sut.draft.name, "", "the draft's plaintext is dropped")
        XCTAssertEqual(rig.sut.reloadCount, 0)
    }

    func testReloadedBlockedItem_saveShowsTheEditBlock() async {
        let blocked = item(name: "Blocked", editBlock: .unsupportedFormat)
        let rig = await conflicted(resyncs: [.synced], latest: .available(blocked))
        rig.sut.performConflictAction()
        let reloaded = await eventually { rig.sut.conflict == .none }
        XCTAssertTrue(reloaded)
        rig.edit.results = [.failure(VaultError.itemNotEditable(.unsupportedFormat))]

        rig.sut.save()
        let failed = await eventually { rig.sut.saveError == EditBlockReason.unsupportedFormat.userMessage && !rig.sut.isSaving }

        XCTAssertTrue(failed)
        XCTAssertEqual(rig.sut.conflict, .none)
        XCTAssertEqual(rig.browser.resyncCallCount, 1, "the edit block starts no sync")
    }

    // MARK: - Partly saved organization edit

    func testCollectionChangeNotSaved_movesTheBaseAndKeepsTheSheet() async {
        let savedItem = item(name: "Edited name", revision: Date(timeIntervalSince1970: 2_000))
        let browser = Browser()
        browser.latest = .available(savedItem)
        let rig = makeRig(results: [.failure(VaultError.collectionChangeNotSaved)], browser: browser)
        rig.sut.draft.collectionIds = ["col-1"]

        rig.sut.save()
        let finished = await eventually { rig.sut.saveError != nil && !rig.sut.isSaving }

        XCTAssertTrue(finished)
        XCTAssertEqual(rig.sut.saveError, VaultError.collectionChangeNotSaved.errorDescription)
        XCTAssertFalse(rig.sut.isDismissed, "the sheet stays open")
        XCTAssertEqual(rig.sut.conflict, .none)
        XCTAssertTrue(rig.sut.canSave, "Save stays enabled for the retry")
        XCTAssertEqual(rig.sut.draft.revisionDate, savedItem.revisionDate, "the retry is based on the saved revision")
        XCTAssertEqual(rig.browser.saved, [savedItem], "the list and detail show the saved content once")
        XCTAssertEqual(rig.browser.resyncCallCount, 0)
        XCTAssertTrue(rig.sut.hasChanges, "the unsaved collection change still counts")
        rig.sut.draft.collectionIds = []
        XCTAssertFalse(rig.sut.hasChanges, "only the collections differ from the saved item")
    }

    // MARK: - Texts and flags

    func testPresentationTexts_perState() async {
        let message = VaultError.conflict.errorDescription
        let title = "Discard my changes and reload"
        let reloadFirst = "Reload the item first."

        // Literal copy, character for character.
        XCTAssertEqual(
            ItemEditViewModel.itemGoneNote,
            "This item is no longer available. It was deleted or moved on another device, or your access was removed.")
        XCTAssertEqual(ItemEditViewModel.reloadAnnouncement, "Reloaded the latest version.")

        // none
        let none = makeRig()
        assertTexts(none.sut, state: "none", banner: nil, status: nil, announcement: nil, title: nil,
                    enabled: true, hint: nil, saveHint: nil, gone: false)

        // syncing
        let browser = Browser()
        let gate = Gate()
        browser.resyncGate = gate
        browser.latest = .available(item(name: "Changed elsewhere"))
        let syncing = makeRig(results: [.failure(VaultError.conflict)], browser: browser)
        syncing.sut.save()
        _ = await eventually { syncing.sut.conflict == .syncing }
        assertTexts(syncing.sut, state: "syncing", banner: message, status: "Syncing\u{2026}", announcement: nil,
                    title: title, enabled: false, hint: "Available when the sync finishes.", saveHint: reloadFirst, gone: false)

        // synced (the same sheet, once released)
        gate.open()
        _ = await eventually { syncing.sut.conflict == .synced }
        assertTexts(syncing.sut, state: "synced", banner: message, status: "Synced", announcement: "Synced",
                    title: title, enabled: true, hint: nil, saveHint: reloadFirst, gone: false)

        // syncFailed
        let failed = await conflicted(resyncs: [.failed("No internet connection.")], latest: .gone)
        assertTexts(failed.sut, state: "syncFailed", banner: message, status: "No internet connection.",
                    announcement: "No internet connection.", title: title, enabled: true, hint: nil,
                    saveHint: reloadFirst, gone: false)

        // syncFailed without a message shows no status line
        let silent = await conflicted(resyncs: [.failed("")], latest: .gone)
        assertTexts(silent.sut, state: "syncFailed, empty", banner: message, status: nil, announcement: nil,
                    title: title, enabled: true, hint: nil, saveHint: reloadFirst, gone: false)

        // itemGone
        let gone = await conflicted(resyncs: [.synced], latest: .gone)
        assertTexts(gone.sut, state: "itemGone", banner: ItemEditViewModel.itemGoneNote, status: nil,
                    announcement: nil, title: "Close", enabled: true, hint: nil,
                    saveHint: "This item no longer exists.", gone: true)
    }

    private func assertTexts(
        _ sut: ItemEditViewModel, state: String, banner: String?, status: String?, announcement: String?,
        title: String?, enabled: Bool, hint: String?, saveHint: String?, gone: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(sut.bannerMessage, banner, "bannerMessage in \(state)", file: file, line: line)
        XCTAssertEqual(sut.conflictStatusText, status, "conflictStatusText in \(state)", file: file, line: line)
        XCTAssertEqual(sut.conflictStatusAnnouncement, announcement, "conflictStatusAnnouncement in \(state)", file: file, line: line)
        XCTAssertEqual(sut.conflictActionTitle, title, "conflictActionTitle in \(state)", file: file, line: line)
        XCTAssertEqual(sut.isConflictActionEnabled, enabled, "isConflictActionEnabled in \(state)", file: file, line: line)
        XCTAssertEqual(sut.conflictActionHint, hint, "conflictActionHint in \(state)", file: file, line: line)
        XCTAssertEqual(sut.saveBlockedHint, saveHint, "saveBlockedHint in \(state)", file: file, line: line)
        XCTAssertEqual(sut.isItemGone, gone, "isItemGone in \(state)", file: file, line: line)
    }

    func testEmptySaveError_showsNoBanner() async {
        struct Silent: LocalizedError { var errorDescription: String? { "" } }
        let rig = makeRig(results: [.failure(Silent())])

        rig.sut.save()
        let finished = await eventually { rig.sut.saveError != nil && !rig.sut.isSaving }

        XCTAssertTrue(finished)
        XCTAssertEqual(rig.sut.saveError, "")
        XCTAssertNil(rig.sut.bannerMessage, "an empty message is never an empty red bar")
        XCTAssertNil(makeRig().sut.bannerMessage)
    }

    /// Every fail-closed error ends a save the same way: its message in the banner, no conflict
    /// action, the sheet open and the user's input untouched. The success path clears the draft, so
    /// a catch that did the same would destroy the edit.
    func testFailClosedSaveErrors_showTheMessageWithoutActionsAndKeepTheDraft() async {
        let errors: [VaultError] = [
            .organizationKeyUnavailable, .itemRecordUnavailable, .itemKeyUnavailable,
            .itemNotEditable(.unsupportedFormat), .itemRevisionUnavailable, .itemKeyGenerationFailed,
        ]
        for error in errors {
            let rig = makeRig(results: [.failure(error)])

            rig.sut.save()
            let finished = await eventually { rig.sut.saveError != nil && !rig.sut.isSaving }

            XCTAssertTrue(finished, "\(error)")
            XCTAssertEqual(rig.sut.bannerMessage, error.errorDescription, "\(error)")
            XCTAssertNil(rig.sut.conflictActionTitle, "\(error)")
            XCTAssertNil(rig.sut.conflictStatusText, "\(error)")
            XCTAssertNil(rig.sut.saveBlockedHint, "\(error)")
            XCTAssertFalse(rig.sut.isDismissed, "the sheet stays open: \(error)")
            XCTAssertEqual(rig.sut.draft.name, "Edited name", "the user's input stays: \(error)")
            XCTAssertTrue(rig.sut.canSave, "Save stays available for a retry: \(error)")
        }
    }
}
