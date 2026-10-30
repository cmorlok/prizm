import XCTest
@testable import Prizm

/// Unit tests for `AttachmentRowViewModel` (task 7.5; fix-attachment-transfer-flow).
///
/// Covers: Open error path, Save to Disk cancel (no download triggered), Delete confirm
/// vs cancel, and the missing-file state.
@MainActor
final class AttachmentRowViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private let cipherId      = "cipher-abc"
    private let plainData     = Data("decrypted file content".utf8)
    private var mockDownload: MockRowDownloadUseCase!
    private var mockDelete:   MockRowDeleteUseCase!
    private var mockTempMgr:  MockTempFileManager!

    private var normalAttachment: Attachment!

    override func setUp() async throws {
        mockDownload = MockRowDownloadUseCase()
        mockDelete   = MockRowDeleteUseCase()
        mockTempMgr  = MockTempFileManager()

        normalAttachment = Attachment(
            id: "att-1", fileName: "report.pdf", encryptedKey: "2.a|b|c",
            size: 1024, sizeName: "1 KB", url: "https://cdn.example.com/blob"
        )
    }

    override func tearDown() async throws {
        for url in mockTempMgr.written { try? FileManager.default.removeItem(at: url) }
    }

    private var fileOpenerCalled = false

    private func makeSUT(attachment: Attachment? = nil,
                         fileSaver: (@MainActor (String) -> URL?)? = nil) -> AttachmentRowViewModel {
        AttachmentRowViewModel(
            cipherId:        cipherId,
            attachment:      attachment ?? normalAttachment,
            downloadUseCase: mockDownload,
            deleteUseCase:   mockDelete,
            tempFileManager: mockTempMgr,
            fileSaver:       fileSaver ?? { _ in nil },
            fileOpener:      { [weak self] _ in self?.fileOpenerCalled = true }
        )
    }

    // MARK: - Open

    func test_open_successfulDownload_opensFile() async throws {
        mockDownload.result = .success(plainData)
        let sut = makeSUT()

        sut.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(mockTempMgr.registerCalled)
        XCTAssertNil(sut.actionError)
    }

    func test_open_downloadFailure_setsActionError() async throws {
        mockDownload.result = .failure(AttachmentError.downloadFailed)
        let sut = makeSUT()

        sut.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(sut.actionError)
        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - Save to Disk

    func test_saveToDisk_userCancelsPanel_noDownloadTriggered() async throws {
        // Return nil from fileSaver to simulate panel cancel.
        // saveToDisk() sets isLoading synchronously then dispatches a Task, so we
        // must await a tick before asserting the post-cancel state.
        let sut = makeSUT(fileSaver: { _ in nil })

        sut.saveToDisk()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(mockDownload.executeCalled)
        XCTAssertFalse(sut.isLoading)
    }

    func test_saveToDisk_success_zerosBuffer() async throws {
        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-save-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: saveURL) }

        mockDownload.result = .success(plainData)
        let sut = makeSUT(fileSaver: { _ in saveURL })

        sut.saveToDisk()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(FileManager.default.fileExists(atPath: saveURL.path))
        XCTAssertNil(sut.actionError)
    }

    /// Downloaded buffers can be Data slices (nonzero startIndex). Zeroing them with a
    /// zero-based range writes out of bounds (run with AddressSanitizer).
    private var slicedPlainData: Data {
        Data([UInt8](repeating: 0xEE, count: 16) + plainData + [UInt8](repeating: 0xEE, count: 16))[16..<(16 + plainData.count)]
    }

    func test_open_slicedDownload_doesNotCrash() async throws {
        mockDownload.result = .success(slicedPlainData)
        let sut = makeSUT()

        sut.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(mockTempMgr.registerCalled)
        XCTAssertNil(sut.actionError)
    }

    func test_saveToDisk_slicedDownload_writesFullContent() async throws {
        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-save-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: saveURL) }

        mockDownload.result = .success(slicedPlainData)
        let sut = makeSUT(fileSaver: { _ in saveURL })

        sut.saveToDisk()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(try Data(contentsOf: saveURL), plainData)
        XCTAssertNil(sut.actionError)
    }

    func test_saveToDisk_downloadFailure_setsActionError() async throws {
        mockDownload.result = .failure(AttachmentError.downloadFailed)
        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-save-\(UUID().uuidString).pdf")
        let sut = makeSUT(fileSaver: { _ in saveURL })

        sut.saveToDisk()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(sut.actionError)
    }

    // MARK: - Delete

    func test_delete_callsDeleteUseCase() async throws {
        let sut = makeSUT()

        sut.delete()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(mockDelete.executeCalled)
        XCTAssertNil(sut.actionError)
    }

    func test_delete_failure_setsActionError() async throws {
        mockDelete.result = .failure(AttachmentError.downloadFailed)
        let sut = makeSUT()

        sut.delete()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(sut.actionError)
    }

    // MARK: - File missing on the server (fix-attachment-transfer-flow, 2.4)

    func test_open_fileMissing_setsTheMissingState_notAnError() async throws {
        mockDownload.result = .failure(AttachmentError.fileMissingOnServer)
        let sut = makeSUT()

        sut.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(sut.isFileMissing)
        XCTAssertNil(sut.actionError)
        XCTAssertFalse(fileOpenerCalled)
        XCTAssertEqual(AttachmentRowViewModel.missingFileNote, "The file is missing on the server")
    }

    /// A lock sweeps the folder while the file downloads: the decrypted file is not written or
    /// opened afterwards (review 2026-10-30).
    func test_open_lockDuringTheDownload_writesAndOpensNothing() async throws {
        mockDownload.result = .success(plainData)
        mockDownload.whileDownloading = { [mockTempMgr] in mockTempMgr?.sweepAll() }
        let sut = makeSUT()

        sut.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(mockTempMgr.written.isEmpty)
        XCTAssertFalse(fileOpenerCalled)
        XCTAssertNil(sut.actionError, "The vault is locked; there is nothing to show")
        XCTAssertFalse(sut.isLoading)
    }

    func test_open_writesThroughTheTempFileManager() async throws {
        mockDownload.result = .success(plainData)
        let sut = makeSUT()

        sut.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mockTempMgr.written.count, 1)
        XCTAssertEqual(mockTempMgr.written.first?.pathExtension, "pdf")
        XCTAssertTrue(fileOpenerCalled)
    }
}

// MARK: - Test doubles

private final class MockRowDownloadUseCase: DownloadAttachmentUseCase {
    var result: Result<Data, Error> = .success(Data())
    private(set) var executeCalled = false
    /// Runs while the download is in progress.
    var whileDownloading: (() -> Void)?

    func execute(cipherId: String, attachment: Attachment) async throws -> Data {
        executeCalled = true
        whileDownloading?()
        return try result.get()
    }
}

private final class MockRowDeleteUseCase: DeleteAttachmentUseCase {
    var result: Result<Void, Error> = .success(())
    private(set) var executeCalled = false

    func execute(cipherId: String, attachmentId: String) async throws {
        executeCalled = true
        try result.get()
    }
}

private final class MockTempFileManager: TempFileManaging, @unchecked Sendable {
    private(set) var registerCalled = false
    private(set) var cleanupCalled  = false
    private(set) var sweepAllCalled = false
    private(set) var written: [URL] = []

    private(set) var sweepGeneration = 0

    func write(_ data: Data, fileExtension: String, generation: Int) throws -> URL {
        guard generation == sweepGeneration else { throw TempFileError.sweptSinceDownload }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-rowtest-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url)
        written.append(url)
        register(url: url)
        return url
    }
    func sweepAll()          { sweepAllCalled = true; sweepGeneration += 1 }
    func register(url: URL) { registerCalled = true }
    func cleanup()           { cleanupCalled  = true }
}
