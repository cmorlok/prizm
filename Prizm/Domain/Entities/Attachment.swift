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
    /// True for an attachment of an organization item without its own key whose file name and key
    /// were encrypted with the user's personal key (Prizm before fix-org-attachment-key). Only this
    /// user can open it; the download unwraps its key with the personal key (design D3).
    var wrappedWithPersonalKey: Bool = false
    /// True when the encrypted size the server reports is a multiple of 16: the file is probably in
    /// the layout Prizm 1.1.0 to 1.5.x wrote, which other Bitwarden apps can't open. A hint for the
    /// UI only; the download checks the real layout (fix-attachment-file-format, D3).
    var storedInLegacyPrizmFormat: Bool = false
}
