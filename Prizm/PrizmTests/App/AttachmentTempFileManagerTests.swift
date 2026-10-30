import XCTest
@testable import Prizm

/// Unit tests for `AttachmentTempFileManager` (task 7.2c; fix-attachment-transfer-flow D7).
///
/// Uses `register(url:deleteAfter:)` to control cleanup timing without sleeping.
@MainActor
final class AttachmentTempFileManagerTests: XCTestCase {

    private var sut: AttachmentTempFileManager!
    private var createdURLs: [URL] = []
    /// A folder per test, so no test touches the app's real `PrizmAttachments` folder.
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-tmptest-folder-\(UUID().uuidString)", isDirectory: true)
        sut = AttachmentTempFileManager(folder: folder)
    }

    override func tearDown() async throws {
        for url in createdURLs { try? FileManager.default.removeItem(at: url) }
        createdURLs.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Helpers

    /// Creates a real temp file on disk and records it for teardown.
    private func makeTempFile(content: String = "sensitive content") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prizm-tmptest-\(UUID().uuidString).txt")
        try? content.data(using: .utf8)!.write(to: url)
        createdURLs.append(url)
        return url
    }

    // MARK: - register

    func test_register_fileStillExistsBeforeCleanup() {
        let url = makeTempFile()
        sut.register(url: url)
        // cleanup() not called yet — file should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - cleanup — expired deadline

    func test_cleanup_deletesFilesPastDeadline() {
        let url = makeTempFile()
        // Register with a deadline 1 second in the past
        sut.register(url: url, deleteAfter: Date().addingTimeInterval(-1))

        sut.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
            "File should be deleted after its deadline passes")
    }

    func test_cleanup_zerosAndDeletesExpiredFile() throws {
        let sensitiveContent = "sensitive data that should be zeroed"
        let url = makeTempFile(content: sensitiveContent)
        sut.register(url: url, deleteAfter: Date().addingTimeInterval(-1))

        sut.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
            "File should not exist after cleanup")
    }

    // MARK: - cleanup — unexpired deadline

    func test_cleanup_leavesFilesNotYetExpired() {
        let url = makeTempFile()
        // Register with a deadline 30 seconds in the future
        sut.register(url: url, deleteAfter: Date().addingTimeInterval(30))

        sut.cleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "File should remain until its deadline passes")
    }

    func test_cleanup_mixedDeadlines_onlyDeletesExpired() {
        let expiredURL  = makeTempFile(content: "expired")
        let freshURL    = makeTempFile(content: "fresh")

        sut.register(url: expiredURL, deleteAfter: Date().addingTimeInterval(-1))
        sut.register(url: freshURL,   deleteAfter: Date().addingTimeInterval(30))

        sut.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path),
            "Expired file should be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path),
            "Fresh file should remain")
    }

    // MARK: - Multiple cleanups

    func test_cleanup_idempotent_doesNotCrashOnMissingFile() {
        let url = makeTempFile()
        sut.register(url: url, deleteAfter: Date().addingTimeInterval(-1))

        sut.cleanup()
        sut.cleanup()  // second call — file already gone, should not throw/crash

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Register + cleanup lifecycle

    func test_registeredFile_isDeletedOnCleanupAfterDeadline() {
        let url = makeTempFile()
        sut.register(url: url)
        // Manually expire by re-registering with past deadline
        sut.register(url: url, deleteAfter: Date().addingTimeInterval(-1))

        sut.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - write / sweepAll (D7)

    func test_write_putsTheFileIntoTheOwnerOnlyFolder() throws {
        let url = try sut.write(Data("plain".utf8), fileExtension: "pdf", generation: sut.sweepGeneration)

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("plain".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o700)
    }

    func test_write_twice_givesTwoFiles() throws {
        let first = try sut.write(Data("a".utf8), fileExtension: "txt", generation: sut.sweepGeneration)
        let second = try sut.write(Data("b".utf8), fileExtension: "txt", generation: sut.sweepGeneration)
        XCTAssertNotEqual(first, second)
    }

    func test_sweepAll_emptiesTheFolder_evenBeforeTheDeadline() throws {
        let opened = try sut.write(Data("plain".utf8), fileExtension: "txt", generation: sut.sweepGeneration)
        // A file left behind by an earlier run (crash) is not registered, but swept too.
        let leftover = folder.appendingPathComponent("leftover.txt")
        try Data("old".utf8).write(to: leftover)

        sut.sweepAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    /// A file decrypted before a lock arrives after the sweep: it is never written (review 2026-10-30).
    func test_write_afterASweep_isRefused_andLeavesNoFile() throws {
        let generation = sut.sweepGeneration
        sut.sweepAll()

        XCTAssertThrowsError(try sut.write(Data("plain".utf8), fileExtension: "txt", generation: generation)) {
            XCTAssertEqual($0 as? TempFileError, .sweptSinceDownload)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func test_sweepAll_leavesFilesOutsideTheFolder() {
        let outside = makeTempFile()
        sut.sweepAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func test_sweepAll_withoutFolder_doesNothing() {
        sut.sweepAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
