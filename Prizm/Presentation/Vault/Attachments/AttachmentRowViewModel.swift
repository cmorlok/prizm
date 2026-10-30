import Foundation
import Observation
import os.log

// MARK: - AttachmentRowViewModel

/// ViewModel for a single attachment row in the vault item detail pane (task 7.1).
///
/// Manages Open, Save to Disk and Delete for one attachment.
///
/// - Security goal: plaintext file bytes are written to a temp file for Open, and to a
///   user-chosen path for Save. The temp file lives in the folder `TempFileManaging` owns and is
///   zeroed and deleted after 30 seconds, on the next foreground, and on lock, sign-out, quit and
///   launch (fix-attachment-transfer-flow, D7). For Save, the plaintext is written directly and
///   the in-memory buffer is zeroed immediately after (Constitution §III).
///
/// - A download that finds no file on the server sets `isFileMissing`; the row then offers only
///   Delete (fix-attachment-transfer-flow, D2).
///
/// - AppKit dependencies (`NSWorkspace`, `NSSavePanel`, `NSOpenPanel`) are injected as
///   closures from the App layer (`AppContainer`) to keep the Presentation layer free of
///   AppKit imports (Constitution §II).
@Observable
@MainActor
final class AttachmentRowViewModel {

    // MARK: - Injected

    private let cipherId:             String
    let attachment:                   Attachment       // accessed by view
    private let downloadUseCase:      any DownloadAttachmentUseCase
    private let deleteUseCase:        any DeleteAttachmentUseCase
    private let convertUseCase:       any ConvertAttachmentUseCase
    private let tempFileManager:      any TempFileManaging
    /// Injectable file-saver closure. Provided by AppContainer (defaults to NSSavePanel).
    private let fileSaver:            @MainActor (_ suggestedName: String) -> URL?
    /// Injectable file-opener closure. Provided by AppContainer (defaults to NSWorkspace.shared.open).
    private let fileOpener:           @MainActor (_ url: URL) -> Void

    private let logger = Logger(subsystem: "com.prizm", category: "attachments")

    /// Called after a successful delete so the parent view can refresh
    /// `itemSelection` and reflect the updated attachment list without waiting for a sync.
    var onAttachmentChanged: (() -> Void)? = nil

    // MARK: - State (observable)

    private(set) var isLoading:   Bool    = false
    private(set) var actionError: String? = nil
    /// True once a download found no file for this attachment on the server.
    private(set) var isFileMissing = false
    /// True while the file is converted to the official layout (fix-attachment-file-format, D5).
    private(set) var isConverting = false

    /// The file is probably in Prizm's old layout, or its key is the personal key on an org item:
    /// both are repaired by converting it.
    /// Set by the detail view: an item in the trash offers no conversion (it is not offered by the
    /// "Convert all" notice either).
    var itemIsDeleted = false
    var canConvert: Bool { !itemIsDeleted && (attachment.storedInLegacyPrizmFormat || attachment.wrappedWithPersonalKey) }

    static let missingFileNote = "The file is missing on the server"

    // MARK: - Init

    init(
        cipherId:        String,
        attachment:      Attachment,
        downloadUseCase: any DownloadAttachmentUseCase,
        deleteUseCase:   any DeleteAttachmentUseCase,
        convertUseCase:  any ConvertAttachmentUseCase,
        tempFileManager: any TempFileManaging,
        fileSaver:       @escaping @MainActor (_ suggestedName: String) -> URL?,
        fileOpener:      @escaping @MainActor (_ url: URL) -> Void
    ) {
        self.cipherId        = cipherId
        self.attachment      = attachment
        self.downloadUseCase = downloadUseCase
        self.deleteUseCase   = deleteUseCase
        self.convertUseCase  = convertUseCase
        self.tempFileManager = tempFileManager
        self.fileSaver       = fileSaver
        self.fileOpener      = fileOpener
    }

    // MARK: - Open (task 7.2b)

    func open() {
        // Not while this file is converted: the conversion replaces it.
        guard !isLoading, !isConverting else { return }
        isLoading   = true
        actionError = nil

        let generation = tempFileManager.sweepGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                var data = try await self.downloadUseCase.execute(
                    cipherId:   self.cipherId,
                    attachment: self.attachment
                )
                let ext = URL(fileURLWithPath: self.attachment.fileName).pathExtension
                let tmpURL: URL
                do {
                    tmpURL = try self.tempFileManager.write(data, fileExtension: ext, generation: generation)
                } catch {
                    data.resetBytes(in: data.indices)
                    throw error
                }
                data.resetBytes(in: data.indices)
                self.fileOpener(tmpURL)

                Task {
                    try? await Task.sleep(for: .seconds(30))
                    self.tempFileManager.cleanup()
                }

                self.logger.info("open: opened \(self.attachment.id, privacy: .public)")
            } catch TempFileError.sweptSinceDownload {
                // The vault locked during the download; the row is gone, so nothing is shown.
                self.logger.info("open: \(self.attachment.id, privacy: .public) not opened, the vault locked during the download")
            } catch {
                self.report(error, action: "open")
            }
            self.isLoading = false
        }
    }

    // MARK: - Save to Disk (task 7.3)

    func saveToDisk() {
        // Not while this file is converted: the conversion replaces it.
        guard !isLoading, !isConverting else { return }
        isLoading   = true
        actionError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let saveURL = self.fileSaver(self.attachment.fileName) else {
                self.isLoading = false
                return
            }
            do {
                var data = try await self.downloadUseCase.execute(
                    cipherId:   self.cipherId,
                    attachment: self.attachment
                )
                try data.write(to: saveURL)
                data.resetBytes(in: data.indices)
                self.logger.info("saveToDisk: saved \(self.attachment.id, privacy: .public)")
            } catch {
                self.report(error, action: "save")
            }
            self.isLoading = false
        }
    }

    // MARK: - Delete (task 7.4)

    func delete() {
        // Not while this file is converted: the conversion replaces it.
        guard !isLoading, !isConverting else { return }
        isLoading   = true
        actionError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteUseCase.execute(
                    cipherId:     self.cipherId,
                    attachmentId: self.attachment.id
                )
                self.logger.info("delete: removed \(self.attachment.id, privacy: .public)")
                self.onAttachmentChanged?()
            } catch {
                self.actionError = "Could not delete attachment: \(error.localizedDescription)"
                self.logger.error("delete failed: \(ErrorLog.describe(error), privacy: .public)")
            }
            self.isLoading = false
        }
    }

    // MARK: - Convert (fix-attachment-file-format, D4/D5)

    /// Re-uploads the file in the official layout; the parent refreshes the item afterwards, also
    /// when only the old copy could not be removed (the item then shows both).
    func convert() {
        guard !isLoading, !isConverting else { return }
        isConverting = true
        actionError  = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let converted = try await self.convertUseCase.execute(cipherId: self.cipherId, attachment: self.attachment)
                self.logger.info("convert: \(self.attachment.id, privacy: .public) → \(converted.id, privacy: .public)")
                self.onAttachmentChanged?()
            } catch {
                self.report(error, action: "convert")
                if case AttachmentError.convertedOldCopyLeft = error { self.onAttachmentChanged?() }
            }
            self.isConverting = false
        }
    }

    // MARK: - Private helpers

    /// A missing file turns the row into the missing-file state; anything else is an inline error.
    private func report(_ error: Error, action: String) {
        if case AttachmentError.fileMissingOnServer = error {
            isFileMissing = true
            actionError = nil
        } else {
            actionError = "Could not \(action) file: \(error.localizedDescription)"
        }
        logger.error("\(action, privacy: .public) failed: \(ErrorLog.describe(error), privacy: .public)")
    }
}
