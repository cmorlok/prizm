import XCTest
@testable import Prizm

/// The "Convert all" notice and its progress (openspec change fix-attachment-file-format, task 4.1).
@MainActor
final class AttachmentConversionViewModelTests: XCTestCase {

    private var convert: RecordingConvertUseCase!
    private var changed: [String] = []
    private var sut: AttachmentConversionViewModel!

    override func setUp() async throws {
        convert = RecordingConvertUseCase()
        changed = []
        sut = AttachmentConversionViewModel(convert: convert, onItemChanged: { [weak self] in self?.changed.append($0) })
    }

    private func attachment(_ id: String, legacy: Bool = true, flagged: Bool = false) -> Attachment {
        Attachment(id: id, fileName: "\(id).pdf", encryptedKey: "2.k|k|k", size: 1072, sizeName: "1 KB",
                   url: nil, wrappedWithPersonalKey: flagged, storedInLegacyPrizmFormat: legacy)
    }

    private func item(_ id: String, _ attachments: [Attachment], deleted: Bool = false) -> VaultItem {
        VaultItem(id: id, name: id, isFavorite: false, isDeleted: deleted, creationDate: Date(), revisionDate: Date(),
                  content: .secureNote(SecureNoteContent(notes: nil, customFields: [])), attachments: attachments)
    }

    // MARK: - Notice

    func testSyncWithOldAttachments_showsTheNoticeOnce() {
        let items = [item("a", [attachment("1"), attachment("2", legacy: false)]),
                     item("b", [attachment("3", legacy: false, flagged: true)]),
                     item("c", [attachment("4", legacy: false)]),
                     item("trashed", [attachment("5")], deleted: true)]

        sut.vaultDidSync(items: items)

        XCTAssertEqual(sut.phase, .notice(count: 2))
        XCTAssertEqual(sut.noticeText,
                       "2 attachments were saved by an earlier Prizm version and can't be opened in other Bitwarden apps.")
        sut.later()
        XCTAssertNil(sut.phase)
        sut.vaultDidSync(items: items)
        XCTAssertNil(sut.phase, "Once per unlock")
    }

    func testNewSession_showsTheNoticeAgain() {
        let items = [item("a", [attachment("1")])]
        sut.vaultDidSync(items: items)
        sut.later()

        sut.resetSession()
        sut.vaultDidSync(items: items)

        XCTAssertEqual(sut.phase, .notice(count: 1))
    }

    func testSyncWithoutOldAttachments_showsNothing() {
        sut.vaultDidSync(items: [item("a", [attachment("1", legacy: false)])])
        XCTAssertNil(sut.phase)
    }

    // MARK: - Convert all

    func testConvertAll_convertsOneAtATime_andListsFailures() async {
        sut.vaultDidSync(items: [item("a", [attachment("1"), attachment("2")]), item("b", [attachment("3")])])
        convert.failing = ["2"]
        convert.onExecute = { [unowned self] in
            if case .converting(let done, let total) = sut.phase {
                convert.progressSeen.append("\(done) of \(total)")
            }
        }

        await sut.convertAll()

        XCTAssertEqual(convert.executed, ["1", "2", "3"])
        XCTAssertEqual(convert.progressSeen, ["0 of 3", "1 of 3", "2 of 3"])
        XCTAssertEqual(sut.phase, .finished(converted: 2, failures: ["2.pdf: Upload failed."]))
        XCTAssertEqual(changed, ["a", "b"], "Every item that was written is refreshed")
    }

    func testCancel_stopsBetweenFiles() async {
        sut.vaultDidSync(items: [item("a", [attachment("1"), attachment("2"), attachment("3")])])
        convert.onExecute = { [unowned self] in
            if convert.executed.count == 1 { sut.cancel() }
        }

        await sut.convertAll()

        XCTAssertEqual(convert.executed, ["1"], "The running file finishes, no next one starts")
        XCTAssertEqual(sut.phase, .finished(converted: 1, failures: []))
    }

    /// A lock during "Convert all" ends that run without touching the next session (review
    /// 2026-10-30): no second pass over the old list, no result sheet over the new notice.
    func testLockDuringConvertAll_stopsThatRun_andLeavesTheNextSessionAlone() async {
        let items = [item("a", [attachment("1"), attachment("2"), attachment("3")])]
        sut.vaultDidSync(items: items)
        convert.onExecute = { [unowned self] in
            if convert.executed.count == 1 {
                // Lock, unlock, and the next sync shows the notice again, all while file 1 converts.
                sut.resetSession()
                sut.vaultDidSync(items: [item("b", [attachment("9")])])
            }
        }

        await sut.convertAll()

        XCTAssertEqual(convert.executed, ["1"], "The old run stops after its current file")
        XCTAssertEqual(sut.phase, .notice(count: 1), "The new session's notice stays")
        XCTAssertEqual(sut.noticeText, "1 attachment was saved by an earlier Prizm version and can't be opened in other Bitwarden apps.")
    }

    func testConvertAll_twice_runsOnce() async {
        sut.vaultDidSync(items: [item("a", [attachment("1"), attachment("2")])])
        var second: Task<Void, Never>?
        convert.onExecute = { [unowned self] in
            if convert.executed.count == 1 { second = Task { await self.sut.convertAll() } }
        }

        await sut.convertAll()
        await second?.value

        XCTAssertEqual(convert.executed, ["1", "2"], "The second press while converting starts nothing")
    }

    func testDone_hidesTheSheet() async {
        sut.vaultDidSync(items: [item("a", [attachment("1")])])
        await sut.convertAll()
        sut.done()
        XCTAssertNil(sut.phase)
    }
}

/// Records conversions; ids in `failing` throw.
final class RecordingConvertUseCase: ConvertAttachmentUseCase, @unchecked Sendable {
    var executed: [String] = []
    var failing: Set<String> = []
    var progressSeen: [String] = []
    var onExecute: (@MainActor () -> Void)?

    func execute(cipherId: String, attachment: Attachment) async throws -> Attachment {
        executed.append(attachment.id)
        await onExecute?()
        if failing.contains(attachment.id) { throw TestConvertError() }
        return Attachment(id: "new-\(attachment.id)", fileName: attachment.fileName, encryptedKey: "2.n|n|n",
                          size: attachment.size + 1, sizeName: attachment.sizeName, url: nil)
    }
}

private struct TestConvertError: LocalizedError {
    var errorDescription: String? { "Upload failed." }
}
