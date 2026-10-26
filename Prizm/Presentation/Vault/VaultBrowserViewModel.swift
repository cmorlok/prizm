import AppKit
import Combine
import Foundation
import os.log

// MARK: - VaultBrowserViewModel

/// ViewModel for the three-pane vault browser (User Story 3).
///
/// Responsibilities:
///   - Manages sidebar selection and item list content
///   - Runs in-memory search filter in real time (FR-012)
///   - Provides clipboard copy through `ClipboardService` (auto-clear after the chosen delay)
///   - Surfaces the last-synced timestamp for the toolbar (FR-037, FR-041)
///   - Tracks and dismisses the sync error banner (FR-049)
@MainActor
final class VaultBrowserViewModel: ObservableObject {

    // MARK: - Published state

    @Published var sidebarSelection: SidebarSelection = .allItems {
        didSet {
            if oldValue != sidebarSelection {
                if isGlobalSearch { deactivateGlobalSearch(restoreSelection: false) }
                Task { @MainActor [weak self] in
                    self?.itemSelection = nil
                    self?.refreshItems()
                }
            }
        }
    }

    @Published var itemSelection: VaultItem?
    @Published var searchQuery:   String = "" {
        didSet { Task { @MainActor in refreshItems() } }
    }

    /// When true, search queries are scoped to `.allItems` regardless of sidebar selection.
    @Published private(set) var isGlobalSearch: Bool = false

    /// The sidebar selection that was active before global search was activated.
    private(set) var previousSelection: SidebarSelection?

    @Published private(set) var displayedItems: [VaultItem] = []
    @Published private(set) var itemCounts: [SidebarSelection: Int] = [:]
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var organizations: [Organization] = []
    @Published private(set) var collections: [OrgCollection] = []

    var selectedFolderId: String? {
        if case .folder(let id) = sidebarSelection { return id }
        return nil
    }

    /// Non-nil when the active sidebar selection is a specific collection.
    /// Used to pre-fill the collection picker when creating items from a collection context (task 5.9).
    var selectedCollectionId: String? {
        if case .collection(let id) = sidebarSelection { return id }
        return nil
    }
    @Published private(set) var lastSyncedAt: Date?
    @Published var syncErrorMessage: String? = nil
    /// Reflects whether the edit sheet is currently open. Used by `MenuBarViewModel`
    /// to enable/disable the Edit and Save menu bar actions.
    @Published private(set) var editSheetOpen: Bool = false

    // MARK: - Published state (trash actions)

    /// Set when a delete, restore, or empty-trash operation fails.
    /// The Presentation layer surfaces this as an alert.
    @Published var actionError: String? = nil

    /// Set to a non-nil `ItemType` to present the create sheet for that type. Ignored while Trash
    /// is selected: nothing is created in Trash (spec list-column-header).
    ///
    /// The check sits in a setter over a private published value. It used to reset the value in
    /// its own `didSet`, and a unit test showed the value stayed set; ⌘N in Trash then crashed the
    /// app, for a reason not traced further (fix-ui-journey-findings).
    var createItemType: ItemType? {
        get { pendingCreateItemType }
        set { pendingCreateItemType = sidebarSelection == .trash ? nil : newValue }
    }
    @Published private var pendingCreateItemType: ItemType? = nil

    // MARK: - Dependencies

    private let vault:                  any VaultRepository
    private let search:                 any SearchVaultUseCase
    private let deleteUseCase:          any DeleteVaultItemUseCase
    private let permanentDeleteUseCase: any PermanentDeleteVaultItemUseCase
    private let restoreUseCase:         any RestoreVaultItemUseCase
    private let createFolderUseCase:      any CreateFolderUseCase
    private let renameFolderUseCase:      any RenameFolderUseCase
    private let deleteFolderUseCase:      any DeleteFolderUseCase
    private let moveItemUseCase:          any MoveItemToFolderUseCase
    private let setFavoriteUseCase:       any SetFavoriteUseCase
    private let emptyTrashUseCase:        any EmptyTrashUseCase
    private let clipboard:                any ClipboardService
    private let createCollectionUseCase:  any CreateCollectionUseCase
    private let renameCollectionUseCase:  any RenameCollectionUseCase
    private let deleteCollectionUseCase:  any DeleteCollectionUseCase
    private var syncTimestamp:          any SyncTimestampRepository
    private var getLastSyncDate:        any GetLastSyncDateUseCase
    private let logger = Logger(subsystem: "com.prizm", category: "VaultBrowserViewModel")

    // MARK: - Menu bar action relay

    /// Incremented each time the "Item > Edit" menu bar action fires (spec §9.3).
    /// `ItemDetailView` uses `.onChange(of: editTrigger)` to open the edit sheet.
    /// An integer counter (rather than a Combine PassthroughSubject) keeps the relay
    /// within the async/await pattern mandated by CLAUDE.md.
    @Published private(set) var editTrigger: Int = 0

    /// Incremented each time the "Item > Save" menu bar action fires (spec §9.4).
    /// `ItemDetailView` uses `.onChange(of: saveTrigger)` to call `save()`.
    @Published private(set) var saveTrigger: Int = 0

    func triggerEdit() { editTrigger += 1 }
    func triggerSave() { saveTrigger += 1 }

    // MARK: - Sync label refresh timer

    /// Fires every 60 seconds to re-evaluate the relative sync label while the app is open.
    /// Invalidated in `deinit` to prevent the timer outliving the ViewModel.
    // nonisolated(unsafe) is required because deinit is always nonisolated in Swift 6,
    // and Timer is non-Sendable. The timer is only mutated on MainActor, so this is safe.
    nonisolated(unsafe) private var labelRefreshTimer: Timer?

    /// Relative label derived from `lastSyncedAt`, refreshed every 60 seconds.
    @Published private(set) var syncStatusLabel: String = "Never synced"

    // MARK: - Session lifetime

    /// False between `clearSession()` and `beginSession()`, while the vault is locked or signed out.
    /// Open at launch: the vault store stays empty until the first unlock.
    /// Results that arrive then are dropped: the lock clears the vault store only after some awaits,
    /// so a refresh started in between would still find decrypted items there.
    private var isSessionOpen = true

    /// Incremented by `clearSession()` and `beginSession()`. A refresh compares it with the value
    /// from when it started, so a read from before a lock cannot deliver into the next session.
    private var sessionGeneration = 0

    /// Whether a result from a refresh started at `generation` may still be shown.
    private func isCurrent(_ generation: Int) -> Bool {
        isSessionOpen && generation == sessionGeneration
    }

    // MARK: - Init

    init(
        vault:             any VaultRepository,
        search:            any SearchVaultUseCase,
        delete:            any DeleteVaultItemUseCase,
        permanentDelete:   any PermanentDeleteVaultItemUseCase,
        restore:           any RestoreVaultItemUseCase,
        createFolder:      any CreateFolderUseCase,
        renameFolder:      any RenameFolderUseCase,
        deleteFolder:      any DeleteFolderUseCase,
        moveItem:          any MoveItemToFolderUseCase,
        setFavorite:       any SetFavoriteUseCase,
        emptyTrash:        any EmptyTrashUseCase,
        clipboard:         any ClipboardService,
        createCollection:  any CreateCollectionUseCase,
        renameCollection:  any RenameCollectionUseCase,
        deleteCollection:  any DeleteCollectionUseCase,
        syncTimestamp:     any SyncTimestampRepository,
        getLastSyncDate:   any GetLastSyncDateUseCase
    ) {
        self.vault                  = vault
        self.search                 = search
        self.deleteUseCase          = delete
        self.permanentDeleteUseCase = permanentDelete
        self.restoreUseCase         = restore
        self.createFolderUseCase    = createFolder
        self.renameFolderUseCase    = renameFolder
        self.deleteFolderUseCase    = deleteFolder
        self.moveItemUseCase        = moveItem
        self.setFavoriteUseCase     = setFavorite
        self.emptyTrashUseCase      = emptyTrash
        self.clipboard              = clipboard
        self.createCollectionUseCase = createCollection
        self.renameCollectionUseCase = renameCollection
        self.deleteCollectionUseCase = deleteCollection
        self.syncTimestamp          = syncTimestamp
        self.getLastSyncDate        = getLastSyncDate
        refreshItems()
        refreshCounts()
        refreshFolders()
        refreshOrganizations()
        lastSyncedAt    = getLastSyncDate.execute()
        syncStatusLabel = lastSyncedAt.syncStatusLabel()
        startLabelRefreshTimer()
    }

    deinit {
        labelRefreshTimer?.invalidate()
    }

    // MARK: - Timer

    private func startLabelRefreshTimer() {
        // Re-evaluate the relative label every 60 seconds so "2 minutes ago" stays accurate
        // without requiring a view reload. The timer is weak-captured to avoid a retain cycle.
        labelRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Guard against no-op updates: only assign when the label text changes,
                // avoiding unnecessary SwiftUI re-renders every 60 seconds.
                let updated = lastSyncedAt.syncStatusLabel()
                if syncStatusLabel != updated { syncStatusLabel = updated }
            }
        }
    }

    // MARK: - Actions

    /// Activates global search mode: stores the current sidebar selection and sets the flag.
    func activateGlobalSearch() {
        guard !isGlobalSearch else { return }
        previousSelection = sidebarSelection
        isGlobalSearch = true
        refreshItems()
    }

    /// Deactivates global search mode: restores the previous sidebar selection and clears the query.
    /// - Parameter restoreSelection: When `true` (default), restores the sidebar selection
    ///   that was active before global search. Pass `false` when the caller already set a new selection.
    func deactivateGlobalSearch(restoreSelection: Bool = true) {
        guard isGlobalSearch else { return }
        let saved = previousSelection
        isGlobalSearch = false
        previousSelection = nil
        if restoreSelection, let previous = saved {
            sidebarSelection = previous
        }
        searchQuery = ""
    }

    /// Copies `value` through the app's clipboard service: concealed from clipboard history and
    /// cleared after the user's chosen delay, and on lock, sign-out and quit (clipboard-hardening).
    func copy(_ value: String) {
        clipboard.copy(value)
    }

    /// Dismisses the sync error banner (FR-049).
    func dismissSyncError() {
        syncErrorMessage = nil
    }

    // MARK: - Session

    /// Drops the decrypted vault data this view model holds: the selected item, the listed items,
    /// the folder, organization and collection names, the search term, and the create and edit
    /// sheet state. Called by `RootViewModel` when the vault locks or the user signs out.
    ///
    /// Security goal: after a lock, no decrypted item stays in memory or reachable from the UI
    /// (Constitution §III). `RootViewModel` clears the vault store and the key caches, but this
    /// view model lives as long as the app and kept its own copies, so Item → Edit stayed enabled
    /// on the unlock screen. Until `beginSession()`, refresh results and late saves are dropped.
    /// Intentionally kept: the sidebar category and the sync timestamp, which hold no vault content.
    /// The clipboard is cleared by `RootViewModel` on lock and sign-out (`ClipboardService`).
    func clearSession() {
        isSessionOpen = false
        sessionGeneration &+= 1
        itemSelection     = nil
        displayedItems    = []
        itemCounts        = [:]
        folders           = []
        organizations     = []
        collections       = []
        isGlobalSearch    = false
        previousSelection = nil
        // Assigning triggers a refresh, which is unnecessary when the term is already empty.
        if !searchQuery.isEmpty { searchQuery = "" }
        createItemType    = nil
        editSheetOpen     = false
        actionError       = nil
        emptyTrashConfirmation = nil
        isEmptyingTrash   = false
        announcement      = nil
        // Not `favoriteInFlight`: a request still open blocks the next one for that item, also
        // across a lock, so two requests for one item never race on the server (D2).
        favoriteIntent    = [:]
    }

    /// Accepts vault data again. Called by `RootViewModel` when it shows the unlocked vault.
    func beginSession() {
        sessionGeneration &+= 1
        isSessionOpen = true
    }

    // MARK: - Refresh

    /// Refreshes `displayedItems` from the vault store based on current selection + search query.
    /// Executes the vault read on the actor executor via a fire-and-forget `Task`.
    func refreshItems() {
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let scope: SidebarSelection
                if isGlobalSearch {
                    if case .folder = sidebarSelection { scope = sidebarSelection }
                    else { scope = .allItems }
                } else {
                    scope = sidebarSelection
                }
                let items = try await search.execute(query: searchQuery, in: scope)
                guard isCurrent(generation) else { return }
                displayedItems = items
            } catch {
                logger.error("Failed to load vault items: \(ErrorLog.describe(error), privacy: .public)")
                displayedItems = []
            }
        }
    }

    /// Re-reads the currently selected item from the vault store and updates `itemSelection`.
    ///
    /// Called after a successful attachment upload so the detail pane reflects the new
    /// attachment list without requiring a full vault sync. Safe to call on cancel — if
    /// the item hasn't changed the assignment is a no-op.
    func refreshItemSelection() {
        guard let currentId = itemSelection?.id else { return }
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            guard let updated = try? await vault.allItems().first(where: { $0.id == currentId }) else { return }
            guard isCurrent(generation) else { return }
            itemSelection = updated
        }
    }

    /// Refreshes sidebar item counts from the vault store.
    func refreshCounts() {
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let counts = try await vault.itemCounts()
                guard isCurrent(generation) else { return }
                itemCounts = counts
            } catch {
                logger.error("Failed to load item counts: \(ErrorLog.describe(error), privacy: .public)")
            }
        }
    }

    /// Re-scopes the sync timestamp repository to a newly resolved account email.
    ///
    /// Called by `RootViewModel` immediately after a login or unlock transition to `.vault`,
    /// before `handleSyncCompleted` — ensures the timestamp is written to and read from
    /// the correct per-account UserDefaults key even on first launch (when the email was
    /// not yet known at `AppContainer.init()` time).
    func updateSyncTimestamp(
        repository: any SyncTimestampRepository,
        useCase:    any GetLastSyncDateUseCase
    ) {
        self.syncTimestamp   = repository
        self.getLastSyncDate = useCase
        // Reload the persisted timestamp from the now-correct account-scoped key.
        lastSyncedAt    = useCase.execute()
        syncStatusLabel = lastSyncedAt.syncStatusLabel()
    }

    /// Called after a successful sync to update counts, items, and timestamp.
    ///
    /// Also persists the timestamp via `SyncTimestampRepository` so it survives app restarts.
    /// Error paths MUST NOT call this method — the stored timestamp reflects the last *successful* sync.
    func handleSyncCompleted(syncedAt: Date) {
        lastSyncedAt = syncedAt
        syncStatusLabel = syncedAt.syncStatusLabel()
        syncTimestamp.recordSuccessfulSync()
        refreshItems()
        refreshCounts()
        refreshFolders()
        refreshOrganizations()
        // Re-read the selected item from the vault store so its attachment list
        // reflects the latest sync data. Without this, itemSelection can be a
        // stale copy (e.g. from before a cipher-key fix that silently dropped
        // attachments), and the detail pane would show "No attachments" even
        // after a sync that correctly mapped them.
        refreshItemSelection()
        syncErrorMessage = nil
    }

    /// Called when a sync fails mid-session (FR-049).
    func handleSyncError(_ message: String) {
        syncErrorMessage = message
    }

    /// Called by `ItemDetailView` when the edit sheet opens or closes.
    func handleEditSheetState(_ open: Bool) {
        editSheetOpen = open
    }

    /// Returns the handler for a save that starts now, to be called with the saved item.
    ///
    /// A save can complete after the vault locked, or even after the next unlock or another
    /// account's sign-in; the handler then ignores the item instead of selecting it again.
    func saveHandler() -> (VaultItem) -> Void {
        let generation = sessionGeneration
        return { [weak self] savedItem in
            self?.handleItemSaved(savedItem, startedIn: generation)
        }
    }

    /// Updates `itemSelection` so the detail pane reflects the saved values, then
    /// refreshes the item list and sidebar counts so any name change appears immediately.
    private func handleItemSaved(_ updatedItem: VaultItem, startedIn generation: Int) {
        guard isCurrent(generation) else { return }
        itemSelection = updatedItem
        refreshItems()
        refreshCounts()
    }

    // MARK: - Toggle Favorite

    /// The favorite state each item should end in, while a change for it is being saved, and the
    /// items with a request in flight (favorite-toggle-serialisation, D1). The view passes the item
    /// as last confirmed, so a second click before the first is saved needs the intent to flip.
    private var favoriteIntent: [String: Bool] = [:]
    private var favoriteInFlight: Set<String> = []

    func toggleFavorite(item: VaultItem) {
        // The selection is updated as soon as a change is confirmed, the list row only after its
        // refresh; take the newer one.
        let confirmed = itemSelection?.id == item.id ? (itemSelection?.isFavorite ?? item.isFavorite) : item.isFavorite
        let intent = !(favoriteIntent[item.id] ?? confirmed)
        favoriteIntent[item.id] = intent
        guard !favoriteInFlight.contains(item.id) else { return }
        sendFavorite(itemId: item.id)
    }

    /// One request per item at a time, so the last one sent is the last one the server applies.
    private func sendFavorite(itemId: String) {
        guard let intent = favoriteIntent[itemId] else { return }
        favoriteInFlight.insert(itemId)
        let onSaved = saveHandler()
        let generation = sessionGeneration
        Task {
            let succeeded: Bool
            do {
                // A partial update, not a re-save of the whole item: see `VaultRepository.setFavorite`.
                let updated = try await setFavoriteUseCase.execute(itemId: itemId, isFavorite: intent)
                onSaved(updated)
                succeeded = true
            } catch {
                logger.error("Toggle favorite failed: \(ErrorLog.describe(error), privacy: .public)")
                succeeded = false
                // No alert for a request from a session that has ended (lock or sign-out meanwhile).
                if isCurrent(generation) {
                    actionError = "Couldn't update favorite. \(error.localizedDescription)"
                }
            }
            // The request is done in any case; a new session may have queued a click meanwhile (D2).
            favoriteInFlight.remove(itemId)
            guard isCurrent(generation) else {
                if isSessionOpen, favoriteIntent[itemId] != nil { sendFavorite(itemId: itemId) }
                return
            }
            if succeeded, let latest = favoriteIntent[itemId], latest != intent {
                sendFavorite(itemId: itemId)
            } else {
                favoriteIntent[itemId] = nil
            }
        }
    }

    // MARK: - Empty Trash

    /// The question shown before Empty Trash deletes anything; nil when no confirmation is pending.
    struct EmptyTrashConfirmation: Equatable {
        let ids: [String]
        var title: String { ids.count == 1 ? "Permanently delete 1 item?" : "Permanently delete \(ids.count) items?" }
        var message: String { "This can't be undone." }
    }

    @Published private(set) var emptyTrashConfirmation: EmptyTrashConfirmation?
    /// True from the start of Empty Trash until its outcome is known.
    @Published private(set) var isEmptyingTrash = false
    /// A status message for VoiceOver; the view announces it when it changes.
    @Published private(set) var announcement: String?

    /// Starts Empty Trash: syncs, then asks for confirmation with the count from the fresh data.
    /// Nothing is deleted before `confirmEmptyTrash()` (fix-empty-trash, D2).
    func beginEmptyTrash() {
        guard !isEmptyingTrash else { return }
        isEmptyingTrash = true
        announcement = nil
        let generation = sessionGeneration
        Task {
            do {
                let ids = try await emptyTrashUseCase.prepare()
                guard isCurrent(generation) else { return }
                handleSyncCompleted(syncedAt: Date())
                if ids.isEmpty {
                    isEmptyingTrash = false
                } else {
                    emptyTrashConfirmation = EmptyTrashConfirmation(ids: ids)
                }
            } catch {
                guard isCurrent(generation) else { return }
                isEmptyingTrash = false
                actionError = error.localizedDescription
            }
        }
    }

    /// The user cancelled, or the alert went away. Does not end a delete that already started.
    func cancelEmptyTrash() {
        emptyTrashConfirmation = nil
        if !isDeletingTrash { isEmptyingTrash = false }
    }

    private var isDeletingTrash = false

    /// Deletes exactly the ids of `confirmation`, the one the user confirmed, then reports the
    /// outcome (D3, D4). Takes the confirmation from the alert, so it works whether SwiftUI closes
    /// the alert before or after running the button's action.
    func confirmEmptyTrash(_ confirmation: EmptyTrashConfirmation) {
        guard !isDeletingTrash else { return }
        emptyTrashConfirmation = nil
        isEmptyingTrash = true
        isDeletingTrash = true
        let generation = sessionGeneration
        Task {
            defer {
                isDeletingTrash = false
                if isCurrent(generation) { isEmptyingTrash = false }
            }
            do {
                let result = try await emptyTrashUseCase.execute(ids: confirmation.ids)
                guard isCurrent(generation) else { return }
                itemSelection = nil
                if result.synced {
                    handleSyncCompleted(syncedAt: Date())
                } else {
                    refreshItems()
                    refreshCounts()
                }
                announcement = result.deleted == 1 ? "1 item permanently deleted" : "\(result.deleted) items permanently deleted"
                if result.remaining > 0 {
                    let count = result.remaining == 1 ? "1 item" : "\(result.remaining) items"
                    actionError = result.failure == .connection
                        ? "\(count) could not be deleted. Check your connection and try again."
                        : "\(count) could not be deleted. You may not have permission to delete them."
                }
            } catch {
                guard isCurrent(generation) else { return }
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: - Delete / Restore / Empty Trash

    /// Soft-deletes `id`, moving it to Trash.
    ///
    /// On success refreshes the active list and sidebar counts. If the deleted item was
    /// selected in the detail pane, it is deselected so the empty-state appears.
    /// Errors are surfaced via `actionError` for the Presentation layer to show as an alert.
    func performSoftDelete(id: String) async {
        do {
            try await deleteUseCase.execute(id: id)
            logger.info("Item soft-deleted: \(id, privacy: .public)")
            if itemSelection?.id == id {
                let idx = displayedItems.firstIndex(where: { $0.id == id })
                refreshItems()
                if let idx {
                    itemSelection = displayedItems.indices.contains(idx) ? displayedItems[idx]
                        : displayedItems.indices.contains(idx - 1) ? displayedItems[idx - 1]
                        : nil
                } else {
                    itemSelection = nil
                }
            } else {
                refreshItems()
            }
            refreshCounts()
        } catch {
            logger.error("Soft-delete failed for \(id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
            actionError = error.localizedDescription
        }
    }

    /// Restores the trashed item with `id` to the active vault.
    ///
    /// On success refreshes the list and sidebar counts. If the restored item was selected
    /// in the detail pane, deselects it (it has moved to the active vault).
    func performRestore(id: String) async {
        do {
            try await restoreUseCase.execute(id: id)
            logger.info("Item restored: \(id, privacy: .public)")
            if itemSelection?.id == id { itemSelection = nil }
            refreshItems()
            refreshCounts()
        } catch {
            logger.error("Restore failed for \(id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
            actionError = error.localizedDescription
        }
    }

    /// Permanently deletes the trashed item with `id`.
    ///
    /// The item must already be in Trash (`isDeleted == true`). Calls `DELETE /ciphers/{id}`
    /// via `PermanentDeleteVaultItemUseCase`, which permanently removes the cipher from the server.
    /// The caller is responsible for showing a confirmation alert before invoking this method.
    func performPermanentDelete(id: String) async {
        do {
            try await permanentDeleteUseCase.execute(id: id)
            logger.info("Item permanently deleted: \(id, privacy: .public)")
            if itemSelection?.id == id { itemSelection = nil }
            refreshItems()
            refreshCounts()
        } catch {
            logger.error("Permanent delete failed for \(id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
            actionError = error.localizedDescription
        }
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await createFolderUseCase.execute(name: trimmed)
                refreshFolders()
                refreshCounts()
            } catch {
                logger.error("Create folder failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

    func renameFolder(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await renameFolderUseCase.execute(id: id, name: trimmed)
                refreshFolders()
            } catch {
                logger.error("Rename folder failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

    func deleteFolder(id: String) {
        Task {
            do {
                let wasSelected = if case .folder(let fid) = sidebarSelection { fid == id } else { false }
                try await deleteFolderUseCase.execute(id: id)
                if wasSelected { sidebarSelection = .allItems }
                refreshFolders()
                refreshItems()
                refreshCounts()
            } catch {
                logger.error("Delete folder failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

    func moveItemsToFolder(itemIds: [String], folderId: String) {
        Task {
            do {
                if itemIds.count == 1, let id = itemIds.first {
                    try await moveItemUseCase.execute(itemId: id, folderId: folderId)
                } else {
                    try await moveItemUseCase.execute(itemIds: itemIds, folderId: folderId)
                }
                refreshItems()
                refreshCounts()
            } catch {
                logger.error("Move to folder failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: - Refresh

    func refreshFolders() {
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await vault.folders()
                guard isCurrent(generation) else { return }
                folders = loaded
            } catch {
                logger.error("Failed to load folders: \(ErrorLog.describe(error), privacy: .public)")
            }
        }
    }

    func refreshOrganizations() {
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let loadedOrganizations = try await vault.organizations()
                let loadedCollections   = try await vault.collections()
                guard isCurrent(generation) else { return }
                organizations = loadedOrganizations
                collections   = loadedCollections
            } catch {
                logger.error("Failed to load organizations: \(ErrorLog.describe(error), privacy: .public)")
            }
        }
    }

    // MARK: - Collection CRUD

    func createCollection(name: String, organizationId: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await createCollectionUseCase.execute(name: trimmed, organizationId: organizationId)
                refreshOrganizations()
                refreshCounts()
            } catch {
                logger.error("Create collection failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

    func renameCollection(id: String, organizationId: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await renameCollectionUseCase.execute(collectionId: id, name: trimmed,
                                                               organizationId: organizationId)
                refreshOrganizations()
                refreshCounts()
            } catch {
                logger.error("Rename collection failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

    func deleteCollection(id: String, organizationId: String) {
        Task {
            do {
                let wasSelected = if case .collection(let cid) = sidebarSelection { cid == id } else { false }
                try await deleteCollectionUseCase.execute(collectionId: id, organizationId: organizationId)
                if wasSelected { sidebarSelection = .allItems }
                refreshOrganizations()
                refreshCounts()
            } catch {
                logger.error("Delete collection failed: \(ErrorLog.describe(error), privacy: .public)")
                actionError = error.localizedDescription
            }
        }
    }

}
