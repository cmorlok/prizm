import Foundation
import os.log

// MARK: - AttachmentRepositoryImpl

/// Concrete implementation of `AttachmentRepository`.
///
/// Handles the full upload/download/delete lifecycle for vault item attachments,
/// including two-layer encryption (attachment key + cipher key), the Bitwarden
/// two-step v2 upload flow, and in-memory vault cache patching.
///
/// - Security goal: all file bytes and key material are encrypted before leaving the
///   device. The attachment key (64 random bytes) encrypts the file blob. The cipher
///   key encrypts the attachment key. Both use AES-256-CBC + HMAC-SHA256
///   (EncString type-2 for key/metadata; the official EncArrayBuffer `0x02‖IV‖HMAC‖ciphertext` for the blob).
///
/// - Algorithm: Bitwarden two-layer attachment encryption per Security Whitepaper §4.
///   - Layer 1: `encryptData` — AES-256-CBC + HMAC-SHA256 over raw file bytes.
///   - Layer 2: `encryptAttachmentKey` — EncString type-2 wrapping the 64-byte attachment key.
///   - File name: `encryptFileName` — EncString type-2 wrapping the plaintext name.
///
/// - Crypto injection: takes `any PrizmCryptoService` (protocol, not concrete type) so that
///   tests can supply a mock. The 6 attachment crypto methods (`generateSymmetricKey`,
///   `encryptData`, `decryptData`, `encryptAttachmentKey`, `decryptAttachmentKey`,
///   `encryptFileName`) are declared `nonisolated` on the protocol and implemented in
///   `AttachmentCrypto.swift` via an extension on `PrizmCryptoServiceImpl`.
///
/// - Key handling:
///   - The 64-byte `cipherKey: Data` parameter (encKey ‖ macKey) is split into
///     `CryptoKeys` at the Data layer boundary (encryptionKey = first 32 bytes,
///     macKey = last 32 bytes) before being passed to `PrizmCryptoService` methods.
///   - All key material is zeroed as soon as it is no longer needed.
///   - No key material appears in log output (Constitution §V).
///
/// - Deviations: none. The upload flow matches the Bitwarden reference client.
///
/// - What is NOT done: no key persistence beyond the current operation; the attachment
///   key exists only in memory for the duration of the upload/download call.
final class AttachmentRepositoryImpl: AttachmentRepository {

    private let apiClient:       any PrizmAPIClientProtocol
    private let crypto:          any PrizmCryptoService
    private let vaultRepository: any VaultRepository
    /// Takes the item from the server's upload and delete answers; nil means every change is
    /// patched locally (`LegacyAttachmentListPatch`).
    private let recordApplier:   (any AttachmentRecordApplying)?

    private let logger = Logger(subsystem: "com.prizm", category: "attachments")

    /// `recordApplier` defaults to `vaultRepository` when that is the Data-layer implementation.
    init(
        apiClient:       any PrizmAPIClientProtocol,
        crypto:          any PrizmCryptoService,
        vaultRepository: any VaultRepository,
        recordApplier:   (any AttachmentRecordApplying)? = nil
    ) {
        self.apiClient       = apiClient
        self.crypto          = crypto
        self.vaultRepository = vaultRepository
        self.recordApplier   = recordApplier ?? (vaultRepository as? any AttachmentRecordApplying)
    }

    // MARK: - Upload

    /// Encrypts and uploads a file to the Bitwarden v2 attachment endpoint.
    ///
    /// Upload flow (Bitwarden Security Whitepaper §4, "Attachments"):
    /// 1. Generate a 64-byte random per-attachment key.
    /// 2. Encrypt the file name as an EncString using the cipher key.
    /// 3. Encrypt the file blob using the attachment key (official layout: 0x02‖IV‖HMAC‖ciphertext).
    /// 4. Wrap the attachment key as an EncString using the cipher key.
    /// 5. POST metadata to `/api/ciphers/{id}/attachment/v2` to register the attachment.
    /// 6. Upload the encrypted blob:
    ///    - fileUploadType 0: POST multipart to `/api/ciphers/{id}/attachment/{attachmentId}`.
    ///    - fileUploadType 1: PUT to the Azure signed URL with `x-ms-blob-type: BlockBlob`.
    ///    Any failure here, cancellation included, deletes the record step 5 created before the
    ///    error is reported, as the official clients do (fix-attachment-transfer-flow, D1).
    /// 7. Zero the attachment key and encrypted blob.
    /// 8. Take the item from the v2 answer into the local vault, or patch the list locally when the
    ///    answer has none (D5).
    func upload(cipherId: String, fileName: String, data: Data, cipherKey: Data) async throws -> Attachment {
        logger.debug("upload: starting for cipher=\(cipherId, privacy: .public) size=\(data.count, privacy: .public)B")

        let keys = try splitKey(cipherKey)

        // Step 1: Generate per-attachment key (64 random bytes, Constitution §III).
        var attachmentKey = try crypto.generateSymmetricKey()
        defer { attachmentKey.resetBytes(in: attachmentKey.indices) }

        // Step 2: Encrypt file name.
        let encFileName = try crypto.encryptFileName(fileName, cipherKey: keys)

        // Step 3: Encrypt file blob.
        var encBlob = try crypto.encryptData(data, attachmentKey: attachmentKey)
        defer { encBlob.resetBytes(in: encBlob.indices) }

        // Step 4: Wrap attachment key as EncString.
        let encKey = try crypto.encryptAttachmentKey(attachmentKey, cipherKey: keys)

        // Step 5: POST metadata to /v2 endpoint.
        let metaRequest = AttachmentMetadataRequest(
            fileName:     encFileName,
            key:          encKey,
            fileSize:     encBlob.count,
            adminRequest: false
        )
        let metaResponse: AttachmentMetadataResponse
        do {
            metaResponse = try await apiClient.createAttachmentMetadata(cipherId: cipherId, body: metaRequest)
        } catch {
            throw Self.serverRejection(error) ?? error
        }
        logger.info("upload: metadata registered attachmentId=\(metaResponse.attachmentId, privacy: .public) type=\(metaResponse.fileUploadType, privacy: .public)")

        // Step 6: Upload the encrypted blob; roll the record back on any failure.
        do {
            try await uploadBlob(encBlob, encryptedFileName: encFileName, for: metaResponse, cipherId: cipherId)
        } catch {
            try await rollBack(cipherId: cipherId, attachmentId: metaResponse.attachmentId, after: error)
            throw Self.serverRejection(error) ?? error
        }
        logger.info("upload: blob uploaded for attachmentId=\(metaResponse.attachmentId, privacy: .public)")

        // Built locally for the legacy patch and the return value: the server's record (with the
        // encrypted size and a download URL) arrives with the answer's item or the next sync.
        let sizeName = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let newAttachment = Attachment(
            id:           metaResponse.attachmentId,
            fileName:     fileName,
            encryptedKey: encKey,
            size:         data.count,
            sizeName:     sizeName,
            url:          nil
        )

        // Step 8: the item from the answer, else the local patch.
        if !(await apply(metaResponse.cipherResponse, for: cipherId)) {
            logger.info("upload: answer has no usable item, patching the list locally for \(cipherId, privacy: .public)")
            // By id over every cached item: `allItems()` leaves out archived ones (archived-items).
            let currentList = (try? await vaultRepository.itemDetail(id: cipherId))?.attachments ?? []
            await vaultRepository.updateAttachments(LegacyAttachmentListPatch.adding(newAttachment, to: currentList),
                                                    for: cipherId)
        }

        return newAttachment
    }

    private func uploadBlob(_ encBlob: Data, encryptedFileName: String, for meta: AttachmentMetadataResponse,
                            cipherId: String) async throws {
        switch meta.fileUploadType {
        case 0:
            // Bitwarden-hosted: POST multipart to API.
            try await apiClient.uploadAttachmentBitwardenHosted(
                cipherId:          cipherId,
                attachmentId:      meta.attachmentId,
                encryptedFileName: encryptedFileName,
                encryptedBlob:     encBlob
            )
        case 1:
            // Azure Blob Storage: one PUT to the signed URL. No block upload or URL renewal: Prizm
            // targets self-hosted servers, which use type 0 (D4).
            guard let azureURL = URL(string: meta.url) else {
                throw AttachmentError.downloadFailed
            }
            try await apiClient.uploadAttachmentAzure(signedURL: azureURL, encryptedBlob: encBlob)
        default:
            logger.fault("upload: unknown fileUploadType=\(meta.fileUploadType, privacy: .public)")
            throw AttachmentError.downloadFailed
        }
    }

    /// Deletes the record of a failed upload. Runs in its own task, so a cancelled upload still
    /// sends it. When the delete fails too, the user is told a broken entry may remain.
    private func rollBack(cipherId: String, attachmentId: String, after uploadError: Error) async throws {
        logger.error("upload: file upload failed for \(attachmentId, privacy: .public), deleting its record: \(ErrorLog.describe(uploadError), privacy: .public)")
        let apiClient = apiClient
        let rollback = Task.detached {
            _ = try await apiClient.deleteAttachment(cipherId: cipherId, attachmentId: attachmentId)
        }
        do {
            try await rollback.value
            logger.info("upload: record \(attachmentId, privacy: .public) deleted after the failed upload")
        } catch let error as APIError where Self.isAlreadyGone(error) {
            // Vaultwarden deletes the record itself when the uploaded size does not match.
            logger.info("upload: record \(attachmentId, privacy: .public) was already gone: \(ErrorLog.describe(error), privacy: .public)")
        } catch {
            logger.error("upload: record \(attachmentId, privacy: .public) could not be deleted: \(ErrorLog.describe(error), privacy: .public)")
            throw AttachmentError.uploadFailedRecordLeft
        }
    }

    /// True for the answers that mean the attachment record does not exist: 404 (Bitwarden server)
    /// or 400 "Attachment doesn't exist" (Vaultwarden 1.37.4, `src/api/core/ciphers.rs`).
    private static func isAlreadyGone(_ error: APIError) -> Bool {
        guard case .httpError(let status, let body) = error else { return false }
        if status == 404 { return true }
        return status == 400 && APIError.serverMessage(statusCode: 400, body: body) == "Attachment doesn't exist"
    }

    /// `AttachmentError.serverRejected` for an HTTP 400 that carries a server message (both servers
    /// send `message`; D3), else nil.
    private static func serverRejection(_ error: Error) -> AttachmentError? {
        guard case APIError.httpError(400, let body) = error,
              let message = APIError.serverMessage(statusCode: 400, body: body) else { return nil }
        return .serverRejected(message: message)
    }

    // MARK: - Download

    /// Downloads and decrypts the file blob for the given attachment.
    ///
    /// Download flow, as the official clients (fix-attachment-transfer-flow, D2):
    /// 1. Fetch a fresh download URL via `GET /api/ciphers/{id}/attachment/{attachmentId}`. The sync
    ///    URL is signed for about 90 seconds on Vaultwarden, so it is used only when this request
    ///    answers 404.
    /// 2. Fetch the encrypted blob from the URL, never from a cache. A 404 means the server has no
    ///    file for the record (`fileMissingOnServer`); there is no retry, the URL is already fresh.
    /// 3. Decrypt the blob: unwrap the attachment key (EncString → 64 bytes) using the
    ///    cipher key, then decrypt the blob (official or old Prizm layout) using the attachment key.
    /// 4. Zero key and blob buffers.
    func download(cipherId: String, attachment: Attachment, cipherKey: Data) async throws -> Data {
        logger.debug("download: starting for cipher=\(cipherId, privacy: .public) attachment=\(attachment.id, privacy: .public)")

        let keys = try splitKey(cipherKey)
        var encBlob = try await fetchBlob(cipherId: cipherId, attachment: attachment)
        defer { encBlob.resetBytes(in: encBlob.indices) }

        let plaintext = try decrypt(encBlob, of: attachment, keys: keys)
        logger.info("download: decrypted \(plaintext.count, privacy: .public) bytes for \(attachment.id, privacy: .public)")
        return plaintext
    }

    /// Steps 1–2 of `download`: the encrypted file from a fresh URL, else the sync URL.
    private func fetchBlob(cipherId: String, attachment: Attachment) async throws -> Data {
        let downloadURL: URL
        do {
            downloadURL = try await fetchFreshDownloadURL(cipherId: cipherId, attachmentId: attachment.id)
        } catch let error as APIError where statusCode(of: error) == 404 {
            guard let urlString = attachment.url, let syncURL = URL(string: urlString) else { throw error }
            logger.info("download: no fresh URL for \(attachment.id, privacy: .public) (404), using the sync URL")
            downloadURL = syncURL
        } catch {
            // D2 step 5: offline, an unreadable answer, or another status. Vaultwarden answers 400
            // "Attachment doesn't exist" for a record deleted elsewhere; the next sync removes the row.
            logger.error("download: no download URL for \(attachment.id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
            throw AttachmentError.downloadFailed
        }

        do {
            return try await apiClient.downloadBlob(from: downloadURL)
        } catch let error as APIError where statusCode(of: error) == 404 {
            logger.error("download: the server has no file for \(attachment.id, privacy: .public)")
            throw AttachmentError.fileMissingOnServer
        } catch {
            logger.error("download: failed for \(attachment.id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
            throw AttachmentError.downloadFailed
        }
    }

    /// Step 3 of `download`: unwraps the attachment key with `keys` and decrypts `encBlob` in
    /// either layout (fix-attachment-file-format, D2). File errors become messages a user can read.
    private func decrypt(_ encBlob: Data, of attachment: Attachment, keys: CryptoKeys) throws -> Data {
        var attachmentKey = try crypto.decryptAttachmentKey(attachment.encryptedKey, cipherKey: keys)
        defer { attachmentKey.resetBytes(in: attachmentKey.indices) }
        do {
            return try crypto.decryptData(encBlob, attachmentKey: attachmentKey)
        } catch AttachmentCryptoError.malformedBlob, AttachmentCryptoError.unsupportedEncryptionType {
            throw AttachmentError.unsupportedFileFormat
        } catch AttachmentCryptoError.macMismatch, AttachmentCryptoError.decryptionFailed {
            throw AttachmentError.fileDecryptionFailed
        }
    }

    // MARK: - Convert

    /// Converts one attachment like the SDK's `upgrade_attachment` (fix-attachment-file-format,
    /// D4): download, check the old layout, re-upload through `upload` (new attachment key,
    /// official layout, rollback on failure), then delete the old attachment.
    ///
    /// - Security goal: files other Bitwarden apps can open, without a second upload path to audit.
    ///   The plaintext and the downloaded blob are zeroed on every path.
    /// - Intentionally NOT done: overwriting the bytes under the same attachment ID. Neither server
    ///   documents it, and Vaultwarden compares the new size with the stored one.
    func convertLegacyFormat(cipherId: String, attachment: Attachment, downloadKey: Data, uploadKey: Data) async throws -> Attachment {
        let downloadKeys = try splitKey(downloadKey)
        var encBlob = try await fetchBlob(cipherId: cipherId, attachment: attachment)
        defer { encBlob.resetBytes(in: encBlob.indices) }

        // The size hint can be wrong; the blob's own layout decides. A flagged attachment still has
        // to move to the item's key, whatever its layout.
        let layout: AttachmentBlobLayout
        do {
            layout = try AttachmentBlobLayout.of(encBlob)
        } catch {
            throw AttachmentError.unsupportedFileFormat
        }
        guard layout == .legacyPrizm || attachment.wrappedWithPersonalKey else {
            logger.info("convert: \(attachment.id, privacy: .public) is already in the official layout")
            throw AttachmentError.alreadyStandardFormat
        }

        var plaintext = try decrypt(encBlob, of: attachment, keys: downloadKeys)
        defer { plaintext.resetBytes(in: plaintext.indices) }

        let converted = try await upload(cipherId: cipherId, fileName: attachment.fileName, data: plaintext, cipherKey: uploadKey)
        do {
            try await delete(cipherId: cipherId, attachmentId: attachment.id)
        } catch {
            logger.error("convert: \(converted.id, privacy: .public) uploaded, old \(attachment.id, privacy: .public) not deleted: \(ErrorLog.describe(error), privacy: .public)")
            throw AttachmentError.convertedOldCopyLeft
        }
        logger.info("convert: \(attachment.id, privacy: .public) replaced by \(converted.id, privacy: .public)")
        return converted
    }

    // MARK: - Delete

    /// Deletes the attachment from the server, then takes the item from the answer into the local
    /// vault, or patches the list locally when the answer has none (D5).
    func delete(cipherId: String, attachmentId: String) async throws {
        logger.debug("delete: cipher=\(cipherId, privacy: .public) attachment=\(attachmentId, privacy: .public)")
        let answer = try await apiClient.deleteAttachment(cipherId: cipherId, attachmentId: attachmentId)
        if !(await apply(answer, for: cipherId)) {
            logger.info("delete: answer has no usable item, patching the list locally for \(cipherId, privacy: .public)")
            let currentList = (try? await vaultRepository.itemDetail(id: cipherId))?.attachments ?? []
            await vaultRepository.updateAttachments(LegacyAttachmentListPatch.removing(attachmentId, from: currentList),
                                                    for: cipherId)
        }
        logger.info("delete: removed \(attachmentId, privacy: .public)")
    }

    /// Hands the answer's item to the vault; false when there is none or it was not applied.
    private func apply(_ record: RawCipher?, for cipherId: String) async -> Bool {
        guard let record, record.id == cipherId, let recordApplier else { return false }
        return await recordApplier.applyAttachmentChange(record: record, for: cipherId)
    }

    // MARK: - Private helpers

    /// Splits a 64-byte raw cipher key into `CryptoKeys`.
    ///
    /// - Security goal: `CryptoKeys` is required by `PrizmCryptoService` methods;
    ///   the raw Data passed through the domain boundary is split here at the Data layer.
    /// - Throws: `AttachmentCryptoError.invalidKeyLength` if key is not 64 bytes.
    private func splitKey(_ raw: Data) throws -> CryptoKeys {
        guard raw.count >= 64 else {
            throw AttachmentCryptoError.invalidKeyLength
        }
        return CryptoKeys(
            encryptionKey: raw[raw.startIndex..<raw.startIndex.advanced(by: 32)],
            macKey:        raw[raw.startIndex.advanced(by: 32)..<raw.startIndex.advanced(by: 64)]
        )
    }

    /// Fetches a fresh signed download URL for the given attachment.
    private func fetchFreshDownloadURL(cipherId: String, attachmentId: String) async throws -> URL {
        let response = try await apiClient.fetchAttachmentDownloadURL(
            cipherId:     cipherId,
            attachmentId: attachmentId
        )
        guard let url = URL(string: response.url) else {
            throw AttachmentError.downloadFailed
        }
        return url
    }

    /// Extracts the status code from an `APIError.httpError`, or nil for other error types.
    private func statusCode(of error: APIError) -> Int? {
        if case .httpError(let code, _) = error { return code }
        return nil
    }
}
