import Foundation

// MARK: - AttachmentDTO

/// Wire-format model for a file attachment returned by the Bitwarden `/sync` API
/// inside the `Ciphers[].Attachments[]` array.
///
/// All sensitive string fields (`fileName`, `key`) are EncStrings; the client
/// decrypts them during sync mapping via `AttachmentMapper`.
///
/// Reference: Bitwarden Server API `/api/sync` response body,
/// `Ciphers[].Attachments[]` array.
nonisolated struct AttachmentDTO: Codable {
    /// Server-assigned attachment ID.
    let id:       String
    /// Encrypted file name — type-2 EncString (`2.<iv>|<ct>|<mac>`).
    /// Decrypted by `AttachmentMapper` using the cipher's effective key.
    let fileName: String          // EncString
    /// Per-attachment symmetric key wrapped as a type-2 EncString using the cipher's
    /// effective key. Stored verbatim on the domain `Attachment` entity as `encryptedKey`;
    /// decrypted on demand during download/upload in `AttachmentRepositoryImpl`.
    let key:      String          // EncString
    /// File size in bytes, encoded as a string by the server (e.g. "1048576").
    /// Parsed to `Int` by `AttachmentMapper`; throws on non-numeric values.
    let size:     String
    /// Human-readable size string computed by the server (e.g. "1 MB").
    /// Mapped verbatim to `Attachment.sizeName` — not reformatted by the client.
    let sizeName: String
    /// Signed download URL from the sync, short-lived. Used only when a fresh URL cannot be
    /// fetched (fix-attachment-transfer-flow, D2); nil or absent says nothing about the file.
    let url:      String?
}
