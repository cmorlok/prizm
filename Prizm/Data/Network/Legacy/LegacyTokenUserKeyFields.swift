import Foundation

// LEGACY(Vaultwarden < 1.35.4, Bitwarden server < v2025.8.0): remove when those versions are no longer supported

/// The top-level `Key` and `Kdf*` fields of a token response, from servers that predate
/// `UserDecryptionOptions.MasterPasswordUnlock` (openspec change `fix-kdf-derivation-and-validation`,
/// design D5).
///
/// `TokenResponse` reads them only when `MasterPasswordUnlock` is absent. The official server marks
/// `Key` "deprecated in favor of UserDecryptionOptions.MasterPasswordUnlock.MasterKeyEncryptedUserKey".
nonisolated struct LegacyTokenUserKeyFields: Equatable {
    /// The user key, encrypted with the stretched master key (EncString).
    let key: String?
    let kdf: WireKdfSettings

    static func read(from c: KeyedDecodingContainer<FirstLetterCaseInsensitiveKey>) throws -> LegacyTokenUserKeyFields {
        LegacyTokenUserKeyFields(
            key: try c.decodeIfPresent(String.self, "key"),
            kdf: WireKdfSettings(
                kdfType:     try c.decodeIfPresent(Int.self, "kdf"),
                iterations:  try c.decodeIfPresent(Int.self, "kdfIterations"),
                memory:      try c.decodeIfPresent(Int.self, "kdfMemory"),
                parallelism: try c.decodeIfPresent(Int.self, "kdfParallelism")
            )
        )
    }
}
