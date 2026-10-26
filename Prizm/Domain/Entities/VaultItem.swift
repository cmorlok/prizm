import Foundation

/// A fully-decrypted vault entry. Produced by `CipherMapper` from a `RawCipher`.
/// Value type — safe to pass across layers without defensive copying.
nonisolated struct VaultItem: Identifiable, Equatable, Hashable {
    let id: String
    /// Settable only inside this file, for `with(folderId:)`.
    private(set) var folderId: String?
    let name: String
    /// Settable only inside this file, for `with(isFavorite:)`.
    private(set) var isFavorite: Bool
    let isDeleted: Bool
    let creationDate: Date
    let revisionDate: Date
    let content: ItemContent
    /// Master-password re-prompt setting mirrored from the Bitwarden wire format.
    /// 0 = disabled (default), 1 = require master password before revealing fields.
    /// Stored here so `CipherMapper.toRawCipher` can round-trip it unchanged on PUT,
    /// preventing silent loss of re-prompt protection during edits.
    let reprompt: Int
    /// File attachments belonging to this vault item.
    /// Empty (`[]`) when the server returns no attachments or an explicit `null`.
    let attachments: [Attachment]
    /// Non-nil when this item belongs to a Bitwarden organization.
    /// Nil for personal vault items.
    let organizationId: String?
    /// The collections this item is assigned to within its organization.
    /// Empty (`[]`) for personal items and org items not assigned to any collection.
    let collectionIds: [String]

    /// Custom memberwise init with `reprompt` defaulted to 0, `attachments` defaulted to `[]`,
    /// `organizationId` defaulted to nil, and `collectionIds` defaulted to `[]` so existing
    /// call sites that pre-date these fields do not need to be updated.
    init(
        id: String, name: String, isFavorite: Bool, isDeleted: Bool,
        creationDate: Date, revisionDate: Date, content: ItemContent,
        reprompt: Int = 0,
        attachments: [Attachment] = [],
        folderId: String? = nil,
        organizationId: String? = nil,
        collectionIds: [String] = []
    ) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
        self.creationDate = creationDate
        self.revisionDate = revisionDate
        self.content = content
        self.reprompt = reprompt
        self.attachments = attachments
        self.organizationId = organizationId
        self.collectionIds = collectionIds
    }
}

// MARK: - Single-field copies

nonisolated extension VaultItem {
    /// A copy in another folder (nil: no folder), with every other field kept.
    ///
    /// Local updates must go through these helpers, not the initializer: its defaulted arguments
    /// silently dropped `organizationId` and `collectionIds` when moving org items to a folder
    /// (fix-favorite-and-folder-partial-updates). Copying `self` keeps every field, including
    /// ones added later.
    func with(folderId: String?) -> VaultItem {
        var copy = self
        copy.folderId = folderId
        return copy
    }

    /// A copy with the favorite state changed, with every other field kept.
    func with(isFavorite: Bool) -> VaultItem {
        var copy = self
        copy.isFavorite = isFavorite
        return copy
    }
}

// MARK: - Item content discriminator

/// Discriminated union of all five Bitwarden vault item types.
nonisolated enum ItemContent: Equatable, Hashable {
    case login(LoginContent)
    case secureNote(SecureNoteContent)
    case card(CardContent)
    case identity(IdentityContent)
    case sshKey(SSHKeyContent)
}

// MARK: - Login

nonisolated struct LoginContent: Equatable, Hashable {
    let username: String?
    let password: String?
    let uris: [LoginURI]
    /// Stored TOTP seed. Present on some items. The raw seed is never displayed or copied; only the
    /// generated one-time code derived from it is shown (see `GenerateTOTPCodeUseCase`).
    let totp: String?
    let notes: String?
    let customFields: [CustomField]
}

nonisolated struct LoginURI: Equatable, Hashable {
    let uri: String
    let matchType: URIMatchType?
}

/// URI-matching strategy used when auto-filling (stored per URI, not used in v1 display).
nonisolated enum URIMatchType: Int, Equatable, Hashable {
    case domain = 0
    case host = 1
    case startsWith = 2
    case exact = 3
    case regularExpression = 4
    case never = 5
}

// MARK: - Card

nonisolated struct CardContent: Equatable, Hashable {
    let cardholderName: String?
    let brand: String?
    let number: String?
    let expMonth: String?
    let expYear: String?
    let code: String?
    let notes: String?
    let customFields: [CustomField]
}

// MARK: - Identity

nonisolated struct IdentityContent: Equatable, Hashable {
    let title: String?
    let firstName: String?
    let middleName: String?
    let lastName: String?
    let address1: String?
    let address2: String?
    let address3: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
    let company: String?
    let email: String?
    let phone: String?
    let ssn: String?
    let username: String?
    let passportNumber: String?
    let licenseNumber: String?
    let notes: String?
    let customFields: [CustomField]
}

// MARK: - Secure Note

nonisolated struct SecureNoteContent: Equatable, Hashable {
    let notes: String?
    let customFields: [CustomField]
}

// MARK: - SSH Key

nonisolated struct SSHKeyContent: Equatable, Hashable {
    let privateKey: String?
    let publicKey: String?
    let keyFingerprint: String?
    let notes: String?
    let customFields: [CustomField]
}

nonisolated extension VaultItem {
    /// True for a Login whose stored TOTP seed is not blank. This only says a seed *exists*;
    /// whether it can produce a code is decided by `TOTPSeedParser`.
    var hasTOTPSeed: Bool {
        guard case .login(let login) = content, let seed = login.totp else { return false }
        return !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
