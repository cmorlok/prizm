import Foundation

/// Why Prizm refuses to edit an item. Set only by the Data layer, from the server record
/// (`CipherMapper.editBlock(for:)`); Presentation shows its message and never looks at raw shapes.
nonisolated enum EditBlockReason: Equatable, Hashable, Sendable {
    /// Another Bitwarden client gave the item its own encryption key, and the save path does not yet
    /// send or use that key, so a save would re-encrypt the item under the wrong key. Temporary: it
    /// goes when saves are written with the item's own key.
    case hasOwnKey

    /// The server stores this item as an encrypted blob in a format Prizm does not understand
    /// (its legacy `data` field holds a record with a `format_version`). Saving the typed fields
    /// would make the official server ignore them or overwrite the blob.
    case unsupportedFormat

    /// The server sent only part of this item (a non-null `partialData`), so Prizm does not hold
    /// the whole record and a save would write back less than the server has.
    case partiallyAvailable

    /// The item's type says it has a login, card, identity or SSH key section, but the server sent
    /// none, so there is nothing for Prizm to rebuild the item from. Saving would write an empty
    /// section over whatever the server holds.
    case unmappable

    /// Plain language plus a next step, no jargon. Shown in the detail pane, read by VoiceOver as
    /// the Edit button's hint, and used as the error text when a save is refused.
    var userMessage: String {
        switch self {
        case .hasOwnKey:
            return "Prizm can't edit items with their own encryption key yet. Edit it in the Bitwarden web vault or browser extension."
        case .unsupportedFormat:
            return "This item uses a format Prizm can't edit yet. Edit it in the Bitwarden web vault or browser extension."
        case .partiallyAvailable:
            return "Prizm received only part of this item, so it can't be edited here. Edit it in the Bitwarden web vault or browser extension."
        case .unmappable:
            return "Some of this item's details are missing, so Prizm can't edit it without losing data. Edit it in the Bitwarden web vault or browser extension."
        }
    }
}

/// A fully-decrypted vault entry. Produced by `CipherMapper` from a `RawCipher`.
/// Value type — safe to pass across layers without defensive copying.
nonisolated struct VaultItem: Identifiable, Equatable, Hashable {
    let id: String
    /// Settable only inside this file, for `with(folderId:)`.
    private(set) var folderId: String?
    let name: String
    /// Settable only inside this file, for `with(isFavorite:)`.
    private(set) var isFavorite: Bool
    /// Settable only inside this file, for `with(isDeleted:)`.
    private(set) var isDeleted: Bool
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
    /// Settable only inside this file, for `with(attachments:)`.
    private(set) var attachments: [Attachment]
    /// Non-nil when this item belongs to a Bitwarden organization.
    /// Nil for personal vault items.
    let organizationId: String?
    /// The collections this item is assigned to within its organization.
    /// Empty (`[]`) for personal items and org items not assigned to any collection.
    /// Settable only inside this file, for `with(collectionIds:)`.
    private(set) var collectionIds: [String]
    /// Non-nil when Prizm must not save this item. Set by the Data layer from the server record, so
    /// every Edit entry point and the repository can refuse it; nil for an item Prizm can edit.
    /// Kept by every `with(...)` copy, so a local update never lifts the block.
    private(set) var editBlock: EditBlockReason?

    /// Custom memberwise init with `reprompt` defaulted to 0, `attachments` defaulted to `[]`,
    /// `organizationId` defaulted to nil, `collectionIds` defaulted to `[]` and `editBlock` defaulted
    /// to nil so existing call sites that pre-date these fields do not need to be updated.
    init(
        id: String, name: String, isFavorite: Bool, isDeleted: Bool,
        creationDate: Date, revisionDate: Date, content: ItemContent,
        reprompt: Int = 0,
        attachments: [Attachment] = [],
        folderId: String? = nil,
        organizationId: String? = nil,
        collectionIds: [String] = [],
        editBlock: EditBlockReason? = nil
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
        self.editBlock = editBlock
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

    /// A copy moved to or out of Trash, with every other field kept (including `editBlock`).
    func with(isDeleted: Bool) -> VaultItem {
        var copy = self
        copy.isDeleted = isDeleted
        return copy
    }

    /// A copy with other attachments, with every other field kept (including `editBlock`).
    func with(attachments: [Attachment]) -> VaultItem {
        var copy = self
        copy.attachments = attachments
        return copy
    }

    /// A copy with other collections, with every other field kept (including `editBlock`).
    func with(collectionIds: [String]) -> VaultItem {
        var copy = self
        copy.collectionIds = collectionIds
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
