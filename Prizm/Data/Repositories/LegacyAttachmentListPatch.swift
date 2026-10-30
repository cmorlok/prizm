import Foundation

// LEGACY(Vaultwarden < 1.34.0, Bitwarden server < v2026.2.1: delete returns no item): remove when those versions are no longer supported

/// The attachment list built locally after an upload or delete whose answer carries no item
/// (openspec change `fix-attachment-transfer-flow`, design D5).
///
/// Current servers return the item from both requests and `AttachmentRepositoryImpl` takes the
/// list from it. Older servers answer a delete with an empty body, so the list is patched here and
/// `VaultRepository.updateAttachments` fetches the item for its revision, as before this change.
/// Reached only when the answer has no item, never as the default.
nonisolated enum LegacyAttachmentListPatch {

    static func adding(_ attachment: Attachment, to list: [Attachment]) -> [Attachment] {
        list.filter { $0.id != attachment.id } + [attachment]
    }

    static func removing(_ attachmentId: String, from list: [Attachment]) -> [Attachment] {
        list.filter { $0.id != attachmentId }
    }
}
