import Foundation
import os.log

// MARK: - ProfileIdCache

/// Holds the profile id (user id) from the last sync, which every cipher create and full update
/// sends as `encryptedFor`.
///
/// - Security goal: `encryptedFor` names the account a cipher was encrypted for, so the server can
///   refuse a cipher that was encrypted for another account. The id therefore comes only from the
///   vault that was synced (`RawProfile.id` of the last sync), never from the Keychain `Account`:
///   the Keychain says who signed in, the sync says whose ciphertext is in memory. Vaultwarden
///   1.37.4 rejects a cipher body without it (HTTP 422); the official server treats it as optional.
///
/// - Lifecycle: set by `SyncRepositoryImpl.sync()` right before it populates the vault, cleared by
///   `VaultRepositoryImpl.clearVault()`, which lock and sign-out both reach. A save without an id
///   fails with `VaultError.profileIdUnavailable` instead of sending a body the server may refuse.
///
/// - Why a type of its own: the id belongs to the account, not to any cipher record, so it is held
///   apart from the cached vault items; its lifetime is the unlocked session (see Lifecycle).
///
/// - Fence: the sync that writes the id passes the record store's generation check
///   (`set(_:ifCurrent:)`), so a sync of an earlier session cannot leave its account's id behind
///   after a lock, also one followed by an unlock or a sign-in as another account. The check runs
///   inside this actor, with no suspension before the write, and `VaultRepositoryImpl.clearVault()`
///   invalidates the store's token before it clears this holder: an id that passed the check is
///   cleared by that lock, and one that arrives later is refused. The id is not a secret (the
///   server sends it with every sync), so it is neither zeroed nor kept out of memory, only kept
///   out of the logs.
actor ProfileIdCache {

    private let logger = Logger(subsystem: "com.prizm", category: "ProfileIdCache")

    private var profileId: String?

    // MARK: - Public API

    /// Stores the profile id of the sync that is about to populate the vault.
    ///
    /// An empty id counts as no id: a server that sends one would get saves it cannot match to an
    /// account, so the saves fail here instead.
    func set(_ id: String) {
        guard !id.isEmpty else {
            profileId = nil
            logger.error("Sync profile id is empty; saves will fail until the next sync")
            return
        }
        profileId = id
        // The id itself is never logged.
        logger.info("ProfileIdCache: profile id captured")
    }

    /// Stores the id only while `isCurrent()` still holds, and says whether it did. A refusal
    /// changes nothing: the id of a sync that was cleared while it ran never reaches a later session.
    @discardableResult
    func set(_ id: String, ifCurrent isCurrent: @Sendable () -> Bool) -> Bool {
        guard isCurrent() else {
            logger.info("ProfileIdCache: profile id refused, the vault was cleared while the sync ran")
            return false
        }
        set(id)
        return true
    }

    /// The profile id of the last sync of this session, or nil before the first sync and after
    /// `clear()`.
    func current() -> String? {
        profileId
    }

    /// Drops the id. Idempotent.
    func clear() {
        profileId = nil
        logger.info("ProfileIdCache: profile id cleared")
    }
}
