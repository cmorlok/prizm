import Foundation

// MARK: - Attachment

/// A decrypted file attachment record belonging to a vault cipher.
///
/// Produced by `AttachmentMapper` from an `AttachmentDTO`. The `fileName` field
/// is plaintext (decrypted from the EncString in the sync payload). The
/// `encryptedKey` is the per-attachment key wrapped as a type-2 EncString;
/// it is preserved verbatim and decrypted on demand when a file operation
/// (upload, download) is required.
///
/// Value type — safe to pass across layers without defensive copying.
nonisolated struct Attachment: Identifiable, Equatable, Hashable {
    /// Server-assigned attachment ID.
    let id: String
    /// Plaintext file name (decrypted from EncString at sync time).
    let fileName: String
    /// Per-attachment key wrapped as a type-2 EncString — NOT decrypted at
    /// rest in the domain entity. Decrypted on demand inside `AttachmentRepositoryImpl`
    /// when a download or upload operation is performed.
    let encryptedKey: String
    /// File size in bytes, parsed from the server's `size` string field.
    let size: Int
    /// Human-readable file size string supplied by the server (e.g. "1.2 MB").
    /// Stored verbatim; not reformatted by the client to match what the server computed.
    let sizeName: String
    /// Download URL from the sync payload. Signed and short-lived (Vaultwarden: about 90 seconds),
    /// so a download always asks for a fresh one first and uses this only when that request
    /// answers 404, as the official clients do (fix-attachment-transfer-flow, D2). Nil right after
    /// an upload whose answer carried no item.
    let url: String?
}
