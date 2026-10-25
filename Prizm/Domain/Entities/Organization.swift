import Foundation

// MARK: - OrgRole

/// The user's membership role within a Bitwarden organization.
/// Derived from the `type` integer in `RawOrganization`.
///
/// Bitwarden API integers: 0=Owner, 1=Admin, 2=User, 3=Manager, 4=Custom.
///
/// `canManageCollections` is a computed property on `Organization` that uses this role.
/// Custom role is intentionally mapped to `false` because the server-side permission flags
/// that govern custom-role collection access are not present in the sync `type` integer.
nonisolated enum OrgRole: Int, Equatable, Hashable {
    case owner   = 0
    case admin   = 1
    case user    = 2
    case manager = 3
    case custom  = 4
}

// MARK: - OrgMembershipId

/// The user's organization-user id (`organizationUserId` in the sync profile), needed to assign the
/// creator to a new collection (fix-collection-access-on-rename). Not a secret.
nonisolated enum OrgMembershipId: Equatable, Hashable {
    case known(String)
    /// The server does not send the field (official servers before v2025.1.0).
    case notSent
    /// The field is present but not a string; Prizm never guesses an id.
    case unreadable
}

// MARK: - Organization

/// A Bitwarden organization the user belongs to.
/// Produced by `CipherMapper` / `SyncRepositoryImpl` from `RawOrganization`.
/// Value type — safe to pass across layers without defensive copying.
nonisolated struct Organization: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let role: OrgRole
    /// No default: an organization built without it would silently take the legacy create path.
    let membershipId: OrgMembershipId

    /// Whether this user may create, rename, and delete collections in this org.
    ///
    /// True for `.owner`, `.admin`, and `.manager`. False for `.user` and `.custom`.
    /// `.custom` defaults to `false` — custom-role collection permissions require server-side
    /// permission flags that are not present in the sync `type` integer (Bitwarden Security
    /// Whitepaper §4). Deny by default.
    var canManageCollections: Bool {
        switch role {
        case .owner, .admin, .manager: return true
        case .user, .custom:           return false
        }
    }
}
