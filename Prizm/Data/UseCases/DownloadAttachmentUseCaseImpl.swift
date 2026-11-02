import Foundation

/// Concrete implementation of `DownloadAttachmentUseCase`.
///
/// Resolves the cipher key internally via `VaultKeyService` so that raw key material
/// never surfaces to the Presentation layer (Constitution §II/§III). Forwards to
/// `AttachmentRepository.download` which fetches, decrypts, and returns the file bytes.
final class DownloadAttachmentUseCaseImpl: DownloadAttachmentUseCase {

    private let repository:      any AttachmentRepository
    private let vaultKeyService: any VaultKeyService
    private let gate:            any SessionGate

    init(repository: any AttachmentRepository, vaultKeyService: any VaultKeyService, gate: any SessionGate) {
        self.repository      = repository
        self.vaultKeyService = vaultKeyService
        self.gate            = gate
    }

    /// - Security goal: no decrypted file comes back after a lock started (lock-state-machine,
    ///   design D8, gap 7). The token is taken before the key is resolved; a decryption that was
    ///   running when the lock came finishes on its own copy of the key, and its result is zeroed
    ///   and dropped here.
    func execute(cipherId: String, attachment: Attachment) async throws -> Data {
        let session = gate.begin()
        guard gate.isCurrent(session) else { throw VaultError.vaultLocked }
        // An org attachment that earlier versions wrapped with the personal key opens only with
        // that key (fix-org-attachment-key, D3); everything else uses the item's effective key.
        let cipherKey = attachment.wrappedWithPersonalKey
            ? try await vaultKeyService.personalKey()
            : try await vaultKeyService.cipherKey(for: cipherId)
        var plaintext = try await repository.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
        guard gate.isCurrent(session) else {
            plaintext.resetBytes(in: plaintext.indices)
            throw VaultError.vaultLocked
        }
        return plaintext
    }
}
