import Foundation

// MARK: - ConvertAttachmentUseCaseImpl

/// Concrete implementation of `ConvertAttachmentUseCase`.
///
/// Reads the old attachment key with the key it was wrapped with (the personal key for an
/// attachment flagged `wrappedWithPersonalKey`, otherwise the item's effective key) and writes the
/// new one with the item's effective key, so a converted organization attachment opens for every
/// member (fix-org-attachment-key, D3/D4).
final class ConvertAttachmentUseCaseImpl: ConvertAttachmentUseCase {

    private let repository:      any AttachmentRepository
    private let vaultKeyService: any VaultKeyService
    /// Attachments being converted now. The row's Convert and "Convert all" share this use case; a
    /// second conversion of a file while the first runs would upload a duplicate.
    private let running = RunningConversions()

    init(repository: any AttachmentRepository, vaultKeyService: any VaultKeyService) {
        self.repository      = repository
        self.vaultKeyService = vaultKeyService
    }

    func execute(cipherId: String, attachment: Attachment) async throws -> Attachment {
        guard await running.begin(attachment.id) else { throw AttachmentError.conversionAlreadyRunning }
        do {
            let uploadKey = try await vaultKeyService.cipherKey(for: cipherId)
            let downloadKey = attachment.wrappedWithPersonalKey ? try await vaultKeyService.personalKey() : uploadKey
            let converted = try await repository.convertLegacyFormat(
                cipherId: cipherId, attachment: attachment, downloadKey: downloadKey, uploadKey: uploadKey)
            await running.end(attachment.id)
            return converted
        } catch {
            await running.end(attachment.id)
            throw error
        }
    }
}

/// The IDs of the attachments being converted.
private actor RunningConversions {
    private var ids: Set<String> = []

    /// False when `id` is already being converted.
    func begin(_ id: String) -> Bool { ids.insert(id).inserted }

    func end(_ id: String) { ids.remove(id) }
}
