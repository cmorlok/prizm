import AppKit
import Combine
import Synchronization
import XCTest
@testable import Prizm

/// Unit tests for `RootViewModel.lockVault()`.
@MainActor
final class RootViewModelLockTests: XCTestCase {

    private var mockAuth: MockAuthRepository!
    private var mockVault: MockVaultRepository!
    private var deps: MockRootDependencies!
    private var sut: RootViewModel!

    private let stubAccount = Account(
        userId: "user-001",
        email: "alice@example.com",
        name: nil,
        serverEnvironment: ServerEnvironment(
            base: URL(string: "https://vault.example.com")!,
            overrides: nil
        )
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAuth = MockAuthRepository()
        mockVault = MockVaultRepository()
        deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        sut = RootViewModel(container: deps)
    }

    /// Yields to the main actor run loop until `condition` returns true or timeout.
    /// Replaces fixed `Task.sleep` which is flaky under parallel test execution
    /// when multiple actor hops are involved (e.g. lockVault → authRepo → vaultKeyCache → orgKeyCache).
    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 1.1 lockVault() transitions screen to .unlock

    func testLockVault_transitionsToUnlock() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        sut.screen = .vault

        sut.lockVault()
        try await waitUntil { if case .unlock = self.sut.screen { return true }; return false }

        guard case .unlock = sut.screen else {
            return XCTFail("Expected .unlock, got \(sut.screen)")
        }
    }

    // MARK: - 1.2 lockVault() is a no-op when screen != .vault

    func testLockVault_noOpWhenLogin() async throws {
        sut.screen = .login
        sut.lockVault()
        // Fixed sleep (not polling) because this is a no-op test — there is no positive
        // state change to poll for. 50ms is enough for the guard-return fast path.
        try await Task.sleep(for: .milliseconds(50))

        guard case .login = sut.screen else {
            return XCTFail("Expected .login, got \(sut.screen)")
        }
    }

    func testLockVault_noOpWhenUnlock() async throws {
        sut.screen = .unlock
        sut.lockVault()
        // Fixed sleep (not polling) because this is a no-op test — there is no positive
        // state change to poll for. 50ms is enough for the guard-return fast path.
        try await Task.sleep(for: .milliseconds(50))

        guard case .unlock = sut.screen else {
            return XCTFail("Expected .unlock, got \(sut.screen)")
        }
    }

    // MARK: - 1.3 lockVault() calls authRepository.lockVault() and vaultStore.clearVault()

    func testLockVault_callsLockAndClear() async throws {
        sut.screen = .vault

        sut.lockVault()
        try await waitUntil { self.mockAuth.lockVaultCalledCount >= 1 }

        XCTAssertEqual(mockAuth.lockVaultCalledCount, 1)
        XCTAssertTrue(mockVault.clearVaultCalled)
    }

    // MARK: - 1.4 lockVault() creates a new unlockVM from the stored account

    func testLockVault_createsUnlockVM() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        sut.screen = .vault
        sut.unlockVM = nil

        sut.lockVault()
        try await waitUntil { self.sut.unlockVM != nil }

        XCTAssertNotNil(sut.unlockVM)
    }

    // MARK: - 1.5 lockVault() falls back to .login when storedAccount() returns nil

    func testLockVault_fallsBackToLogin_whenNoStoredAccount() async throws {
        mockAuth.stubbedStoredAccount = nil
        sut.screen = .vault

        sut.lockVault()
        try await waitUntil { if case .login = self.sut.screen { return true }; return false }

        guard case .login = sut.screen else {
            return XCTFail("Expected .login, got \(sut.screen)")
        }
    }

    // MARK: - Locking and signing out drop the vault browser's decrypted state (fix-ui-journey-findings)

    private let secretItem = VaultItem(
        id: "secret-1", name: "Secret", isFavorite: false, isDeleted: false,
        creationDate: .now, revisionDate: .now,
        content: .login(LoginContent(username: "alice", password: "hunter2", uris: [], totp: nil,
                                     notes: nil, customFields: []))
    )

    /// Puts decrypted data into the vault browser the way a user session does: listed items,
    /// folders, a selected item and a search term.
    private func openVaultBrowser() async throws -> VaultBrowserViewModel {
        await mockVault.populate(items: [secretItem], folders: [Folder(id: "f1", name: "Private")],
                                 organizations: [], collections: [], syncedAt: .now)
        let browser = sut.vaultBrowserVM
        browser.refreshItems()
        browser.refreshFolders()
        try await waitUntil { !browser.displayedItems.isEmpty && !browser.folders.isEmpty }
        browser.itemSelection = secretItem
        try await waitUntil { self.sut.menuBarCanEdit && self.sut.selectedLogin != nil }
        XCTAssertFalse(browser.displayedItems.isEmpty, "Precondition: items are listed")
        XCTAssertTrue(sut.menuBarCanEdit, "Precondition: Edit is enabled for the selected item")
        return browser
    }

    private func assertVaultBrowserCleared(_ browser: VaultBrowserViewModel,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(browser.itemSelection, "The selected item must not survive", file: file, line: line)
        XCTAssertTrue(browser.displayedItems.isEmpty, "Listed items must not survive", file: file, line: line)
        XCTAssertTrue(browser.folders.isEmpty, "Folder names must not survive", file: file, line: line)
        XCTAssertEqual(browser.searchQuery, "", "The search term must not survive", file: file, line: line)
        XCTAssertTrue(browser.itemCounts.isEmpty, "Item counts must not survive", file: file, line: line)
        XCTAssertFalse(browser.isGlobalSearch, "Global search must end", file: file, line: line)
        XCTAssertFalse(sut.menuBarCanEdit, "Item → Edit must be disabled", file: file, line: line)
        XCTAssertNil(sut.selectedLogin, "Copy commands must have no login to copy from", file: file, line: line)
    }

    // MARK: - Item > Edit is disabled for an item that cannot be edited

    func testItemMenuEdit_isDisabledForAnItemThatCannotBeEdited() async throws {
        let browser = try await openVaultBrowser()
        let blocked = VaultItem(
            id: "blocked-1", name: "Blocked", isFavorite: false, isDeleted: false,
            creationDate: .now, revisionDate: .now,
            content: .login(LoginContent(username: "bob", password: "pw", uris: [], totp: nil,
                                         notes: nil, customFields: [])),
            editBlock: .unsupportedFormat
        )

        browser.itemSelection = blocked
        try await waitUntil { !self.sut.menuBarCanEdit }
        XCTAssertFalse(sut.menuBarCanEdit, "Item > Edit (and its shortcut) must be disabled for a blocked item")

        browser.itemSelection = secretItem
        try await waitUntil { self.sut.menuBarCanEdit }
        XCTAssertTrue(sut.menuBarCanEdit, "A normal item can be edited again")
    }

    func testLockVault_clearsVaultBrowserState() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        let browser = try await openVaultBrowser()
        // After the awaits: the login flow's initial state arrives on the main queue and resets it.
        sut.screen = .vault
        browser.searchQuery = "Sec"

        sut.lockVault()
        try await waitUntil { if case .unlock = self.sut.screen { return true }; return false }
        try await waitUntil { !self.sut.menuBarCanEdit && self.sut.selectedLogin == nil }

        assertVaultBrowserCleared(browser)
    }

    func testSignOut_clearsVaultBrowserState() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        let browser = try await openVaultBrowser()
        // After the awaits: the login flow's initial state arrives on the main queue and resets it.
        sut.screen = .vault
        browser.sidebarSelection = .folder("f1")

        sut.signOut()
        try await waitUntil { if case .login = self.sut.screen { return true }; return false }
        try await waitUntil { !self.sut.menuBarCanEdit && self.sut.selectedLogin == nil }

        assertVaultBrowserCleared(browser)
        XCTAssertEqual(browser.sidebarSelection, .allItems,
                       "The next account must not start in the previous account's folder")
    }

    /// Sign-out must reach `VaultRepository.clearVault()`, the hook that drops the profile id for
    /// `encryptedFor` (and everything else the session held).
    func testSignOut_clearsTheVaultRepository() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        sut.screen = .vault

        sut.signOut()
        try await waitUntil { if case .login = self.sut.screen { return true }; return false }

        XCTAssertTrue(mockVault.clearVaultCalled)
    }

    func testLockVault_clearsACopiedSecret() async throws {
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        let root = RootViewModel(container: deps)
        root.vaultBrowserVM.copy("hunter2")
        XCTAssertEqual(deps.fakePasteboard.string, "hunter2")
        mockAuth.stubbedStoredAccount = stubAccount
        root.screen = .vault

        root.lockVault()
        try await waitUntil { if case .unlock = root.screen { return true }; return false }

        XCTAssertNil(deps.fakePasteboard.string, "A copied secret must not outlive the session")
    }

    func testSignOut_clearsACopiedSecret() async throws {
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        let root = RootViewModel(container: deps)
        root.vaultBrowserVM.copy("hunter2")
        XCTAssertEqual(deps.fakePasteboard.string, "hunter2")
        root.screen = .vault

        root.signOut()
        try await waitUntil { if case .login = root.screen { return true }; return false }

        XCTAssertNil(deps.fakePasteboard.string, "A copied secret must not outlive the session")
    }

    /// Quitting clears a secret Prizm copied, and leaves what another app copied since
    /// (clipboard-hardening, scenario "Quit with a foreign clipboard value").
    func testQuit_clearsOnlyAnOwnedSecret() {
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        let root = RootViewModel(container: deps)
        root.vaultBrowserVM.copy("hunter2")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertNil(deps.fakePasteboard.string, "Prizm's copy is cleared on quit")

        root.vaultBrowserVM.copy("hunter2")
        deps.fakePasteboard.foreignCopy("not ours")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(deps.fakePasteboard.string, "not ours", "Another app's value stays")
    }

    // MARK: - Opened attachment files (fix-attachment-transfer-flow, D7)

    func testLockVault_sweepsOpenedAttachmentFiles() async throws {
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        let root = RootViewModel(container: deps)
        mockAuth.stubbedStoredAccount = stubAccount
        root.screen = .vault

        root.lockVault()
        try await waitUntil { if case .unlock = root.screen { return true }; return false }

        XCTAssertEqual(deps.tempFiles.sweepCount, 1)
    }

    func testSignOut_sweepsOpenedAttachmentFiles() async throws {
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        let root = RootViewModel(container: deps)
        root.screen = .vault

        root.signOut()
        try await waitUntil { if case .login = root.screen { return true }; return false }

        XCTAssertEqual(deps.tempFiles.sweepCount, 1)
    }

    // MARK: - Website icons (fix-website-icons-privacy, D1)

    /// Polls the loader's icons base: it is set from a Task, after the screen change.
    private func waitForIconsBase(_ deps: MockRootDependencies, toBe expected: URL?) async throws {
        let deadline = ContinuousClock.now + .milliseconds(500)
        while deps.faviconLoader.iconsBase != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Code review 2026-10-30: configured before the vault is shown, so no row asks an
    /// unconfigured loader (and keeps its type icon for the session).
    func testVaultTransition_configuresTheAccountsIconService_beforeTheVaultShows() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        var baseWhenShown: URL?? = .none
        let observer = sut.$screen.sink { [deps] screen in
            if case .vault = screen { baseWhenShown = .some(deps!.faviconLoader.iconsBase) }
        }
        defer { observer.cancel() }
        sut.handleLoginFlow(.vault)
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }

        XCTAssertEqual(baseWhenShown, .some(URL(string: "https://vault.example.com/icons")!))
    }

    /// Code review 2026-10-30: unconfigured when the lock starts, not after its teardown.
    func testLockVault_unconfiguresTheIconService_rightAway() {
        mockAuth.stubbedStoredAccount = stubAccount
        deps.faviconLoader.configure(iconsBase: URL(string: "https://vault.example.com/icons")!)
        sut.screen = .vault

        sut.lockVault()

        XCTAssertNil(deps.faviconLoader.iconsBase)
    }

    func testLockVault_unconfiguresTheIconService() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        deps.faviconLoader.configure(iconsBase: URL(string: "https://vault.example.com/icons")!)
        sut.screen = .vault

        sut.lockVault()
        try await waitUntil { if case .unlock = self.sut.screen { return true }; return false }

        let base = deps.faviconLoader.iconsBase
        XCTAssertNil(base)
        let generation = await deps.faviconLoader.generation
        XCTAssertEqual(generation, 1, "reset() ran")
    }

    func testSignOut_unconfiguresTheIconService() async throws {
        deps.faviconLoader.configure(iconsBase: URL(string: "https://vault.example.com/icons")!)
        sut.screen = .vault

        sut.signOut()
        try await waitUntil { if case .login = self.sut.screen { return true }; return false }

        let base = deps.faviconLoader.iconsBase
        XCTAssertNil(base)
        let generation = await deps.faviconLoader.generation
        XCTAssertEqual(generation, 1, "reset() ran")
    }

    func testQuit_sweepsOpenedAttachmentFiles() {
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        let root = RootViewModel(container: deps)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(deps.tempFiles.sweepCount, 1)
        _ = root
    }

    /// Task 6.3: an attachment opened through its row is gone from the folder after a lock.
    func testOpenAttachmentThenLock_leavesTheFolderEmpty() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-locktest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tempFiles = AttachmentTempFileManager(folder: folder)
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
        deps.attachmentTempFiles = tempFiles
        mockAuth.stubbedStoredAccount = stubAccount
        let root = RootViewModel(container: deps)
        let opened = OpenedURL()
        let row = AttachmentRowViewModel(
            cipherId: "c1",
            attachment: Attachment(id: "att-1", fileName: "secret.txt", encryptedKey: "2.k|k|k",
                                   size: 6, sizeName: "6 B", url: nil),
            downloadUseCase: FixedDownload(), deleteUseCase: UnusedDelete(), convertUseCase: RecordingConvertUseCase(),
            tempFileManager: tempFiles, fileSaver: { _ in nil }, fileOpener: { opened.url = $0 })

        row.open()
        try await waitUntil { opened.url != nil }
        let openedFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(openedFiles.count, 1, "The opened file is in the folder")

        // Set after the wait: the launch check may have moved the screen meanwhile.
        root.screen = .vault
        root.lockVault()
        try await waitUntil { if case .unlock = root.screen { return true }; return false }

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(left.isEmpty, "No decrypted file outlives the session")
    }

    func testCopyCommands_unavailableWhileLocked() async throws {
        sut.screen = .unlock
        // Even if a decrypted item were still selected, nothing may be copied while locked.
        sut.vaultBrowserVM.itemSelection = secretItem
        try await waitUntil { self.sut.selectedLogin != nil }

        XCTAssertFalse(sut.selectedFieldAvailable(.password))
        XCTAssertFalse(sut.selectedFieldAvailable(.username))
    }

    // MARK: - lockVault() works from .syncing state

    func testLockVault_worksFromSyncing() async throws {
        mockAuth.stubbedStoredAccount = stubAccount
        sut.screen = .syncing(message: "Syncing…")

        sut.lockVault()
        try await waitUntil { if case .unlock = self.sut.screen { return true }; return false }

        guard case .unlock = sut.screen else {
            return XCTFail("Expected .unlock, got \(sut.screen)")
        }
    }
}

// MARK: - Lock during the sync after unlocking or signing in (lock-during-unlock-sync)

@MainActor
final class RootViewModelLockDuringSyncTests: XCTestCase {

    private var mockAuth: MockAuthRepository!
    private var deps: MockRootDependencies!
    private var sut: RootViewModel!

    private let account = Account(
        userId: "user-001", email: "alice@example.com", name: nil,
        serverEnvironment: ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil)
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAuth = MockAuthRepository()
        mockAuth.stubbedStoredAccount = account
        mockAuth.stubbedLoginResult = .success(account)
        deps = MockRootDependencies(auth: mockAuth, vault: MockVaultRepository())
        sut = RootViewModel(container: deps)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private var isUnlockScreen: Bool { if case .unlock = sut.screen { true } else { false } }
    private var isSyncingScreen: Bool { if case .syncing = sut.screen { true } else { false } }

    /// Holds a mock until opened; thread-safe, and opened at the end of each test so a failing
    /// test never leaves a task spinning.
    private let gate = Mutex(false)
    private func waitForGate() async {
        while !gate.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    override func tearDown() async throws {
        gate.withLock { $0 = true }
        try await super.tearDown()
    }

    /// 1.1: the old unlock view model's late "Syncing…" and `.vault` must not undo the lock.
    func testLockDuringUnlockSync_staysLockedWhenTheSyncEnds() async throws {
        deps.mockSyncUseCase.onExecute = { [self] in await waitForGate() }
        deps.mockSyncUseCase.progressMessage = "Decrypting…"
        let firstUnlock = deps.makeUnlockViewModel(account: account)
        sut.unlockVM = firstUnlock
        firstUnlock.password = "pw"
        firstUnlock.unlock()
        try await waitUntil { self.isSyncingScreen }
        XCTAssertTrue(isSyncingScreen, "The unlock sync runs")

        sut.lockVault()
        try await waitUntil { self.isUnlockScreen && self.sut.unlockVM !== firstUnlock }
        gate.withLock { $0 = true }
        try await waitUntil { firstUnlock.flowState == .vault }
        try await Task.sleep(for: .milliseconds(100))  // let any late state reach the screen

        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
    }

    /// D2: a `.vault` whose check started before a lock ends locked. Its key check was read before
    /// the lock, so it may tear down once more; that is idempotent.
    func testVaultCheckOverlappingALock_endsLocked() async throws {
        mockAuth.whileReadingIsVaultUnlocked = { [self] in await waitForGate() }
        sut.screen = .syncing(message: "Syncing…")

        sut.handleUnlockFlow(.vault)        // reads "unlocked" and waits
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen }
        let locksBefore = mockAuth.lockVaultCalledCount
        gate.withLock { $0 = true }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
        XCTAssertGreaterThanOrEqual(mockAuth.lockVaultCalledCount, locksBefore)
    }

    /// W1 (third verification): a stale sign-in that ends after a lock and a new unlock must not
    /// lock the new session again.
    func testStaleSignInEndingAfterANewUnlock_leavesTheNewSessionAlone() async throws {
        sut.screen = .loading
        sut.handleLoginFlow(.loading)             // a sign-in is running
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen && self.mockAuth.lockVaultCalledCount == 1 }
        let unlock = try XCTUnwrap(sut.unlockVM)
        try await Task.sleep(for: .milliseconds(20))
        unlock.password = "pw"
        unlock.unlock()
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }

        sut.handleLoginFlow(.vault)               // the old sign-in's sync ends now
        try await Task.sleep(for: .milliseconds(100))

        guard case .vault = sut.screen else { return XCTFail("Expected the vault, got \(sut.screen)") }
        XCTAssertEqual(mockAuth.lockVaultCalledCount, 1, "The new session is not locked again")
    }

    /// Final review 1a: a sign-in whose start reached the auth layer only after the lock (a lock
    /// during its server setup) loads keys; its stale `.vault` tears them down.
    func testStaleSignInWithKeysLoadedAfterTheLock_tearsThemDown() async throws {
        sut.screen = .loading
        sut.handleLoginFlow(.loading)
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen && self.mockAuth.lockVaultCalledCount == 1 }
        mockAuth.stubbedIsVaultUnlocked = true   // the sign-in loaded its keys after the lock

        sut.handleLoginFlow(.vault)
        try await waitUntil { self.mockAuth.lockVaultCalledCount == 2 }

        XCTAssertEqual(mockAuth.lockVaultCalledCount, 2, "Keys torn down")
        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
    }

    /// Last review 1c: a stale sign-in that ends without keys while a newer unlock is deriving
    /// keys leaves that unlock alone; it is not replaced (which would hide its keys and data
    /// behind a fresh lock screen) and reaches the vault.
    func testStaleSignInEndingDuringANewUnlock_leavesItRunning() async throws {
        sut.screen = .loading
        sut.handleLoginFlow(.loading)
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen && self.mockAuth.lockVaultCalledCount == 1 }
        let unlock = try XCTUnwrap(sut.unlockVM)
        try await Task.sleep(for: .milliseconds(20))
        mockAuth.whileUnlockingWithPassword = { [self] in await waitForGate() }
        unlock.password = "pw"
        unlock.unlock()
        try await waitUntil { unlock.flowState == .loading }

        sut.handleLoginFlow(.vault)               // the old sign-in ends, no keys loaded
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sut.unlockVM === unlock, "The running unlock is not replaced")

        gate.withLock { $0 = true }
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }
        guard case .vault = sut.screen else { return XCTFail("Expected the vault, got \(sut.screen)") }
    }

    /// D5/D6: a lock while the unlock screen derives keys applies to that unlock. The unlock ends
    /// without keys and says why; it never shows "Syncing…" or the vault.
    func testLockDuringUnlockKeyDerivation_staysLocked() async throws {
        mockAuth.whileUnlockingWithPassword = { [self] in await waitForGate() }
        mockAuth.stubbedIsVaultUnlocked = false
        var screens: [String] = []
        let watch = sut.$screen.sink { screens.append(String(describing: $0)) }
        defer { watch.cancel() }
        let unlock = deps.makeUnlockViewModel(account: account)
        sut.unlockVM = unlock
        unlock.password = "pw"

        unlock.unlock()
        try await waitUntil { unlock.flowState == .loading }
        XCTAssertTrue(sut.canLock, "A lock applies while the unlock derives keys")
        sut.lockVault()
        try await waitUntil { self.mockAuth.lockVaultCalledCount == 1 && self.isUnlockScreen }
        XCTAssertTrue(sut.unlockVM === unlock, "The running unlock is kept, so its end is checked")
        screens.removeAll()

        gate.withLock { $0 = true }               // the key derivation ends after the lock
        try await waitUntil { unlock.flowState == .unlock }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
        XCTAssertFalse(screens.contains { $0.hasPrefix("syncing") || $0 == "vault" }, "Shown after the lock: \(screens)")
        XCTAssertEqual(unlock.errorMessage, AuthError.lockedWhileUnlocking.errorDescription)
        XCTAssertEqual(mockAuth.lockVaultCalledCount, 1)
    }

    /// The mark of a flow from before a lock does not make a new unlock after it stale.
    func testUnlockAfterALock_reachesTheVault() async throws {
        sut.screen = .vault
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen && self.mockAuth.lockVaultCalledCount == 1 }
        let unlock = try XCTUnwrap(sut.unlockVM)
        try await Task.sleep(for: .milliseconds(20))   // its initial state reaches the root first

        unlock.password = "pw"
        unlock.unlock()
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }

        guard case .vault = sut.screen else { return XCTFail("Expected the vault, got \(sut.screen)") }
    }

    /// D5: a two-factor prompt from a sign-in that started before a lock is cancelled, not shown.
    func testTwoFactorAfterALockDuringSignIn_isCancelled() async throws {
        sut.screen = .loading
        sut.handleLoginFlow(.loading)
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen }

        sut.handleLoginFlow(.totpPrompt)

        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
        XCTAssertEqual(sut.loginVM.flowState, .login, "The pending two-factor step is cancelled")
    }

    /// The first sync after signing in shows `.loading`; a lock there must apply.
    func testLockWhileSigningIn_isNotIgnored() async throws {
        sut.screen = .loading

        XCTAssertTrue(sut.canLock)
        sut.lockVault()
        try await waitUntil { self.isUnlockScreen }

        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
    }

    /// 1.2: the login flow's `.vault` after a lock leads to the lock screen.
    func testLoginFlowVault_afterALock_showsTheLockScreen() async throws {
        mockAuth.stubbedIsVaultUnlocked = false

        sut.handleLoginFlow(.vault)
        try await waitUntil { self.isUnlockScreen }

        XCTAssertTrue(isUnlockScreen, "Expected the lock screen, got \(sut.screen)")
        XCTAssertNotNil(sut.unlockVM)
    }

    /// 1.3: a lock without a stored account removes the unlock view model.
    func testLockWithoutStoredAccount_removesTheUnlockViewModel() async throws {
        sut.unlockVM = deps.makeUnlockViewModel(account: account)
        mockAuth.stubbedStoredAccount = nil
        sut.screen = .vault

        sut.lockVault()
        try await waitUntil { if case .login = self.sut.screen { true } else { false } }

        XCTAssertNil(sut.unlockVM)
    }

    /// 1.4: the normal flows still reach the vault.
    func testUnlockAndLoginFlows_stillReachTheVault() async throws {
        sut.handleUnlockFlow(.vault)
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }
        guard case .vault = sut.screen else { return XCTFail("Expected the vault, got \(sut.screen)") }

        sut.screen = .login
        sut.handleLoginFlow(.vault)
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }
        guard case .vault = sut.screen else { return XCTFail("Expected the vault, got \(sut.screen)") }
    }
}

// MARK: - Mock Dependencies

@MainActor
final class MockRootDependencies: RootViewModelDependencies {
    /// Replaceable so copy-code tests can inject a deterministic generator.
    var generateTOTPCode: any GenerateTOTPCodeUseCase = UnusedGenerateTOTPCode()
    /// One pasteboard and one clipboard service, shared with the vault browser, as in the app.
    let fakePasteboard = FakePasteboard()
    lazy var clipboardService = ClipboardServiceImpl(pasteboard: fakePasteboard)
    var clipboard: any ClipboardService { clipboardService }
    let tempFiles = SweepCountingTempFiles()
    /// Replaceable so an integration test can use the real temp-file manager.
    lazy var attachmentTempFiles: any TempFileManaging = tempFiles
    /// A real loader; its own settings suite, and a stub that answers any request with 404.
    let faviconLoader = FaviconLoader(defaultsSuiteName: "MockRootDependencies-\(UUID().uuidString)",
                                      protocolClasses: [IconStub.self])
    let authRepo: any AuthRepository
    let vaultRepo: any VaultRepository

    private let mockLoginUseCase = MockLoginUseCase()
    /// Shared by every unlock view model it makes; tests can hold its sync with `onExecute`.
    let mockSyncUseCase = MockSyncUseCase()
    private let mockVault: MockVaultRepository

    init(auth: MockAuthRepository, vault: MockVaultRepository) {
        self.authRepo = auth
        self.vaultRepo = vault
        self.mockVault = vault
    }

    func makeLoginViewModel() -> LoginViewModel {
        LoginViewModel(loginUseCase: mockLoginUseCase)
    }

    func makeUnlockViewModel(account: Account) -> UnlockViewModel {
        UnlockViewModel(auth: authRepo as! MockAuthRepository, sync: mockSyncUseCase, account: account)
    }

    func makeVaultBrowserViewModel() -> VaultBrowserViewModel {
        let syncRepo = MockSyncTimestampRepository(storedDate: nil)
        return VaultBrowserViewModel(
            vault:           mockVault,
            search:          SearchVaultUseCaseImpl(vault: mockVault),
            delete:          StubDeleteUseCase(),
            permanentDelete: StubPermanentDeleteUseCase(),
            restore:         StubRestoreUseCase(),
            createFolder:     StubCreateFolder(),
            renameFolder:     StubRenameFolder(),
            deleteFolder:     StubDeleteFolder(),
            moveItem:         StubMoveItem(),
            setFavorite:      SetFavoriteUseCaseImpl(repository: mockVault),
            emptyTrash:       EmptyTrashUseCaseImpl(repository: mockVault, sync: MockSyncUseCase()),
            clipboard:        clipboardService,
            createCollection: StubCreateCollection(),
            renameCollection: StubRenameCollection(),
            deleteCollection: StubDeleteCollection(),
            syncTimestamp:    syncRepo,
            getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo),
            sync:             MockSyncUseCase()
        )
    }

    func makeSyncTimestampDependencies(for email: String) -> (repository: any SyncTimestampRepository, useCase: any GetLastSyncDateUseCase) {
        let repo = MockSyncTimestampRepository(storedDate: nil)
        return (repo, GetLastSyncDateUseCaseImpl(repository: repo))
    }

    #if DEBUG
    /// The items the UI-test seam asked to store records for.
    private(set) var seededUITestItems: [[VaultItem]] = []

    func seedUITestRecords(for items: [VaultItem]) async {
        seededUITestItems.append(items)
    }
    #endif
}

// Minimal stubs for VaultBrowserViewModel dependencies.
@MainActor private final class StubDeleteUseCase: DeleteVaultItemUseCase {
    func execute(id: String) async throws {}
}
@MainActor private final class StubPermanentDeleteUseCase: PermanentDeleteVaultItemUseCase {
    func execute(id: String) async throws {}
}
@MainActor private final class StubRestoreUseCase: RestoreVaultItemUseCase {
    func execute(id: String) async throws {}
}
@MainActor private struct StubCreateFolder: CreateFolderUseCase {
    func execute(name: String) async throws -> Folder { Folder(id: "stub", name: name) }
}
@MainActor private struct StubRenameFolder: RenameFolderUseCase {
    func execute(id: String, name: String) async throws -> Folder { Folder(id: id, name: name) }
}
@MainActor private struct StubDeleteFolder: DeleteFolderUseCase {
    func execute(id: String) async throws {}
}
@MainActor private struct StubMoveItem: MoveItemToFolderUseCase {
    func execute(itemId: String, folderId: String?) async throws {}
    func execute(itemIds: [String], folderId: String?) async throws {}
}
@MainActor private struct StubCreateCollection: CreateCollectionUseCase {
    func execute(name: String, organizationId: String) async throws -> OrgCollection {
        OrgCollection(id: "stub", organizationId: organizationId, name: name)
    }
}
@MainActor private struct StubRenameCollection: RenameCollectionUseCase {
    func execute(collectionId: String, name: String, organizationId: String) async throws -> OrgCollection {
        OrgCollection(id: collectionId, organizationId: organizationId, name: name)
    }
}
@MainActor private struct StubDeleteCollection: DeleteCollectionUseCase {
    func execute(collectionId: String, organizationId: String) async throws {}
}

/// Default generator for tests that never generate a code.
private struct UnusedGenerateTOTPCode: GenerateTOTPCodeUseCase {
    func execute(seed: String, at date: Date) async throws -> TOTPCode {
        throw TOTPError.invalidSecret
    }
}

/// Counts `sweepAll()` calls; writes nothing.
final class SweepCountingTempFiles: TempFileManaging, @unchecked Sendable {
    private(set) var sweepCount = 0
    var sweepGeneration: Int { sweepCount }
    func write(_ data: Data, fileExtension: String, generation: Int) throws -> URL { throw CocoaError(.featureUnsupported) }
    func sweepAll() { sweepCount += 1 }
    func register(url: URL) {}
    func cleanup() {}
}

private final class FixedDownload: DownloadAttachmentUseCase {
    func execute(cipherId: String, attachment: Attachment) async throws -> Data { Data("secret".utf8) }
}

private final class UnusedDelete: DeleteAttachmentUseCase {
    func execute(cipherId: String, attachmentId: String) async throws {}
}

@MainActor
private final class OpenedURL {
    var url: URL?
}
