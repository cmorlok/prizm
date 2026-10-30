import Foundation

// LEGACY(Vaultwarden < 1.37.0, Bitwarden server < v2025.12.0): remove when those versions are no longer supported

/// The flat KDF fields of a prelogin response (`kdf`, `kdfIterations`, `kdfMemory`,
/// `kdfParallelism`), from servers that predate `kdfSettings` (openspec change
/// `fix-kdf-derivation-and-validation`, design D5).
///
/// `PreLoginResponse` reads them only when `kdfSettings` is absent. Newer servers still send both,
/// and the official server marks the flat fields for removal ("PM-28143 Remove with cleanup").
nonisolated enum LegacyPreloginKdfFields {

    static func read(from c: KeyedDecodingContainer<FirstLetterCaseInsensitiveKey>) throws -> WireKdfSettings {
        WireKdfSettings(
            kdfType:     try c.decodeIfPresent(Int.self, "kdf"),
            iterations:  try c.decodeIfPresent(Int.self, "kdfIterations"),
            memory:      try c.decodeIfPresent(Int.self, "kdfMemory"),
            parallelism: try c.decodeIfPresent(Int.self, "kdfParallelism")
        )
    }
}
