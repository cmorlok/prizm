import Foundation
import os.log

// MARK: - CipherMapperError

/// Errors that can be thrown by `CipherMapper.map(raw:keys:)`.
nonisolated enum CipherMapperError: Error, Equatable {
    /// The cipher belongs to an organisation and is intentionally skipped in
    /// the personal vault view (organizationId != nil).
    case organisationCipherSkipped
    /// The cipher has an unknown `type` integer.
    case unsupportedCipherType(Int)
    /// A required encrypted field could not be decrypted.
    case fieldDecryptionFailed(String)
}

// MARK: - CipherMapper

/// Transforms a `RawCipher` (wire-format, encrypted) into a `VaultItem` (domain,
/// decrypted) using the provided symmetric `CryptoKeys`.
///
/// **Responsibilities** (single responsibility per §III of the project constitution):
/// - Decrypt each EncString field using AES-256-CBC + HMAC-SHA256 (EncString type-2).
///   Decryption is eager (at sync time, inside the mapper) rather than lazy (at display
///   time, inside Views). This keeps `VaultItem` domain entities as plain decrypted
///   Swift structs, so the Presentation layer never imports or calls crypto code.
///   Decryption failures are surfaced once during sync rather than scattered across the UI.
/// - Map the raw `type` integer to a typed `ItemContent` enum case.
/// - Filter out organisation ciphers (`organizationId != nil`) — personal vault only.
/// - Map raw `RawField` array to `[CustomField]` domain values.
///
/// **What this class does NOT do**:
/// - Network I/O.
/// - Keychain access.
/// - KDF derivation.
// `Sendable`: all state is immutable (let properties, nonisolated(unsafe) static).
nonisolated final class CipherMapper: Sendable {

    private let attachmentMapper = AttachmentMapper()

    private static let logger = Logger(subsystem: "com.prizm", category: "CipherMapper")

    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Public API

    /// Maps a single `RawCipher` to a `VaultItem` and returns the effective cipher key.
    ///
    /// The returned tuple is used by:
    /// - **Callers that only need the item** (`SyncRepositoryImpl`, `VaultRepositoryImpl.update`,
    ///   `VaultRepositoryImpl.create`): destructure and discard the `cipherKey` value.
    /// - **`SyncRepositoryImpl`**: collect all `cipherKey` values and populate `VaultKeyCache`.
    ///
    /// **Effective cipher key** (Bitwarden Security Whitepaper §4, see `effectiveKeys(for:activeKeys:)`):
    /// - If `raw.key` is non-nil (cipher has a per-item symmetric key), the 64-byte plaintext of
    ///   that key decrypts every field and attachment, and is returned as `cipherKey`.
    /// - If `raw.key` is nil, the cipher uses the vault key (personal) or organization key
    ///   (organization) directly, and that key is returned.
    ///
    /// - Parameters:
    ///   - raw:      The encrypted wire-format cipher from the sync response.
    ///   - vaultKeys: The personal vault symmetric key pair (used for personal ciphers).
    ///   - orgKeys:  Snapshot of `OrgKeyCache` keyed by organization ID. Pass `[:]` when
    ///               no org key support is available (personal-only vault).
    /// - Returns: A tuple of the decrypted `VaultItem` and its 64-byte effective cipher key.
    /// - Throws: `CipherMapperError.organisationCipherSkipped` when the cipher's org key is absent from `orgKeys`.
    /// - Throws: `CipherMapperError.unsupportedCipherType` for unknown type integers.
    /// - Throws: `EncStringError` or `CipherMapperError.fieldDecryptionFailed` on decryption failure.
    func map(raw: RawCipher, vaultKeys: CryptoKeys, orgKeys: [String: CryptoKeys] = [:]) throws -> (item: VaultItem, cipherKey: Data) {
        // Select the key to use for this cipher.
        // Org ciphers use the org's symmetric key; personal ciphers use the vault key.
        let activeKeys: CryptoKeys
        if let orgId = raw.organizationId {
            guard let orgKey = orgKeys[orgId] else {
                // Org key not available (org sync not yet complete, or org key unwrap failed).
                // Skip this cipher rather than showing garbled content.
                throw CipherMapperError.organisationCipherSkipped
            }
            activeKeys = orgKey
        } else {
            activeKeys = vaultKeys
        }

        // Resolved before the first field is decrypted: every field of an item with its own key is
        // encrypted with that key, not with the vault or organization key.
        let effective = try effectiveKeys(for: raw, activeKeys: activeKeys)

        let name   = try decryptRequired(raw.name, field: "name", keys: effective)
        let notes  = try raw.notes.map { try decryptRequired($0, field: "notes", keys: effective) }
        let fields = try mapFields(raw.fields ?? [], keys: effective)

        let content: ItemContent = try mapContent(
            type:   raw.type,
            raw:    raw,
            notes:  notes,
            fields: fields,
            keys:   effective
        )

        let fallbackDate = Date(timeIntervalSince1970: 0)
        let creationDate  = raw.creationDate.flatMap  { Self.iso8601.date(from: $0) } ?? fallbackDate
        let revisionDate  = raw.revisionDate.flatMap  { Self.iso8601.date(from: $0) } ?? fallbackDate

        // Map attachments using the cipher's effective key, not the raw vault key.
        // Attachment filenames are encrypted under the same key as the cipher's fields.
        let attachments: [Attachment] = (raw.attachments ?? []).compactMap { dto in
            do {
                return try attachmentMapper.map(dto, cipherKey: effective)
            } catch {
                Self.logger.error("Attachment mapping failed for cipher \(raw.id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
                return nil
            }
        }

        let item = VaultItem(
            id:             raw.id,
            name:           name,
            isFavorite:     raw.favorite,
            isDeleted:      raw.deletedDate != nil,
            creationDate:   creationDate,
            revisionDate:   revisionDate,
            content:        content,
            reprompt:       raw.reprompt ?? 0,
            attachments:    attachments,
            folderId:       raw.folderId,
            organizationId: raw.organizationId,
            collectionIds:  raw.collectionIds,
            editBlock:      editBlock(for: raw)
        )
        return (item: item, cipherKey: effective.toData())
    }

    /// Backward-compatible overload — passes empty orgKeys (personal vault, no org support).
    func map(raw: RawCipher, keys: CryptoKeys) throws -> (item: VaultItem, cipherKey: Data) {
        try map(raw: raw, vaultKeys: keys, orgKeys: [:])
    }

    // MARK: - Effective key

    /// The key that encrypts every field and attachment of `raw`: the item's own key when it has
    /// one, otherwise `activeKeys` (the organization key for an organization item, the vault key
    /// otherwise).
    ///
    /// - Security goal: an item that another Bitwarden client gave its own key (`key` is non-nil)
    ///   is read entirely under that key. Reading its fields under the vault or organization key
    ///   would drop the item at sync, and worse, would let a mixed-key item be listed and later
    ///   edited with the wrong key. The write path uses this same function (never the key cache,
    ///   which falls back to the vault key) so what is read and what is written agree.
    /// - Algorithm: `key` is an EncString type 2 (AES-256-CBC, HMAC-SHA256 verified before decrypt,
    ///   Bitwarden Security Whitepaper §4, "Cipher Key Wrapping") holding 64 bytes, the AES key
    ///   followed by the MAC key. The Bitwarden SDK does the same in `decrypt_cipher_key`: a cipher
    ///   with no key is decrypted with the key it is given.
    /// - Intentionally NOT done:
    ///   • No fallback to `activeKeys` when the unwrap fails or the unwrapped key has the wrong
    ///     length (rbw#364: a retry produces items that read under one key and save under another).
    ///     The caller drops the item and counts it.
    ///   • No fallback for a field that fails to decrypt under the item key either; `map` throws.
    ///   • The local copy of the unwrapped key is not zeroed. `CryptoKeys` holds value-type `Data`
    ///     halves, same posture as the vault keys; only the long-lived stores are zeroed on lock.
    ///   • An EncString type 0 key is refused, never decrypted: it has no MAC, so a wrong
    ///     `activeKeys` would show up only as a padding error or a wrong length, and nothing would
    ///     authenticate the key that every field of the item is then read and written with. Other
    ///     non-type-2 strings are refused too. The item is dropped.
    /// - Logging: the cipher id only (`privacy: .public`), never key bytes or field values.
    ///
    /// - Throws: `CipherMapperError.fieldDecryptionFailed("key")` when the key is not an EncString
    ///   type 2, does not unwrap, or is not exactly 64 bytes (`CryptoKeys(data:)` enforces the length).
    func effectiveKeys(for raw: RawCipher, activeKeys: CryptoKeys) throws -> CryptoKeys {
        guard let wrappedKey = raw.key else { return activeKeys }
        do {
            let wrapped = try EncString(string: wrappedKey)
            // Only type 2 carries a MAC that `decrypt` verifies; see "Intentionally NOT done" above.
            guard wrapped.encType == .aes256Cbc_HmacSha256_B64 else {
                throw CipherMapperError.fieldDecryptionFailed("key")
            }
            let unwrapped = try wrapped.decrypt(keys: activeKeys)
            guard let itemKeys = CryptoKeys(data: unwrapped) else {
                throw CipherMapperError.fieldDecryptionFailed("key")
            }
            return itemKeys
        } catch {
            // `.error`, not `.fault`: one item is dropped (sync) or refused (save) and everything else goes on.
            Self.logger.error("Per-item key decryption failed for cipher \(raw.id, privacy: .public)")
            throw CipherMapperError.fieldDecryptionFailed("key")
        }
    }

    // MARK: - Edit block

    /// Why Prizm must not save `raw` as it is, or nil when it can.
    ///
    /// Computed here, from the record, so Presentation never looks at raw shapes. Today the only
    /// reason is an item key: the write path does not yet send `key` or encrypt with it, so a save
    /// would put fields under the vault or organization key that the server and other clients read
    /// under the item key. The own-key reason goes when saves use the item key; further reasons
    /// (formats Prizm cannot rebuild) are added with the lasting guard.
    /// Nothing is logged per item: every item can be keyed.
    func editBlock(for raw: RawCipher) -> EditBlockReason? {
        raw.key != nil ? .hasOwnKey : nil
    }

    // MARK: - Private: Content dispatch

    private func mapContent(
        type:   Int,
        raw:    RawCipher,
        notes:  String?,
        fields: [CustomField],
        keys:   CryptoKeys
    ) throws -> ItemContent {
        // Type integers match the Bitwarden server CipherType enum:
        // 1=Login, 2=SecureNote, 3=Card, 4=Identity, 5=SSHKey.
        // Reference: github.com/bitwarden/server CipherType.cs; vaultwarden CipherType enum.
        switch type {
        case 1: return try mapLogin(raw.login,       notes: notes, fields: fields, keys: keys)
        case 2: return mapSecureNote(                notes: notes, fields: fields)
        case 3: return try mapCard(raw.card,         notes: notes, fields: fields, keys: keys)
        case 4: return try mapIdentity(raw.identity, notes: notes, fields: fields, keys: keys)
        case 5: return try mapSSHKey(raw.sshKey,     notes: notes, fields: fields, keys: keys)
        default:
            throw CipherMapperError.unsupportedCipherType(type)
        }
    }

    // MARK: - Login

    private func mapLogin(
        _ data: RawLoginData?,
        notes:  String?,
        fields: [CustomField],
        keys:   CryptoKeys
    ) throws -> ItemContent {
        let login = data ?? RawLoginData(username: nil, password: nil, uris: [], totp: nil)
        let uris: [LoginURI] = try (login.uris ?? []).compactMap { rawURI in
            guard let encUri = rawURI.uri else { return nil }
            let uriStr = try decryptRequired(encUri, field: "uri", keys: keys)
            let match  = rawURI.match.flatMap { URIMatchType(rawValue: $0) }
            return LoginURI(uri: uriStr, matchType: match)
        }
        return .login(LoginContent(
            username:     try login.username.map { try decryptRequired($0, field: "username", keys: keys) },
            password:     try login.password.map { try decryptRequired($0, field: "password", keys: keys) },
            uris:         uris,
            totp:         try login.totp.map { try decryptRequired($0, field: "totp", keys: keys) },
            notes:        notes,
            customFields: fields
        ))
    }

    // MARK: - Secure Note

    private func mapSecureNote(notes: String?, fields: [CustomField]) -> ItemContent {
        .secureNote(SecureNoteContent(notes: notes, customFields: fields))
    }

    // MARK: - Card

    private func mapCard(
        _ data: RawCardData?,
        notes:  String?,
        fields: [CustomField],
        keys:   CryptoKeys
    ) throws -> ItemContent {
        let card = data ?? RawCardData(cardholderName: nil, brand: nil, number: nil,
                                      expMonth: nil, expYear: nil, code: nil)
        return .card(CardContent(
            cardholderName: try card.cardholderName.map { try decryptRequired($0, field: "cardholderName", keys: keys) },
            brand:          try card.brand.map          { try decryptRequired($0, field: "brand",          keys: keys) },
            number:         try card.number.map         { try decryptRequired($0, field: "number",         keys: keys) },
            expMonth:       try card.expMonth.map       { try decryptRequired($0, field: "expMonth",       keys: keys) },
            expYear:        try card.expYear.map        { try decryptRequired($0, field: "expYear",        keys: keys) },
            code:           try card.code.map           { try decryptRequired($0, field: "code",           keys: keys) },
            notes:          notes,
            customFields:   fields
        ))
    }

    // MARK: - Identity

    private func mapIdentity(
        _ data: RawIdentityData?,
        notes:  String?,
        fields: [CustomField],
        keys:   CryptoKeys
    ) throws -> ItemContent {
        let id = data ?? RawIdentityData(
            title: nil, firstName: nil, middleName: nil, lastName: nil,
            address1: nil, address2: nil, address3: nil, city: nil, state: nil,
            postalCode: nil, country: nil, company: nil, email: nil, phone: nil,
            ssn: nil, username: nil, passportNumber: nil, licenseNumber: nil
        )
        func dec(_ s: String?, field: String) throws -> String? {
            try s.map { try decryptRequired($0, field: field, keys: keys) }
        }
        return .identity(IdentityContent(
            title:          try dec(id.title,           field: "title"),
            firstName:      try dec(id.firstName,       field: "firstName"),
            middleName:     try dec(id.middleName,      field: "middleName"),
            lastName:       try dec(id.lastName,        field: "lastName"),
            address1:       try dec(id.address1,        field: "address1"),
            address2:       try dec(id.address2,        field: "address2"),
            address3:       try dec(id.address3,        field: "address3"),
            city:           try dec(id.city,            field: "city"),
            state:          try dec(id.state,           field: "state"),
            postalCode:     try dec(id.postalCode,      field: "postalCode"),
            country:        try dec(id.country,         field: "country"),
            company:        try dec(id.company,         field: "company"),
            email:          try dec(id.email,           field: "email"),
            phone:          try dec(id.phone,           field: "phone"),
            ssn:            try dec(id.ssn,             field: "ssn"),
            username:       try dec(id.username,        field: "username"),
            passportNumber: try dec(id.passportNumber,  field: "passportNumber"),
            licenseNumber:  try dec(id.licenseNumber,   field: "licenseNumber"),
            notes:          notes,
            customFields:   fields
        ))
    }

    // MARK: - SSH Key

    private func mapSSHKey(
        _ data: RawSSHKeyData?,
        notes:  String?,
        fields: [CustomField],
        keys:   CryptoKeys
    ) throws -> ItemContent {
        let ssh = data ?? RawSSHKeyData(privateKey: nil, publicKey: nil, keyFingerprint: nil)
        return .sshKey(SSHKeyContent(
            privateKey:     try ssh.privateKey.map  { try decryptRequired($0, field: "privateKey",  keys: keys) },
            publicKey:      try ssh.publicKey.map   { try decryptRequired($0, field: "publicKey",   keys: keys) },
            keyFingerprint: try ssh.keyFingerprint.map { try decryptRequired($0, field: "keyFingerprint", keys: keys) },
            notes:          notes,
            customFields:   fields
        ))
    }

    // MARK: - Custom Fields

    private func mapFields(_ rawFields: [RawField], keys: CryptoKeys) throws -> [CustomField] {
        try rawFields.compactMap { raw in
            // name is required for CustomField; skip fields with no name
            guard let rawName = raw.name else { return nil }
            let name     = try decryptRequired(rawName, field: "field.name", keys: keys)
            let value    = try raw.value.map { try decryptRequired($0, field: "field.value", keys: keys) }
            let type     = CustomFieldType(rawValue: raw.type) ?? .text
            let linkedId = raw.linkedId.flatMap { LinkedFieldId(rawValue: $0) }
            return CustomField(name: name, value: value, type: type, linkedId: linkedId)
        }
    }

    // MARK: - Reverse mapper (domain → wire)

    /// Converts a mutable `DraftVaultItem` into an encrypted `RawCipher` ready for
    /// `PUT /ciphers/{id}`.
    ///
    /// - Security goal: ensures that no vault secret (password, card number, private key, etc.)
    ///   ever leaves the device in plaintext. Every string field that is an EncString on the
    ///   Bitwarden wire format is re-encrypted here before the request body is serialised.
    ///
    /// - Algorithm: EncString type-2 — AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC).
    ///   Spec reference: Bitwarden Security Whitepaper §4 (https://bitwarden.com/images/resources/security-white-paper-download.pdf).
    ///   Standard reference: AES-CBC per NIST SP 800-38A; HMAC-SHA256 per RFC 2104.
    ///   Each field gets a cryptographically random 16-byte IV via `SecRandomCopyBytes`
    ///   (Security.framework). Reusing IVs across fields would break CBC confidentiality;
    ///   the fresh-IV-per-field approach matches the Bitwarden client reference implementation.
    ///
    /// - Deviations from the Bitwarden reference: none. The EncString type-2 format and
    ///   key material (AES key + MAC key from `CryptoKeys`) are identical to what the
    ///   official web vault uses when editing an item.
    ///
    /// - What is NOT done:
    ///   • `id`, `type`, `favorite` are plain JSON values (not EncStrings) — sent as-is.
    ///   • `organizationId` is sent as `nil` — this mapper only handles personal vault items;
    ///     editing org ciphers is out of scope for v1 and requires org key unwrapping.
    ///   • `deletedDate`, `creationDate`, `revisionDate` are sent as `nil` — the server is
    ///     authoritative for these timestamps and ignores client-provided values on PUT.
    ///   • Biometric re-authentication before re-encryption is not performed here; it is
    ///     the caller's responsibility (see `VaultRepositoryImpl.update` TODO).
    ///
    /// - Parameter draft: The edited item to re-encrypt.
    /// - Parameter keys:  The symmetric key pair (AES-256 enc key + HMAC-SHA256 MAC key).
    /// - Parameter encryptedFor: The user id sent as `encryptedFor`. The repository passes the
    ///   profile id of the last sync; nil is for mapper unit tests only.
    /// - Returns: A `RawCipher` with all sensitive string fields encrypted as EncStrings.
    /// - Throws: `EncStringError` if IV generation or AES/HMAC computation fails.
    func toRawCipher(_ draft: DraftVaultItem, encryptedWith keys: CryptoKeys,
                     encryptedFor: String? = nil) throws -> RawCipher {
        let encName  = try encryptString(draft.name, keys: keys)
        let encNotes: String? = try {
            switch draft.content {
            case .login(let c):      return try c.notes.map { try encryptString($0, keys: keys) }
            case .secureNote(let c): return try c.notes.map { try encryptString($0, keys: keys) }
            case .card(let c):       return try c.notes.map { try encryptString($0, keys: keys) }
            case .identity(let c):   return try c.notes.map { try encryptString($0, keys: keys) }
            case .sshKey(let c):     return try c.notes.map { try encryptString($0, keys: keys) }
            }
        }()
        let encFields = try toRawFields(customFieldsOf(draft.content), keys: keys)

        let (type, loginData, cardData, identityData, secureNoteData, sshKeyData) =
            try encryptContent(draft.content, keys: keys)

        return RawCipher(
            id:             draft.id,
            organizationId: draft.organizationId,
            folderId:       draft.folderId,
            type:           type,
            name:           encName,
            notes:          encNotes,
            favorite:       draft.isFavorite,
            reprompt:       draft.reprompt,
            deletedDate:    nil,
            creationDate:   nil,
            revisionDate:   nil,
            login:          loginData,
            card:           cardData,
            identity:       identityData,
            secureNote:     secureNoteData,
            sshKey:         sshKeyData,
            fields:         encFields.isEmpty ? nil : encFields,
            key:            nil,
            collectionIds:  draft.collectionIds,
            attachments:    nil,
            encryptedFor:   encryptedFor
        )
    }

    // MARK: - Private: Reverse content dispatch

    private func encryptContent(
        _ content: DraftItemContent,
        keys: CryptoKeys
    ) throws -> (
        type: Int,
        login: RawLoginData?,
        card: RawCardData?,
        identity: RawIdentityData?,
        secureNote: RawSecureNoteData?,
        sshKey: RawSSHKeyData?
    ) {
        // Type integers: 1=Login, 2=SecureNote, 3=Card, 4=Identity, 5=SSHKey.
        // Must match the forward mapper (mapContent) and the Bitwarden server CipherType enum.
        switch content {
        case .login(let c):
            return (1, try toRawLogin(c, keys: keys), nil, nil, nil, nil)
        case .secureNote:
            return (2, nil, nil, nil, RawSecureNoteData(type: 0), nil)
        case .card(let c):
            return (3, nil, try toRawCard(c, keys: keys), nil, nil, nil)
        case .identity(let c):
            return (4, nil, nil, try toRawIdentity(c, keys: keys), nil, nil)
        case .sshKey(let c):
            return (5, nil, nil, nil, nil, try toRawSSHKey(c, keys: keys))
        }
    }

    // MARK: - Private: Login reverse map

    private func toRawLogin(_ c: DraftLoginContent, keys: CryptoKeys) throws -> RawLoginData {
        let rawURIs: [RawURI] = try c.uris.map { uri in
            let encURI = try encryptString(uri.uri, keys: keys)
            return RawURI(uri: encURI, match: uri.matchType?.rawValue)
        }
        return RawLoginData(
            username: try c.username.map { try encryptString($0, keys: keys) },
            password: try c.password.map { try encryptString($0, keys: keys) },
            uris:     rawURIs,
            totp:     try c.totp.map { try encryptString($0, keys: keys) }
        )
    }

    // MARK: - Private: Card reverse map

    private func toRawCard(_ c: DraftCardContent, keys: CryptoKeys) throws -> RawCardData {
        RawCardData(
            cardholderName: try c.cardholderName.map { try encryptString($0, keys: keys) },
            brand:          try c.brand.map          { try encryptString($0, keys: keys) },
            number:         try c.number.map         { try encryptString($0, keys: keys) },
            expMonth:       try c.expMonth.map       { try encryptString($0, keys: keys) },
            expYear:        try c.expYear.map        { try encryptString($0, keys: keys) },
            code:           try c.code.map           { try encryptString($0, keys: keys) }
        )
    }

    // MARK: - Private: Identity reverse map

    private func toRawIdentity(_ c: DraftIdentityContent, keys: CryptoKeys) throws -> RawIdentityData {
        func enc(_ s: String?) throws -> String? { try s.map { try encryptString($0, keys: keys) } }
        return RawIdentityData(
            title:          try enc(c.title),
            firstName:      try enc(c.firstName),
            middleName:     try enc(c.middleName),
            lastName:       try enc(c.lastName),
            address1:       try enc(c.address1),
            address2:       try enc(c.address2),
            address3:       try enc(c.address3),
            city:           try enc(c.city),
            state:          try enc(c.state),
            postalCode:     try enc(c.postalCode),
            country:        try enc(c.country),
            company:        try enc(c.company),
            email:          try enc(c.email),
            phone:          try enc(c.phone),
            ssn:            try enc(c.ssn),
            username:       try enc(c.username),
            passportNumber: try enc(c.passportNumber),
            licenseNumber:  try enc(c.licenseNumber)
        )
    }

    // MARK: - Private: SSH Key reverse map

    private func toRawSSHKey(_ c: DraftSSHKeyContent, keys: CryptoKeys) throws -> RawSSHKeyData {
        // keyFingerprint is auto-derived and not sent to the API — it is server-authoritative.
        RawSSHKeyData(
            privateKey:     try c.privateKey.map  { try encryptString($0, keys: keys) },
            publicKey:      try c.publicKey.map   { try encryptString($0, keys: keys) },
            keyFingerprint: nil
        )
    }

    // MARK: - Private: Custom fields reverse map

    private func toRawFields(_ fields: [DraftCustomField], keys: CryptoKeys) throws -> [RawField] {
        try fields.map { f in
            RawField(
                type:     f.type.rawValue,
                name:     try encryptString(f.name, keys: keys),
                value:    try f.value.map { try encryptString($0, keys: keys) },
                linkedId: f.linkedId?.rawValue
            )
        }
    }

    // MARK: - Private: Custom field extractor

    private func customFieldsOf(_ content: DraftItemContent) -> [DraftCustomField] {
        switch content {
        case .login(let c):      return c.customFields
        case .secureNote(let c): return c.customFields
        case .card(let c):       return c.customFields
        case .identity(let c):   return c.customFields
        case .sshKey(let c):     return c.customFields
        }
    }

    // MARK: - Encrypt helper

    /// Encrypts a plaintext string as a Type-2 EncString and returns its wire representation.
    private func encryptString(_ plaintext: String, keys: CryptoKeys) throws -> String {
        guard let data = plaintext.data(using: .utf8) else {
            throw CipherMapperError.fieldDecryptionFailed("utf8-encode")
        }
        return try EncString.encrypt(data: data, keys: keys).toString()
    }

    // MARK: - Decrypt helpers

    /// Decrypts an EncString field that is expected to be present.
    private func decryptRequired(_ encStr: String, field: String, keys: CryptoKeys) throws -> String {
        do {
            let enc  = try EncString(string: encStr)
            let data = try enc.decrypt(keys: keys)
            guard let str = String(data: data, encoding: .utf8) else {
                throw CipherMapperError.fieldDecryptionFailed(field)
            }
            return str
        } catch let e as EncStringError {
            throw e
        } catch {
            Self.logger.error("Field decryption failed: \(field, privacy: .public)")
            throw CipherMapperError.fieldDecryptionFailed(field)
        }
    }
}
