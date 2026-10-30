import Combine
import Foundation

/// The history sheet's state (openspec change `password-history`, design D1 and D3).
///
/// - Security goal: the decrypted entries live only while the sheet is open. They are released on
///   dismiss and on `.vaultDidLock` (the array is emptied; `String` cannot be zeroed, so the
///   guarantee is that no reference outlives the sheet), and a load that finishes after either is
///   dropped.
@MainActor
final class PasswordHistoryViewModel: ObservableObject, Identifiable {

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    struct Row: Equatable, Identifiable {
        /// The row's position on screen, used for accessibility identifiers: two entries saved in
        /// the same minute would collide on their date.
        let id: Int
        /// Nil for an entry that could not be read.
        let value: String?
        let dateText: String

        var accessibilityLabel: String { "History entry from \(dateText)" }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var isDismissed = false

    private let itemId: String
    private let useCase: any GetPasswordHistoryUseCase
    private let formatDate: (Date) -> String
    private nonisolated(unsafe) var lockObserver: NSObjectProtocol?

    /// `dd.MM.yyyy HH:mm` in the user's time zone (design D3).
    nonisolated static func defaultFormat(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }

    init(itemId: String, useCase: any GetPasswordHistoryUseCase,
         formatDate: @escaping (Date) -> String = PasswordHistoryViewModel.defaultFormat) {
        self.itemId = itemId
        self.useCase = useCase
        self.formatDate = formatDate
        lockObserver = NotificationCenter.default.addObserver(
            forName: .vaultDidLock, object: nil, queue: .main
        ) { [weak self] _ in
            // Dismissed in this turn, not a later one: a load finishing in between would otherwise
            // fill the rows after the lock (security review 2026-10-31). `queue: .main` makes this
            // the main actor.
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    deinit {
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    func load() async {
        do {
            let entries = try await useCase.execute(itemId: itemId)
            guard !isDismissed else { return }
            rows = Self.sorted(entries).enumerated().map { index, entry in
                Row(id: index, value: entry.value,
                    dateText: entry.lastUsedDate.map(formatDate) ?? "Unknown date")
            }
            loadState = .loaded
        } catch VaultError.vaultLocked {
            dismiss()
        } catch {
            guard !isDismissed else { return }
            // Logged by the repository with the item id; the sheet says what happened and stays.
            loadState = .failed("Prizm couldn't read this item's password history.")
        }
    }

    func dismiss() {
        rows = []
        isDismissed = true
    }

    /// More rows than fit `Spacing.historyListMaxHeight` scroll. Clients keep 5 entries, so only a
    /// history the server grew beyond what any client writes reaches this.
    static let maxUnscrolledRows = 10

    static func scrolls(rowCount: Int) -> Bool { rowCount > maxUnscrolledRows }

    /// Newest first; entries with the same date keep their stored order, and entries without a date
    /// follow in stored order. iOS appends new entries at the end, so stored order alone is not
    /// reliable.
    static func sorted(_ entries: [PasswordHistoryEntry]) -> [PasswordHistoryEntry] {
        let dated = entries.enumerated().filter { $0.element.lastUsedDate != nil }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.element.lastUsedDate!, rhs.element.lastUsedDate!)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
        return dated + entries.filter { $0.lastUsedDate == nil }
    }
}

/// What the detail footer shows (openspec change `password-history`, design D3): the dates, newest
/// first, and the history button when the server holds entries.
struct ItemFooterModel: Equatable {

    struct Row: Equatable {
        let label: String
        let date: Date
        let accessibilityID: String
    }

    let rows: [Row]
    /// Nil when the item has no history entries.
    let historyButtonTitle: String?

    init(item: VaultItem) {
        var rows: [Row] = []
        if case .login(let login) = item.content, let changed = login.passwordRevisionDate {
            rows.append(Row(label: "Password updated:", date: changed,
                            accessibilityID: AccessibilityID.Detail.passwordUpdatedDate))
        }
        rows.append(Row(label: "Updated:", date: item.revisionDate, accessibilityID: AccessibilityID.Detail.updatedDate))
        rows.append(Row(label: "Created:", date: item.creationDate, accessibilityID: AccessibilityID.Detail.createdDate))
        self.rows = rows
        historyButtonTitle = item.passwordHistoryCount > 0 ? "Password history: \(item.passwordHistoryCount)" : nil
    }
}
