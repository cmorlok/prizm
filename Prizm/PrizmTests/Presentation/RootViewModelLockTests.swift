import XCTest
@testable import Prizm

/// Unit tests for `RootViewModel.lockVault()`.
@MainActor
final class RootViewModelLockTests: XCTestCase {

    private var mockAuth: MockAuthRepository!
    private var mockVault: MockVaultRepository!
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
        let deps = MockRootDependencies(auth: mockAuth, vault: mockVault)
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

// MARK: - Mock Dependencies

@MainActor
final class MockRootDependencies: RootViewModelDependencies {
    /// Replaceable so copy-code tests can inject a deterministic generator.
    var generateTOTPCode: any GenerateTOTPCodeUseCase = UnusedGenerateTOTPCode()
    let authRepo: any AuthRepository
    let vaultRepo: any VaultRepository
    let vaultKeyCache = VaultKeyCache()
    let orgKeyCache   = OrgKeyCache()

    private let mockLoginUseCase = MockLoginUseCase()
    private let mockSyncUseCase = MockSyncUseCase()
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
            createCollection: StubCreateCollection(),
            renameCollection: StubRenameCollection(),
            deleteCollection: StubDeleteCollection(),
            syncTimestamp:    syncRepo,
            getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo)
        )
    }

    func makeSyncTimestampDependencies(for email: String) -> (repository: any SyncTimestampRepository, useCase: any GetLastSyncDateUseCase) {
        let repo = MockSyncTimestampRepository(storedDate: nil)
        return (repo, GetLastSyncDateUseCaseImpl(repository: repo))
    }
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
