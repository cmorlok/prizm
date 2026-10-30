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
            SettingsView(authRepository: container.authRepository)
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
                makeCodesViewModel: { container.makeTOTPCodesViewModel() }
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
    @Published var unlockVM: UnlockViewModel?
    let vaultBrowserVM:   VaultBrowserViewModel

    private let container: any RootViewModelDependencies
    /// Combine subscriptions — held for the lifetime of this object.
    /// Using Combine (not SwiftUI .onChange) so transitions fire regardless
    /// of whether the source view is currently in the view hierarchy.
    private var cancellables = Set<AnyCancellable>()
    /// Counts locks, so a flow that ends after one can tell (`showVaultIfUnlocked`).
    private var lockGeneration = 0
    /// True from `lockVault()` until its teardown has finished.
    private var isLocking = false
    /// `lockGeneration` when the current sign-in or unlock started (`.loading`), nil when none runs.
    private var loginFlowStart: Int?
    private var unlockFlowStart: Int?
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
        ) { [weak self] _ in MainActor.assumeIsolated { self?.container.clipboard.clearIfOwned() } }

        // Auto-lock on Mac sleep.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lockVault() } }

        // Auto-lock on screensaver start.
        screensaverObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lockVault() } }

        // Auto-lock on screen lock (⌃⌘Q / Lock Screen menu).
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lockVault() } }
    }

    /// Shows the vault only if no lock came in between (lock-during-unlock-sync, D2).
    ///
    /// Security goal: a lock (⌘L, sleep, screensaver) during the sync after unlocking or signing in
    /// stays in effect when that sync ends. The flow's final `.vault` is checked after the await
    /// against the keys, against a lock whose teardown is still running (`isLocking`), and against
    /// a lock that ran since the flow started (`flowStart`, the lock count when it started). The
    /// auth layer refuses keys of a flow it saw start before a lock (D6); keys a stale flow still
    /// loaded (its start reached the auth layer only after the lock) are torn down here, unless a
    /// newer unlock is running or already shows the vault.
    private func showVaultIfUnlocked(caller: String, flow: Flow, flowStart: Int) {
        let generation = flowStart
        Task { [weak self] in
            guard let self else { return }
            let unlocked = await container.authRepo.isVaultUnlocked
            guard unlocked, !isLocking, generation == lockGeneration else {
                logger.info("\(caller, privacy: .public)(.vault) after a lock: the vault stays locked")
                // A lock still tearing down shows its screen when it finishes, and a newer flow
                // that is running or shows the vault shows its own: this one changes nothing.
                guard !isLocking, !isVaultShown, !isOtherFlowActive(than: flow) else { return }
                if unlocked {
                    // No newer flow, so the keys came from this one: its start reached the auth
                    // layer only after the lock (for example a lock during the sign-in's server
                    // setup). Tear them down (D2).
                    vaultBrowserVM.clearSession()
                    await container.authRepo.lockVault()
                    await container.vaultRepo.clearVault()
                }
                showLockedScreen()
                return
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
        // A sign-in that started before a lock changes nothing after it; its `.vault` only goes
        // through the checks of `showVaultIfUnlocked` (lock-during-unlock-sync, D5).
        let stale = startedBeforeALock(loginFlowStart)
        switch state {
        case .login:
            // See the unlock flow: only the current `.login` ends the sign-in.
            if loginVM.flowState == .login { loginFlowStart = nil }
            if !stale { screen = .login }
        case .loading:
            // Kept if `lockVault()` already marked this sign-in: states arrive asynchronously.
            if loginFlowStart == nil { loginFlowStart = lockGeneration }
            if !stale { screen = .loading }
        case .totpPrompt:
            // Discards the pending two-factor keys instead of asking for a code behind a lock.
            if stale { loginVM.cancelTOTP() } else { screen = .totpPrompt }
        case .syncing(let msg):
            if !stale { screen = .syncing(message: msg) }
        case .vault:
            let start = loginFlowStart ?? lockGeneration
            loginFlowStart = nil
            showVaultIfUnlocked(caller: "handleLoginFlow", flow: .login, flowStart: start)
        }
        logger.info("Screen transition → \(String(describing: state))")
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
        // Counts as a lock for flows still running: their `.vault` must not open the vault (D6).
        lockGeneration += 1
        // Drop the vault browser's decrypted copies right away, not after the awaits below.
        vaultBrowserVM.clearSession()
        Task {
            do {
                try await container.authRepo.signOut()
            } catch {
                logger.error("Sign-out error: \(ErrorLog.describe(error), privacy: .public)")
            }
            // authRepo.signOut() zeroes and clears every key cache through its lockVault().
            await container.vaultRepo.clearVault()
            container.clipboard.clearIfOwned()
            // Again: a vault shown while the sign-out ran must not keep its items.
            vaultBrowserVM.clearSession()
            // The next account must not start in a folder or collection of this one.
            vaultBrowserVM.sidebarSelection = .allItems
            unlockVM = nil
            screen   = .login
            logger.info("Sign out completed")
        }
    }

    // MARK: - Lock

    /// Zeros in-memory key material, clears the vault cache, and transitions to the unlock screen.
    /// No-op if the vault is not currently unlocked.
    func lockVault() {
        guard canLock else { return }
        // An unlock in progress keeps its view model, so its end still reaches the checks of
        // `showVaultIfUnlocked` (D5); the auth layer refuses its keys (D6).
        let keepUnlockFlow = isUnlockInProgress
        // Mark a sign-in or unlock in progress as started before this lock, also when its
        // `.loading` has not reached `handle…Flow` yet.
        if keepUnlockFlow, unlockFlowStart == nil { unlockFlowStart = lockGeneration }
        if case .loading = screen, loginFlowStart == nil { loginFlowStart = lockGeneration }
        lockGeneration += 1
        isLocking = true
        // Drop the vault browser's decrypted copies right away, not after the awaits below.
        vaultBrowserVM.clearSession()
        Task {
            // Zeroes and clears every key cache (Constitution §III): one teardown path in the
            // Data layer for lock and sign-out (harden-key-lifecycle-and-logging, D1).
            await container.authRepo.lockVault()
            await container.vaultRepo.clearVault()
            // A copied secret does not outlive the session (clipboard-hardening, D3).
            container.clipboard.clearIfOwned()
            // Again: a vault shown while the teardown ran must not keep its items (D2).
            vaultBrowserVM.clearSession()
            if let account = container.authRepo.storedAccount() {
                if !keepUnlockFlow { unlockVM = container.makeUnlockViewModel(account: account) }
                screen = .unlock
            } else {
                unlockVM = nil
                screen = .login
            }
            isLocking = false
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

    /// Whether a lock applies: the vault is unlocked, or a sign-in is loading keys and syncing
    /// (the login flow shows `.loading` until its sync ends). Without it, sleep during the first
    /// sync after signing in was ignored (lock-during-unlock-sync).
    var canLock: Bool {
        if case .loading = screen { return true }
        if isUnlockInProgress { return true }
        return isVaultUnlocked
    }

    /// The unlock screen is deriving keys (password entered): a lock must apply to that unlock too.
    private var isUnlockInProgress: Bool {
        guard case .unlock = screen, let unlockVM else { return false }
        return unlockVM.flowState == .loading
    }

    private var isVaultShown: Bool {
        if case .vault = screen { return true }
        return false
    }

    enum Flow { case login, unlock }

    /// Whether the other flow (the unlock for a sign-in, and the sign-in for an unlock) is deriving
    /// keys, syncing, or has just reached the vault and is about to show it.
    private func isOtherFlowActive(than flow: Flow) -> Bool {
        switch flow {
        case .login:
            switch unlockVM?.flowState {
            case .loading, .syncing, .vault: return true
            default: return false
            }
        case .unlock:
            switch loginVM.flowState {
            case .loading, .syncing: return true
            default: return false
            }
        }
    }


    private func startedBeforeALock(_ flowStart: Int?) -> Bool {
        flowStart.map { $0 != lockGeneration } ?? false
    }

    func handleUnlockFlow(_ state: UnlockFlowState) {
        switch state {
        case .unlock:
            // States arrive through the main queue; a late `.unlock` from before the user started
            // unlocking must not drop the mark `lockVault()` set on the unlock now running.
            if unlockVM?.flowState == .unlock { unlockFlowStart = nil }
            screen = .unlock
        case .loading:
            // Kept if `lockVault()` already marked this unlock: states arrive asynchronously.
            if unlockFlowStart == nil { unlockFlowStart = lockGeneration }
            screen = .unlock   // stay on unlock screen with spinner
        case .syncing(let msg):
            // An unlock that started before a lock does not cover the lock screen (D5).
            if !startedBeforeALock(unlockFlowStart) { screen = .syncing(message: msg) }
        case .vault:
            let start = unlockFlowStart ?? lockGeneration
            unlockFlowStart = nil
            showVaultIfUnlocked(caller: "handleUnlockFlow", flow: .unlock, flowStart: start)
        case .login:
            // "Sign in with a different account" — reset to login.
            unlockFlowStart = nil
            unlockVM = nil
            screen   = .login
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
