import Foundation
import XCTest
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

    /// 2026-10-26 10:00:00.123 UTC, a whole millisecond.
    ///
    /// A test that saves uses this date for the seeded item and for the draft it saves, so the stored
    /// revision and the draft's revision are equal; two `Date()` values would agree only by luck.
    ///
    /// `nonisolated` so a test class can use it in a stored property's default value.
    nonisolated static let revisionDate = Date(timeIntervalSince1970: 1_793_008_800.123)

    /// `date` in the shape Vaultwarden 1.37.4 writes revisions, for example
    /// `2026-10-26T18:54:01.393000Z`. Defined once, in the UI-test vault's
    /// `UITestFixtures.serverRevisionString(for:)`, so both kinds of test stamp the same format.
    nonisolated static func serverRevisionString(for date: Date) -> String {
        UITestFixtures.serverRevisionString(for: date)
    }

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
        recordStore: RawCipherStore? = nil,
        vaultKeyCache: VaultKeyCache = VaultKeyCache()
    ) async -> VaultRepositoryImpl {
        let holder: ProfileIdCache
        if let profileIds { holder = profileIds } else { holder = await Self.profileIds() }
        return VaultRepositoryImpl(
            apiClient: apiClient, crypto: crypto, mapper: mapper,
            orgKeyCache: orgKeyCache, profileIds: holder, recordStore: recordStore ?? RawCipherStore(),
            vaultKeyCache: vaultKeyCache
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
    ///
    /// Each record carries its item's `revisionDate` in the server's format, the base a save's
    /// stale-write check reads. The date must be a whole millisecond (`RepositoryFixtures.revisionDate`
    /// is one) and the draft saved for the item must use the same date; the helper throws otherwise.
    static func seedRecords(
        for items: [VaultItem],
        in store: RawCipherStore,
        vaultKeys: CryptoKeys,
        orgKeys: [String: CryptoKeys] = [:]
    ) async throws {
        let mapper = CipherMapper()
        for item in items {
            // The stored revision and the revision of the draft saved for the item must be equal for
            // the save to pass the stale-write check, and two `Date()` values agree only by luck. The
            // tolerance absorbs the floating-point error of a decimal millisecond (a date built from
            // the reference date can sit a hair off the whole millisecond) and nothing else.
            let milliseconds = item.revisionDate.timeIntervalSince1970 * 1000
            guard abs(milliseconds - milliseconds.rounded()) <= 0.001 else {
                throw SeedError(description: "revisionDate of \(item.id) is not a whole millisecond; use RepositoryFixtures.revisionDate")
            }
            let keys: CryptoKeys
            if let organizationId = item.organizationId {
                guard let orgKey = orgKeys[organizationId] else {
                    throw SeedError(description: "No organization key for \(organizationId), needed to seed item \(item.id)")
                }
                keys = orgKey
            } else {
                keys = vaultKeys
            }
            let record = try mapper.toNewRawCipher(DraftVaultItem(item), encryptedWith: keys, encryptedFor: RepositoryFixtures.profileId)
            let mappedBack = try mapper.map(raw: record, vaultKeys: vaultKeys, orgKeys: orgKeys).item
            guard mappedBack.name == item.name else {
                throw SeedError(description: "Seeded record of item \(item.id) does not map back to its name")
            }
            let stamped = try withRevision(record, RepositoryFixtures.serverRevisionString(for: item.revisionDate))
            let token = await store.currentGeneration()
            await store.upsert(stamped, ifCurrent: token)
        }
    }

    /// Makes `api` answer every full update with the request it received, stamped with `date` in the
    /// server's format, instead of the bare echo the mock gives (a request carries no revision, and
    /// the record a save leaves in the store must have one for the next save of the same item).
    ///
    /// Installs `whileUpdatingCipher`, so a test that needs that hook for something else sets its own.
    static func answerUpdatesWithRevision(of api: MockPrizmAPIClient, _ date: Date = RepositoryFixtures.revisionDate) {
        answerUpdates(of: api, withRevisionString: serverRevisionString(for: date))
    }

    /// The same with a revision string as it is, for a test whose stored record carries its own
    /// (a fixture record with six fractional digits, say).
    ///
    /// `collectionsRevision` and `getRevision` also prepare the answers to the requests an
    /// organization save sends after the PUT (`/collections`, and the fetch that replaces a
    /// collections answer without a cipher). Both carry the content the PUT sent, as a server's do,
    /// and only the revision differs: a follow-up answer built from the record stored before the
    /// save would hold another client's content and is not a conflict-free refresh.
    static func answerUpdates(
        of api: MockPrizmAPIClient, withRevisionString revision: String,
        collectionsRevision: String? = nil, getRevision: String? = nil
    ) {
        api.whileUpdatingCipher = { [api] in
            // A failure is reported here, not skipped: without the stamped answer the mock echoes the
            // request (which has no revision) and the next save fails with `itemRevisionUnavailable`,
            // far from the cause.
            guard let sent = api.lastUpdatedCipher else {
                XCTFail("answerUpdates: no update request was recorded, so there is nothing to answer")
                return
            }
            do {
                api.updateCipherResponse = try withRevision(sent, revision)
                if let collectionsRevision {
                    api.updateCipherCollectionsResponse = try withRevision(sent, collectionsRevision)
                }
                if let getRevision {
                    api.getCipherResponses[sent.id] = try withRevision(sent, getRevision)
                }
            } catch {
                XCTFail("answerUpdates: could not stamp the answer for \(sent.id): \(error)")
            }
        }
    }

    /// `record` with another `revisionDate` (`UITestFixtures.withRevision`, the one definition).
    ///
    /// Also what a test that saves twice uses for the server's answer to the first save: the API mock
    /// echoes the request, which carries no revision, and a server record always has one.
    nonisolated static func withRevision(_ record: RawCipher, _ revision: String) throws -> RawCipher {
        try UITestFixtures.withRevision(record, revision)
    }
}
