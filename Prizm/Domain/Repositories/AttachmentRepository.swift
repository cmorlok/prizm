import Foundation

// MARK: - AttachmentRepository

/// Domain repository for file attachment operations — upload, download, and delete.
///
/// All methods accept a raw 64-byte `cipherKey: Data` (encryptionKey ‖ macKey).
/// The Data layer implementation splits this into `CryptoKeys` at the boundary
/// and passes the components to `PrizmCryptoService` methods.
///
/// The caller (use case) is responsible for obtaining the cipher key via
/// `VaultKeyService.cipherKey(for:)` — it is NEVER a parameter on the
/// use-case `execute(...)` signatures (Constitution §II/§III).
///
/// Implemented by `AttachmentRepositoryImpl` in the Data layer.
protocol AttachmentRepository {

    /// Uploads a file as a new attachment to the given cipher.
    ///
    /// - Parameters:
    ///   - cipherId:  The ID of the vault item to attach the file to.
    ///   - fileName:  Plaintext file name (will be encrypted before upload).
    ///   - data:      Raw file bytes (will be encrypted before upload).
    ///   - cipherKey: 64-byte effective cipher key (encKey ‖ macKey) used to
    ///                wrap the per-attachment key and encrypt the file name.
    /// - Returns: The newly created `Attachment`.
    /// - Throws: `AttachmentError.serverRejected` when the server refuses with a message (HTTP 400),
    ///   `AttachmentError.uploadFailedRecordLeft` when the upload failed and its attachment record
    ///   could not be removed again; otherwise the original error. A record created before a failed
    ///   or cancelled file upload is deleted again (fix-attachment-transfer-flow, D1).
    /// - Throws: `VaultError.vaultLocked` if the vault is locked before the call.
    func upload(cipherId: String, fileName: String, data: Data, cipherKey: Data) async throws -> Attachment

    /// Downloads and decrypts the file blob for the given attachment.
    ///
    /// - Parameters:
    ///   - cipherId:   The ID of the vault item the attachment belongs to.
    ///   - attachment: The attachment record containing the encrypted key and download URL.
    ///   - cipherKey:  64-byte effective cipher key used to unwrap the attachment key.
    /// - Returns: Decrypted plaintext file bytes.
    /// - Throws: `AttachmentError.fileMissingOnServer` when the server has no file for the record,
    ///   `AttachmentError.downloadFailed` for other download failures.
    func download(cipherId: String, attachment: Attachment, cipherKey: Data) async throws -> Data

    /// Deletes an attachment from the given cipher.
    ///
    /// On success the in-memory vault cache is updated via `VaultRepository.updateAttachments`
    /// so the row disappears from the UI without a full re-sync.
    ///
    /// - Parameters:
    ///   - cipherId:     The ID of the vault item the attachment belongs to.
    ///   - attachmentId: The ID of the attachment to delete.
    func delete(cipherId: String, attachmentId: String) async throws

    /// Re-uploads a file in the official layout as a new attachment with a new attachment key and
    /// the same file name, then deletes the old attachment (fix-attachment-file-format, D4).
    ///
    /// - Parameters:
    ///   - downloadKey: 64-byte key the old attachment key is wrapped with.
    ///   - uploadKey:   64-byte effective key of the item, for the new attachment.
    /// - Returns: The new attachment.
    /// - Throws: `AttachmentError.alreadyStandardFormat` (nothing written) when the file is already
    ///   official and the attachment is not `wrappedWithPersonalKey`; the upload's errors (the new
    ///   record is rolled back, the old one kept); `AttachmentError.convertedOldCopyLeft` when the
    ///   old attachment could not be deleted.
    func convertLegacyFormat(cipherId: String, attachment: Attachment, downloadKey: Data, uploadKey: Data) async throws -> Attachment
}

// MARK: - AttachmentError

/// Errors thrown by `AttachmentRepositoryImpl`.
nonisolated enum AttachmentError: Error, LocalizedError, Equatable {
    /// The server refused the upload with HTTP 400 and this message, for example "You must have
    /// premium status to use attachments." or a storage limit (fix-attachment-transfer-flow, D3).
    case serverRejected(message: String)
    /// The file upload failed, and deleting the attachment record it had created failed too.
    case uploadFailedRecordLeft
    /// The server has an attachment record but no file for it (HTTP 404 on a fresh download URL).
    case fileMissingOnServer
    /// The encrypted blob could not be downloaded.
    case downloadFailed
    /// The file is in a layout Prizm does not decrypt (type 0 without a MAC, an unknown type, or a
    /// length that fits no layout) (fix-attachment-file-format, D2).
    case unsupportedFileFormat
    /// The file's MAC did not verify: corrupt, tampered with, or encrypted with another key.
    case fileDecryptionFailed
    /// A conversion found the file already in the official layout and changed nothing (D4).
    case alreadyStandardFormat
    /// A conversion uploaded the new file, but deleting the old attachment failed; the item has
    /// both (D4).
    case convertedOldCopyLeft
    /// The same file is already being converted (the row's Convert and "Convert all" overlap).
    case conversionAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .serverRejected(let message):
            return "The server rejected the upload: \(message)"
        case .uploadFailedRecordLeft:
            return "Upload failed. A broken attachment entry may remain; delete it from the item."
        case .fileMissingOnServer:
            return "The file is missing on the server."
        case .downloadFailed:
            return "Download failed. If this keeps happening, try locking and unlocking your vault."
        case .unsupportedFileFormat:
            return "The file uses a format Prizm can't open."
        case .fileDecryptionFailed:
            return "The file could not be decrypted."
        case .alreadyStandardFormat:
            return "This file is already in the standard format."
        case .convertedOldCopyLeft:
            return "Converted, but the old copy could not be removed. Delete it from the item."
        case .conversionAlreadyRunning:
            return "This file is already being converted."
        }
    }
}
