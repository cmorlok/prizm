import Foundation

/// A Bitwarden collection belonging to an organization.
/// Produced by `SyncRepositoryImpl` from `RawCollection` (name decrypted with the org key).
/// Value type — safe to pass across layers without defensive copying.
///
/// Named `OrgCollection` to avoid shadowing the `Swift.Collection` protocol in files
/// that import this module.
nonisolated struct OrgCollection: Identifiable, Equatable, Hashable {
    let id: String
    let organizationId: String
    let name: String
    /// The user can see the collection's items but not add items to it or remove them from it
    /// (fix-collection-assignment, D1).
    let readOnly: Bool

    init(id: String, organizationId: String, name: String, readOnly: Bool = false) {
        self.id = id
        self.organizationId = organizationId
        self.name = name
        self.readOnly = readOnly
    }
}
