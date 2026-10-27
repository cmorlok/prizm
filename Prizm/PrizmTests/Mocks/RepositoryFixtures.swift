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
}
