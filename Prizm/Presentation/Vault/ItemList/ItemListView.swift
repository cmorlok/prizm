import SwiftUI

// MARK: - ItemListView

/// Middle-column list of vault items for the currently selected sidebar category (FR-040).
///
/// Items are already pre-sorted by `VaultRepositoryImpl`; this view renders them as-is.
/// An empty state message is shown when the list is empty (FR-042).
/// Each row has a context menu with a "Delete" action that moves the item to Trash.
struct ItemListView: View {

    let items:         [VaultItem]
    @Binding var selection: VaultItem?
    let faviconLoader: FaviconLoader
    var searchQuery:   String? = nil
    /// Organizations list for resolving org names shown on item rows (6.1).
    var organizations: [Organization] = []
    /// Called when the user confirms moving an item to Trash from the row context menu.
    /// Nil disables the delete context-menu action (e.g. when trash actions are unavailable).
    var onDelete: ((String) async -> Void)? = nil
    var onToggleFavorite: ((VaultItem) -> Void)? = nil
    /// Archives (`true`) or unarchives an item; nil for an item it is not offered on (archived-items).
    var onSetArchived: ((VaultItem) -> ((Bool) async -> Void)?)? = nil

    // Tracks which item is pending a soft-delete confirmation alert.
    @State private var itemToDelete:    VaultItem? = nil
    @State private var showDeleteAlert: Bool       = false

    /// Keyboard focus for the list, so the arrow keys move the selection (fix-ui-journey-findings).
    @FocusState private var isListFocused: Bool

    private var sections: [(letter: String, items: [VaultItem])] {
        let grouped = Dictionary(grouping: items) { item in
            let first = item.name.first.map { String($0).uppercased() } ?? "#"
            return first.first?.isLetter == true ? first : "#"
        }
        return grouped.sorted { lhs, rhs in
            if lhs.key == "#" { return false }
            if rhs.key == "#" { return true }
            return lhs.key < rhs.key
        }.map { (letter: $0.key, items: $0.value) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Items",
                    systemImage: "tray",
                    description: Text("No items in this category.")
                )
                .accessibilityIdentifier(AccessibilityID.ItemList.emptyState)
            } else {
                List(selection: $selection) {
                    ForEach(sections, id: \.letter) { section in
                        Section(header: Text(section.letter)) {
                            ForEach(section.items, id: \.id) { item in
                                ItemRowView(item: item, faviconLoader: faviconLoader, searchQuery: searchQuery,
                                            orgName: orgName(for: item))
                                    .tag(item)
                                    .draggable(item.id)
                                    .accessibilityIdentifier(AccessibilityID.ItemList.row(item.id))
                                    .contextMenu {
                                        if let onToggleFavorite {
                                            Button(item.isFavorite ? "Unfavorite" : "Favorite") {
                                                onToggleFavorite(item)
                                            }
                                        }
                                        if let setArchived = onSetArchived?(item) {
                                            Button(item.isArchived ? "Unarchive" : "Archive") {
                                                Task { await setArchived(!item.isArchived) }
                                            }
                                        }
                                        if onDelete != nil {
                                            Button("Delete", role: .destructive) {
                                                itemToDelete    = item
                                                showDeleteAlert = true
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
                .focused($isListFocused)
                // A click on a row does not make the list the first responder: `.draggable` lets
                // SwiftUI handle the click itself, so the arrow keys went to whichever view had
                // focus before. Focus the list on every click.
                .simultaneousGesture(TapGesture().onEnded { isListFocused = true })
                // Soft-delete confirmation alert — shown when the user selects "Delete"
                // from a row context menu. The item is only moved to Trash, not permanently
                // deleted; it can be recovered from the Trash view.
                .alert(
                    "Move to Trash?",
                    isPresented: $showDeleteAlert,
                    presenting:  itemToDelete
                ) { item in
                    Button("Move to Trash", role: .destructive) {
                        Task { await onDelete?(item.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { item in
                    Text("\"\(item.name)\" will be moved to Trash.")
                }
            }
        }
    }

    /// Returns the org name for a vault item, or nil for personal items.
    private func orgName(for item: VaultItem) -> String? {
        guard let orgId = item.organizationId else { return nil }
        return organizations.first(where: { $0.id == orgId })?.name
    }
}
