import AppKit
import Foundation
import os.log

// MARK: - AttachmentTempFileManager

/// Tracks temporary files written during attachment "Open" and cleans them up.
///
/// Placed in the App layer because it imports `AppKit` (`NSApplication`) per the
/// Clean Architecture constraint in CLAUDE.md (§II). `AttachmentRowViewModel` in the
/// Presentation layer depends on the `TempFileManaging` protocol, never this concrete type.
///
/// Cleanup strategy:
/// - Opened files are written only to one folder, `<tmp>/PrizmAttachments` (owner-only, `0700`),
///   so they can be swept as a whole (fix-attachment-transfer-flow, D7).
/// - Each registered file has a 30-second deletion deadline.
/// - `cleanup()` is called on every foreground transition (via `NSApplication.didBecomeActiveNotification`)
///   and by a scheduled Task inside `AttachmentRowViewModel` 30 s after registration.
/// - `sweepAll()` empties the folder on lock, sign-out, quit and launch, so no decrypted file
///   outlives the vault session; the launch sweep removes what a crash left behind.
/// - On cleanup, the file is overwritten with zeros then deleted (Constitution §III).
///
/// - Security goal: no plaintext attachment stays on disk after the session. Deletion is the
///   control that matters; the zero overwrite is best effort, because APFS copy-on-write and SSD
///   wear levelling can keep the old blocks (FileVault protects those).
/// - Intentionally NOT done: closing the file in the app it was opened in. Preview and the like
///   keep their in-memory copy after the disk copy is gone (documented in SECURITY.md).
///
/// Thread safety: `entries` is protected by a `Lock` because `register` and `cleanup`
/// may be called from background Tasks or notification callbacks.
final class AttachmentTempFileManager: TempFileManaging, @unchecked Sendable {

    // MARK: - Types

    private struct Entry {
        let url:         URL
        let deleteAfter: Date
    }

    // MARK: - State

    private var entries: [Entry] = []
    private var generation = 0
    private let lock = NSLock()

    /// The only folder opened files are written to.
    let folder: URL

    private let logger = Logger(subsystem: "com.prizm", category: "attachments")

    static var defaultFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PrizmAttachments", isDirectory: true)
    }

    // MARK: - Init

    init(folder: URL = AttachmentTempFileManager.defaultFolder) {
        self.folder = folder
        // Register for foreground notification to trigger cleanup whenever the app
        // comes to the front — catches the common case where the user switches back
        // to Prizm after opening an attachment in another app.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - TempFileManaging

    var sweepGeneration: Int {
        lock.withLock { generation }
    }

    /// The check and the write run under the lock, and `sweepAll()` bumps the generation under it
    /// before listing the folder: a file is either refused or written before the listing and swept.
    func write(_ data: Data, fileExtension: String, generation expected: Int) throws -> URL {
        let url = try lock.withLock {
            guard expected == generation else { throw TempFileError.sweptSinceDownload }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let name = fileExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(fileExtension)"
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .withoutOverwriting)
            entries.append(Entry(url: url, deleteAfter: Date().addingTimeInterval(30)))
            return url
        }
        logger.debug("tempFile registered: \(url.lastPathComponent, privacy: .public)")
        return url
    }

    func sweepAll() {
        lock.lock()
        generation &+= 1
        entries.removeAll()
        lock.unlock()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            zeroAndDelete(url)
        }
        if !files.isEmpty {
            logger.info("tempFile sweep removed \(files.count, privacy: .public) file(s)")
        }
    }

    /// Records `url` with a 30-second deletion deadline.
    func register(url: URL) {
        register(url: url, deleteAfter: Date().addingTimeInterval(30))
    }

    /// Records `url` with a custom deletion deadline.
    ///
    /// Exposed for testing — allows tests to register a file with a deadline in the past
    /// without sleeping 30 seconds (Constitution §VI, YAGNI: no separate Clock injection).
    func register(url: URL, deleteAfter: Date) {
        lock.lock()
        entries.append(Entry(url: url, deleteAfter: deleteAfter))
        lock.unlock()
        logger.debug("tempFile registered: \(url.lastPathComponent, privacy: .public)")
    }

    /// Zeroes and deletes all entries whose deadline has passed.
    func cleanup() {
        let now = Date()
        var expired: [Entry] = []

        lock.lock()
        entries = entries.filter { entry in
            if entry.deleteAfter <= now {
                expired.append(entry)
                return false
            }
            return true
        }
        lock.unlock()

        for entry in expired {
            zeroAndDelete(entry.url)
        }
    }

    // MARK: - Private

    /// Overwrites the file at `url` with zeros then deletes it.
    ///
    /// - Security goal: reduces (but does not guarantee elimination of) plaintext attachment data on disk (APFS copy-on-write may retain original blocks; FileVault is recommended)
    ///   after the open action completes (Constitution §III).
    private func zeroAndDelete(_ url: URL) {
        do {
            // Overwrite with zero bytes of the same size.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                let zeros = Data(repeating: 0, count: size)
                try zeros.write(to: url)
            }
            try FileManager.default.removeItem(at: url)
            logger.debug("tempFile zeroed and deleted: \(url.lastPathComponent, privacy: .public)")
        } catch {
            // Best-effort: if we can't zero or delete, log and continue.
            logger.error("tempFile cleanup failed: \(ErrorLog.describe(error), privacy: .public)")
        }
    }

    @objc private func appDidBecomeActive() {
        cleanup()
    }
}
