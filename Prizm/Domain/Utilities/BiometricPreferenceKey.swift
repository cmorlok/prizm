import Foundation

/// The `UserDefaults` keys of the Touch ID preferences, written by `AuthRepositoryImpl` and read by
/// the unlock and Settings view models. One definition, so a typo cannot split the state
/// (fix-biometric-test-isolation, code review 2026-10-30). The names are unchanged, so stored
/// settings carry over.
nonisolated enum BiometricPreferenceKey {
    /// "Unlock with Touch ID" is on.
    static let unlockEnabled = "biometricUnlockEnabled"
    /// The offer to turn Touch ID unlock on was shown once and answered.
    static let enrollmentPromptShown = "biometricEnrollmentPromptShown"
}
