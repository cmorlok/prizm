import Foundation

/// KDF settings as the servers send them: prelogin `kdfSettings` and the token response's
/// `UserDecryptionOptions.MasterPasswordUnlock.Kdf` (`{ kdfType, iterations, memory, parallelism }`,
/// memory in MiB).
///
/// `kdfParams` is nil for an unknown KDF type or a missing iteration count; login then refuses the
/// settings as unusable (fix-kdf-derivation-and-validation, D2 and D5). Range checks are left to
/// `KdfValidator`.
nonisolated struct WireKdfSettings: Decodable, Equatable {
    let kdfType:     Int?
    let iterations:  Int?
    let memory:      Int?
    let parallelism: Int?

    init(kdfType: Int?, iterations: Int?, memory: Int?, parallelism: Int?) {
        self.kdfType     = kdfType
        self.iterations  = iterations
        self.memory      = memory
        self.parallelism = parallelism
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FirstLetterCaseInsensitiveKey.self)
        kdfType     = try c.decodeIfPresent(Int.self, "kdfType")
        iterations  = try c.decodeIfPresent(Int.self, "iterations")
        memory      = try c.decodeIfPresent(Int.self, "memory")
        parallelism = try c.decodeIfPresent(Int.self, "parallelism")
    }

    var kdfParams: KdfParams? {
        guard let type = kdfType.flatMap(WireKdfSettings.kdfType(_:)), let iterations else { return nil }
        return KdfParams(type: type, iterations: iterations, memory: memory, parallelism: parallelism)
    }

    /// Bitwarden `KdfType`: 0 = PBKDF2-SHA256, 1 = Argon2id. Anything else is unknown and refused,
    /// never guessed.
    static func kdfType(_ raw: Int) -> KdfType? {
        switch raw {
        case 0: .pbkdf2
        case 1: .argon2id
        default: nil
        }
    }
}
