import Foundation

// MARK: - RawCipher

/// Wire-format model for a single cipher (vault item) returned by the Bitwarden
/// `/sync` API endpoint.
///
/// All string fields that contain sensitive data are stored as Bitwarden EncStrings
/// (e.g. `"2.<iv_b64>|<ct_b64>|<mac_b64>"`).  Plain-text fields (ids, dates, type
/// integers) are never encrypted.
///
/// The model is lossless for what other Bitwarden clients store (design D1 of the OpenSpec change
/// `fix-cipher-edit-data-loss`):
/// - the top level is a typed allowlist (`CipherKeys.modelled` + `CipherKeys.preserved`);
///   `passwordHistory` is opaque `JSONValue` ciphertext;
/// - the six levels Prizm rebuilds (`login`, `uris[]`, `card`, `identity`, `sshKey`, `fields[]`)
///   keep every unknown key in `extras`;
/// - keys only a response carries (`CipherKeys.serverDerived`, `login.uri`, `response`) are dropped
///   when decoding, so the model never holds them and the encoder needs no filter.
///
/// Reference: Bitwarden Server API `/api/sync` response body, `Ciphers[]` array.
nonisolated struct RawCipher: Codable {
    let id:             String
    let organizationId: String?
    let folderId:       String?
    /// 1 = Login, 2 = SecureNote, 3 = Card, 4 = Identity, 5 = SSH Key
    /// Reference: Bitwarden server `CipherType` enum (C#), Vaultwarden `CipherType` (Rust),
    /// and Bitwarden web client `CipherType` enum (TypeScript). All three sources agree.
    let type:           Int
    let name:           String          // EncString
    let notes:          String?         // EncString
    let favorite:       Bool
    /// Master-password re-prompt setting. 0 = disabled, 1 = require master password.
    /// Must be round-tripped unchanged on PUT — omitting it silently resets re-prompt
    /// protection for items that have it enabled.
    /// Reference: Bitwarden server `CipherRepromptType` enum (0 = None, 1 = Password).
    let reprompt:       Int?
    let deletedDate:    String?         // ISO-8601 UTC, nil if not deleted
    let creationDate:   String?         // ISO-8601 UTC
    let revisionDate:   String?         // ISO-8601 UTC
    let login:          RawLoginData?
    let card:           RawCardData?
    let identity:       RawIdentityData?
    let secureNote:     RawSecureNoteData?
    let sshKey:         RawSSHKeyData?
    let fields:         [RawField]?
    /// Per-cipher symmetric key wrapped as an EncString. When present, this key encrypts
    /// the cipher's fields instead of the vault-level key. When nil, the vault-level key
    /// is used directly (Bitwarden Security Whitepaper §4 — "Cipher Key Wrapping").
    let key:            String?         // EncString, optional
    /// Collections this cipher is assigned to within its organization.
    /// Defaults to `[]` when absent (personal items, or servers that omit the key).
    let collectionIds:  [String]
    /// File attachments belonging to this cipher. Nil when the server returns no
    /// attachments or omits the field entirely; treated as `[]` by `CipherMapper`.
    /// Decoded for the vault UI but never encoded: a response carries an array of objects, a
    /// request carries a different shape, and the official server answers 400 on the mismatch.
    let attachments:    [AttachmentDTO]?
    /// Request-only: the user id this cipher was encrypted for (`RawProfile.id` of the last sync).
    /// Vaultwarden 1.37.4 requires it in every cipher body (HTTP 422 without); the official server
    /// accepts it when present. `encryptedByKeyId` is intentionally never modelled or sent
    /// (fix-cipher-edit-data-loss, D5). Typed `String?` and not held as received: Vaultwarden
    /// 1.37.4 sends it in no response (the golden fixture has none, tested; the official server is
    /// source-reviewed, not tested), and a request must always carry the id of the current session,
    /// never one from a stored record. Decoded leniently so a server that did send it with another
    /// type cannot abort a sync; nothing reads the decoded value.
    let encryptedFor:   String?
    /// ISO-8601 UTC, `null` if not archived. A server sends it, so it is held as received like
    /// `passwordHistory` (a wrong type, `null` and an absent key are all written back unchanged):
    /// saving an item that another client archived must not unarchive it, and a value of an
    /// unexpected type must not be dropped without trace. The one value it cannot hold is a number
    /// that fits no Swift number type (`1e999`): that fails the decode (see `JSONValue.swift`).
    /// `nil` = key absent, `.null` = key present with `null`.
    let archivedDate:   JSONValue?
    /// Password history as the server stores it: an array of EncString entries, or JSON `null`
    /// (the official server) where Vaultwarden sends `[]`. Opaque ciphertext, never decrypted here.
    /// `nil` = key absent, `.null` = key present with `null`; both are written back as received.
    let passwordHistory: JSONValue?
    /// Request-only, encode-only: the revision date the client last saw, which the server uses to
    /// refuse an update of an outdated copy (HTTP 400). Every update sends the stored record's raw
    /// `revisionDate` string unchanged (`CipherMapper.buildRawCipher` takes it from the base record),
    /// so a change made elsewhere is rejected instead of overwritten; a create sends none, and a
    /// formatted or epoch date is never sent, because a changed fraction is a different revision.
    /// Never read when decoding, so a value in a server record can never be sent back: a stale one
    /// would defeat the check it exists for. No server sends it (the 1.37.4 golden fixture has
    /// none), so nothing is lost.
    let lastKnownRevisionDate: String?
    /// Decode-time diagnostic: the top-level key names of the payload that `CipherKeys` does not
    /// classify, sorted. Names only, never values. Not a `CodingKey` and never encoded, so a request
    /// can never carry it.
    let unclassifiedKeys: [String]
    /// Decode-time diagnostic: the payload's `data` is an encrypted-blob record that Prizm cannot
    /// rebuild, meaning a string holding a JSON object with a top-level `format_version` key (or
    /// such an object itself). `data` alone is not a blob: the official server sends a legacy `data`
    /// string on every cipher. Only the presence of the key is read, never its value, and the
    /// `data` value is not kept (a Bool is all this model holds of it). Not a `CodingKey`, never
    /// encoded.
    let hasBlobData: Bool
    /// Decode-time diagnostic: the payload carries a `partialData` that is not JSON `null`, so the
    /// server sent this item in part. The official server sends `"partialData": null` on every
    /// cipher, which does not count. Not a `CodingKey`, never encoded, and the value is not kept.
    let hasPartialData: Bool

    /// Every key this model reads or writes, by construction equal to
    /// `CipherKeys.modelled ∪ CipherKeys.preserved` (a test pins that).
    static var codingKeyNames: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }

    // Explicit (not synthesized) so that adding a stored property cannot silently add a key to a
    // request, and so a test can compare the key list with `CipherKeys`.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, organizationId, folderId, type, name, notes, favorite, reprompt
        case deletedDate, creationDate, revisionDate
        case login, card, identity, secureNote, sshKey, fields
        case key, collectionIds, attachments
        case encryptedFor, archivedDate, passwordHistory, lastKnownRevisionDate
    }

    /// Custom decoder — all fields use standard decoding except `collectionIds`, which
    /// defaults to `[]` when the key is absent so that personal-item ciphers (which the
    /// server omits the key for) decode without error.
    init(from decoder: Decoder) throws {
        let c          = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self,                forKey: .id)
        organizationId = try c.decodeIfPresent(String.self,       forKey: .organizationId)
        folderId       = try c.decodeIfPresent(String.self,       forKey: .folderId)
        type           = try c.decode(Int.self,                   forKey: .type)
        name           = try c.decode(String.self,                forKey: .name)
        notes          = try c.decodeIfPresent(String.self,       forKey: .notes)
        favorite       = try c.decode(Bool.self,                  forKey: .favorite)
        reprompt       = try c.decodeIfPresent(Int.self,          forKey: .reprompt)
        deletedDate    = try c.decodeIfPresent(String.self,       forKey: .deletedDate)
        creationDate   = try c.decodeIfPresent(String.self,       forKey: .creationDate)
        revisionDate   = try c.decodeIfPresent(String.self,       forKey: .revisionDate)
        login          = try c.decodeIfPresent(RawLoginData.self,     forKey: .login)
        card           = try c.decodeIfPresent(RawCardData.self,      forKey: .card)
        identity       = try c.decodeIfPresent(RawIdentityData.self,  forKey: .identity)
        secureNote     = try c.decodeIfPresent(RawSecureNoteData.self, forKey: .secureNote)
        sshKey         = try c.decodeIfPresent(RawSSHKeyData.self,    forKey: .sshKey)
        fields         = try c.decodeIfPresent([RawField].self,       forKey: .fields)
        key            = try c.decodeIfPresent(String.self,           forKey: .key)
        // `collectionIds` is absent for personal items; default to [] rather than throwing.
        collectionIds  = (try? c.decode([String].self, forKey: .collectionIds)) ?? []
        attachments    = try c.decodeIfPresent([AttachmentDTO].self,  forKey: .attachments)
        // Lenient: a wrong type must never abort a sync, which decodes all ciphers or none.
        encryptedFor   = try? c.decodeIfPresent(String.self,          forKey: .encryptedFor)
        // Encode-only: a request value, never taken from a server record (see the property).
        lastKnownRevisionDate = nil
        // `contains` + `decode`, not `decodeIfPresent`: that turns JSON null into nil, which would
        // erase the difference between `null` and an absent key.
        archivedDate    = c.contains(.archivedDate)
            ? try c.decode(JSONValue.self, forKey: .archivedDate)
            : nil
        passwordHistory = c.contains(.passwordHistory)
            ? try c.decode(JSONValue.self, forKey: .passwordHistory)
            : nil
        // Names only, from a second, dynamic-key view of the same object: `CodingKeys` cannot list
        // keys it does not know. Values are never read, so nothing secret can reach a log or a test
        // message through this property.
        let wire = try decoder.container(keyedBy: WireKey.self)
        unclassifiedKeys = wire.allKeys.map(\.stringValue)
            .filter { !CipherKeys.classified.contains($0) }.sorted()
        // Both flags are read leniently (`try?`): a `data` or `partialData` of any shape must never
        // abort a sync, which decodes all ciphers or none. The values are parsed into locals and
        // dropped; only the two Bools below survive, so a request can never carry them.
        hasBlobData = Self.isBlob(try? wire.decodeIfPresent(JSONValue.self, forKey: WireKey("data")))
        hasPartialData = wire.contains(WireKey("partialData"))
            && (try? wire.decode(JSONValue.self, forKey: WireKey("partialData"))) != .null
    }

    /// Whether a payload's `data` is a blob record: an object with a top-level `format_version` key,
    /// either as the value itself or as the JSON text of a string. Anything else (not JSON, an array,
    /// an object without the key, a missing `data`) is not a blob. The key's value is not looked at.
    private static func isBlob(_ data: JSONValue?) -> Bool {
        switch data {
        case .object(let members):
            return members["format_version"] != nil
        case .string(let text):
            guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                  case .object(let members) = parsed else { return false }
            return members["format_version"] != nil
        default:
            return false
        }
    }

    /// Writes every field this model holds, except `attachments`. Keys only a response carries
    /// are never decoded, so nothing needs filtering here.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                       forKey: .id)
        try c.encodeIfPresent(organizationId,  forKey: .organizationId)
        try c.encodeIfPresent(folderId,        forKey: .folderId)
        try c.encode(type,                     forKey: .type)
        try c.encode(name,                     forKey: .name)
        try c.encodeIfPresent(notes,           forKey: .notes)
        try c.encode(favorite,                 forKey: .favorite)
        try c.encodeIfPresent(reprompt,        forKey: .reprompt)
        try c.encodeIfPresent(deletedDate,     forKey: .deletedDate)
        try c.encodeIfPresent(creationDate,    forKey: .creationDate)
        try c.encodeIfPresent(revisionDate,    forKey: .revisionDate)
        try c.encodeIfPresent(login,           forKey: .login)
        try c.encodeIfPresent(card,            forKey: .card)
        try c.encodeIfPresent(identity,        forKey: .identity)
        try c.encodeIfPresent(secureNote,      forKey: .secureNote)
        try c.encodeIfPresent(sshKey,          forKey: .sshKey)
        try c.encodeIfPresent(fields,          forKey: .fields)
        try c.encodeIfPresent(key,             forKey: .key)
        try c.encode(collectionIds,            forKey: .collectionIds)
        // `attachments` is deliberately not written (see the property).
        try c.encodeIfPresent(encryptedFor,    forKey: .encryptedFor)
        try c.encodeIfPresent(archivedDate,    forKey: .archivedDate)
        try c.encodeIfPresent(passwordHistory, forKey: .passwordHistory)
        try c.encodeIfPresent(lastKnownRevisionDate, forKey: .lastKnownRevisionDate)
    }

    /// Memberwise init with `collectionIds` defaulted to `[]` and the later fields defaulted to nil
    /// so existing call sites that pre-date those fields continue to compile without changes.
    init(id: String, organizationId: String?, folderId: String?, type: Int, name: String,
         notes: String?, favorite: Bool, reprompt: Int?, deletedDate: String?,
         creationDate: String?, revisionDate: String?, login: RawLoginData?,
         card: RawCardData?, identity: RawIdentityData?, secureNote: RawSecureNoteData?,
         sshKey: RawSSHKeyData?, fields: [RawField]?, key: String?,
         collectionIds: [String] = [], attachments: [AttachmentDTO]?,
         encryptedFor: String? = nil, archivedDate: JSONValue? = nil,
         passwordHistory: JSONValue? = nil, lastKnownRevisionDate: String? = nil,
         unclassifiedKeys: [String] = [], hasBlobData: Bool = false, hasPartialData: Bool = false) {
        self.id             = id
        self.organizationId = organizationId
        self.folderId       = folderId
        self.type           = type
        self.name           = name
        self.notes          = notes
        self.favorite       = favorite
        self.reprompt       = reprompt
        self.deletedDate    = deletedDate
        self.creationDate   = creationDate
        self.revisionDate   = revisionDate
        self.login          = login
        self.card           = card
        self.identity       = identity
        self.secureNote     = secureNote
        self.sshKey         = sshKey
        self.fields         = fields
        self.key            = key
        self.collectionIds  = collectionIds
        self.attachments    = attachments
        self.encryptedFor   = encryptedFor
        self.archivedDate   = archivedDate
        self.passwordHistory = passwordHistory
        self.lastKnownRevisionDate = lastKnownRevisionDate
        self.unclassifiedKeys = unclassifiedKeys
        self.hasBlobData = hasBlobData
        self.hasPartialData = hasPartialData
    }
}

// MARK: - Nested levels
//
// Each level Prizm rebuilds from a draft keeps every key it does not model in `extras`, so what
// another Bitwarden client stored there is written back unchanged. New fields are `var … = nil` and
// Codable lives in a `nonisolated` extension: that keeps the memberwise initializer, so existing
// call sites compile unchanged, and keeps the conformance nonisolated under the app's default
// MainActor isolation.
//
// `excludedKeys` are dropped when decoding, so they never reach `extras` and are never sent back.

// MARK: - Login

nonisolated struct RawLoginData {
    let username: String?       // EncString
    let password: String?       // EncString
    let uris:     [RawURI]?
    let totp:     String?       // EncString
    /// ISO-8601 UTC. Typed (decoded leniently) so the date other clients set is not lost.
    var passwordRevisionDate: String? = nil
    /// Unknown keys, for example `fido2Credentials` (passkeys, EncString members) and
    /// `autofillOnPageLoad`. Opaque: never decrypted or filtered, even a `response` member inside a
    /// passkey credential.
    var extras: [String: JSONValue] = [:]
}

nonisolated extension RawLoginData: Codable {
    static let knownKeys: Set<String> = ["username", "password", "uris", "totp", "passwordRevisionDate"]
    /// - `uri`: the legacy first-URI echo. Vaultwarden 1.37.4 emits it (the golden fixture shows it,
    ///   tested); the official server's setter appends a sent `uri` to `uris`, so sending it back
    ///   would add a duplicate URI (source-reviewed, not tested).
    /// - `response`: a response-only member; never part of a request.
    static let excludedKeys: Set<String> = ["uri", "response"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        username = try c.decodeIfPresent(String.self,  forKey: WireKey("username"))
        password = try c.decodeIfPresent(String.self,  forKey: WireKey("password"))
        uris     = try c.decodeIfPresent([RawURI].self, forKey: WireKey("uris"))
        totp     = try c.decodeIfPresent(String.self,  forKey: WireKey("totp"))
        var extras = try WireExtras.capture(from: c, known: Self.knownKeys, excluded: Self.excludedKeys)
        passwordRevisionDate = WireExtras.lenientString(c, "passwordRevisionDate", extras: &extras)
        self.extras = extras
    }

    func encode(to encoder: Encoder) throws {
        var w = WireWriter(encoder)
        try w.put(username, "username")
        try w.put(password, "password")
        try w.put(uris, "uris")
        try w.put(totp, "totp")
        try w.put(passwordRevisionDate, "passwordRevisionDate")
        try w.putExtras(extras, excluded: Self.excludedKeys)
    }
}

nonisolated struct RawURI {
    let uri:   String?          // EncString
    /// 0 Domain, 1 Host, 2 StartsWith, 3 Exact, 4 Regex, 5 Never, null default
    /// (Bitwarden `UriMatchType`).
    let match: Int?
    /// EncString of the URI's checksum, set by other clients. Typed (decoded leniently) so it is
    /// not lost when the URI list is written back.
    var uriChecksum: String? = nil
    var extras: [String: JSONValue] = [:]
}

nonisolated extension RawURI: Codable {
    static let knownKeys: Set<String> = ["uri", "match", "uriChecksum"]
    /// `response`: a response-only member; never part of a request.
    static let excludedKeys: Set<String> = ["response"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        uri   = try c.decodeIfPresent(String.self, forKey: WireKey("uri"))
        match = try c.decodeIfPresent(Int.self,    forKey: WireKey("match"))
        var extras = try WireExtras.capture(from: c, known: Self.knownKeys, excluded: Self.excludedKeys)
        uriChecksum = WireExtras.lenientString(c, "uriChecksum", extras: &extras)
        self.extras = extras
    }

    func encode(to encoder: Encoder) throws {
        var w = WireWriter(encoder)
        try w.put(uri, "uri")
        try w.put(match, "match")
        try w.put(uriChecksum, "uriChecksum")
        try w.putExtras(extras, excluded: Self.excludedKeys)
    }
}

// MARK: - Card

nonisolated struct RawCardData {
    let cardholderName: String? // EncString
    let brand:          String? // EncString
    let number:         String? // EncString
    let expMonth:       String? // EncString
    let expYear:        String? // EncString
    let code:           String? // EncString
    var extras: [String: JSONValue] = [:]
}

nonisolated extension RawCardData: Codable {
    static let knownKeys: Set<String> = ["cardholderName", "brand", "number", "expMonth", "expYear", "code"]
    /// `response`: a response-only member; never part of a request.
    static let excludedKeys: Set<String> = ["response"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        cardholderName = try c.decodeIfPresent(String.self, forKey: WireKey("cardholderName"))
        brand          = try c.decodeIfPresent(String.self, forKey: WireKey("brand"))
        number         = try c.decodeIfPresent(String.self, forKey: WireKey("number"))
        expMonth       = try c.decodeIfPresent(String.self, forKey: WireKey("expMonth"))
        expYear        = try c.decodeIfPresent(String.self, forKey: WireKey("expYear"))
        code           = try c.decodeIfPresent(String.self, forKey: WireKey("code"))
        extras = try WireExtras.capture(from: c, known: Self.knownKeys, excluded: Self.excludedKeys)
    }

    func encode(to encoder: Encoder) throws {
        var w = WireWriter(encoder)
        try w.put(cardholderName, "cardholderName")
        try w.put(brand, "brand")
        try w.put(number, "number")
        try w.put(expMonth, "expMonth")
        try w.put(expYear, "expYear")
        try w.put(code, "code")
        try w.putExtras(extras, excluded: Self.excludedKeys)
    }
}

// MARK: - Identity

nonisolated struct RawIdentityData {
    let title:          String? // EncString
    let firstName:      String? // EncString
    let middleName:     String? // EncString
    let lastName:       String? // EncString
    let address1:       String? // EncString
    let address2:       String? // EncString
    let address3:       String? // EncString
    let city:           String? // EncString
    let state:          String? // EncString
    let postalCode:     String? // EncString
    let country:        String? // EncString
    let company:        String? // EncString
    let email:          String? // EncString
    let phone:          String? // EncString
    let ssn:            String? // EncString
    let username:       String? // EncString
    let passportNumber: String? // EncString
    let licenseNumber:  String? // EncString
    var extras: [String: JSONValue] = [:]
}

nonisolated extension RawIdentityData: Codable {
    static let knownKeys: Set<String> = [
        "title", "firstName", "middleName", "lastName", "address1", "address2", "address3", "city",
        "state", "postalCode", "country", "company", "email", "phone", "ssn", "username",
        "passportNumber", "licenseNumber",
    ]
    /// `response`: a response-only member; never part of a request.
    static let excludedKeys: Set<String> = ["response"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        title          = try c.decodeIfPresent(String.self, forKey: WireKey("title"))
        firstName      = try c.decodeIfPresent(String.self, forKey: WireKey("firstName"))
        middleName     = try c.decodeIfPresent(String.self, forKey: WireKey("middleName"))
        lastName       = try c.decodeIfPresent(String.self, forKey: WireKey("lastName"))
        address1       = try c.decodeIfPresent(String.self, forKey: WireKey("address1"))
        address2       = try c.decodeIfPresent(String.self, forKey: WireKey("address2"))
        address3       = try c.decodeIfPresent(String.self, forKey: WireKey("address3"))
        city           = try c.decodeIfPresent(String.self, forKey: WireKey("city"))
        state          = try c.decodeIfPresent(String.self, forKey: WireKey("state"))
        postalCode     = try c.decodeIfPresent(String.self, forKey: WireKey("postalCode"))
        country        = try c.decodeIfPresent(String.self, forKey: WireKey("country"))
        company        = try c.decodeIfPresent(String.self, forKey: WireKey("company"))
        email          = try c.decodeIfPresent(String.self, forKey: WireKey("email"))
        phone          = try c.decodeIfPresent(String.self, forKey: WireKey("phone"))
        ssn            = try c.decodeIfPresent(String.self, forKey: WireKey("ssn"))
        username       = try c.decodeIfPresent(String.self, forKey: WireKey("username"))
        passportNumber = try c.decodeIfPresent(String.self, forKey: WireKey("passportNumber"))
        licenseNumber  = try c.decodeIfPresent(String.self, forKey: WireKey("licenseNumber"))
        extras = try WireExtras.capture(from: c, known: Self.knownKeys, excluded: Self.excludedKeys)
    }

    func encode(to encoder: Encoder) throws {
        var w = WireWriter(encoder)
        try w.put(title, "title")
        try w.put(firstName, "firstName")
        try w.put(middleName, "middleName")
        try w.put(lastName, "lastName")
        try w.put(address1, "address1")
        try w.put(address2, "address2")
        try w.put(address3, "address3")
        try w.put(city, "city")
        try w.put(state, "state")
        try w.put(postalCode, "postalCode")
        try w.put(country, "country")
        try w.put(company, "company")
        try w.put(email, "email")
        try w.put(phone, "phone")
        try w.put(ssn, "ssn")
        try w.put(username, "username")
        try w.put(passportNumber, "passportNumber")
        try w.put(licenseNumber, "licenseNumber")
        try w.putExtras(extras, excluded: Self.excludedKeys)
    }
}

// MARK: - Secure Note

/// No `extras`: Prizm writes a secure note's `type` only, and the nested inventory test lists its
/// keys so a new server key still forces a decision.
nonisolated struct RawSecureNoteData: Codable {
    let type: Int   // 0 = Generic
}

// MARK: - SSH Key

nonisolated struct RawSSHKeyData {
    let privateKey:     String?    // EncString
    let publicKey:      String?    // EncString
    let keyFingerprint: String?    // EncString
    var extras: [String: JSONValue] = [:]
}

nonisolated extension RawSSHKeyData: Codable {
    static let knownKeys: Set<String> = ["privateKey", "publicKey", "keyFingerprint"]
    /// `response`: a response-only member; never part of a request.
    static let excludedKeys: Set<String> = ["response"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        privateKey     = try c.decodeIfPresent(String.self, forKey: WireKey("privateKey"))
        publicKey      = try c.decodeIfPresent(String.self, forKey: WireKey("publicKey"))
        keyFingerprint = try c.decodeIfPresent(String.self, forKey: WireKey("keyFingerprint"))
        extras = try WireExtras.capture(from: c, known: Self.knownKeys, excluded: Self.excludedKeys)
    }

    func encode(to encoder: Encoder) throws {
        var w = WireWriter(encoder)
        try w.put(privateKey, "privateKey")
        try w.put(publicKey, "publicKey")
        try w.put(keyFingerprint, "keyFingerprint")
        try w.putExtras(extras, excluded: Self.excludedKeys)
    }
}

// MARK: - Custom Field

nonisolated struct RawField {
    /// 0 = text, 1 = hidden, 2 = boolean, 3 = linked
    let type:     Int
    let name:     String?   // EncString
    let value:    String?   // EncString
    let linkedId: Int?
    var extras: [String: JSONValue] = [:]
}

nonisolated extension RawField: Codable {
    static let knownKeys: Set<String> = ["type", "name", "value", "linkedId"]
    /// `response`: a response-only member; never part of a request.
    static let excludedKeys: Set<String> = ["response"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        type     = try c.decode(Int.self,                forKey: WireKey("type"))
        name     = try c.decodeIfPresent(String.self,    forKey: WireKey("name"))
        value    = try c.decodeIfPresent(String.self,    forKey: WireKey("value"))
        linkedId = try c.decodeIfPresent(Int.self,       forKey: WireKey("linkedId"))
        extras = try WireExtras.capture(from: c, known: Self.knownKeys, excluded: Self.excludedKeys)
    }

    func encode(to encoder: Encoder) throws {
        var w = WireWriter(encoder)
        try w.put(type, "type")
        try w.put(name, "name")
        try w.put(value, "value")
        try w.put(linkedId, "linkedId")
        try w.putExtras(extras, excluded: Self.excludedKeys)
    }
}

// MARK: - Cipher key classification

/// Every top-level key a server cipher can carry, in one place. Literals on purpose: this list is
/// the reference the tests compare the model against, so it must never be derived from a payload or
/// from the model itself.
///
/// - `modelled`: typed fields of `RawCipher` that Prizm reads, and writes except `attachments`
///   (decode-only: a response carries objects there and a request a different shape).
/// - `preserved`: typed fields that exist so other clients' data survives (`archivedDate` and
///   `passwordHistory` as opaque JSON) or that only a request carries (`encryptedFor`,
///   `lastKnownRevisionDate`).
/// - `serverDerived`: keys only a response carries. They are dropped when decoding, so the model
///   never holds them and a request can never echo them. `data` (the official server stores a
///   non-blank request `data` verbatim and ignores the typed fields) and `partialData` come from
///   the official server only; Vaultwarden 1.37.4 sends the others.
nonisolated enum CipherKeys {
    static let modelled: Set<String> = [
        "id", "organizationId", "folderId", "type", "name", "notes", "favorite", "reprompt",
        "deletedDate", "creationDate", "revisionDate", "login", "card", "identity", "secureNote",
        "sshKey", "fields", "key", "collectionIds", "attachments",
    ]
    static let preserved: Set<String> = ["archivedDate", "passwordHistory", "encryptedFor", "lastKnownRevisionDate"]
    static let serverDerived: Set<String> = [
        "object", "edit", "viewPassword", "permissions", "organizationUseTotp",
        "bankAccount", "driversLicense", "passport", "data", "partialData",
    ]
    static var classified: Set<String> { modelled.union(preserved).union(serverDerived) }

    /// Text for the sync log line that names top-level cipher keys Prizm does not classify; `nil`
    /// when there are none.
    ///
    /// The names come from the user's own server and end up in a log marked public, so they are
    /// restricted and capped: log injection (a newline or a format directive inside a key name) and
    /// log flooding (thousands of keys) must not be possible through a server response
    /// (Constitution V and III). Rule: each name keeps only `A-Z a-z 0-9 _` and is cut to 64
    /// characters, names left empty are dropped, distinct names are sorted, at most 20 are listed,
    /// and ` (+N more)` counts the distinct input names that are not listed.
    static func unclassifiedKeyLogText(_ names: some Collection<String>) -> String? {
        let distinctInput = Set(names)
        guard !distinctInput.isEmpty else { return nil }

        let maxNames = 20
        let maxLength = 64
        let cleaned = Set(distinctInput.compactMap { name -> String? in
            var kept = String.UnicodeScalarView()
            kept.append(contentsOf: name.unicodeScalars.filter(isLogSafe).prefix(maxLength))
            return kept.isEmpty ? nil : String(kept)
        })

        let listed = cleaned.sorted().prefix(maxNames)
        let omitted = distinctInput.count - listed.count
        let list = listed.joined(separator: ", ")
        guard omitted > 0 else { return list }
        return list.isEmpty ? "(+\(omitted) more)" : "\(list) (+\(omitted) more)"
    }

    private static func isLogSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true  // 0-9 A-Z a-z _
        default: return false
        }
    }
}

// MARK: - Redaction

// Every wire struct prints as its type name only (see `RedactedWireModel`).
nonisolated extension RawCipher: RedactedWireModel {}
nonisolated extension RawLoginData: RedactedWireModel {}
nonisolated extension RawURI: RedactedWireModel {}
nonisolated extension RawCardData: RedactedWireModel {}
nonisolated extension RawIdentityData: RedactedWireModel {}
nonisolated extension RawSecureNoteData: RedactedWireModel {}
nonisolated extension RawSSHKeyData: RedactedWireModel {}
nonisolated extension RawField: RedactedWireModel {}
