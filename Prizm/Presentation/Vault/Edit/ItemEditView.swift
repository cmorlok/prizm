import AppKit
import SwiftUI

// MARK: - ItemEditView

/// Modal sheet container for editing a vault item.
///
/// Owns the Save and Discard toolbar buttons, the per-type edit form, and the inline
/// error banner shown on save failure. Sheet presentation is managed by the caller
/// (`ItemDetailView`) which toggles `isPresented` based on `viewModel.isDismissed`.
///
/// Keyboard shortcuts:
/// - ⌘S: Save (wired via `.keyboardShortcut` on the Save button)
/// - ⌘E: No-op (sheet is already open; handled in ItemDetailView)
/// - Esc: Triggers the same discard logic as the Discard button (via `.onExitCommand`)
struct ItemEditView: View {

    @ObservedObject var viewModel: ItemEditViewModel

    /// Drives sheet dismissal from the parent.
    @Binding var isPresented: Bool

    /// Called when the user confirms deletion from the edit sheet.
    var onDelete: ((String) async -> Void)? = nil

    /// Whether the discard confirmation alert is currently showing.
    @State private var showingDiscardAlert = false
    /// Whether the delete confirmation alert is currently showing.
    @State private var showingDeleteAlert = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            // Error banner — shown when a save fails or the item changed elsewhere.
            saveErrorBanner

            // Name field — always the first editable field regardless of item type (spec §3.1).
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $viewModel.draft.name)
                    .font(Typography.pageTitle)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Spacing.pageMargin)
                    .padding(.top, Spacing.pageTop)
                    .padding(.bottom, 4)

                // Live validation: shown immediately when Name field becomes empty (spec §3.2).
                if let nameError = viewModel.nameValidationError {
                    Text(nameError)
                        .font(Typography.utility)
                        .foregroundStyle(.red)
                        .padding(.horizontal, Spacing.pageMargin)
                }
            }
            .padding(.bottom, Spacing.pageHeaderBottom)

            // Collections — shown for org items. Folder picker — shown for every item when
            // folders exist: folders are personal and also hold org items, as in the official item
            // form (org-items-in-personal-folders).
            if viewModel.draft.organizationId != nil {
                collectionsCard
            }
            if !viewModel.folders.isEmpty {
                DetailSectionCard("Folder") {
                    HStack {
                        Picker(selection: $viewModel.draft.folderId) {
                            Text("None").tag(String?.none)
                            ForEach(viewModel.folders) { folder in
                                Text(folder.name).tag(Optional(folder.id))
                            }
                        } label: { EmptyView() }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Folder")
                        Spacer()
                    }
                    .padding(.vertical, Spacing.rowVertical)
                    .padding(.horizontal, Spacing.rowHorizontal)
                }
            }

            Divider()

            // Per-type edit form.
            typeEditForm

            // Delete button — shown only when editing an existing item (not during creation).
            // Hidden once the item is gone: there is nothing left on the server to delete.
            if viewModel.isEditing, onDelete != nil, !viewModel.isItemGone {
                Button("Delete Item") {
                    showingDeleteAlert = true
                }
                .foregroundStyle(.red)
                .padding(.vertical, Spacing.cardTop)
                .padding(.horizontal, Spacing.pageMargin)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier(AccessibilityID.Edit.deleteButton)
            }
        }
        .frame(minWidth: 480, minHeight: 400, idealHeight: Spacing.editSheetIdealHeight)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard") {
                    handleDiscard()
                }
                .disabled(viewModel.isSaving)
                .help("Discard changes (Esc)")
                .accessibilityIdentifier(AccessibilityID.Edit.discardButton)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.isSaving ? "Saving…" : "Save") {
                    viewModel.save()
                }
                .disabled(!viewModel.canSave)
                // While a conflict blocks Save, say why for VoiceOver and the pointer.
                .accessibilityHint(viewModel.saveBlockedHint ?? "")
                .help(viewModel.saveBlockedHint ?? "")
                // ⌘S triggers save while this sheet is open and the form is valid (spec §6.1).
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier(AccessibilityID.Edit.saveButton)
            }
        }
        // Esc key invokes the same discard logic as the Discard button (spec §8.3).
        .onExitCommand {
            handleDiscard()
        }
        // Discard confirmation alert (spec §8.3).
        .alert("Discard Changes?", isPresented: $showingDiscardAlert) {
            Button("Discard Changes", role: .destructive) {
                viewModel.discard()
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your unsaved changes will be lost.")
        }
        // Delete confirmation alert — dismiss sheet then execute soft-delete.
        .alert("Move to Trash?", isPresented: $showingDeleteAlert) {
            Button("Move to Trash", role: .destructive) {
                let itemId = viewModel.draft.id
                viewModel.discard()
                if let onDelete {
                    Task { await onDelete(itemId) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\"\(viewModel.draft.name)\" will be moved to Trash.")
        }
        // The banner alone is not read out, so announce what changes in it (§VIII). The observed
        // value is the displayed message, not `saveError`: the item-gone note replaces the
        // conflict message without passing through `saveError`. The sync after a conflict often
        // ends while the message is still being read, and a later announcement at default
        // priority cuts off an earlier one, so the message goes out at high priority (never
        // interrupted) and the status below at low priority (queued until the message is read).
        .onChange(of: viewModel.bannerMessage) { _, message in
            if let message { Self.announce(message, priority: .high) }
        }
        // "Synced" or the sync error. Nil while syncing, so "Syncing…" never cuts off the message.
        .onChange(of: viewModel.conflictStatusAnnouncement) { _, status in
            if let status { Self.announce(status, priority: .low) }
        }
        // A reload refills the fields without any visible event for VoiceOver.
        .onChange(of: viewModel.reloadCount) { _, _ in
            AccessibilityNotification.Announcement(ItemEditViewModel.reloadAnnouncement).post()
        }
        // Dismiss the sheet when the ViewModel signals it (save success or discard).
        .onChange(of: viewModel.isDismissed) { _, dismissed in
            if dismissed { isPresented = false }
        }
    }

    // MARK: - Announcements

    /// Posts through AppKit because macOS VoiceOver ignores the priority that SwiftUI's
    /// `AccessibilityNotification.Announcement` carries in its attributed string.
    private static func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: priority.rawValue]
        )
    }

    // MARK: - Error banner

    /// The banner above the form. Generic errors show only the message row; a conflict adds an
    /// action row below it with the reload (or Close) button first and the sync status after it,
    /// so the visual order equals the VoiceOver order. Nothing has a fixed height: the banner
    /// grows with wrapped text and the text size.
    @ViewBuilder
    private var saveErrorBanner: some View {
        if let message = viewModel.bannerMessage {
            VStack(alignment: .leading, spacing: Spacing.bannerContentGap) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.bannerContentGap) {
                    // The message says it all; the icon is decoration.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(Typography.fieldValue)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }

                if let title = viewModel.conflictActionTitle {
                    HStack(spacing: Spacing.bannerContentGap) {
                        // Plain bordered, not prominent or destructive: reload discards typed text,
                        // so it must not look like the primary action, and red text on the red
                        // banner is hard to read. No shortcut and not the default action.
                        Button(title) {
                            viewModel.performConflictAction()
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .disabled(!viewModel.isConflictActionEnabled)
                        .accessibilityHint(viewModel.conflictActionHint ?? "")
                        .accessibilityIdentifier(
                            viewModel.isItemGone
                                ? AccessibilityID.Edit.conflictCloseButton
                                : AccessibilityID.Edit.conflictReloadButton
                        )

                        // Progress and success are in the status text; the symbols only decorate it.
                        switch viewModel.conflict {
                        case .syncing:
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        case .synced:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        case .none, .syncFailed, .itemGone, .accessLost, .createdButUnconfirmed:
                            EmptyView()
                        }

                        if let status = viewModel.conflictStatusText {
                            // Lower priority than the button: the status wraps before the button truncates.
                            Text(status)
                                .font(Typography.bannerText)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(-1)
                                .accessibilityIdentifier(AccessibilityID.Edit.conflictStatus)
                        }

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, Spacing.bannerHorizontal)
            .padding(.vertical, Spacing.bannerVertical)
            .background(Color.red.opacity(Opacity.errorBanner(contrast)))
            // Keep message, button and status as separate elements; merged, the button would be
            // unreachable for VoiceOver.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Edit.errorBanner)
        }
    }

    // MARK: - Per-type dispatch

    /// Generate and import for a new SSH key; nil when editing (ssh-key-import-and-generation, D6).
    private var sshKeyCreateActions: SSHKeyCreateActions? {
        guard viewModel.offersSSHKeyActions else { return nil }
        return SSHKeyCreateActions(
            generate: { viewModel.generateSSHKey() },
            importFromClipboard: { importSSHKeyFromPasteboard() },
            importFromFile: { viewModel.importSSHKey(fromFile: $0) },
            importFailed: { viewModel.sshKeyFileImportFailed($0) },
            message: viewModel.sshKeyMessage,
            refusalCount: viewModel.sshKeyRefusalCount
        )
    }

    /// Read only when the user chooses "From clipboard". A key file copied in Finder is a file URL,
    /// not text, so that file is imported instead (design D4). The pasteboard is not cleared: its
    /// content is the user's (design D7).
    private func importSSHKeyFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            viewModel.importSSHKey(fromFile: url)
        } else {
            viewModel.importSSHKey(text: pasteboard.string(forType: .string) ?? "")
        }
    }

    /// The organization item's collections as checkboxes (fix-collection-assignment, D3): the
    /// writable ones of its organization, then the read-only assignments, checked and disabled. The
    /// view model builds the saved list, so assignments the user cannot change are never dropped.
    /// The rows scroll once they pass `Spacing.collectionListMaxHeight`, because the card sits in the
    /// sheet's fixed header.
    private var collectionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailSectionCard("Collections") {
                if viewModel.writableCollections.isEmpty {
                    Text(ItemEditViewModel.noWritableCollectionNote)
                        .font(Typography.fieldValue)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Spacing.rowVertical)
                        .padding(.horizontal, Spacing.rowHorizontal)
                }
                ViewThatFits(in: .vertical) {
                    collectionRows
                    ScrollView { collectionRows }
                }
                .frame(maxHeight: Spacing.collectionListMaxHeight)
            }
            if let hint = viewModel.collectionHint {
                Text(hint)
                    .font(Typography.utility)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.pageMargin)
                    .padding(.bottom, Spacing.cardBottom)
                    .accessibilityIdentifier(AccessibilityID.Edit.collectionHint)
            }
        }
    }

    private var collectionRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.writableCollections) { collection in
                Toggle(isOn: Binding(
                    get: { viewModel.isCollectionChecked(collection.id) },
                    set: { viewModel.setCollection(collection.id, checked: $0) }
                )) {
                    Text(collection.name).font(Typography.fieldValue)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(collection.name)
                .accessibilityIdentifier(AccessibilityID.Edit.collectionCheckbox(collection.id))
                .padding(.vertical, Spacing.rowVertical)
                .padding(.horizontal, Spacing.rowHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(viewModel.readOnlyAssignments) { collection in
                Toggle(isOn: .constant(true)) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(collection.name).font(Typography.fieldValue)
                        Text(ItemEditViewModel.readOnlyCollectionNote)
                            .font(Typography.fieldLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(true)
                .accessibilityLabel(collection.name)
                .accessibilityHint(ItemEditViewModel.readOnlyCollectionHint)
                .accessibilityIdentifier(AccessibilityID.Edit.collectionCheckbox(collection.id))
                .padding(.vertical, Spacing.rowVertical)
                .padding(.horizontal, Spacing.rowHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var typeEditForm: some View {
        switch viewModel.draft.content {
        case .login(let content):
            // Use a local binding projected from the draft's associated value.
            LoginEditForm(draft: Binding(
                get:  {
                    guard case .login(let c) = viewModel.draft.content else { return content }
                    return c
                },
                set:  { newContent in viewModel.draft.content = .login(newContent) }
            ))

        case .card(let content):
            CardEditForm(draft: Binding(
                get:  {
                    guard case .card(let c) = viewModel.draft.content else { return content }
                    return c
                },
                set:  { newContent in viewModel.draft.content = .card(newContent) }
            ))

        case .identity(let content):
            IdentityEditForm(draft: Binding(
                get:  {
                    guard case .identity(let c) = viewModel.draft.content else { return content }
                    return c
                },
                set:  { newContent in viewModel.draft.content = .identity(newContent) }
            ))

        case .secureNote(let content):
            SecureNoteEditForm(draft: Binding(
                get:  {
                    guard case .secureNote(let c) = viewModel.draft.content else { return content }
                    return c
                },
                set:  { newContent in viewModel.draft.content = .secureNote(newContent) }
            ))

        case .sshKey(let content):
            SSHKeyEditForm(draft: Binding(
                get:  {
                    guard case .sshKey(let c) = viewModel.draft.content else { return content }
                    return c
                },
                set:  { newContent in viewModel.draft.content = .sshKey(newContent) }
            ), itemId: viewModel.draft.id, createActions: sshKeyCreateActions)
        }
    }

    // MARK: - Discard logic

    /// Handles both the Discard button press and the Esc key.
    ///
    /// - If no changes have been made: dismiss immediately without a prompt (spec §8.3 "no changes" scenario).
    /// - If unsaved changes exist: show the confirmation alert first (spec §8.3 "with changes" scenario).
    private func handleDiscard() {
        if viewModel.asksBeforeDiscard {
            showingDiscardAlert = true
        } else {
            viewModel.discard()
        }
    }
}
