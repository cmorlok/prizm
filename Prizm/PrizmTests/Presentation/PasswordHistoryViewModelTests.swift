import XCTest
@testable import Prizm

/// The history sheet's view model (openspec change `password-history`, task 4.1) and the footer
/// rules (task 5.1).
@MainActor
final class PasswordHistoryViewModelTests: XCTestCase {

    /// A use case whose answer the test releases, so it can lock or dismiss while the load runs.
    private final class GatedUseCase: GetPasswordHistoryUseCase, @unchecked Sendable {
        var entries: [PasswordHistoryEntry] = []
        var error: Error?
        var gate: CheckedContinuation<Void, Never>?
        var gated = false
        private(set) var requests: [String] = []

        func execute(itemId: String) async throws -> [PasswordHistoryEntry] {
            requests.append(itemId)
            if gated { await withCheckedContinuation { gate = $0 } }
            if let error { throw error }
            return entries
        }
    }

    private func date(_ day: Int) -> Date { Date(timeIntervalSince1970: 1_767_225_600 + Double(day) * 86_400) }

    private func makeViewModel(_ useCase: GatedUseCase) -> PasswordHistoryViewModel {
        PasswordHistoryViewModel(itemId: "item-1", useCase: useCase, formatDate: { "day \(Int($0.timeIntervalSince1970))" })
    }

    // MARK: - Load and sort

    func testLoad_sortsNewestFirst_unknownDatesLastInStoredOrder() async {
        let useCase = GatedUseCase()
        useCase.entries = [
            PasswordHistoryEntry(value: "b", lastUsedDate: date(1)),
            PasswordHistoryEntry(value: "x", lastUsedDate: nil),
            PasswordHistoryEntry(value: "c", lastUsedDate: date(3)),
            PasswordHistoryEntry(value: "a", lastUsedDate: date(1)),
            PasswordHistoryEntry(value: nil, lastUsedDate: nil),
        ]
        let vm = makeViewModel(useCase)

        await vm.load()

        XCTAssertEqual(useCase.requests, ["item-1"])
        XCTAssertEqual(vm.rows.map(\.value), ["c", "b", "a", "x", nil], "ties keep stored order")
        XCTAssertEqual(vm.rows.map(\.id), [0, 1, 2, 3, 4], "identifiers by row index")
        XCTAssertEqual(vm.rows[3].dateText, "Unknown date")
        XCTAssertEqual(vm.loadState, .loaded)
    }

    func testRowLabel_namesTheDate() async {
        let useCase = GatedUseCase()
        useCase.entries = [PasswordHistoryEntry(value: "a", lastUsedDate: date(1))]
        let vm = makeViewModel(useCase)
        await vm.load()
        XCTAssertEqual(vm.rows[0].accessibilityLabel, "History entry from \(vm.rows[0].dateText)")
    }

    func testLoad_failure_showsAMessageAndNoRows() async {
        let useCase = GatedUseCase()
        useCase.error = VaultError.itemKeyUnavailable
        let vm = makeViewModel(useCase)

        await vm.load()

        XCTAssertEqual(vm.rows, [])
        guard case .failed(let message) = vm.loadState else { return XCTFail("expected failed") }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Released on dismiss and lock

    func testDismiss_emptiesTheRows() async {
        let useCase = GatedUseCase()
        useCase.entries = [PasswordHistoryEntry(value: "secret", lastUsedDate: date(1))]
        let vm = makeViewModel(useCase)
        await vm.load()

        vm.dismiss()

        XCTAssertEqual(vm.rows, [])
        XCTAssertTrue(vm.isDismissed)
    }

    func testVaultLock_dismissesAndEmptiesTheRows() async {
        let useCase = GatedUseCase()
        useCase.entries = [PasswordHistoryEntry(value: "secret", lastUsedDate: date(1))]
        let vm = makeViewModel(useCase)
        await vm.load()

        NotificationCenter.default.post(name: .vaultDidLock, object: nil)
        let dismissed = expectation(description: "dismissed")
        Task { @MainActor in
            while !vm.isDismissed { await Task.yield() }
            dismissed.fulfill()
        }
        await fulfillment(of: [dismissed], timeout: 2)

        XCTAssertEqual(vm.rows, [])
    }

    /// Security review 2026-10-31: the rows are gone when the lock notification returns, not after a
    /// later main-actor turn in which a finishing load could still fill them.
    func testVaultLock_emptiesTheRowsBeforeThePostReturns() async {
        let useCase = GatedUseCase()
        useCase.entries = [PasswordHistoryEntry(value: "secret", lastUsedDate: date(1))]
        let vm = makeViewModel(useCase)
        await vm.load()

        NotificationCenter.default.post(name: .vaultDidLock, object: nil)

        XCTAssertTrue(vm.isDismissed)
        XCTAssertEqual(vm.rows, [])
    }

    func testResultAfterDismiss_isDropped() async {
        let useCase = GatedUseCase()
        useCase.gated = true
        useCase.entries = [PasswordHistoryEntry(value: "secret", lastUsedDate: date(1))]
        let vm = makeViewModel(useCase)

        let load = Task { await vm.load() }
        while useCase.gate == nil { await Task.yield() }
        vm.dismiss()
        useCase.gate?.resume()
        await load.value

        XCTAssertEqual(vm.rows, [], "the late result is not kept")
    }

    // MARK: - Footer rules (task 5.1)

    private func item(passwordRevisionDate: Date?, count: Int, isLogin: Bool = true) -> VaultItem {
        let content: ItemContent = isLogin
            ? .login(LoginContent(username: nil, password: "p", uris: [], totp: nil, notes: nil, customFields: [],
                                  passwordRevisionDate: passwordRevisionDate))
            : .secureNote(SecureNoteContent(notes: nil, customFields: []))
        return VaultItem(id: "i", name: "n", isFavorite: false, isDeleted: false,
                         creationDate: date(0), revisionDate: date(2), content: content,
                         passwordHistoryCount: count)
    }

    func testFooter_passwordUpdatedOnlyWithADate() {
        let with = ItemFooterModel(item: item(passwordRevisionDate: date(1), count: 0))
        XCTAssertEqual(with.rows.map(\.label), ["Password updated:", "Updated:", "Created:"])
        XCTAssertEqual(with.rows.first?.date, date(1))

        let without = ItemFooterModel(item: item(passwordRevisionDate: nil, count: 0))
        XCTAssertEqual(without.rows.map(\.label), ["Updated:", "Created:"])
    }

    func testFooter_historyButtonOnlyWithEntries() {
        XCTAssertNil(ItemFooterModel(item: item(passwordRevisionDate: nil, count: 0)).historyButtonTitle)
        XCTAssertEqual(ItemFooterModel(item: item(passwordRevisionDate: nil, count: 3)).historyButtonTitle,
                       "Password history: 3")
        XCTAssertEqual(ItemFooterModel(item: item(passwordRevisionDate: nil, count: 2, isLogin: false)).historyButtonTitle,
                       "Password history: 2", "hidden-field entries exist on any item type")
    }

    /// Security review 2026-10-31: a history the server grew beyond what clients keep scrolls.
    func testLongHistory_scrolls_usualOneDoesNot() {
        XCTAssertFalse(PasswordHistoryViewModel.scrolls(rowCount: 5), "what clients keep")
        XCTAssertFalse(PasswordHistoryViewModel.scrolls(rowCount: 10))
        XCTAssertTrue(PasswordHistoryViewModel.scrolls(rowCount: 11))
    }
}
