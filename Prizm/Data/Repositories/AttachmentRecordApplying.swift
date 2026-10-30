import Foundation

/// Takes the item a server returns from an attachment upload or delete into the local vault
/// (openspec change `fix-attachment-transfer-flow`, design D5). Data layer only: the record is a
/// wire type the Domain protocols never see. Implemented by `VaultRepositoryImpl`.
protocol AttachmentRecordApplying: AnyObject, Sendable {
    /// Stores `record` as the item's server record, moves the cached revision to it and replaces the
    /// cached attachment list with its attachments.
    /// - Returns: false when nothing was applied (another item's record, an item that is not cached,
    ///   a record that cannot be read, or a lock meanwhile); the caller then patches the list itself.
    func applyAttachmentChange(record: RawCipher, for cipherId: String) async -> Bool
}
