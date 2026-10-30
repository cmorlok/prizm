import Foundation
import Observation
import os.log

// MARK: - AttachmentConversionViewModel

/// The "Convert all" notice after a sync, its progress and its result (openspec change
/// fix-attachment-file-format, D5).
///
/// After a sync it collects the attachments that need converting: files probably in Prizm's old
/// layout and organization attachments wrapped with the personal key (fix-org-attachment-key, D4),
/// on items not in the trash. If there are any, it shows the notice once per unlock. "Convert all"
/// converts them one at a time, can be cancelled between files, and lists the failures at the end.
///
/// Conversion writes to the server and changes attachment IDs, so it never starts on its own.
@Observable
@MainActor
final class AttachmentConversionViewModel {

    /// What the sheet shows; `nil` hides it.
    enum Phase: Equatable {
        case notice(count: Int)
        case converting(done: Int, total: Int)
        case finished(converted: Int, failures: [String])
    }

    private struct Candidate {
        let cipherId: String
        let attachment: Attachment
    }

    private(set) var phase: Phase?
    private var candidates: [Candidate] = []
    private var noticeShownThisSession = false
    private var cancelRequested = false
    /// Bumped on lock and sign-out. A run started before checks it after every file, so it never
    /// writes into the next session's state (review 2026-10-30).
    private var session = 0

    private let convert: any ConvertAttachmentUseCase
    /// Called with the item's ID after each attachment that was written, so the caller refreshes it.
    private let onItemChanged: (String) -> Void
    private let logger = Logger(subsystem: "com.prizm", category: "attachments")

    init(convert: any ConvertAttachmentUseCase, onItemChanged: @escaping (String) -> Void) {
        self.convert = convert
        self.onItemChanged = onItemChanged
    }

    var noticeText: String {
        let count = candidates.count
        let noun = count == 1 ? "attachment was" : "attachments were"
        return "\(count) \(noun) saved by an earlier Prizm version and can't be opened in other Bitwarden apps."
    }

    // MARK: - Session

    /// Shows the notice when `items` hold attachments to convert, at most once per unlock.
    func vaultDidSync(items: [VaultItem]) {
        guard !noticeShownThisSession, phase == nil else { return }
        candidates = items.filter { !$0.isDeleted }.flatMap { item in
            item.attachments
                .filter { $0.storedInLegacyPrizmFormat || $0.wrappedWithPersonalKey }
                .map { Candidate(cipherId: item.id, attachment: $0) }
        }
        guard !candidates.isEmpty else { return }
        noticeShownThisSession = true
        phase = .notice(count: candidates.count)
        logger.info("Attachment conversion offered for \(self.candidates.count, privacy: .public) file(s)")
    }

    /// Called on lock and sign-out: the next unlock may show the notice again.
    func resetSession() {
        session &+= 1
        noticeShownThisSession = false
        cancelRequested = true
        candidates = []
        phase = nil
    }

    // MARK: - Actions

    func later() {
        phase = nil
    }

    func done() {
        phase = nil
    }

    /// Asks the running "Convert all" to stop after the current file.
    func cancel() {
        cancelRequested = true
    }

    func convertAll() async {
        // Only from the notice: a second press while converting starts nothing.
        guard case .notice = phase else { return }
        let runSession = session
        let queue = candidates
        cancelRequested = false
        var converted = 0
        var failures: [String] = []
        for (index, candidate) in queue.enumerated() {
            if cancelRequested { break }
            phase = .converting(done: index, total: queue.count)
            do {
                _ = try await convert.execute(cipherId: candidate.cipherId, attachment: candidate.attachment)
                guard runSession == session else { return }
                converted += 1
                onItemChanged(candidate.cipherId)
            } catch {
                guard runSession == session else { return }
                failures.append("\(candidate.attachment.fileName): \(error.localizedDescription)")
                logger.error("Convert all: \(candidate.attachment.id, privacy: .public) failed: \(ErrorLog.describe(error), privacy: .public)")
                // Both copies are on the item now; show them.
                if case AttachmentError.convertedOldCopyLeft = error { onItemChanged(candidate.cipherId) }
            }
        }
        candidates = []
        phase = .finished(converted: converted, failures: failures)
    }
}
