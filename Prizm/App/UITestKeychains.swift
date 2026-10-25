#if DEBUG
import Foundation
import LocalAuthentication

/// In-memory `KeychainService` for XCUITest runs (openspec change `fix-ui-test-target`, design D2).
///
/// Active only in a `--ui-test-*` launch state, so a UI test that locks or signs out acts on this
/// store and never reads, writes or deletes the developer's real keychain items. Compiled out of
/// Release builds.
final class InMemoryKeychainService: KeychainService {

    private var store: [String: Data] = [:]

    func write(data: Data, key: String) throws {
        store[key] = data
    }

    func read(key: String) throws -> Data {
        guard let data = store[key] else { throw KeychainError.itemNotFound }
        return data
    }

    func delete(key: String) throws {
        store.removeValue(forKey: key)
    }
}

/// In-memory `BiometricKeychainService` for XCUITest runs (design D2).
///
/// Performs no biometric evaluation: Touch ID journeys are skipped until simulated biometrics
/// exist (follow-up change `ui-test-biometrics`). Its only job is to keep a test run away from the
/// developer's real biometric keychain item.
final class InMemoryBiometricKeychainService: BiometricKeychainService {

    private var store: [String: Data] = [:]

    func writeBiometric(data: Data, key: String) throws {
        store[key] = data
    }

    func readBiometric(key: String) async throws -> Data {
        guard let data = store[key] else { throw KeychainError.itemNotFound }
        return data
    }

    func readBiometric(key: String, context: LAContext) async throws -> Data {
        try await readBiometric(key: key)
    }

    func deleteBiometric(key: String) throws {
        store.removeValue(forKey: key)
    }
}
#endif
