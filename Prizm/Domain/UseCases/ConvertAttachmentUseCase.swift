import Foundation

// MARK: - ConvertAttachmentUseCase

/// Converts an attachment saved by Prizm 1.1.0 to 1.5.x into the official Bitwarden file layout
/// (openspec change fix-attachment-file-format, D4), and moves an organization attachment that was
/// wrapped with the personal key to the organization key (fix-org-attachment-key, D4).
///
/// The keys are resolved internally via `VaultKeyService`, as for upload and download, so no key
/// material reaches the Presentation layer (Constitution §II/§III).
///
/// Implemented by `ConvertAttachmentUseCaseImpl` in the Data layer.
protocol ConvertAttachmentUseCase: AnyObject {

    /// Re-uploads the file as a new attachment and deletes the old one.
    ///
    /// - Returns: The new attachment.
    /// - Throws: see `AttachmentRepository.convertLegacyFormat`, and `VaultError` from key resolution.
    func execute(cipherId: String, attachment: Attachment) async throws -> Attachment
}
