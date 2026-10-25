import Foundation

// MARK: - Collection access wire models
//
// A collection's access list (members and groups with their permissions) must be sent back
// unchanged when the collection is renamed: both servers replace the stored list with the one in
// the request, so an empty list removes everyone's access (fix-collection-access-on-rename).

/// One member or group with its permissions on a collection. `id` is the organization-user id or
/// the group id.
nonisolated struct CollectionAccessSelection: Codable, Equatable {
    let id: String
    let readOnly: Bool
    let hidePasswords: Bool
    let manage: Bool

    init(id: String, readOnly: Bool, hidePasswords: Bool, manage: Bool) {
        self.id = id
        self.readOnly = readOnly
        self.hidePasswords = hidePasswords
        self.manage = manage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id            = try (try? c.decode(String.self, forKey: .id)) ?? c.decode(String.self, forKey: .idUpper)
        readOnly      = try (try? c.decode(Bool.self, forKey: .readOnly)) ?? c.decode(Bool.self, forKey: .readOnlyUpper)
        hidePasswords = try (try? c.decode(Bool.self, forKey: .hidePasswords)) ?? c.decode(Bool.self, forKey: .hidePasswordsUpper)
        manage        = Self.decodeManage(c)
    }

    // LEGACY(Vaultwarden < 1.33.0): remove when those versions are no longer supported
    /// Vaultwarden before 1.33.0 has no Manage permission: its selections are only
    /// `{id, readOnly, hidePasswords}`. A missing `manage` is false there; those versions ignore the
    /// field when it is sent back.
    private static func decodeManage(_ c: KeyedDecodingContainer<Keys>) -> Bool {
        (try? c.decode(Bool.self, forKey: .manage)) ?? (try? c.decode(Bool.self, forKey: .manageUpper)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(readOnly, forKey: .readOnly)
        try c.encode(hidePasswords, forKey: .hidePasswords)
        try c.encode(manage, forKey: .manage)
    }

    private enum Keys: String, CodingKey {
        case id, readOnly, hidePasswords, manage
        case idUpper = "Id", readOnlyUpper = "ReadOnly", hidePasswordsUpper = "HidePasswords", manageUpper = "Manage"
    }
}

/// Response of `GET /api/organizations/{orgId}/collections/{id}/details` (Vaultwarden
/// `get_org_collection_detail`, Bitwarden `CollectionsController.GetDetails`). `users` and `groups`
/// are nil when the server did not send them, which a rename must not treat as "no access".
nonisolated struct CollectionAccessDetailsResponse: Decodable, Equatable {
    let id: String
    let organizationId: String
    let name: String
    let externalId: String?
    let users: [CollectionAccessSelection]?
    let groups: [CollectionAccessSelection]?

    init(id: String, organizationId: String, name: String, externalId: String?,
         users: [CollectionAccessSelection]?, groups: [CollectionAccessSelection]?) {
        self.id = id
        self.organizationId = organizationId
        self.name = name
        self.externalId = externalId
        self.users = users
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id             = try (try? c.decode(String.self, forKey: .id)) ?? c.decode(String.self, forKey: .idUpper)
        organizationId = try (try? c.decode(String.self, forKey: .organizationId)) ?? c.decode(String.self, forKey: .organizationIdUpper)
        name           = try (try? c.decode(String.self, forKey: .name)) ?? c.decode(String.self, forKey: .nameUpper)
        externalId     = (try? c.decodeIfPresent(String.self, forKey: .externalId)) ?? (try? c.decodeIfPresent(String.self, forKey: .externalIdUpper)) ?? nil
        users          = try c.decodeIfPresent([CollectionAccessSelection].self, forKey: .users)
                         ?? c.decodeIfPresent([CollectionAccessSelection].self, forKey: .usersUpper)
        groups         = try c.decodeIfPresent([CollectionAccessSelection].self, forKey: .groups)
                         ?? c.decodeIfPresent([CollectionAccessSelection].self, forKey: .groupsUpper)
    }

    private enum Keys: String, CodingKey {
        case id, organizationId, name, externalId, users, groups
        case idUpper = "Id", organizationIdUpper = "OrganizationId", nameUpper = "Name"
        case externalIdUpper = "ExternalId", usersUpper = "Users", groupsUpper = "Groups"
    }
}

/// Body of `POST /api/organizations/{orgId}/collections` and `PUT …/collections/{id}`.
/// `externalId` is always sent, as JSON null when absent: both servers take it from the body.
nonisolated struct CollectionWriteRequest: Encodable, Equatable {
    let name: String
    let externalId: String?
    let users: [CollectionAccessSelection]
    let groups: [CollectionAccessSelection]

    private enum Keys: String, CodingKey { case name, externalId, users, groups }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        if let externalId { try c.encode(externalId, forKey: .externalId) } else { try c.encodeNil(forKey: .externalId) }
        try c.encode(users, forKey: .users)
        try c.encode(groups, forKey: .groups)
    }
}
