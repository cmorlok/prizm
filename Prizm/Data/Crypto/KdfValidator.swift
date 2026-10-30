import Foundation

// MARK: - KdfValidator

/// Checks KDF settings before any master key is derived, at login and at unlock (openspec change
/// `fix-kdf-derivation-and-validation`, design D2 and D4).
///
/// - Security goal: a malicious or compromised server, or anyone who can answer prelogin, must not
///   make Prizm send a password hash that is cheap to brute-force offline ("pre-login downgrade",
///   as the official clients call it), nor make Prizm trap or exhaust memory with absurd values.
/// - Minimums: those of the Bitwarden SDK (`bitwarden-crypto/src/keys/kdf.rs`): PBKDF2 ≥ 5000
///   iterations; Argon2id ≥ 2 iterations, ≥ 16 MiB memory, parallelism ≥ 1. Below them: `.tooWeak`.
/// - Deviation from the SDK, stricter on purpose: Argon2id memory above 1024 MiB and parallelism
///   above 16 are `.invalid`. Both servers refuse to store larger values, so no real account has
///   them, and they would let a server exhaust the Mac's memory (design D4). Iterations get no cap
///   beyond what the KDF APIs accept (`UInt32`), so no real account is locked out. Accepted risk:
///   a hostile server can send a huge count and keep the CPU busy for a long time; the user can
///   quit Prizm, and nothing leaks (design, Risks).
/// - Intentionally NOT done: warn and continue. Every official client refuses; so does Prizm.
nonisolated enum KdfValidator {

    enum Refusal: Equatable {
        /// Usable, but below the minimums.
        case tooWeak
        /// Unknown or missing values, zero or negative values, values above the caps or above
        /// what the KDF APIs accept.
        case invalid
    }

    enum Limits {
        static let pbkdf2MinIterations = 5_000
        static let argon2MinIterations = 2
        static let argon2MinMemoryMiB = 16
        static let argon2MaxMemoryMiB = 1_024
        static let argon2MaxParallelism = 16
        static let maxIterations = Int(UInt32.max)
    }

    /// Nil when `kdf` may be used.
    static func check(_ kdf: KdfParams) -> Refusal? {
        switch kdf.type {
        case .pbkdf2:
            guard (1...Limits.maxIterations).contains(kdf.iterations) else { return .invalid }
            return kdf.iterations < Limits.pbkdf2MinIterations ? .tooWeak : nil
        case .argon2id:
            guard let memory = kdf.memory, let parallelism = kdf.parallelism,
                  (1...Limits.maxIterations).contains(kdf.iterations),
                  (1...Limits.argon2MaxMemoryMiB).contains(memory),
                  (1...Limits.argon2MaxParallelism).contains(parallelism) else { return .invalid }
            // The SDK's parallelism minimum of 1 is enforced by the range check above.
            let weak = kdf.iterations < Limits.argon2MinIterations || memory < Limits.argon2MinMemoryMiB
            return weak ? .tooWeak : nil
        }
    }
}
