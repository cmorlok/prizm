import Foundation

// MARK: - TempFileManaging

/// Protocol for managing the lifecycle of temporary files written during attachment open.
///
/// Placed in the Presentation layer (not Domain) because it is an infrastructure concern
/// driven by UI lifecycle events — not a business rule. `AttachmentRowViewModel` depends
/// on `any TempFileManaging` so it never imports the App-layer concrete type directly,
/// keeping the Presentation layer clean (Constitution §II).
///
/// The concrete implementation `AttachmentTempFileManager` lives in the App layer,
/// which may import AppKit to register for `NSApplication.didBecomeActiveNotification`.
/// Errors thrown by `TempFileManaging.write`.
enum TempFileError: Error, Equatable {
    /// The folder was swept (lock, sign-out) after the download started.
    case sweptSinceDownload
}

protocol TempFileManaging: AnyObject, Sendable {

    /// Counts the `sweepAll()` calls. Read before a download starts and passed to `write`, so a file
    /// that finishes decrypting after a lock is never written (review 2026-10-30).
    var sweepGeneration: Int { get }

    /// Writes `data` to a new file in the manager's own folder and registers it with a 30-second
    /// deletion deadline (fix-attachment-transfer-flow, D7).
    /// - Parameter generation: `sweepGeneration` as read before the download.
    /// - Returns: the file's URL, named `<UUID>.<fileExtension>` (no extension when empty).
    /// - Throws: `TempFileError.sweptSinceDownload` when `sweepAll()` ran since `generation` was read.
    func write(_ data: Data, fileExtension: String, generation: Int) throws -> URL

    /// Zeroes and deletes every file in the manager's folder, whatever its deadline: on lock,
    /// sign-out, quit and launch.
    func sweepAll()

    /// Records `url` with a 30-second deletion deadline.
    ///
    /// The file will be zeroed and deleted by `cleanup()` once its deadline passes.
    func register(url: URL)

    /// Zeroes and deletes all registered files whose deletion deadline has passed.
    ///
    /// Called on each foreground transition and by a scheduled background task spawned
    /// by `AttachmentRowViewModel` 30 seconds after `register(url:)`.
    func cleanup()
}
