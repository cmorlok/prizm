import Combine
import Foundation
import os.log
import SwiftUI

// MARK: - ItemEditViewModel

/// ViewModel for the item edit sheet. Owns the mutable `DraftVaultItem`, orchestrates
/// the async save call, and coordinates discard confirmation and vault-lock dismissal.
///
/// Lifecycle:
/// 1. Created with an existing `VaultItem` when the edit sheet opens.
/// 2. The view binds to `draft` — changes are reflected immediately in the form.
/// 3. `save()` is called when the user presses Save / ⌘S.
/// 4. On success: `isDismissed` is set to `true`; the caller dismisses the sheet.
/// 5. On dismiss (save or discard): the caller should call `clearDraft()` to satisfy
///    Constitution §III (plaintext minimisation for in-memory secret data).
/// 6. On vault lock: `isDismissed` is set immediately without confirmation.
@MainActor
final class ItemEditViewModel: ObservableObject {

    // MARK: - Published state

    /// The mutable draft being edited. Bound directly to form fields.
    @Published var draft: DraftVaultItem

    /// `true` while the save request is in-flight. Used to disable Save / ⌘S and
    /// change the Save button label to "Saving…". Set synchronously in `save()`, so a second
    /// click or ⌘S in the same run-loop turn finds `canSave` false and sends nothing.
    @Published private(set) var isSaving: Bool = false

    /// Where the sheet stands after the server rejected a save because the item changed
    /// elsewhere. Only an explicit reload leaves a conflict state; Save never does.
    ///
    /// - `none`: no conflict. The sheet shows no error, or a save error that Save may retry.
    /// - `syncing`: the vault is syncing to learn what the server holds.
    /// - `synced`: the sync worked and the item still exists; reload can refill the sheet.
    /// - `syncFailed`: the sync failed with this message; reload starts a new sync.
    /// - `itemGone`: the synced vault no longer has the item, or has it in Trash.
    enum ConflictState: Equatable {
        case none
        case syncing
        case synced
        case syncFailed(String)
        case itemGone
    }

    /// The conflict state; `.none` outside a conflict.
    @Published private(set) var conflict: ConflictState = .none

    /// Non-nil when the save request failed. Shown as an inline error banner.
    @Published private(set) var saveError: String? = nil

    /// Set to `true` to signal the enclosing sheet to dismiss.
    @Published private(set) var isDismissed: Bool = false

    // MARK: - Derived state

    /// `true` when the Name field is non-empty, no save is in-flight and no conflict is open.
    ///
    /// The conflict check lives here and not in the toolbar button: Item > Save and its shortcut
    /// reach `save()` through the vault browser without the button, so only this guard blocks them.
    var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving && conflict == .none
    }

    /// Non-nil when `draft.name` is blank, triggering inline validation.
    var nameValidationError: String? {
        draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Name is required" : nil
    }

    // MARK: - Banner texts and flags
    //
    // The view only binds these, so every state of the conflict banner is unit-tested here. The
    // strings are the product copy for the edit sheet.

    /// Replaces the conflict message when the synced vault no longer has the item. One text for
    /// deleted, trashed and revoked access, because Prizm cannot tell them apart.
    static let itemGoneNote =
        "This item is no longer available. It was deleted or moved on another device, or your access was removed."

    /// Announced after a reload refills the sheet, because the fields change silently.
    static let reloadAnnouncement = "Reloaded the latest version."

    /// Counts completed reloads; the view announces `reloadAnnouncement` when it increases.
    @Published private(set) var reloadCount = 0

    /// The message the banner shows, or nil for no banner (never an empty banner).
    var bannerMessage: String? {
        if conflict == .itemGone { return Self.itemGoneNote }
        guard let saveError, !saveError.isEmpty else { return nil }
        return saveError
    }

    /// The status line next to the conflict action: progress, success or the sync error.
    var conflictStatusText: String? {
        switch conflict {
        case .none, .itemGone:       return nil
        case .syncing:               return "Syncing…"
        case .synced:                return "Synced"
        case .syncFailed(let text):  return text.isEmpty ? nil : text
        }
    }

    /// What VoiceOver announces when the status line changes. "Syncing…" is not announced: it
    /// would cut off the conflict message that was just read.
    var conflictStatusAnnouncement: String? {
        conflict == .syncing ? nil : conflictStatusText
    }

    /// The label of the banner button, or nil when the banner has none.
    var conflictActionTitle: String? {
        switch conflict {
        case .none:                          return nil
        case .syncing, .synced, .syncFailed: return "Discard my changes and reload"
        case .itemGone:                      return "Close"
        }
    }

    /// `false` only while the sync runs; the button enables itself when the result arrives.
    var isConflictActionEnabled: Bool { conflict != .syncing }

    /// Why the button is disabled; only while syncing.
    var conflictActionHint: String? {
        conflict == .syncing ? "Available when the sync finishes." : nil
    }

    /// Why Save is disabled, for its accessibility hint and tooltip; nil when no conflict blocks it.
    var saveBlockedHint: String? {
        switch conflict {
        case .none:                          return nil
        case .syncing, .synced, .syncFailed: return "Reload the item first."
        case .itemGone:                      return "This item no longer exists."
        }
    }

    /// `true` when the synced vault no longer has the item; the view hides Delete Item.
    var isItemGone: Bool { conflict == .itemGone }

    /// `true` when any field differs from the original item captured at open time.
    /// Used to decide whether the discard confirmation prompt is needed.
    var hasChanges: Bool {
        draft != original
    }

    /// `true` when editing an existing item (as opposed to creating a new one).
    /// Used to conditionally show the Delete button in the edit sheet.
    var isEditing: Bool { editUseCase != nil }

    // MARK: - Private state

    /// Snapshot of the item as it was when the sheet opened — used for `hasChanges`.
    /// `var` so `clearDraft()` can overwrite it with a blank sentinel (Constitution §III).
    private var original: DraftVaultItem

    private let editUseCase: (any EditVaultItemUseCase)?
    private let createUseCase: (any CreateVaultItemUseCase)?
    private let logger  = Logger(subsystem: "com.prizm", category: "ItemEditViewModel")

    /// Called on save success with the server-confirmed `VaultItem` so the caller
    /// (VaultBrowserViewModel or parent) can refresh the list pane.
    var onSaveSuccess: ((VaultItem) -> Void)?

    /// Syncs the vault after a conflict and reports whether that worked. Set by the app for edit
    /// sheets only (a new item cannot conflict); the sheet has no sync use case of its own.
    var onConflict: (() async -> ConflictResync)?

    /// Looks up an item by id in the synced vault. Set by the app together with `onConflict`.
    var latestItem: ((String) async -> LatestItem)?

    /// Available folders for the folder picker in the edit sheet.
    let folders: [Folder]

    /// Available organizations — used to resolve collection org names.
    let organizations: [Organization]

    /// Collections available for the collection picker (all orgs).
    let collections: [OrgCollection]

    /// `true` while a reload looks up the synced item, so a second press cannot refill twice.
    private var isReloading = false

    /// Retain token for the vault-lock observer.
    private nonisolated(unsafe) var lockObserver: NSObjectProtocol?

    // MARK: - Init

    /// Edit mode: initialised with an existing item.
    init(item: VaultItem, useCase: any EditVaultItemUseCase, folders: [Folder] = [],
         organizations: [Organization] = [], collections: [OrgCollection] = []) {
        self.draft         = DraftVaultItem(item)
        self.original      = DraftVaultItem(item)
        self.editUseCase   = useCase
        self.createUseCase = nil
        self.folders       = folders
        self.organizations = organizations
        self.collections   = collections
        subscribeToVaultLock()
    }

    /// Create mode: initialised with a blank draft for the given type.
    init(type: ItemType, useCase: any CreateVaultItemUseCase, folders: [Folder] = [],
         folderId: String? = nil, organizationId: String? = nil, collectionIds: [String] = [],
         organizations: [Organization] = [], collections: [OrgCollection] = []) {
        var blank = DraftVaultItem.blank(type: type)
        blank.folderId       = folderId
        blank.organizationId = organizationId
        blank.collectionIds  = collectionIds
        self.draft         = blank
        self.original      = blank
        self.editUseCase   = nil
        self.createUseCase = useCase
        self.folders       = folders
        self.organizations = organizations
        self.collections   = collections
        subscribeToVaultLock()
    }

    // MARK: - Save

    /// Validates, calls the use case, handles success/failure.
    func save() {
        guard canSave else { return }
        // Marked in progress before the task starts: a second call in the same turn is refused by
        // `canSave` above, so one click sends one request.
        isSaving  = true
        saveError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let saved: VaultItem
                let toSave = draftToSave()
                if let createUseCase {
                    saved = try await createUseCase.execute(draft: toSave)
                } else if let editUseCase {
                    saved = try await editUseCase.execute(draft: toSave)
                } else {
                    preconditionFailure("ItemEditViewModel: no use case configured")
                }
                onSaveSuccess?(saved)
                clearDraft()
                isDismissed = true
                logger.info("Item saved: \(self.draft.id, privacy: .public)")
            } catch VaultError.conflict {
                // The sheet may have been dismissed by a lock while the request was out: show
                // nothing and sync nothing for a vault that is gone.
                if isDismissed {
                    logger.info("Conflict ignored: the sheet was dismissed meanwhile")
                    isSaving = false
                    return
                }
                saveError = VaultError.conflict.localizedDescription
                conflict  = .syncing
                // The save itself is over. During the sync Discard and Esc must work and Save
                // keeps its normal title; `conflict` keeps Save blocked.
                isSaving = false
                logger.info("Save rejected, item changed elsewhere: \(self.draft.id, privacy: .public)")
                await runConflictResync()
                return
            } catch VaultError.collectionChangeNotSaved {
                if isDismissed {
                    logger.info("Save error ignored: the sheet was dismissed meanwhile")
                } else {
                    saveError = VaultError.collectionChangeNotSaved.localizedDescription
                    logger.error("Save partly failed: the collection change was not saved")
                    await moveBaseToSavedItem()
                }
            } catch {
                if isDismissed {
                    logger.info("Save error ignored: the sheet was dismissed meanwhile")
                } else {
                    saveError = error.localizedDescription
                    logger.error("Save failed: \(ErrorLog.describe(error), privacy: .public)")
                }
            }
            isSaving = false
        }
    }

    /// Syncs through the vault browser, then moves `conflict` to `.synced`, `.syncFailed` or
    /// `.itemGone`. Never touches `isSaving`: a resync is not a save.
    private func runConflictResync() async {
        guard let onConflict, let latestItem else {
            // Create mode cannot conflict and the app wires both closures for edit sheets, so this
            // is a wiring mistake; the sheet stays blocked rather than refilling from nothing.
            logger.error("Conflict resync unavailable: closures not set")
            conflict = .syncFailed("")
            return
        }
        let id = draft.id
        let result = await onConflict()
        guard !isDismissed else { return }
        switch result {
        case .failed(let message):
            logger.error("Conflict resync failed")
            conflict = .syncFailed(message)
        case .synced:
            let latest = await latestItem(id)
            guard !isDismissed else { return }
            switch latest {
            case .gone:      conflict = .itemGone
            case .available: conflict = .synced
            }
        }
    }

    /// After an organization edit whose collection change failed: the item itself is saved, so the
    /// retry must be based on the saved revision, or it would be refused as a conflict with the
    /// user's own save. The draft keeps the user's input; `original` becomes the saved item, so the
    /// unsaved collection change still counts as a change. The list and detail show the saved item.
    private func moveBaseToSavedItem() async {
        guard let latestItem else {
            logger.error("Saved item lookup unavailable: closures not set")
            return
        }
        let latest = await latestItem(draft.id)
        guard !isDismissed else { return }
        guard case .available(let savedItem) = latest else {
            logger.error("Saved item not found after a partly failed save")
            return
        }
        draft.revisionDate = savedItem.revisionDate
        original = DraftVaultItem(savedItem)
        onSaveSuccess?(savedItem)
    }

    // MARK: - Conflict action

    /// The banner button: "Discard my changes and reload" or "Close".
    ///
    /// - `.synced`: refills draft and original from the synced item.
    /// - `.syncFailed`: starts a new sync; the sheet is never refilled from the copy the server
    ///   rejected or from a failed sync.
    /// - `.itemGone`: closes the sheet like Discard, without the alert (the user was told).
    /// - `.syncing`, `.none`: nothing.
    func performConflictAction() {
        switch conflict {
        case .none, .syncing:
            return
        case .syncFailed:
            // Set before the task starts, so a second press in the same turn finds `.syncing`.
            conflict = .syncing
            Task { @MainActor [weak self] in
                await self?.runConflictResync()
            }
        case .synced:
            guard !isReloading, let latestItem else { return }
            isReloading = true
            let id = draft.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { isReloading = false }
                let latest = await latestItem(id)
                guard !isDismissed else { return }
                switch latest {
                case .available(let item):
                    // The same overwrite `clearDraft()` uses, so the rejected draft's plaintext
                    // is dropped.
                    draft     = DraftVaultItem(item)
                    original  = DraftVaultItem(item)
                    saveError = nil
                    conflict = .none
                    reloadCount += 1
                    logger.info("Item reloaded after a conflict: \(item.id, privacy: .public)")
                case .gone:
                    conflict = .itemGone
                }
            }
        case .itemGone:
            discard()
        }
    }

    /// The draft in the format official clients write (card-field-normalisation).
    ///
    /// An edit that changes only folder and/or favorite is sent as is, so it stays a `/partial`
    /// save, which also works for items in read-only collections (org-items-in-personal-folders;
    /// same test as `VaultRepositoryImpl.update`). New items are always normalised.
    private func draftToSave() -> DraftVaultItem {
        if createUseCase == nil {
            var perUserChangeOnly = original
            perUserChangeOnly.folderId = draft.folderId
            perUserChangeOnly.isFavorite = draft.isFavorite
            if perUserChangeOnly == draft { return draft }
        }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return draft.normalisedForSave(currentYear: currentYear)
    }

    // MARK: - Discard

    /// Discards changes and signals the sheet to dismiss. Call only after confirming
    /// with the user when `hasChanges == true`.
    func discard() {
        clearDraft()
        isDismissed = true
    }

    // MARK: - Memory cleanup (Constitution §III)

    /// Clears the draft's plaintext field values from memory.
    ///
    /// Called on both the save path (after receiving the server response) and the discard
    /// path. Reduces the window during which plaintext passwords and other secrets are
    /// held in the heap. Swift ARC may retain additional copies; this removes the primary
    /// reference held by this ViewModel.
    func clearDraft() {
        // Replace both draft and original with a blank sentinel to release all
        // string values (passwords, keys, notes) from the heap (Constitution §III).
        // `original` must also be cleared — it holds a full snapshot of the item
        // as it was when the sheet opened, including any sensitive plaintext fields.
        let blank = DraftVaultItem(VaultItem(
            id: original.id,
            name: "",
            isFavorite: false,
            isDeleted: false,
            creationDate: original.creationDate,
            revisionDate: original.revisionDate,
            content: .secureNote(SecureNoteContent(notes: nil, customFields: []))
        ))
        draft    = blank
        original = blank
    }

    // MARK: - Vault lock observation

    private func subscribeToVaultLock() {
        lockObserver = NotificationCenter.default.addObserver(
            forName: .vaultDidLock,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Dismiss immediately — no confirmation prompt (spec §8.10).
                self?.clearDraft()
                self?.isDismissed = true
            }
        }
    }

    deinit {
        if let obs = lockObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
