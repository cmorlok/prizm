import CryptoKit
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
    /// A value of the item's stored server record could not be read under the item's key while a
    /// save was built over it, so the save cannot be matched with what the server holds. The name is
    /// the field kind only, never a value.
    case storedValueUnreadable(String)
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

    /// The clock for the dates Prizm writes itself (`login.passwordRevisionDate`). Injected so tests
    /// get a fixed time; production always uses the current time.
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

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

    // MARK: - Key check

    /// Checks that `keys` is the key the item's stored fields are encrypted with, by verifying and
    /// decrypting the stored name. Nothing is kept: the decrypted bytes are zeroed before returning.
    ///
    /// - Security goal: a wrong active key on an item without its own key (for example the vault key
    ///   for a record the server keeps under an organization key) would otherwise produce a
    ///   mixed-key item: new fields under one key next to the copied passkey and password-history
    ///   ciphertext under another, which no client can read. The unwrap of an item key already fails
    ///   closed on a wrong key; this check covers the keyless records and the unwrap that happens to
    ///   succeed.
    /// - Algorithm: the name must be an EncString type 2 (AES-256-CBC with HMAC-SHA256, Bitwarden
    ///   Security Whitepaper §4). `EncString.decrypt` verifies the HMAC before it decrypts
    ///   (encrypt-then-MAC), so a wrong key is a MAC mismatch and not a padding guess.
    /// - Deviation from the Bitwarden SDK: the SDK's default edit is lenient and writes whatever it
    ///   is given; only its flag-gated strict mode checks like this. This is Prizm's deliberate,
    ///   stricter choice and not parity.
    /// - Intentionally NOT done: preserved values (passkeys, password history, SSH fingerprint,
    ///   unknown keys) are never decrypted to validate them, because that would turn a passkey's
    ///   private key into plaintext for no benefit. A type-0 name is refused because it carries no
    ///   MAC, so it proves nothing about the key; this stays until `fix-encstring-validation` refuses
    ///   type 0 everywhere. The decrypted name is not logged and not returned.
    ///
    /// - Throws: `CipherMapperError.fieldDecryptionFailed("name")` when the name is not a type-2
    ///   EncString, its MAC does not verify, or it does not decrypt under `keys`.
    func verifyKey(_ keys: CryptoKeys, against base: RawCipher) throws {
        let name: EncString
        do {
            name = try EncString(string: base.name)
        } catch {
            throw CipherMapperError.fieldDecryptionFailed("name")
        }
        guard name.encType == .aes256Cbc_HmacSha256_B64 else {
            throw CipherMapperError.fieldDecryptionFailed("name")
        }
        var plaintext: Data
        do {
            plaintext = try name.decrypt(keys: keys)
        } catch {
            throw CipherMapperError.fieldDecryptionFailed("name")
        }
        plaintext.resetBytes(in: plaintext.indices)
    }

    // MARK: - Edit block

    /// Why Prizm must not save `raw` as it is, or nil when it can.
    ///
    /// Computed here, from the record, so Presentation never looks at raw shapes. In order:
    /// - a blob (`hasBlobData`): the official server stores a `data` that carries a `format_version`
    ///   verbatim and ignores the typed fields, so a save would not change the item;
    /// - a partial item (`hasPartialData`): Prizm does not hold the whole record;
    /// - a type 1, 3, 4 or 5 item without its login, card, identity or SSH key object: nothing to
    ///   rebuild the section from. A secure note (type 2) is mappable without its object, because
    ///   Prizm writes `{ "type": 0 }` back;
    /// - a name that is an EncString of type 0 (`usesLegacyEncryption`): every save would fail the
    ///   key check of `verifyKey`, so the item is read-only up front instead of failing at save time
    ///   with a text that tells the user to lock and unlock.
    ///
    /// An item with its own key is not blocked: a save is written with that key (`effectiveKeys`).
    /// A `data` alone and a null `partialData` do not block: the official server sends both on every
    /// cipher (source-reviewed, see `cipher-official-shaped.json`), so blocking on either would make
    /// every item on that server read-only.
    func editBlock(for raw: RawCipher) -> EditBlockReason? {
        let reason = lastingEditBlock(for: raw)
        if let reason {
            Self.logger.debug("Cipher \(raw.id, privacy: .public) cannot be edited: \(String(describing: reason), privacy: .public)")
        }
        return reason
    }

    private func lastingEditBlock(for raw: RawCipher) -> EditBlockReason? {
        if raw.hasBlobData { return .unsupportedFormat }
        if raw.hasPartialData { return .partiallyAvailable }
        if lacksItsTypeObject(raw) { return .unmappable }
        if usesLegacyEncryption(raw) { return .legacyEncryption }
        return nil
    }

    /// True when the stored name carries the type prefix `0` (AES-CBC without a MAC). Only the
    /// prefix is read, never the ciphertext, so a malformed type-0 string counts too: it cannot be
    /// saved either. A name without a type prefix is not type 0 and is left to the key check.
    private func usesLegacyEncryption(_ raw: RawCipher) -> Bool {
        guard let dot = raw.name.firstIndex(of: ".") else { return false }
        return Int(raw.name[..<dot]) == EncType.aes256Cbc_B64.rawValue
    }

    /// True for a login, card, identity or SSH key item whose own section is absent or null.
    private func lacksItsTypeObject(_ raw: RawCipher) -> Bool {
        switch raw.type {
        case 1: return raw.login == nil
        case 3: return raw.card == nil
        case 4: return raw.identity == nil
        case 5: return raw.sshKey == nil
        default: return false
        }
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

    /// Converts a new `DraftVaultItem` into an encrypted `RawCipher` ready for `POST /ciphers`.
    ///
    /// This is the create path, and the name says so: there is no stored server record, so there is
    /// no item key and no preserved value. Used for an edit it would silently bring the data-loss
    /// bug back. A save of an existing item goes through
    /// `toRawCipher(_:overlaying:effectiveKeys:encryptedFor:)`, which cannot be called without the
    /// item's stored record.
    ///
    /// - Security goal: ensures that no vault secret (password, card number, private key, etc.)
    ///   ever leaves the device in plaintext. Every string field that is an EncString on the
    ///   Bitwarden wire format is encrypted here before the request body is serialised.
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
    ///   official web vault uses.
    ///
    /// - What is NOT done:
    ///   • No `key` is sent: a new item has none, and Prizm does not give new items their own key
    ///     (that is the separate change `per-item-key-on-create`).
    ///   • `deletedDate`, `creationDate`, `revisionDate` are sent as `nil` — the server is
    ///     authoritative for these timestamps and ignores client-provided values.
    ///   • Biometric re-authentication before encryption is not performed here; it is
    ///     the caller's responsibility (see `VaultRepositoryImpl.update` TODO).
    ///
    /// - Parameter draft: The new item to encrypt.
    /// - Parameter keys:  The symmetric key pair (AES-256 enc key + HMAC-SHA256 MAC key): the vault
    ///   key, or the organization key for an organization item.
    /// - Parameter encryptedFor: The user id sent as `encryptedFor`. The repository passes the
    ///   profile id of the last sync. Required: Vaultwarden 1.37.4 answers 422 to a create without it.
    /// - Returns: A `RawCipher` with all sensitive string fields encrypted as EncStrings.
    /// - Throws: `EncStringError` if IV generation or AES/HMAC computation fails.
    func toNewRawCipher(_ draft: DraftVaultItem, encryptedWith keys: CryptoKeys,
                        encryptedFor: String) throws -> RawCipher {
        try buildRawCipher(draft, keys: keys, encryptedFor: encryptedFor, base: nil)
    }

    /// Converts an edited `DraftVaultItem` into the `RawCipher` for `PUT /ciphers/{id}`, built over
    /// the item's last server record `base`.
    ///
    /// - Security goal: send the server's own record with only the user's edits replaced, so nothing
    ///   another client stored is lost and nothing is mixed under another key. A save that dropped
    ///   the item key, or encrypted the edited fields under another key than the copied passkey and
    ///   history ciphertext, would leave an item no client can read.
    /// - Algorithm: EncString type-2 as on create (AES-256-CBC + HMAC-SHA256, Bitwarden Security
    ///   Whitepaper §4). `keys` must be the item's effective key (`effectiveKeys(for:activeKeys:)`
    ///   over `base`), already checked with `verifyKey(_:against:)`; this function does not choose
    ///   a key and has no fallback.
    /// - Owned by the draft, re-encrypted with a fresh IV under `keys` on every save (as the Bitwarden
    ///   SDK does; nothing tries to detect an unchanged field): name, notes, custom field values,
    ///   login username, password, totp, websites and their match type, every card, identity and SSH
    ///   key text field. Plain values from the draft: folder, favorite, reprompt, organization and
    ///   collections.
    /// - Copied from `base` as received, never decrypted: `key` (byte for byte, never re-wrapped),
    ///   `passwordHistory`, `archivedDate`, `sshKey.keyFingerprint`
    ///   and the unknown keys of the login, each website, card, identity, SSH key and each custom
    ///   field (passkeys and `autofillOnPageLoad` among them). They are ciphertext or plain flags
    ///   that Prizm has no reason to read; decrypting a passkey or a history entry to validate it
    ///   would make a secret plaintext for nothing. A website takes the unknown keys of the stored
    ///   website with the same text, a custom field those of the stored field with the same name and
    ///   type (first unused match each), never those of the one at the same position.
    /// - Never copied from `base`: `folderId`, `favorite`, `organizationId`, `collectionIds`. Prizm's
    ///   own folder, favorite and collection changes do not refresh the stored record until
    ///   stale-write protection does, so a stored value could revert the user's change. The
    ///   response-only keys (`data`, the legacy `login.uri`, `edit`, `permissions`) never reach the
    ///   model, so they cannot be sent.
    /// - Set by Prizm: `login.passwordRevisionDate` is the save time when the password was changed,
    ///   added or cleared, else the stored value as received (`passwordRevisionDate(newPassword:base:keys:)`).
    /// - Intentionally NOT done: re-encrypting only the fields that changed; adding, dropping or
    ///   re-wrapping the item key (the SDK re-wraps a key under the key it was read with; Prizm
    ///   keeps it unchanged, and giving new items a key is `per-item-key-on-create`); appending to
    ///   the password history when the password changes (the separate `password-history` change).
    ///
    /// - Parameter encryptedFor: The profile id of the last sync (Vaultwarden 1.37.4 answers 422
    ///   without it).
    /// - Throws: `EncStringError` if encryption fails, `CipherMapperError.storedValueUnreadable` when
    ///   a stored website, field name or password that is compared with the draft cannot be read under
    ///   `keys`.
    func toRawCipher(_ draft: DraftVaultItem, overlaying base: RawCipher, effectiveKeys keys: CryptoKeys,
                     encryptedFor: String) throws -> RawCipher {
        try buildRawCipher(draft, keys: keys, encryptedFor: encryptedFor, base: base)
    }

    /// The part both entry points share. `base` is nil on create.
    private func buildRawCipher(_ draft: DraftVaultItem, keys: CryptoKeys,
                                encryptedFor: String, base: RawCipher?) throws -> RawCipher {
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
        let encFields = try toRawFields(customFieldsOf(draft.content), keys: keys, base: base?.fields, itemId: draft.id)

        let (type, loginData, cardData, identityData, secureNoteData, sshKeyData) =
            try encryptContent(draft.content, keys: keys, base: base, itemId: draft.id)

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
            // The stored key string itself, never re-wrapped or re-encoded; nil for an item without one.
            key:            base?.key,
            collectionIds:  draft.collectionIds,
            attachments:    nil,
            encryptedFor:   encryptedFor,
            // As received (absent stays absent, null stays null): a request without them clears both
            // on the server (design E4).
            archivedDate:   base?.archivedDate,
            // TODO: append the replaced password here when the password changes. Deferred to the
            // password-history change; until then the stored history goes back unchanged (design D3).
            passwordHistory: base?.passwordHistory,
            // Stale-write protection sets it; until then a request never carries one.
            lastKnownRevisionDate: nil
        )
    }

    // MARK: - Private: Reverse content dispatch

    private func encryptContent(
        _ content: DraftItemContent,
        keys: CryptoKeys,
        base: RawCipher?,
        itemId: String
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
            return (1, try toRawLogin(c, keys: keys, base: base?.login), nil, nil, nil, nil)
        case .secureNote:
            return (2, nil, nil, nil, RawSecureNoteData(type: 0), nil)
        case .card(let c):
            return (3, nil, try toRawCard(c, keys: keys, base: base?.card), nil, nil, nil)
        case .identity(let c):
            return (4, nil, nil, try toRawIdentity(c, keys: keys, base: base?.identity), nil, nil)
        case .sshKey(let c):
            return (5, nil, nil, nil, nil, try toRawSSHKey(c, keys: keys, base: base?.sshKey))
        }
    }

    // MARK: - Private: Login reverse map

    private func toRawLogin(_ c: DraftLoginContent, keys: CryptoKeys, base: RawLoginData?) throws -> RawLoginData {
        // An empty address is not sent (the edit sheet drops blank rows already; this is the
        // backstop). Every other address gets a checksum computed from the exact string that is
        // encrypted as `uri`, under the same keys, so official clients accept it.
        //
        // On a save, each address takes the unknown keys of the stored address with the same text
        // (first unused match), not of the one at the same position: the edit sheet adds, removes and
        // reorders websites. A stored address's text is read here under the item's key because it is a
        // field Prizm shows anyway; it is a comparison key and is not kept.
        var storedURIs = try readStoredURIs(base?.uris, keys: keys)
        let rawURIs: [RawURI] = try c.uris.filter { !$0.uri.isEmpty }.map { uri in
            var extras: [String: JSONValue] = [:]
            if let match = storedURIs.firstIndex(where: { $0.text == uri.uri }) {
                extras = storedURIs.remove(at: match).extras
            }
            return RawURI(
                uri: try encryptString(uri.uri, keys: keys),
                match: uri.matchType?.rawValue,
                uriChecksum: try encryptString(Self.uriChecksumPlaintext(uri.uri), keys: keys),
                extras: extras
            )
        }
        return RawLoginData(
            username: try c.username.map { try encryptString($0, keys: keys) },
            password: try c.password.map { try encryptString($0, keys: keys) },
            uris:     rawURIs,
            totp:     try c.totp.map { try encryptString($0, keys: keys) },
            passwordRevisionDate: try passwordRevisionDate(newPassword: c.password, base: base, keys: keys),
            // From the stored login as received: the passkeys, `autofillOnPageLoad` and unknown keys.
            extras:   base?.extras ?? [:]
        )
    }

    /// The `login.passwordRevisionDate` to send: the save time when the password was changed, added
    /// or cleared, otherwise the stored value exactly as received. Nil on create (no stored login):
    /// the server stamps a new item itself.
    ///
    /// - Rule and source: Bitwarden SDK `login.rs`, `detect_password_change`. A missing original
    ///   login keeps the date; two empty passwords keep it; an empty original with a new password
    ///   gets now; equal passwords keep the original date; any other difference (changed or
    ///   cleared) gets now. A missing and an empty password count as the same (`?? ""`).
    /// - Why plaintext: every save re-encrypts with a fresh IV, so comparing ciphertext would
    ///   report a change on every edit. The stored password is decrypted under the item's effective
    ///   key for this one comparison, held in a `Data` local that is zeroed before returning, never
    ///   logged and never written back. A stored password that is not valid UTF-8 compares as
    ///   changed; such an item cannot be mapped for display, so it never reaches an edit.
    /// - Never compares dates: an unchanged password returns the typed stored value, and a
    ///   wrong-typed stored value that sits in `extras` goes back through `extras` untouched; a
    ///   changed password sets the typed field, which `WireWriter` writes before `extras` and so
    ///   once only.
    /// - Format: ISO-8601 UTC with milliseconds and `Z` (RFC 3339), the formatter this mapper already
    ///   uses for dates. The SDK writes nanoseconds and `+00:00`. Vaultwarden 1.37.4 accepts this
    ///   form (tested live); the official server is source-reviewed, not tested.
    /// - Intentionally NOT done: the replaced password is not appended to `passwordHistory`
    ///   (the separate `password-history` change).
    ///
    /// - Throws: `CipherMapperError.storedValueUnreadable("password")` when the stored password does
    ///   not decrypt under `keys` (a mixed-key record that passed the name check); the save fails.
    private func passwordRevisionDate(newPassword: String?, base: RawLoginData?, keys: CryptoKeys) throws -> String? {
        guard let base else { return nil }
        // Compared as bytes, not as `String`: a `String` cannot be zeroed, `Data` can (Constitution III).
        // The typed password still arrives as a `String` from the draft; only the copies made here
        // are wiped.
        var stored = Data()
        defer { stored.resetBytes(in: stored.indices) }
        if let encrypted = base.password {
            do {
                stored = try EncString(string: encrypted).decrypt(keys: keys)
            } catch {
                throw CipherMapperError.storedValueUnreadable("password")
            }
        }
        var typed = Data((newPassword ?? "").utf8)
        defer { typed.resetBytes(in: typed.indices) }
        if stored == typed { return base.passwordRevisionDate }
        return Self.iso8601.string(from: now())
    }

    // MARK: - Private: Card reverse map

    private func toRawCard(_ c: DraftCardContent, keys: CryptoKeys, base: RawCardData?) throws -> RawCardData {
        RawCardData(
            cardholderName: try c.cardholderName.map { try encryptString($0, keys: keys) },
            brand:          try c.brand.map          { try encryptString($0, keys: keys) },
            number:         try c.number.map         { try encryptString($0, keys: keys) },
            expMonth:       try c.expMonth.map       { try encryptString($0, keys: keys) },
            expYear:        try c.expYear.map        { try encryptString($0, keys: keys) },
            code:           try c.code.map           { try encryptString($0, keys: keys) },
            extras:         base?.extras ?? [:]
        )
    }

    // MARK: - Private: Identity reverse map

    private func toRawIdentity(_ c: DraftIdentityContent, keys: CryptoKeys, base: RawIdentityData?) throws -> RawIdentityData {
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
            licenseNumber:  try enc(c.licenseNumber),
            extras:         base?.extras ?? [:]
        )
    }

    // MARK: - Private: SSH Key reverse map

    private func toRawSSHKey(_ c: DraftSSHKeyContent, keys: CryptoKeys, base: RawSSHKeyData?) throws -> RawSSHKeyData {
        // The fingerprint is not derived or checked here. A request without it makes Vaultwarden
        // 1.37.4 drop the whole SSH key (design E8), so an edit sends the stored EncString back as
        // received. Editing the key text keeps the old fingerprint until `fix-ssh-key-roundtrip`
        // derives a new one. A create sends none, which that change also covers.
        RawSSHKeyData(
            privateKey:     try c.privateKey.map  { try encryptString($0, keys: keys) },
            publicKey:      try c.publicKey.map   { try encryptString($0, keys: keys) },
            keyFingerprint: base?.keyFingerprint,
            extras:         base?.extras ?? [:]
        )
    }

    // MARK: - Private: Custom fields reverse map

    /// A draft field takes the unknown keys of the stored field with the same name and the same type
    /// (first unused match, in stored order, so fields with equal names pair up in order). A stored
    /// field is used at most once; a draft field without a match takes none.
    ///
    /// Why name and type and not position: the edit sheet cannot add, remove or reorder fields, but
    /// the stored record can change under an open sheet (a sync replaced it). Pairing by position
    /// would then attach one field's unknown keys to another field, which is wrong data and worse
    /// than a missing key. A name and type that match are the best identity a field has: the wire
    /// model carries no field id. Same approach as websites (`toRawLogin`).
    ///
    /// The stored names are read under the item's key only for this comparison, as stored websites
    /// are: they are local `String`s that are never kept or logged (a Swift `String` cannot be
    /// zeroed; the key check's `Data` is). A stored field without a name is not listed by Prizm, so
    /// nothing can match it. Stored fields that no draft field takes are dropped, and only the
    /// count is logged, never names or values.
    ///
    /// - Throws: `CipherMapperError.storedValueUnreadable("field.name")` when a stored name does not
    ///   decrypt under `keys`; the key check ran before, so this means a damaged record, and the save
    ///   fails instead of guessing which field carried which keys (same as an unreadable website).
    private func toRawFields(_ fields: [DraftCustomField], keys: CryptoKeys,
                             base: [RawField]? = nil, itemId: String = "") throws -> [RawField] {
        var stored = try readStoredFields(base, keys: keys)
        let storedWithExtras = stored.filter { !$0.extras.isEmpty }.count
        let rawFields: [RawField] = try fields.map { f in
            var extras: [String: JSONValue] = [:]
            if let match = stored.firstIndex(where: { $0.name == f.name && $0.type == f.type }) {
                extras = stored.remove(at: match).extras
            }
            return RawField(
                type:     f.type.rawValue,
                name:     try encryptString(f.name, keys: keys),
                value:    try f.value.map { try encryptString($0, keys: keys) },
                linkedId: f.linkedId?.rawValue,
                extras:   extras
            )
        }
        let dropped = stored.filter { !$0.extras.isEmpty }.count
        if dropped > 0 {
            Self.logger.info("Custom field unknown keys dropped for \(itemId, privacy: .public): \(dropped, privacy: .public) of \(storedWithExtras, privacy: .public) stored field(s) with unknown keys had no draft field of the same name and type")
        }
        return rawFields
    }

    /// The name, type and unknown keys of the stored custom fields that have a name, in stored order.
    /// The type is read the way `mapFields` reads it, so it compares with the draft's type.
    private func readStoredFields(_ stored: [RawField]?, keys: CryptoKeys) throws
        -> [(name: String, type: CustomFieldType, extras: [String: JSONValue])] {
        try (stored ?? []).compactMap { field in
            guard let encrypted = field.name else { return nil }
            do {
                return (try decryptRequired(encrypted, field: "field.name", keys: keys),
                        CustomFieldType(rawValue: field.type) ?? .text,
                        field.extras)
            } catch {
                throw CipherMapperError.storedValueUnreadable("field.name")
            }
        }
    }

    /// The text and unknown keys of the stored addresses that have a value, in stored order.
    ///
    /// Throws `CipherMapperError.storedValueUnreadable("uri")` when one does not decrypt under
    /// `keys`; the key check ran before, so this means a damaged record, and the save fails instead
    /// of guessing which addresses carried which keys.
    private func readStoredURIs(_ stored: [RawURI]?, keys: CryptoKeys) throws -> [(text: String, extras: [String: JSONValue])] {
        try (stored ?? []).compactMap { uri in
            guard let encrypted = uri.uri else { return nil }
            do {
                return (try decryptRequired(encrypted, field: "uri", keys: keys), uri.extras)
            } catch {
                throw CipherMapperError.storedValueUnreadable("uri")
            }
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

    // MARK: - URI checksum

    /// The plaintext of a website's `uriChecksum`: base64 of the SHA-256 of the address's UTF-8 bytes.
    /// The caller encrypts it as an EncString under the key the item's fields use.
    ///
    /// - Security goal: official Bitwarden clients verify the checksum of every website of an item
    ///   that has its own key. A website whose checksum is missing or does not match is hidden, and
    ///   dropped when that client next saves the item. The checksum also binds an address to its
    ///   ciphertext, so an address swapped in by someone who cannot compute the checksum is noticed.
    /// - Algorithm: SHA-256 (FIPS 180-4), base64 (RFC 4648 section 4), as `generate_checksum` in the
    ///   Bitwarden SDK (`bitwarden-vault`, `login.rs`). CryptoKit's `SHA256`, no own implementation.
    /// - Intentionally NOT done: no trimming, lowercasing or other normalisation. The hash covers
    ///   exactly the string that is encrypted as `uri`; a checksum of a normalised form would not
    ///   match what other clients compute from the decrypted address. A stored checksum is never
    ///   reused: every save and create computes a fresh one for every website, as the SDK does, so
    ///   an edited address can never keep the checksum of its old value.
    /// - Not a secret and not authentication: the checksum is a hash of data that is encrypted next
    ///   to it, and it is itself sent encrypted.
    static func uriChecksumPlaintext(_ uri: String) -> String {
        Data(SHA256.hash(data: Data(uri.utf8))).base64EncodedString()
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
