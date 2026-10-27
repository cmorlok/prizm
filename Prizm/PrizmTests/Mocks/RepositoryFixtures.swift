import Foundation
@testable import Prizm

/// The one place tests build `VaultRepositoryImpl` and `SyncRepositoryImpl`.
///
/// Both take a `ProfileIdCache` that has no default (production wires one shared instance in
/// `AppContainer`). The helper seeds it with the id the mock sync profile uses, so a test that only
/// saves does not have to sync first, and a later change to how the repositories are built changes
/// this file instead of every test. The argument labels equal the initializers' labels.
///
/// A test that combines a sync repository and a vault repository passes one shared holder to both,
/// as `AppContainer` does; without it each call makes its own. The same holds for `recordStore`:
/// both repositories must get the same `RawCipherStore`, or what a sync stores is not what a save
/// sees. A fresh store is built when none is passed.
///
/// `@MainActor`: the repository initializers are main-actor isolated in this module, as the tests
/// that call them are.
@MainActor
enum RepositoryFixtures {

    /// The profile id of the default sync response of `MockPrizmAPIClient`.
    static let profileId = "pid"

    /// A holder seeded with `id`, or an empty one when `id` is nil.
    static func profileIds(seededWith id: String? = profileId) async -> ProfileIdCache {
        let holder = ProfileIdCache()
        if let id { await holder.set(id) }
        return holder
    }

    /// `profileIds` nil builds a fresh holder seeded with `profileId`; `recordStore` nil builds a
    /// fresh store.
    static func vaultRepository(
        apiClient:   any PrizmAPIClientProtocol,
        crypto:      any PrizmCryptoService,
        mapper:      CipherMapper = CipherMapper(),
        orgKeyCache: OrgKeyCache = OrgKeyCache(),
        profileIds:  ProfileIdCache? = nil,
        recordStore: RawCipherStore? = nil
    ) async -> VaultRepositoryImpl {
        let holder: ProfileIdCache
        if let profileIds { holder = profileIds } else { holder = await Self.profileIds() }
        return VaultRepositoryImpl(
            apiClient: apiClient, crypto: crypto, mapper: mapper,
            orgKeyCache: orgKeyCache, profileIds: holder, recordStore: recordStore ?? RawCipherStore()
        )
    }

    /// `profileIds` nil builds a fresh holder seeded with `profileId`; `recordStore` nil builds a
    /// fresh store.
    static func syncRepository(
        apiClient:       any PrizmAPIClientProtocol,
        crypto:          any PrizmCryptoService,
        vaultRepository: any VaultRepository,
        vaultKeyCache:   VaultKeyCache,
        orgKeyCache:     OrgKeyCache = OrgKeyCache(),
        profileIds:      ProfileIdCache? = nil,
        recordStore:     RawCipherStore? = nil
    ) async -> SyncRepositoryImpl {
        let holder: ProfileIdCache
        if let profileIds { holder = profileIds } else { holder = await Self.profileIds() }
        return SyncRepositoryImpl(
            apiClient: apiClient, crypto: crypto, vaultRepository: vaultRepository,
            vaultKeyCache: vaultKeyCache, orgKeyCache: orgKeyCache, profileIds: holder,
            recordStore: recordStore ?? RawCipherStore()
        )
    }

    /// A test setup failure of `seedRecords`, kept apart from the production error types so a seeding
    /// problem is never mistaken for behaviour under test.
    struct SeedError: Error, CustomStringConvertible {
        let description: String
    }

    /// Stores one server record per item, as a sync would have, so a later `update()` has a record to
    /// save over.
    ///
    /// Why: from the effective-key write on, a save without a stored record fails closed, so every
    /// test that saves an item must first store the record the save is built on. Each record is built
    /// with the create-path mapper, so its fields are real type-2 EncStrings, under the vault key or,
    /// for an organization item, under that organization's key from `orgKeys`.
    ///
    /// The keys must be the ones the test's crypto returns from `currentKeys()` (and the org keys the
    /// test puts into its `OrgKeyCache`), otherwise the repository cannot read the record back.
    ///
    /// There is deliberately no fallback to the vault key for an organization item whose key is
    /// missing: the helper throws, so a test can never hide the fail-closed behaviour it is meant to
    /// exercise. Every record is mapped back and its name compared before it is stored, which catches
    /// a seed under the wrong key in the helper and not as a confusing failure later.
    static func seedRecords(
        for items: [VaultItem],
        in store: RawCipherStore,
        vaultKeys: CryptoKeys,
        orgKeys: [String: CryptoKeys] = [:]
    ) async throws {
        let mapper = CipherMapper()
        for item in items {
            let keys: CryptoKeys
            if let organizationId = item.organizationId {
                guard let orgKey = orgKeys[organizationId] else {
                    throw SeedError(description: "No organization key for \(organizationId), needed to seed item \(item.id)")
                }
                keys = orgKey
            } else {
                keys = vaultKeys
            }
            let record = try mapper.toRawCipher(DraftVaultItem(item), encryptedWith: keys)
            let mappedBack = try mapper.map(raw: record, vaultKeys: vaultKeys, orgKeys: orgKeys).item
            guard mappedBack.name == item.name else {
                throw SeedError(description: "Seeded record of item \(item.id) does not map back to its name")
            }
            let token = await store.currentGeneration()
            await store.upsert(record, ifCurrent: token)
        }
    }
}
