//
//  PrizmApp.swift
//  Prizm
//
//  Created by Benjamin on 15.03.26.
//

import AppKit
import Combine
import SwiftUI
import os.log

@main
struct PrizmApp: App {

    @StateObject private var container: AppContainer
    @StateObject private var rootVM:    RootViewModel
    @State       private var optionKeyMonitor = OptionKeyMonitor()

    // Used by the About menu item to open the custom About window scene.
    @Environment(\.openWindow) private var openWindow

    init() {
        let c = AppContainer()
        _container = StateObject(wrappedValue: c)
        _rootVM    = StateObject(wrappedValue: RootViewModel(container: c))
        NSApplication.shared.activate()
    }

    /// Identifier of the main window scene, so "New Window" can open it.
    enum MainWindow {
        static let id = "main"
    }

    var body: some Scene {
        WindowGroup(id: MainWindow.id) {
            rootView
                .frame(minWidth: 480, minHeight: 360)
                .environment(optionKeyMonitor)
                .environment(container.clipboardService)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Replace the default "About Prizm" panel with our custom SwiftUI window.
            CommandGroup(replacing: .appInfo) {
                Button("About Prizm") {
                    openWindow(id: "about")
                }
            }

            CommandGroup(replacing: .newItem) {
                // Opens the main window scene. Prizm is not document-based, so the previous
                // `NSDocumentController.newDocument(_:)` only showed "No document could be opened"
                // (fix-ui-journey-findings, bug 6).
                Button("New Window") {
                    openWindow(id: MainWindow.id)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }

            CommandGroup(after: .appInfo) {
                // No keyboard shortcut, as in the official Bitwarden desktop client: signing out is
                // rare and clears all local data. ⌘⇧Q, used before, is the system's Log Out
                // shortcut; a UI test that sent it logged the user out of macOS
                // (fix-ui-journey-findings).
                Button("Sign Out…") {
                    rootVM.confirmSignOut()
                }
                .disabled(!rootVM.isSignedIn)

                Button("Lock Vault") {
                    rootVM.lockVault()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!rootVM.canLock)
            }

            // "Item" menu — sits in the standard macOS menu bar next to Edit/View/Window.
            // Edit opens the edit sheet for the selected vault item (⌘E).
            // Save persists in-flight edits (⌘S).
            // Buttons are disabled by `rootVM` Combine subscriptions that track
            // item selection and edit-sheet state.
            CommandMenu("Item") {
                Button("Edit") {
                    rootVM.vaultBrowserVM.triggerEdit()
                }
                .disabled(!rootVM.menuBarCanEdit)
                .keyboardShortcut("e", modifiers: .command)

                Button("Save") {
                    rootVM.vaultBrowserVM.triggerSave()
                }
                .disabled(!rootVM.menuBarCanSave)
                .keyboardShortcut("s", modifiers: .command)

                Divider()

                Button("Copy Username") {
                    rootVM.copySelectedField(.username)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!rootVM.selectedFieldAvailable(.username))

                Button("Copy Password") {
                    rootVM.copySelectedField(.password)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!rootVM.selectedFieldAvailable(.password))

                Button("Copy Code") {
                    rootVM.copySelectedField(.totp)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(!rootVM.selectedFieldAvailable(.totp))

                Button("Copy Website") {
                    rootVM.copySelectedField(.website)
                }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(!rootVM.selectedFieldAvailable(.website))
            }
        }

        // Custom About window — opened via Prizm → About Prizm.
        // hiddenTitleBar: AboutView provides its own header with the app icon and name,
        // so the system title bar would be redundant.
        // contentSize resizability: window sizes to AboutView's fixed 380pt width; no
        // free resize since the content is a fixed-layout info panel.
        Window("About Prizm", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Settings window — opened via ⌘, (macOS convention) or the gear toolbar button.
        // The Settings scene does not inherit the WindowGroup environment, so we pass
        // the container explicitly via .environmentObject().
        Settings {
            SettingsView(authRepository: container.authRepository, preferences: container.preferences,
                         sessionGate: container.sessionGate)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch rootVM.screen {
        case .login:
            LoginView(viewModel: rootVM.loginVM)

        case .loading:
            ProgressView("Signing in…")
                .frame(minWidth: 480, minHeight: 360)

        case .totpPrompt:
            TOTPPromptView(viewModel: rootVM.loginVM)

        case .unlock:
            if let unlockVM = rootVM.unlockVM {
                UnlockView(viewModel: unlockVM)
            }

        case .syncing(let message):
            SyncProgressView(message: message)

        case .vault:
            VaultBrowserView(
                viewModel:         rootVM.vaultBrowserVM,
                faviconLoader:     container.faviconLoader,
                makeEditViewModel: { [vaultBrowserVM = rootVM.vaultBrowserVM] item in
                    let vm = container.makeItemEditViewModel(
                        for: item,
                        folders: vaultBrowserVM.folders,
                        organizations: vaultBrowserVM.organizations,
                        collections: vaultBrowserVM.collections
                    )
                    // Wire the list-pane refresh callback to the shared VaultBrowserViewModel.
                    // Ignores a save that completes after the vault locked.
                    vm.onSaveSuccess = vaultBrowserVM.saveHandler()
                    vm.onItemRemoved = vaultBrowserVM.removalHandler()
                    // The resync and the lookup run in the vault browser; the sheet gets no use case.
                    vm.onConflict = { await vaultBrowserVM.resyncAfterConflict() }
                    vm.latestItem = { await vaultBrowserVM.latestItem(id: $0) }
                    return vm
                },
                makeCreateViewModel: { [vaultBrowserVM = rootVM.vaultBrowserVM] type, contextId in
                    // contextId is either a folderId (personal item) or collectionId (org item),
                    // determined by whether the current sidebar selection is a collection.
                    let cols = vaultBrowserVM.collections
                    let isCollection = contextId != nil && cols.contains(where: { $0.id == contextId })
                    let vm: ItemEditViewModel
                    if isCollection {
                        vm = container.makeItemCreateViewModel(
                            for: type, collectionId: contextId,
                            folders: vaultBrowserVM.folders, organizations: vaultBrowserVM.organizations, collections: cols
                        )
                    } else {
                        vm = container.makeItemCreateViewModel(
                            for: type, folderId: contextId,
                            folders: vaultBrowserVM.folders, organizations: vaultBrowserVM.organizations, collections: cols
                        )
                    }
                    // Ignores a save that completes after the vault locked.
                    vm.onSaveSuccess = vaultBrowserVM.saveHandler()
                    return vm
                },
                makeAddAttachmentViewModel: { cipherId in
                    container.makeAddAttachmentViewModel(for: cipherId)
                },
                makeBatchAttachmentViewModel: { cipherId in
                    container.makeBatchAttachmentViewModel(for: cipherId)
                },
                makeAttachmentRowViewModel: { cipherId, attachment in
                    container.makeAttachmentRowViewModel(cipherId: cipherId, attachment: attachment)
                },
                makeCodesViewModel: { container.makeTOTPCodesViewModel() },
                makePasswordHistoryViewModel: { container.makePasswordHistoryViewModel(itemId: $0) }
            )
        }
    }
}

// MARK: - RootViewModel

/// Dependencies required by `RootViewModel` — extracted for testability.
@MainActor
protocol RootViewModelDependencies: AnyObject {
    var authRepo: any AuthRepository { get }
    var vaultRepo: any VaultRepository { get }
    /// Generates the current TOTP code for the "Copy Code" command.
    var generateTOTPCode: any GenerateTOTPCodeUseCase { get }
    /// The app's one clipboard service; cleared on lock, sign-out and quit.
    var clipboard: any ClipboardService { get }
    /// Folder of opened attachment files; emptied on lock, sign-out and quit.
    var attachmentTempFiles: any TempFileManaging { get }
    /// Website icon loader; pointed at the signed-in server, cleared on lock and sign-out.
    var faviconLoader: FaviconLoader { get }
    /// The app's lock fence: closed first by every lock and sign-out, opened by its teardown
    /// (lock-state-machine, design D1).
    var sessionGate: any SessionGate { get }
    func makeLoginViewModel() -> LoginViewModel
    func makeUnlockViewModel(account: Account) -> UnlockViewModel
    func makeVaultBrowserViewModel() -> VaultBrowserViewModel
    /// Returns a fresh sync timestamp repository and use case scoped to the given email.
    /// Called after login/unlock to re-scope to the correct account before the first sync.
    func makeSyncTimestampDependencies(for email: String) -> (repository: any SyncTimestampRepository, useCase: any GetLastSyncDateUseCase)
    #if DEBUG
    /// XCUITest seam: stores a server record for each fixture item next to the populated vault.
    func seedUITestRecords(for items: [VaultItem]) async
    #endif
}

extension AppContainer: RootViewModelDependencies {
    var authRepo: any AuthRepository { authRepository }
    var vaultRepo: any VaultRepository { vaultStore }
    var generateTOTPCode: any GenerateTOTPCodeUseCase { generateTOTPCodeUseCase }
    var attachmentTempFiles: any TempFileManaging { tempFileManager }
}

/// Top-level state machine that decides which screen to show.
///
/// On launch: checks for a stored session via `AuthRepository.storedAccount()`.
/// - Session found → `UnlockView` (User Story 2)
/// - No session    → `LoginView`  (User Story 1)
@MainActor
final class RootViewModel: ObservableObject {

    enum Screen {
        case login
        case loading
        case totpPrompt
        case unlock
        case syncing(message: String)
        case vault
    }

    @Published var screen: Screen

    // MARK: - "Item" menu state

    /// Whether the Edit command should be enabled: an item is selected and the edit sheet is closed.
    @Published private(set) var menuBarCanEdit: Bool = false

    /// Whether the Save command should be enabled: the edit sheet is currently open.
    @Published private(set) var menuBarCanSave: Bool = false

    /// The login content of the currently selected item, or nil. Drives copy command disabled state.
    @Published private(set) var selectedLogin: LoginContent?

    private let logger = Logger(subsystem: "com.prizm", category: "RootViewModel")

    let loginVM:          LoginViewModel
    @Published var unlockVM: UnlockViewModel? {
        didSet {
            // A replaced unlock screen is over: its Touch ID context must not stay armed, also
            // when overlapping locks replace one that no lock ended (code review C6).
            if oldValue !== unlockVM { oldValue?.end() }
            connectSignOut(unlockVM)
        }
    }
    let vaultBrowserVM:   VaultBrowserViewModel

    private let container: any RootViewModelDependencies
    /// Combine subscriptions — held for the lifetime of this object.
    /// Using Combine (not SwiftUI .onChange) so transitions fire regardless
    /// of whether the source view is currently in the view hierarchy.
    private var cancellables = Set<AnyCancellable>()
    /// Lock and sign-out teardowns still running. The session gate opens only when the last one
    /// finished, so an overlapping lock is never opened by an earlier teardown (design D1). While
    /// one runs, the lock owns the screen and flow states change nothing.
    private var pendingTeardowns = 0
    /// System notification observers for auto-lock (sleep, screensaver, screen lock).
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screensaverObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenLockObserver: NSObjectProtocol?
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    init(container: any RootViewModelDependencies) {
        self.container      = container
        self.loginVM        = container.makeLoginViewModel()
        self.vaultBrowserVM = container.makeVaultBrowserViewModel()

        // Check for stored session at launch.
        if let account = container.authRepo.storedAccount() {
            self.screen   = .unlock
            self.unlockVM = container.makeUnlockViewModel(account: account)
        } else {
            self.screen   = .login
            self.unlockVM = nil
        }

        // `didSet` does not run for the assignment in `init` (code review C7).
        connectSignOut(unlockVM)
        subscribeToFlowStates()

        #if DEBUG
        // XCUITest seam: skip login and show a seeded in-memory vault (see UITestFixtures).
        if UITestFixtures.isEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await container.vaultRepo.populate(
                    items: UITestFixtures.items, folders: UITestFixtures.folders,
                    organizations: UITestFixtures.organizations,
                    collections: UITestFixtures.collections, syncedAt: Date()
                )
                // Saves in the UI-test vault are built over a stored server record, so seed one per
                // item. The seam does not unlock the crypto service and has no server, so saving
                // journeys stay skipped until a UI test backend unlocks with
                // `UITestFixtures.vaultKeys`.
                await container.seedUITestRecords(for: UITestFixtures.items)
                self.transitionToVault(caller: "UITestFixtures")

                // Optional: open straight on the Codes list with an item selected (screenshots).
                if UITestFixtures.opensOnCodes {
                    try? await Task.sleep(for: .milliseconds(600))
                    self.vaultBrowserVM.sidebarSelection = .verificationCodes
                    try? await Task.sleep(for: .milliseconds(600))
                    self.vaultBrowserVM.itemSelection = self.vaultBrowserVM.displayedItems.first
                }
            }
        }
        #endif
    }

    deinit {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let screensaverObserver { DistributedNotificationCenter.default().removeObserver(screensaverObserver) }
        if let screenLockObserver { DistributedNotificationCenter.default().removeObserver(screenLockObserver) }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    // MARK: - Combine subscriptions

    private func subscribeToFlowStates() {
        // Login flow — observe for the lifetime of the app (loginVM is never replaced).
        loginVM.$flowState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleLoginFlow(state) }
            .store(in: &cancellables)

        // Unlock flow — only the current unlockVM counts. `switchToLatest` drops the previous one
        // when a lock replaces it or a sign-out removes it, so its late sync states can't undo the
        // lock (lock-during-unlock-sync, D1). `flatMap` kept every old subscription alive.
        $unlockVM
            .map { $0?.$flowState.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher() }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleUnlockFlow(state) }
            .store(in: &cancellables)

        // canEdit: item selected, editable (no edit block), and edit sheet not yet open.
        // canSave: edit sheet is open.
        // Both are derived by watching editSheetOpen and itemSelection independently.
        // `for await` on @Published.values avoids Combine callbacks (CLAUDE.md async/await rule).
        Task { [weak self, vaultBrowserVM] in
            for await open in vaultBrowserVM.$editSheetOpen.values {
                guard let self else { break }
                self.menuBarCanSave = open
                let selection = vaultBrowserVM.itemSelection
                self.menuBarCanEdit = selection != nil && selection?.editBlock == nil && !open
            }
        }
        Task { [weak self, vaultBrowserVM] in
            for await selection in vaultBrowserVM.$itemSelection.values {
                guard let self else { break }
                self.menuBarCanEdit = selection != nil && selection?.editBlock == nil
                    && !vaultBrowserVM.editSheetOpen
                if case .login(let login) = selection?.content {
                    self.selectedLogin = login
                } else {
                    self.selectedLogin = nil
                }
            }
        }

        // Quit: a copied secret does not outlive the app (clipboard-hardening, D3). The app has no
        // NSApplicationDelegate, so observe the notification.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.container.clipboard.clearIfOwned()
                // Opened attachment files do not outlive the app (fix-attachment-transfer-flow, D7).
                self?.container.attachmentTempFiles.sweepAll()
            }
        }

        // Auto-lock on Mac sleep.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lockForSystemEvent() } }

        // Auto-lock on screensaver start.
        screensaverObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lockForSystemEvent() } }

        // Auto-lock on screen lock (⌃⌘Q / Lock Screen menu).
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lockForSystemEvent() } }
    }

    /// Shows the vault for a flow that reached it, only while that flow is still current.
    ///
    /// Security goal: a lock or sign-out during the sync after unlocking or signing in stays in
    /// effect when that sync ends (lock-state-machine, design D7). Flow states reach this type
    /// after a main-queue hop, so `isCurrent` is checked when the state arrives and again after
    /// the await, in the same turn as the transition.
    /// - A stale flow changes nothing: the lock that overtook it owns the screen. Showing the lock
    ///   screen here would replace the unlock view model a newer flow may be using.
    /// - Intentionally NOT done: tearing down keys "a stale flow loaded". Flows take their token at
    ///   their first step, so the auth layer never loads keys for a stale one (design D2).
    private func showVaultIfUnlocked(caller: String, isCurrent: @escaping () -> Bool) {
        guard pendingTeardowns == 0, isCurrent() else {
            logger.info("\(caller, privacy: .public)(.vault) after a lock: the vault stays locked")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let unlocked = await container.authRepo.isVaultUnlocked
            guard pendingTeardowns == 0, isCurrent() else {
                logger.info("\(caller, privacy: .public)(.vault) after a lock: the vault stays locked")
                return
            }
            guard unlocked else {
                logger.error("\(caller, privacy: .public)(.vault) without keys: showing the lock screen")
                return showLockedScreen()
            }
            transitionToVault(caller: caller)
        }
    }

    /// The screen a lock leads to: unlock with the stored account, else login.
    private func showLockedScreen() {
        if let account = container.authRepo.storedAccount() {
            // A fresh one: the current one may be the flow that just ended after the lock.
            unlockVM = container.makeUnlockViewModel(account: account)
            screen = .unlock
        } else {
            unlockVM = nil
            screen = .login
        }
    }

    /// Re-scopes the sync timestamp to the current account and records a successful sync,
    /// then transitions to the vault screen.
    ///
    /// Called from both `handleLoginFlow` and `handleUnlockFlow` — the vault transition
    /// logic is identical in both flows. `caller` is included in the error log so the
    /// originating flow is identifiable when the account is unexpectedly missing.
    private func transitionToVault(caller: String) {
        // Re-scope before recording: on first login the AppContainer was initialised without
        // a known email; this corrects the UserDefaults key before handleSyncCompleted writes to it.
        if let email = container.authRepo.storedAccount()?.email {
            let deps = container.makeSyncTimestampDependencies(for: email)
            vaultBrowserVM.updateSyncTimestamp(repository: deps.repository, useCase: deps.useCase)
        } else {
            // Unexpected: vault transition reached with no stored account — timestamp will
            // be written under the fallback empty-email key. Should not occur in normal flow.
            logger.error("\(caller, privacy: .public)(.vault): no stored account; sync timestamp not re-scoped")
        }
        // Icons come only from this account's server (fix-website-icons-privacy, D1).
        var iconsBase = container.authRepo.storedAccount()?.serverEnvironment.iconsURL
        #if DEBUG
        // UI-test runs have no real server; the seam exists in Debug builds only (fix-release-build).
        if UITestFixtures.isEnabled { iconsBase = nil }
        #endif
        container.faviconLoader.configure(iconsBase: iconsBase)
        vaultBrowserVM.beginSession()
        screen = .vault
        // Defer handleSyncCompleted to the next run-loop cycle so that the initial
        // VaultBrowserView layout pass (triggered by `screen = .vault` above) commits
        // before any @Published mutations from async vault reads arrive.
        //
        // Root cause: VaultRepositoryImpl is an `actor`, so every refresh Task suspends
        // at a cross-actor hop; the continuations resume on @MainActor asynchronously.
        // If they land while SwiftUI is computing its first layout pass for VaultBrowserView,
        // SwiftUI emits "Publishing changes from within view updates is not allowed" →
        // undefined behaviour → heap corruption → z_ccm_xcma_malloc_freelist EXC_BREAKPOINT.
        //
        // DispatchQueue.main.async (not a Swift Task) is intentional: it guarantees
        // the block runs between run-loop iterations, after the current CATransaction
        // (which drives the SwiftUI layout commit) has flushed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.vaultBrowserVM.handleSyncCompleted(syncedAt: Date())
            }
        }
    }

    func handleLoginFlow(_ state: LoginFlowState) {
        // During a lock's teardown the lock owns the screen (design D6); a sign-in that started
        // before it is stale for good, so nothing it publishes is applied afterwards either.
        guard pendingTeardowns == 0 else { return }
        let current = loginVM.isFlowCurrent
        switch state {
        case .login:
            // Only the login flow's own screens go back to login; a stale sign-in's `.login`
            // must not replace the unlock screen a lock showed.
            if isLoginFlowScreen { screen = .login }
        case .loading:
            if current { screen = .loading }
        case .totpPrompt:
            // Discards the pending two-factor keys instead of asking for a code behind a lock.
            if current { screen = .totpPrompt } else { loginVM.cancelTOTP() }
        case .vault:
            let vm = loginVM
            showVaultIfUnlocked(caller: "handleLoginFlow", isCurrent: { vm.isFlowCurrent })
        }
        logger.info("Screen transition → \(String(describing: state))")
    }

    /// The screen belongs to the login flow.
    private var isLoginFlowScreen: Bool {
        switch screen {
        case .login, .loading, .totpPrompt: return true
        // The sign-in syncs behind its loading screen; only an unlock shows `.syncing`.
        case .unlock, .vault, .syncing: return false
        }
    }

    /// Whether the user has an active session (vault or unlock screen).
    var isSignedIn: Bool {
        switch screen {
        case .vault, .unlock, .syncing: return true
        default: return false
        }
    }

    /// Shows a confirmation alert before signing out (FR-014).
    func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign Out"
        alert.informativeText = "All local data will be cleared."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        signOut()
    }

    /// Clears all session data and returns to the login screen.
    func signOut() {
        beginTeardown()
        // Drop the vault browser's decrypted copies right away, not after the awaits below.
        vaultBrowserVM.clearSession()
        // No icon request from here on, not only after the teardown below, which may wait for the
        // network (fix-website-icons-privacy, D1; code review 2026-10-30).
        container.faviconLoader.configure(iconsBase: nil)
        Task {
            // No icon of this account kept (D4).
            await container.faviconLoader.reset()
            do {
                try await container.authRepo.signOut()
            } catch {
                logger.error("Sign-out error: \(ErrorLog.describe(error), privacy: .public)")
            }
            // authRepo.signOut() zeroes and clears every key cache through its lockVault().
            await container.vaultRepo.clearVault()
            container.clipboard.clearIfOwned()
            container.attachmentTempFiles.sweepAll()
            // Again: a vault shown while the sign-out ran must not keep its items.
            vaultBrowserVM.clearSession()
            // The next account must not start in a folder or collection of this one.
            vaultBrowserVM.sidebarSelection = .allItems
            endTeardown()
            unlockVM = nil
            screen   = .login
            logger.info("Sign out completed")
        }
    }

    // MARK: - Lock

    /// Closes the session gate and counts a teardown. The first statement of every lock and
    /// sign-out, before any await: from here on no running flow can pass a check, and nothing that
    /// starts before the teardown ends counts (lock-state-machine, design D1).
    private func beginTeardown() {
        container.sessionGate.end()
        pendingTeardowns += 1
        // The flows on screen end in the same turn: Touch ID is disarmed, the enrollment sheet and
        // the two-factor prompt close (design D1, D4, D6).
        unlockVM?.end()
        loginVM.endFlow()
    }

    /// The last step of a teardown: opens the gate when no other teardown still runs, right before
    /// the unlock or login screen that starts new flows is shown.
    private func endTeardown() {
        pendingTeardowns -= 1
        if pendingTeardowns == 0 { container.sessionGate.open() }
    }

    /// Zeros in-memory key material, clears the vault cache, and transitions to the unlock screen.
    /// ⌘L and the menu: a no-op where locking changes nothing the user sees (`canLock`), so a
    /// password typed on an idle unlock screen stays.
    func lockVault() {
        guard canLock else { return }
        lock()
    }

    /// Sleep, screensaver and screen lock (design D5): a lock where `canLock` allows it, and on an
    /// idle unlock screen a new one, so a Touch ID prompt armed before the event cannot finish
    /// after it.
    func lockForSystemEvent() {
        if canLock { return lock() }
        // On an idle unlock screen too: the whole teardown, not only a renewed screen, so nothing an
        // unlock may have loaded just before stays behind the lock screen (security review S2).
        guard case .unlock = screen else { return }
        lock()
    }

    /// "Sign in with a different account" signs out here, so the gate closes first (design D1).
    private func connectSignOut(_ vm: UnlockViewModel?) {
        vm?.onSignOutRequested = { [weak self] in self?.signOut() }
    }

    private func lock() {
        beginTeardown()
        // Drop the vault browser's decrypted copies right away, not after the awaits below.
        vaultBrowserVM.clearSession()
        // No icon request while locked, from the start of the lock (fix-website-icons-privacy, D1).
        container.faviconLoader.configure(iconsBase: nil)
        Task {
            // No icon kept (D4).
            await container.faviconLoader.reset()
            // Zeroes and clears every key cache (Constitution §III): one teardown path in the
            // Data layer for lock and sign-out (harden-key-lifecycle-and-logging, D1).
            await container.authRepo.lockVault()
            await container.vaultRepo.clearVault()
            // A copied secret does not outlive the session (clipboard-hardening, D3), nor does an
            // opened attachment file (fix-attachment-transfer-flow, D7).
            container.clipboard.clearIfOwned()
            container.attachmentTempFiles.sweepAll()
            // Again: a vault shown while the teardown ran must not keep its items (D2).
            vaultBrowserVM.clearSession()
            endTeardown()
            // Always a new unlock view model: the old one was ended (lock-state-machine, D6).
            if let account = container.authRepo.storedAccount() {
                unlockVM = container.makeUnlockViewModel(account: account)
                screen = .unlock
            } else {
                unlockVM = nil
                screen = .login
            }
            logger.info("Vault locked")
        }
    }

    /// Whether the vault is currently unlocked (vault browser or sync in progress).
    var isVaultUnlocked: Bool {
        switch screen {
        case .vault, .syncing: return true
        default: return false
        }
    }

    /// Whether a lock applies (design D5): the vault is unlocked, a sign-in or its two-factor step
    /// runs, or an unlock runs (password or Touch ID, through enrollment and sync).
    var canLock: Bool {
        switch screen {
        case .loading, .totpPrompt: return true
        case .unlock: return unlockVM?.isFlowRunning ?? false
        default: return isVaultUnlocked
        }
    }

    func handleUnlockFlow(_ state: UnlockFlowState) {
        // Only the current unlock view model reaches here (`switchToLatest`); during a lock's
        // teardown the lock owns the screen (design D6).
        guard pendingTeardowns == 0 else { return }
        switch state {
        case .unlock, .loading:
            screen = .unlock   // `.loading`: stay on the unlock screen with its spinner
        case .syncing(let msg):
            if unlockVM?.isFlowCurrent ?? false {
                screen = .syncing(message: msg)
            }
        case .vault:
            let vm = unlockVM
            showVaultIfUnlocked(caller: "handleUnlockFlow", isCurrent: { vm?.isFlowCurrent ?? false })
        }
        logger.info("Screen transition → \(String(describing: state))")
    }

    // MARK: - Copy field from selected item

    enum CopyableField {
        case username, password, totp, website
    }

    func copySelectedField(_ field: CopyableField) {
        guard isVaultUnlocked else { return }
        // Copy Code copies the *generated* code, never the stored seed (FR-016, FR-017).
        if field == .totp {
            Task { await copySelectedCode() }
            return
        }
        guard let value = selectedFieldValue(field) else { return }
        vaultBrowserVM.copy(value)
    }

    func selectedFieldAvailable(_ field: CopyableField) -> Bool {
        // Defense in depth: the lock clears the selection, but nothing is copied while locked.
        guard isVaultUnlocked else { return false }
        if field == .totp {
            guard let seed = selectedLogin?.totp else { return false }
            return (try? TOTPSeedParser.parse(seed)) != nil
        }
        return selectedFieldValue(field) != nil
    }

    /// Generates the current code for the selected Login and puts it on the clipboard through the
    /// shared path, so the clipboard auto-clear applies. Does nothing for an unusable seed.
    func copySelectedCode() async {
        guard let seed = selectedLogin?.totp, selectedFieldAvailable(.totp) else { return }
        do {
            let code = try await container.generateTOTPCode.execute(seed: seed, at: Date())
            // The vault can lock while the code is generated.
            guard isVaultUnlocked else { return }
            vaultBrowserVM.copy(code.copyValue)
        } catch {
            // Never log the seed or the error payload (Constitution §III, §V).
            logger.error("Copy Code skipped: the stored seed is not usable")
        }
    }

    private func selectedFieldValue(_ field: CopyableField) -> String? {
        guard let login = selectedLogin else { return nil }

        switch field {
        case .username: return login.username
        case .password: return login.password
        case .website:  return login.firstAddress
        case .totp:     return nil   // handled by copySelectedCode(); the seed is never copied
        }
    }
}
