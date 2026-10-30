import Foundation
import os.log

// MARK: - Protocol

/// Bitwarden REST API client for auth and vault sync operations.
///
/// All requests to the configured server include `Device-Type`, `Bitwarden-Client-Name` and
/// `Bitwarden-Client-Version` (values in `Config`).
/// The identity token request additionally sends `client_id` and `deviceType` as form parameters.
/// Reference: https://contributing.bitwarden.com/architecture/adr/integration-identifiers/
/// Missing or invalid headers result in `400 Bad Request` / `403 Forbidden` from the server.
///
/// Implemented as an `actor` to serialise the mutable `baseURL` and `accessToken` state.
protocol PrizmAPIClientProtocol: Actor {

    /// The base URL configured by `AuthRepositoryImpl` after the user enters their server address.
    var baseURL: URL? { get }

    /// Stores the base URL; sets up derived endpoint URLs.
    func setBaseURL(_ url: URL)

    /// Stores the access token used for subsequent authenticated requests.
    func setAccessToken(_ token: String)

    /// Clears the in-memory access token.
    ///
    /// - Security goal: removes the bearer token from memory on sign-out so it cannot
    ///   be read from a heap dump after the session ends (Constitution §III).
    func clearAccessToken()

    /// POST `/identity/accounts/prelogin/password` (legacy servers: `/identity/accounts/prelogin`)
    /// — returns KDF parameters for the given email.
    /// Used to derive the master key before posting credentials to `/connect/token`.
    ///
    /// No authentication required; sends only the email address.
    func preLogin(email: String) async throws -> PreLoginResponse

    /// POST `/connect/token` — exchanges a hashed password (or TOTP code) for tokens.
    ///
    /// The request is `application/x-www-form-urlencoded` as required by the OAuth2 spec.
    /// On a 2FA challenge the server returns HTTP 400 with `TwoFactorProviders` in the body;
    /// the caller should inspect `TokenResponse.twoFactorProviders` and handle accordingly.
    ///
    /// - Parameters:
    ///   - email:              The user's email address.
    ///   - passwordHash:       Base64-encoded server authentication hash (from `makeServerHash`).
    ///   - deviceIdentifier:   UUID uniquely identifying this installation (persisted in Keychain).
    ///   - twoFactorToken:     TOTP code from the authenticator app, if completing a 2FA challenge.
    ///   - twoFactorProvider:  Numeric 2FA provider identifier (0 = authenticatorApp).
    ///   - twoFactorRemember:  When true, requests a `TwoFactorToken` cookie for future logins.
    func identityToken(
        email:              String,
        passwordHash:       String,
        deviceIdentifier:   String,
        twoFactorToken:     String?,
        twoFactorProvider:  Int?,
        twoFactorRemember:  Bool
    ) async throws -> TokenResponse

    /// GET `/sync?excludeDomains=true` — returns the full encrypted vault.
    ///
    /// Requires a valid `Authorization: Bearer <accessToken>` header.
    /// Throws `SyncError.unauthorized` on HTTP 401.
    func fetchSync() async throws -> SyncResponse

    /// POST `/identity/connect/token` with `grant_type=refresh_token` — exchanges a refresh token
    /// for a new access token. Updates the stored access token on success.
    ///
    /// - Returns: A tuple of (newAccessToken, newRefreshToken). The refresh token may be nil
    ///   if the server does not rotate it.
    func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?)

    /// PUT `/api/ciphers/{id}` — updates an existing cipher with re-encrypted field values.
    ///
    /// Requires a valid `Authorization: Bearer <accessToken>` header.
    /// The request body is a JSON-encoded `RawCipher` with all sensitive fields re-encrypted
    /// as EncStrings (type-2 AES-256-CBC + HMAC-SHA256).
    /// On success the server returns the updated cipher, which is decoded back into `RawCipher`.
    ///
    /// Reference: Bitwarden Server API PUT /api/ciphers/{id}
    func updateCipher(id: String, cipher: RawCipher) async throws -> RawCipher

    /// GET `/api/ciphers/{id}` — one cipher, in the shape `/api/sync` uses for its `ciphers` array.
    ///
    /// Used to learn the server's current record (and so its revision) of an item after an operation
    /// whose answer carries none. Vaultwarden 1.37.4 answers with the same fields as the sync
    /// (`deletedDate` included, tested on that version); the official server's shape is source-reviewed,
    /// not tested.
    ///
    /// Reference: Bitwarden Server API GET /api/ciphers/{id}
    func getCipher(id: String) async throws -> RawCipher

    /// PUT `/api/ciphers/{id}/collections_v2` — sets the collections of an org cipher, as the
    /// Bitwarden SDK does (`bitwarden-vault/src/cipher/cipher_client/edit.rs`).
    ///
    /// `PUT /api/ciphers/{id}` does not change collection assignments, so this is a separate call.
    /// The posted list replaces the user's *writable* assignments only: the official server removes
    /// the item from every writable collection not in the list and leaves read-only ones alone
    /// (`CollectionCipher_UpdateCollections.sql`). Vaultwarden 1.37.4 fails the whole request when
    /// the list contains a collection the user cannot write, even an unchanged one, and keeps a
    /// read-only assignment that is left out (live rig 2026-10-30). So the list leaves out the
    /// read-only collections, and an empty list unassigns the item from all writable collections;
    /// it never means "Default collection" (fix-collection-assignment, D2 and D6).
    ///
    /// The answer is `{unavailable, cipher?}`. The official server changes the item's revision on
    /// this call, so the cipher is returned for the caller to keep as the item's record; nil when
    /// the answer has none Prizm can read (the change itself succeeded, and the caller fetches the
    /// item). Servers without `collections_v2` get the same list on `LegacyCipherCollectionsEndpoint`.
    func updateCipherCollections(id: String, collectionIds: [String]) async throws -> CipherCollectionsResult

    /// PUT `/api/ciphers/{id}/delete` — soft-deletes a cipher by moving it to Trash.
    ///
    /// Sets `deletedDate` on the server. The item remains in the user's vault data and
    /// can be restored. Bitwarden cloud auto-purges trashed items after 30 days server-side;
    /// self-hosted Vaultwarden only auto-purges if `TRASH_AUTO_DELETE_DAYS` is configured.
    ///
    /// Note: `DELETE /api/ciphers/{id}` is the *permanent* delete endpoint — do NOT use it
    /// for soft-delete. The soft-delete endpoint is `PUT /api/ciphers/{id}/delete`.
    ///
    /// Reference: Bitwarden Server API PUT /api/ciphers/{id}/delete
    func softDeleteCipher(id: String) async throws

    /// DELETE `/api/ciphers/{id}` — permanently deletes a cipher.
    ///
    /// **Irreversible.** Removes the cipher from the server entirely.
    /// Used only when deleting an item that is already in Trash.
    ///
    /// Reference: Bitwarden Server API DELETE /api/ciphers/{id}
    func permanentDeleteCipher(id: String) async throws

    /// DELETE `/api/ciphers` with `{"ids": [...]}` — permanently deletes the given ciphers, the call
    /// the web vault makes when all items in Trash are selected and deleted.
    ///
    /// Not to be confused with `POST /api/ciphers/purge`, the "Purge vault" action, which deletes
    /// every item the user owns, trashed or not, and on Vaultwarden every folder
    /// (`vaultwarden/src/api/core/ciphers.rs` `purge_personal_vault`; Bitwarden
    /// `CiphersController.PostPurge`). Prizm has no method for it (fix-empty-trash, D5).
    func permanentDeleteCiphers(ids: [String]) async throws

    /// PUT `/api/ciphers/{id}/restore` — restores a trashed cipher to the active vault.
    ///
    /// Clears `deletedDate` on the server. The item becomes visible in the active vault again.
    ///
    /// Vaultwarden 1.37.4 answers with the restored cipher (tested), and so does the official server
    /// (source-reviewed, not tested); this returns it so the caller can take the new revision from
    /// it. A successful restore whose answer is empty or not a cipher returns nil: the restore
    /// happened, only the answer is unusable. An HTTP failure still throws.
    ///
    /// Reference: Bitwarden Server API PUT /api/ciphers/{id}/restore
    func restoreCipher(id: String) async throws -> RawCipher?

    /// POST `/api/ciphers` — creates a new cipher with encrypted field values.
    ///
    /// Requires a valid `Authorization: Bearer <accessToken>` header.
    /// The request body is a JSON-encoded `RawCipher`. The server assigns the ID and timestamps.
    /// On success the server returns the created cipher, decoded back into `RawCipher`.
    func createCipher(cipher: RawCipher) async throws -> RawCipher

    /// POST `/api/ciphers/create` — creates an org-scoped cipher.
    ///
    /// Used for items belonging to an organization (when `cipher.organizationId != nil`).
    /// The body must include `collectionIds[]` so the server assigns the item to the
    /// specified collections.
    ///
    /// Reference: Bitwarden Server API POST /api/ciphers/create
    func createOrgCipher(cipher: RawCipher) async throws -> RawCipher

    // MARK: - Attachment endpoints

    /// POST `/api/ciphers/{cipherId}/attachment/v2` — creates attachment metadata on the server.
    ///
    /// Returns the attachment ID, a signed upload URL (or Bitwarden-hosted URL for fileUploadType 0),
    /// and the file upload type (0 = Bitwarden-hosted, 1 = Azure blob storage).
    ///
    /// Reference: Bitwarden Server API POST /api/ciphers/{id}/attachment/v2
    func createAttachmentMetadata(cipherId: String, body: AttachmentMetadataRequest) async throws -> AttachmentMetadataResponse

    /// POST `/api/ciphers/{cipherId}/attachment/{attachmentId}` — uploads a file blob via multipart.
    ///
    /// Used when `fileUploadType == 0` (Bitwarden-hosted storage).
    /// The encrypted blob is sent as the `data` field of a multipart/form-data body.
    func uploadAttachmentBitwardenHosted(cipherId: String, attachmentId: String, encryptedBlob: Data) async throws

    /// PUT `<signedURL>` with `x-ms-blob-type: BlockBlob` — uploads to Azure Blob Storage.
    ///
    /// Used when `fileUploadType == 1` (Azure). The signed URL is provided by the v2 metadata response.
    /// The request body is the raw encrypted blob with the Azure-required header.
    func uploadAttachmentAzure(signedURL: URL, encryptedBlob: Data) async throws

    /// GET `/api/ciphers/{cipherId}/attachment/{attachmentId}` — fetches a fresh signed download URL.
    ///
    /// Returns an `AttachmentDownloadResponse` containing the signed URL valid for a limited time.
    /// Called when `Attachment.url` is nil or returns HTTP 403.
    func fetchAttachmentDownloadURL(cipherId: String, attachmentId: String) async throws -> AttachmentDownloadResponse

    /// DELETE `/api/ciphers/{cipherId}/attachment/{attachmentId}` — deletes an attachment.
    func deleteAttachment(cipherId: String, attachmentId: String) async throws

    /// GET `<signedURL>` — downloads the raw encrypted blob from a signed URL.
    ///
    /// Used by `AttachmentRepositoryImpl` to fetch attachment blobs. Routed through the
    /// API client (rather than `URLSession.shared`) so tests can mock the download path
    /// and the shared session configuration (timeouts, etc.) is applied.
    func downloadBlob(from url: URL) async throws -> Data

    // MARK: - Folder CRUD

    /// POST `/api/folders` — creates a new folder with an encrypted name.
    func createFolder(encryptedName: String) async throws -> RawFolder

    /// PUT `/api/folders/{id}` — renames a folder with an encrypted name.
    func updateFolder(id: String, encryptedName: String) async throws -> RawFolder

    /// DELETE `/api/folders/{id}` — permanently deletes a folder.
    /// Items in the folder are unfoldered, not deleted.
    func deleteFolder(id: String) async throws

    // MARK: - Cipher partial / move

    /// PUT `/ciphers/{id}/partial` — updates folderId and favorite without re-encrypting.
    func updateCipherPartial(id: String, folderId: String?, favorite: Bool) async throws -> PartialCipherResponse

    /// PUT `/ciphers/move` — bulk-moves ciphers to a folder.
    func moveCiphersToFolder(ids: [String], folderId: String?) async throws

    // MARK: - Collection CRUD

    /// POST `/api/organizations/{orgId}/collections` — creates a new collection.
    ///
    /// - Parameters:
    ///   - organizationId: The org the collection belongs to.
    ///   - request: The encrypted name and the full access list (users, groups, external id).
    func createCollection(organizationId: String, request: CollectionWriteRequest) async throws -> RawCollection

    /// GET `/api/organizations/{orgId}/collections/{id}/details`: the collection with its access list.
    func getCollectionAccessDetails(organizationId: String, id: String) async throws -> CollectionAccessDetailsResponse

    /// PUT `/api/organizations/{orgId}/collections/{id}` — renames an existing collection. `request`
    /// must carry the current access list: the server replaces members and groups with it.
    func renameCollection(id: String, organizationId: String, request: CollectionWriteRequest) async throws -> RawCollection

    /// DELETE `/api/organizations/{orgId}/collections/{id}` — deletes a collection.
    func deleteCollection(id: String, organizationId: String) async throws

}

// MARK: - Wire Models

/// Response from POST `/identity/accounts/prelogin/password` (or the legacy `/identity/accounts/prelogin`).
///
/// Contains the KDF settings and salt needed to derive the master key locally. `kdfSettings` is read
/// first; only when it is absent are the flat `kdf*` fields read, by `LegacyPreloginKdfFields`
/// (fix-kdf-derivation-and-validation, D5).
nonisolated struct PreLoginResponse: Decodable {
    /// The settings to derive with; nil when the server sent none Prizm can use (unknown type,
    /// no iteration count). Range checks happen in `KdfValidator`.
    let kdfParams: KdfParams?
    /// The master password salt, when the server sends one. Vaultwarden 1.37.4 sends null, the
    /// official server the email; Prizm then uses the email (D3).
    let salt: String?

    init(kdfParams: KdfParams?, salt: String? = nil) {
        self.kdfParams = kdfParams
        self.salt      = salt
    }

    /// The settings as an old server sends them, in the flat fields.
    init(kdf: Int, kdfIterations: Int, kdfMemory: Int?, kdfParallelism: Int?) {
        self.init(kdfParams: WireKdfSettings(kdfType: kdf, iterations: kdfIterations,
                                             memory: kdfMemory, parallelism: kdfParallelism).kdfParams)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FirstLetterCaseInsensitiveKey.self)
        let settings = try c.decodeIfPresent(WireKdfSettings.self, "kdfSettings")
            ?? LegacyPreloginKdfFields.read(from: c)
        kdfParams = settings.kdfParams
        salt      = try c.decodeIfPresent(String.self, "salt")
    }
}

/// Response from POST `/connect/token`.
///
/// On success, contains access + refresh tokens and the encrypted user key. On a 2FA challenge,
/// `twoFactorProviders` is non-nil and `accessToken` will be empty/absent.
///
/// The user key and its KDF settings come from `UserDecryptionOptions.MasterPasswordUnlock`; only
/// when that is absent are the top-level `Key` and `Kdf*` read, by `LegacyTokenUserKeyFields`
/// (fix-kdf-derivation-and-validation, D5).
nonisolated struct TokenResponse: Decodable {
    let accessToken:        String
    let refreshToken:       String?
    let tokenType:          String
    let expiresIn:          Int
    /// The encrypted RSA private key (EncString). Used for org cipher decryption.
    let privateKey:         String?
    /// Device remember token returned when `twoFactorRemember == true`.
    let twoFactorToken:     String?
    /// Non-nil when the server requires 2FA; lists available provider type numbers.
    let twoFactorProviders: [Int]?
    let userId:             String?
    let email:              String?
    let name:               String?
    let masterPasswordUnlock: MasterPasswordUnlock?
    /// Read only when `masterPasswordUnlock` is nil.
    let legacyUserKey:      LegacyTokenUserKeyFields?

    /// `UserDecryptionOptions.MasterPasswordUnlock`.
    nonisolated struct MasterPasswordUnlock: Decodable, Equatable {
        let kdf:                       WireKdfSettings?
        let masterKeyEncryptedUserKey: String?
        let salt:                      String?

        init(kdf: WireKdfSettings?, masterKeyEncryptedUserKey: String?, salt: String?) {
            self.kdf                       = kdf
            self.masterKeyEncryptedUserKey = masterKeyEncryptedUserKey
            self.salt                      = salt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: FirstLetterCaseInsensitiveKey.self)
            kdf                       = try c.decodeIfPresent(WireKdfSettings.self, "kdf")
            masterKeyEncryptedUserKey = try c.decodeIfPresent(String.self, "masterKeyEncryptedUserKey")
            salt                      = try c.decodeIfPresent(String.self, "salt")
        }
    }

    /// The user key encrypted with the stretched master key (EncString). Present on success.
    var key: String? { masterPasswordUnlock?.masterKeyEncryptedUserKey ?? legacyUserKey?.key }

    /// The KDF settings the server reports for the user key, if any. Prizm stores the settings it
    /// derived with, not these (D6); they are only compared.
    var kdfSettings: WireKdfSettings? { masterPasswordUnlock?.kdf ?? legacyUserKey?.kdf }

    init(
        accessToken: String, refreshToken: String?, tokenType: String, expiresIn: Int,
        privateKey: String?, twoFactorToken: String?, twoFactorProviders: [Int]?,
        userId: String?, email: String?, name: String?,
        masterPasswordUnlock: MasterPasswordUnlock?, legacyUserKey: LegacyTokenUserKeyFields?
    ) {
        self.accessToken          = accessToken
        self.refreshToken         = refreshToken
        self.tokenType            = tokenType
        self.expiresIn            = expiresIn
        self.privateKey           = privateKey
        self.twoFactorToken       = twoFactorToken
        self.twoFactorProviders   = twoFactorProviders
        self.userId               = userId
        self.email                = email
        self.name                 = name
        self.masterPasswordUnlock = masterPasswordUnlock
        self.legacyUserKey        = masterPasswordUnlock == nil ? legacyUserKey : nil
    }

    /// A response as an old server sends it, with the top-level `Key` and `Kdf*` fields.
    init(
        accessToken: String, refreshToken: String?, tokenType: String, expiresIn: Int,
        key: String?, privateKey: String?,
        kdf: Int?, kdfIterations: Int?, kdfMemory: Int?, kdfParallelism: Int?,
        twoFactorToken: String?, twoFactorProviders: [Int]?,
        userId: String?, email: String?, name: String?
    ) {
        self.init(
            accessToken: accessToken, refreshToken: refreshToken, tokenType: tokenType, expiresIn: expiresIn,
            privateKey: privateKey, twoFactorToken: twoFactorToken, twoFactorProviders: twoFactorProviders,
            userId: userId, email: email, name: name, masterPasswordUnlock: nil,
            legacyUserKey: LegacyTokenUserKeyFields(
                key: key,
                kdf: WireKdfSettings(kdfType: kdf, iterations: kdfIterations, memory: kdfMemory, parallelism: kdfParallelism)
            )
        )
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FirstLetterCaseInsensitiveKey.self)
        accessToken        = try c.decode(String.self, "access_token")
        refreshToken       = try c.decodeIfPresent(String.self, "refresh_token")
        tokenType          = try c.decode(String.self, "token_type")
        expiresIn          = try c.decode(Int.self, "expires_in")
        privateKey         = try c.decodeIfPresent(String.self, "privateKey")
        twoFactorToken     = try c.decodeIfPresent(String.self, "twoFactorToken")
        twoFactorProviders = try c.decodeIfPresent([Int].self, "twoFactorProviders")
        userId             = try c.decodeIfPresent(String.self, "userId")
        email              = try c.decodeIfPresent(String.self, "email")
        name               = try c.decodeIfPresent(String.self, "name")
        masterPasswordUnlock = try c.nestedContainer("userDecryptionOptions")?
            .decodeIfPresent(MasterPasswordUnlock.self, "masterPasswordUnlock")
        legacyUserKey = masterPasswordUnlock == nil ? try LegacyTokenUserKeyFields.read(from: c) : nil
    }
}

// MARK: - Identity Token Semantic Errors

/// Semantic errors from the `/connect/token` endpoint, distinct from raw transport errors.
///
/// The Bitwarden identity service returns HTTP 400 for both wrong passwords and 2FA challenges;
/// `IdentityTokenError` models the meaningful distinctions so the repository layer can act on them.
nonisolated enum IdentityTokenError: Error, Equatable {
    /// The server requires two-factor authentication before issuing a token.
    /// `providers` is the list of available 2FA type numbers (0 = authenticatorApp, etc.).
    case twoFactorRequired(providers: [Int])
    /// The submitted TOTP code (or remember-device token) was rejected by the server.
    case twoFactorCodeInvalid
    /// Email or password is incorrect (HTTP 400 `invalid_grant` without 2FA challenge).
    case invalidCredentials
}

// MARK: - Errors

/// Errors thrown by `PrizmAPIClientImpl` at the transport layer.
///
/// Higher-level semantic errors (e.g. `.invalidCredentials`, `.unauthorized`) are mapped
/// by the repository layer (`AuthRepositoryImpl`, `SyncRepositoryImpl`) from these raw codes.
nonisolated enum APIError: Error, Equatable {
    /// The HTTP response status code indicates failure.
    case httpError(statusCode: Int, body: String)
    /// The response body could not be decoded into the expected type.
    case decodingFailed
    /// `setBaseURL` was never called before making a request.
    case baseURLNotSet
}

nonisolated extension APIError: LocalizedError {
    /// The server's own message for an HTTP error, never the raw body (server-error-texts D1).
    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let body):
            return Self.serverMessage(statusCode: statusCode, body: body) ?? "Server error \(statusCode)."
        case .decodingFailed:
            return "The server response could not be read. Please try again."
        case .baseURLNotSet:
            return "No server URL is configured."
        }
    }
}

nonisolated extension APIError: LogSafeError {
    var logDescription: String {
        switch self {
        case .httpError(let statusCode, _): "HTTP \(statusCode)"
        case .decodingFailed:               "decodingFailed"
        case .baseURLNotSet:                "baseURLNotSet"
        }
    }
}

nonisolated extension APIError {

    /// Longest server message shown; longer ones are cut, so a misbehaving server can't fill an alert.
    static let maxMessageLength = 300

    /// The message official clients show for a failed request (`ErrorResponse`, clients
    /// `libs/common/src/models/response/error.response.ts`): the first validation error, else
    /// `message`, else the identity error model's message. Keys are matched in camelCase and
    /// PascalCase, as both servers use either. 429 gets the official rate limit text.
    /// Deviation: with several validation keys, the official clients take the first in the JSON's
    /// order; `JSONSerialization` keeps no order, so Prizm takes the first in sorted key order.
    static func serverMessage(statusCode: Int, body: String) -> String? {
        if statusCode == 429 { return "Rate limit exceeded. Try again later." }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return nil
        }
        let message = firstValidationError(in: object)
            ?? nonEmptyString(value(object, "message"))
            ?? (value(object, "errorModel") as? [String: Any]).flatMap { nonEmptyString(value($0, "message")) }
        return message.map { String($0.prefix(maxMessageLength)) }
    }

    /// True for the answer Vaultwarden and the official server give to an update based on an
    /// outdated copy: HTTP 400 whose message says the item is "out of date", in any letter case.
    ///
    /// - Vaultwarden 1.37.4 (tested, `stale-put-400-1.37.4.json`): "The client copy of this cipher is
    ///   out of date. Resync the client and try again."
    /// - Official server (source-reviewed, not tested, `official-out-of-date-400.json`): "The item
    ///   cannot be saved because it is out of date. To edit this item, first sync your vault, or
    ///   log out and back in."
    ///
    /// Matched on `serverMessage`, so camelCase and PascalCase keys and the three message places are
    /// covered, and on 400 only: a 409 or 500 that happens to contain the phrase is not a stale write.
    /// The phrase is the only signal the servers give; neither sends a distinct error code.
    var isOutOfDateRejection: Bool {
        guard case .httpError(let statusCode, let body) = self, statusCode == 400,
              let message = Self.serverMessage(statusCode: statusCode, body: body) else { return false }
        return message.localizedCaseInsensitiveContains("out of date")
    }

    private static func value(_ object: [String: Any], _ camelCaseKey: String) -> Any? {
        object[camelCaseKey] ?? object[camelCaseKey.prefix(1).uppercased() + camelCaseKey.dropFirst()]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    /// Sorted keys, so the same body always gives the same message.
    private static func firstValidationError(in object: [String: Any]) -> String? {
        guard let errors = value(object, "validationErrors") as? [String: Any] else { return nil }
        for key in errors.keys.sorted() {
            if let message = (errors[key] as? [Any])?.lazy.compactMap(nonEmptyString).first { return message }
        }
        return nil
    }
}

// MARK: - Partial update wire model

/// The fields of the `PUT /api/ciphers/{id}/partial` response that Prizm checks. Both servers answer
/// with the cipher as the user sees it after the update (Vaultwarden `put_cipher_partial`, Bitwarden
/// `CiphersController.PutPartial`).
nonisolated struct PartialCipherResponse: Decodable, Equatable {
    let favorite: Bool?
    /// `.some(nil)`: the field is present and null (no folder). `nil`: the server did not send it.
    let folderId: String??

    init(favorite: Bool?, folderId: String??) {
        self.favorite = favorite
        self.folderId = folderId
    }

    private enum CodingKeys: String, CodingKey { case favorite, folderId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite)
        folderId = container.contains(.folderId)
            ? .some(try container.decodeIfPresent(String.self, forKey: .folderId))
            : nil
    }
}

// MARK: - Attachment wire models

/// Request body for POST `/api/ciphers/{id}/attachment/v2`.
///
/// `fileName` is an EncString (encrypted). `key` is the per-attachment key wrapped as
/// an EncString. Both are produced by `AttachmentRepositoryImpl` before sending.
///
/// Reference: Bitwarden Server API POST /api/ciphers/{id}/attachment/v2
nonisolated struct AttachmentMetadataRequest: Encodable {
    let fileName:     String    // EncString
    let key:          String    // EncString — per-attachment key wrapped with cipher key
    let fileSize:     Int
    let adminRequest: Bool      // always false for personal vault

    // Server expects camelCase — synthesized Encodable matches.
}

/// Response from POST `/api/ciphers/{id}/attachment/v2`.
///
/// `fileUploadType`: 0 = Bitwarden-hosted (POST to API), 1 = Azure (PUT to signed URL).
/// `url` is the signed upload destination (Azure) or the API upload endpoint (Bitwarden-hosted).
/// `attachmentId` is the server-assigned ID for the new attachment.
nonisolated struct AttachmentMetadataResponse: Decodable {
    let attachmentId:   String
    let url:            String
    let fileUploadType: Int
}

/// Response from GET `/api/ciphers/{id}/attachment/{attachmentId}`.
///
/// Contains a fresh signed download URL for the encrypted blob.
nonisolated struct AttachmentDownloadResponse: Decodable {
    let url: String
}

// MARK: - Implementation

/// URLSession-backed Bitwarden API client.
///
/// All requests include the required Bitwarden client identification headers:
/// - `Device-Type: 7` (MacOsDesktop) and `Bitwarden-Client-Name: desktop`
/// - `Bitwarden-Client-Version: "2024.12.0"` (>= 2024.12.0 required for SSH key support on Vaultwarden)
///
/// The identity token request additionally sends these as form body parameters:
/// - `client_id: "desktop"`   (registered client identifier)
/// - `deviceType: "7"`        (7 = macOS desktop, per Bitwarden DeviceType enum)
///
/// Header requirements: https://contributing.bitwarden.com/architecture/adr/integration-identifiers/
/// DeviceType enum values: https://github.com/bitwarden/server/blob/main/src/Core/Enums/DeviceType.cs
actor PrizmAPIClientImpl: PrizmAPIClientProtocol {

    // MARK: - Private state

    private(set) var baseURL: URL?
    private var accessToken: String?

    private let session:   URLSession
    private let logger:    Logger = Logger(
        subsystem: "com.prizm",
        category:  "PrizmAPIClient"
    )

    // MARK: - Bitwarden client identification headers
    // These are mandatory on every request to the Bitwarden identity + API services.
    // deviceType 7 = macOS desktop per the Bitwarden DeviceType enum:
    // https://github.com/bitwarden/server/blob/main/src/Core/Enums/DeviceType.cs
    private enum ClientHeaders {
        static let clientId      = Config.clientName
        static let clientVersion = Config.bitwardenClientVersion
        static let deviceType    = String(Config.deviceType)
        static let userAgent     = Config.userAgent
    }

    /// Idle time-out, in seconds, of `getCipher`, instead of the session default of 60.
    ///
    /// Why: the fetch learns an item's revision after one of Prizm's own writes and runs inside that
    /// item's write queue, so while it waits every later write to the item waits too (an edit-sheet
    /// Save shows "Saving…" meanwhile). A failed fetch is only logged and costs at most one later
    /// conflict, so giving up early is cheap; one cipher is a small answer. `timeoutInterval` limits
    /// the time without data, so a slow answer that keeps arriving is not cut off.
    nonisolated static let revisionRefreshTimeout: TimeInterval = 10

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Configuration

    func setBaseURL(_ url: URL) {
        baseURL = url
    }

    func setAccessToken(_ token: String) {
        accessToken = token
    }

    func clearAccessToken() {
        accessToken = nil
    }

    // MARK: - preLogin

    /// Fetches the account's KDF settings from `POST {base}/identity/accounts/prelogin/password`,
    /// the route the official clients and the Bitwarden SDK use (Vaultwarden 1.36.0+, Bitwarden
    /// server v2025.12.0+). Older servers answer 404 or 405 there; they get the same request on
    /// `LegacyPreloginEndpoint`. Any other failure is thrown as is.
    func preLogin(email: String) async throws -> PreLoginResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        do {
            return try await sendPreLogin(email: email, to: base.appendingPathComponent("identity/accounts/prelogin/password"),
                                          expectedFailures: [404, 405])
        } catch where LegacyPreloginEndpoint.isFallback(for: error) {
            logger.info("preLogin: the server has no prelogin/password route; using the legacy prelogin route")
            return try await sendPreLogin(email: email, to: base.appendingPathComponent(LegacyPreloginEndpoint.path))
        }
    }

    /// - Parameter expectedFailures: statuses that are logged at `.info`, not `.error`: on the
    ///   primary route, 404 and 405 only mean the server predates it.
    private func sendPreLogin(email: String, to url: URL, expectedFailures: Set<Int> = []) async throws -> PreLoginResponse {
        if DebugConfig.isEnabled {
            logger.debug("[debug] preLogin → POST \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = try JSONEncoder().encode(["email": email])
        request.httpBody = body

        let response: PreLoginResponse = try await perform(request: request, expectedFailures: expectedFailures)
        if DebugConfig.isEnabled {
            // KDF values and the salt stay out of the log (fix-kdf-derivation-and-validation, 6.2).
            logger.debug("[debug] preLogin ← settings=\(response.kdfParams != nil, privacy: .public) salt=\(response.salt != nil, privacy: .public)")
        }
        return response
    }

    // MARK: - identityToken

    /// The token request parameters that may appear in a debug log: an allow-list, so a parameter
    /// added later is not logged by default. Never logged: `username` (the email), `password` (the
    /// server hash), `twoFactorToken`, `deviceIdentifier` (harden-key-lifecycle-and-logging, D4).
    nonisolated static let loggableTokenParams: Set<String> = [
        "grant_type", "scope", "client_id", "deviceType", "deviceName", "twoFactorProvider", "twoFactorRemember",
    ]

    /// The token request parameters as one debug-log line, with only the allow-listed ones.
    nonisolated static func debugDescription(ofTokenParams params: [String: String]) -> String {
        params.filter { loggableTokenParams.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " | ")
    }

    func identityToken(
        email:             String,
        passwordHash:      String,
        deviceIdentifier:  String,
        twoFactorToken:    String?,
        twoFactorProvider: Int?,
        twoFactorRemember: Bool
    ) async throws -> TokenResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("identity/connect/token")

        if DebugConfig.isEnabled {
            let isTOTP = twoFactorToken != nil
            logger.debug("[debug] identityToken → POST \(url.absoluteString, privacy: .public) 2FA=\(isTOTP, privacy: .public) provider=\(twoFactorProvider.map(String.init) ?? "nil", privacy: .public)")
        }

        var params: [String: String] = [
            "grant_type":      "password",
            "username":        email,
            "password":        passwordHash,
            "scope":           "api offline_access",
            "client_id":       ClientHeaders.clientId,
            "deviceType":      ClientHeaders.deviceType,
            "deviceIdentifier": deviceIdentifier,
            // Deliberately not "macos" as the official desktop app sends: the device name shows in
            // the web vault's device list and the new-device email, and "Prizm" tells this app apart
            // from the official one on the same Mac (client-identification-headers, D4).
            "deviceName":      "Prizm",
        ]
        if let token    = twoFactorToken    { params["twoFactorToken"]    = token }
        if let provider = twoFactorProvider { params["twoFactorProvider"] = String(provider) }
        if twoFactorRemember                { params["twoFactorRemember"] = "true" }

        if DebugConfig.isEnabled {
            logger.debug("[debug] identityToken params: \(Self.debugDescription(ofTokenParams: params), privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formEncoded(params)

        return try await performIdentityToken(request: request)
    }

    /// Specialized perform for the identity token endpoint.
    ///
    /// The Bitwarden identity service overloads HTTP 400 for three distinct outcomes —
    /// disambiguation requires inspecting the response body:
    ///   1. 2FA challenge (occurs on first password attempt when 2FA is enabled):
    ///      body contains `"TwoFactorProviders2"` key → throw `.twoFactorRequired`
    ///   2. Bad TOTP code (occurs on the second request when the code is wrong):
    ///      `error_description` contains "Two-factor" → throw `.twoFactorCodeInvalid`
    ///   3. Wrong password (no 2FA in play, or bad credentials at any step):
    ///      generic `invalid_grant` body → throw `.invalidCredentials`
    /// Cases 2 and 3 use the same fallthrough path because they produce the same
    /// user-facing error: re-enter your password / code.
    private func performIdentityToken(request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(statusCode: 0, body: "")
        }

        logger.debug("[\(http.statusCode)] \(request.httpMethod ?? "?") \(request.url?.path ?? "")")

        if http.statusCode == 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if DebugConfig.isEnabled {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ", ")
                    logger.debug("[debug] identityToken 400 body keys: [\(keys, privacy: .public)]")
                    // Server-generated text can echo the email or other input: private.
                    if let errorDesc = json["error_description"] as? String {
                        logger.debug("[debug] identityToken 400 error_description: \(errorDesc, privacy: .private)")
                    }
                    if let msg = json["message"] as? String {
                        logger.debug("[debug] identityToken 400 message: \(msg, privacy: .private)")
                    }
                    if let errorModel = json["errorModel"] as? [String: Any],
                       let errMsg = errorModel["message"] as? String {
                        logger.debug("[debug] identityToken 400 errorModel.message: \(errMsg, privacy: .private)")
                    }
                } else {
                    logger.debug("[debug] identityToken 400 body (non-JSON): \(body.prefix(200), privacy: .private)")
                }
            }
            // Parse the error body to determine the specific error type.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 2FA challenge: server returns TwoFactorProviders2 dict with available providers.
                if let providers2 = json["TwoFactorProviders2"] as? [String: Any] {
                    let providerTypes = providers2.keys.compactMap { Int($0) }
                    if DebugConfig.isEnabled {
                        logger.debug("[debug] identityToken → 2FA required, providers: \(providerTypes, privacy: .public)")
                    }
                    throw IdentityTokenError.twoFactorRequired(providers: providerTypes)
                }
                // Invalid TOTP code or wrong password.
                if let errorDesc = json["error_description"] as? String {
                    if errorDesc.contains("Two-factor") || errorDesc.contains("two factor") {
                        if DebugConfig.isEnabled {
                            logger.debug("[debug] identityToken → 2FA code invalid (error_description match)")
                        }
                        throw IdentityTokenError.twoFactorCodeInvalid
                    }
                }
            }
            // Generic invalid_grant (wrong email/password).
            if DebugConfig.isEnabled {
                logger.debug("[debug] identityToken → invalidCredentials (generic 400)")
            }
            throw IdentityTokenError.invalidCredentials
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("HTTP \(http.statusCode) for \(request.url?.path ?? "unknown")")
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }

        do {
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            if DebugConfig.isEnabled {
                // Log which fields are present — never log token values.
                let hasKey         = tokenResponse.key != nil
                let hasKdf         = tokenResponse.kdfSettings != nil
                let hasUserId      = tokenResponse.userId != nil
                let hasEmail       = tokenResponse.email != nil
                let has2FA         = tokenResponse.twoFactorProviders != nil
                logger.debug("[debug] identityToken ← key=\(hasKey, privacy: .public) kdf=\(hasKdf, privacy: .public) userId=\(hasUserId, privacy: .public) email=\(hasEmail, privacy: .public) 2fa=\(has2FA, privacy: .public)")
            }
            return tokenResponse
        } catch {
            logger.error("Decoding failed for TokenResponse: \(error.localizedDescription)")
            if DebugConfig.isEnabled {
                // Keys only: a truncated token response would start with the access token.
                let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.sorted().joined(separator: ", ")
                logger.debug("[debug] TokenResponse body keys: \(keys ?? "(non-JSON, \(data.count) bytes)", privacy: .public)")
            }
            throw APIError.decodingFailed
        }
    }

    // MARK: - fetchSync

    func fetchSync() async throws -> SyncResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        var components   = URLComponents(url: base.appendingPathComponent("api/sync"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "excludeDomains", value: "true")]
        let url          = components.url!

        if DebugConfig.isEnabled {
            logger.debug("[debug] fetchSync → GET \(url.absoluteString, privacy: .public) hasToken=\(self.accessToken != nil, privacy: .public)")
        }

        var request      = baseRequest(url: url)
        request.httpMethod = "GET"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let response: SyncResponse = try await perform(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] fetchSync ← ciphers=\(response.ciphers.count, privacy: .public) folders=\(response.folders.count, privacy: .public) profileEmail=\(response.profile.email, privacy: .private) hasPrivateKey=\(response.profile.privateKey != nil, privacy: .public)")
        }
        return response
    }

    // MARK: - updateCipher

    func updateCipher(id: String, cipher: RawCipher) async throws -> RawCipher {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/\(id)")

        if DebugConfig.isEnabled {
            logger.debug("[debug] updateCipher → PUT \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Encode the re-encrypted RawCipher as the request body.
        // Field values are already EncStrings — no plaintext leaves the device.
        request.httpBody = try JSONEncoder().encode(cipher)

        let updated: RawCipher = try await perform(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] updateCipher ← id=\(updated.id, privacy: .public)")
        }
        return updated
    }

    // MARK: - getCipher

    func getCipher(id: String) async throws -> RawCipher {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/\(id)")

        if DebugConfig.isEnabled {
            logger.debug("[debug] getCipher → GET \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.revisionRefreshTimeout
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let cipher: RawCipher = try await perform(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] getCipher ← id=\(cipher.id, privacy: .public)")
        }
        return cipher
    }

    // MARK: - updateCipherCollections

    func updateCipherCollections(id: String, collectionIds: [String]) async throws -> CipherCollectionsResult {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        do {
            let request = try collectionsRequest(url: base.appendingPathComponent("api/ciphers/\(id)/collections_v2"),
                                                 collectionIds: collectionIds)
            let answer: OptionalCipherDetailsResponse? = try await performOptional(request: request)
            return CipherCollectionsResult(unavailable: answer?.unavailable ?? false, cipher: answer?.cipher)
        } catch where LegacyCipherCollectionsEndpoint.isFallback(for: error) {
            logger.info("updateCipherCollections: the server has no collections_v2 route; using the legacy route")
            let request = try collectionsRequest(url: base.appendingPathComponent(LegacyCipherCollectionsEndpoint.path(id: id)),
                                                 collectionIds: collectionIds)
            let cipher: RawCipher? = try await performOptional(request: request)
            return CipherCollectionsResult(unavailable: false, cipher: cipher)
        }
    }

    private func collectionsRequest(url: URL, collectionIds: [String]) throws -> URLRequest {
        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["collectionIds": collectionIds])
        return request
    }

    // MARK: - softDeleteCipher

    func softDeleteCipher(id: String) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        // PUT /api/ciphers/{id}/delete — soft-delete (moves to Trash, sets deletedDate).
        // Do NOT use DELETE /api/ciphers/{id} here; that endpoint permanently removes the cipher.
        let url = base.appendingPathComponent("api/ciphers/\(id)/delete")

        if DebugConfig.isEnabled {
            logger.debug("[debug] softDeleteCipher → PUT \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        try await performEmpty(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] softDeleteCipher ← ok id=\(id, privacy: .public)")
        }
    }

    // MARK: - permanentDeleteCipher

    func permanentDeleteCipher(id: String) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/\(id)")

        if DebugConfig.isEnabled {
            logger.debug("[debug] permanentDeleteCipher → DELETE \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "DELETE"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        try await performEmpty(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] permanentDeleteCipher ← ok id=\(id, privacy: .public)")
        }
    }

    func permanentDeleteCiphers(ids: [String]) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers")
        var request = baseRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["ids": ids])
        try await performEmpty(request: request)
    }

    // MARK: - restoreCipher

    func restoreCipher(id: String) async throws -> RawCipher? {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/\(id)/restore")

        if DebugConfig.isEnabled {
            logger.debug("[debug] restoreCipher → PUT \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // No body — the server identifies the cipher by URL path only.
        // Sending Content-Type: application/json with a body causes Vaultwarden to return 400.

        let restored: RawCipher? = try await performOptional(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] restoreCipher ← ok id=\(id, privacy: .public) cipher=\(restored != nil, privacy: .public)")
        }
        return restored
    }

    // MARK: - createAttachmentMetadata

    func createAttachmentMetadata(cipherId: String, body: AttachmentMetadataRequest) async throws -> AttachmentMetadataResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers").appendingPathComponent(cipherId).appendingPathComponent("attachment/v2")
        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request: request)
    }

    // MARK: - uploadAttachmentBitwardenHosted

    func uploadAttachmentBitwardenHosted(cipherId: String, attachmentId: String, encryptedBlob: Data) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers").appendingPathComponent(cipherId).appendingPathComponent("attachment").appendingPathComponent(attachmentId)

        // Multipart/form-data with a single `data` field containing the encrypted blob.
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"data\"; filename=\"attachment\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(encryptedBlob)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        try await performEmpty(request: request)
    }

    // MARK: - uploadAttachmentAzure

    func uploadAttachmentAzure(signedURL: URL, encryptedBlob: Data) async throws {
        // Azure Blob Storage requires `x-ms-blob-type: BlockBlob` on PUT uploads.
        // Reference: https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = encryptedBlob
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: code, body: "Azure upload failed")
        }
    }

    // MARK: - fetchAttachmentDownloadURL

    func fetchAttachmentDownloadURL(cipherId: String, attachmentId: String) async throws -> AttachmentDownloadResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers").appendingPathComponent(cipherId).appendingPathComponent("attachment").appendingPathComponent(attachmentId)
        var request = baseRequest(url: url)
        request.httpMethod = "GET"
        if let token = accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await perform(request: request)
    }

    // MARK: - deleteAttachment

    func deleteAttachment(cipherId: String, attachmentId: String) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers").appendingPathComponent(cipherId).appendingPathComponent("attachment").appendingPathComponent(attachmentId)
        var request = baseRequest(url: url)
        request.httpMethod = "DELETE"
        if let token = accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        try await performEmpty(request: request)
    }


    // MARK: - downloadBlob

    func downloadBlob(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(statusCode: 0, body: "Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode, body: "")
        }
        return data
    }

    // MARK: - refreshAccessToken

    // MARK: - createCipher

    func createCipher(cipher: RawCipher) async throws -> RawCipher {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers")

        if DebugConfig.isEnabled {
            logger.debug("[debug] createCipher → POST \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(cipher)

        let created: RawCipher = try await perform(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] createCipher ← id=\(created.id, privacy: .public)")
        }
        return created
    }

    // MARK: - createOrgCipher

    /// Wrapper body for `POST /api/ciphers/create` — Bitwarden expects `{ "cipher": ..., "collectionIds": [...] }`.
    private struct OrgCipherCreateRequest: Encodable {
        let cipher: RawCipher
        let collectionIds: [String]
    }

    func createOrgCipher(cipher: RawCipher) async throws -> RawCipher {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/create")

        if DebugConfig.isEnabled {
            logger.debug("[debug] createOrgCipher → POST \(url.absoluteString, privacy: .public)")
        }

        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body = OrgCipherCreateRequest(cipher: cipher, collectionIds: cipher.collectionIds)
        request.httpBody = try JSONEncoder().encode(body)

        let created: RawCipher = try await perform(request: request)
        if DebugConfig.isEnabled {
            logger.debug("[debug] createOrgCipher ← id=\(created.id, privacy: .public)")
        }
        return created
    }

    // MARK: - Folder CRUD

    func createFolder(encryptedName: String) async throws -> RawFolder {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/folders")
        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["name": encryptedName])
        return try await perform(request: request)
    }

    func updateFolder(id: String, encryptedName: String) async throws -> RawFolder {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/folders/\(id)")
        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["name": encryptedName])
        return try await perform(request: request)
    }

    func deleteFolder(id: String) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/folders/\(id)")
        var request = baseRequest(url: url)
        request.httpMethod = "DELETE"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        try await performEmpty(request: request)
    }

    // MARK: - Collection CRUD

    /// The body carries the full access list (`CollectionWriteRequest`): both servers replace the
    /// collection's members and groups with it (fix-collection-access-on-rename).
    func createCollection(organizationId: String, request body: CollectionWriteRequest) async throws -> RawCollection {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/organizations/\(organizationId)/collections")
        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request: request)
    }

    func getCollectionAccessDetails(organizationId: String, id: String) async throws -> CollectionAccessDetailsResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/organizations/\(organizationId)/collections/\(id)/details")
        var request = baseRequest(url: url)
        request.httpMethod = "GET"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request: request)
    }

    /// See `createCollection`: the body must carry the access list read from the server, or the
    /// rename removes everyone's access.
    func renameCollection(id: String, organizationId: String, request body: CollectionWriteRequest) async throws -> RawCollection {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/organizations/\(organizationId)/collections/\(id)")
        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request: request)
    }

    func deleteCollection(id: String, organizationId: String) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/organizations/\(organizationId)/collections/\(id)")
        var request = baseRequest(url: url)
        request.httpMethod = "DELETE"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        try await performEmpty(request: request)
    }

    // MARK: - Cipher partial / move

    func updateCipherPartial(id: String, folderId: String?, favorite: Bool) async throws -> PartialCipherResponse {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/\(id)/partial")
        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["favorite": favorite]
        body["folderId"] = folderId as Any
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request: request)
    }

    func moveCiphersToFolder(ids: [String], folderId: String?) async throws {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("api/ciphers/move")
        var request = baseRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["ids": ids]
        if let folderId { body["folderId"] = folderId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await performEmpty(request: request)
    }

    func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?) {
        guard let base = baseURL else { throw APIError.baseURLNotSet }
        let url = base.appendingPathComponent("identity/connect/token")

        if DebugConfig.isEnabled {
            logger.debug("[debug] refreshAccessToken → POST \(url.absoluteString, privacy: .public)")
        }

        let params: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     ClientHeaders.clientId,
        ]

        var request = baseRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(params)

        let tokenResponse: TokenResponse = try await perform(request: request)
        accessToken = tokenResponse.accessToken

        if DebugConfig.isEnabled {
            logger.debug("[debug] refreshAccessToken ← new token obtained")
        }
        return (tokenResponse.accessToken, tokenResponse.refreshToken)
    }

    // MARK: - Private helpers

    /// Builds a `URLRequest` pre-loaded with mandatory Bitwarden client identification headers.
    private func baseRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        // Identification is for the configured server only; blob storage, signed download URLs and
        // favicons use plain requests (client-identification-headers, D5).
        assert(baseURL == nil || url.host == baseURL?.host, "baseRequest is only for the configured server")
        req.setValue(ClientHeaders.userAgent,     forHTTPHeaderField: "User-Agent")
        req.setValue("application/json",          forHTTPHeaderField: "Accept")
        req.setValue(ClientHeaders.deviceType,    forHTTPHeaderField: "Device-Type")
        req.setValue(ClientHeaders.clientId,      forHTTPHeaderField: "Bitwarden-Client-Name")
        req.setValue(ClientHeaders.clientVersion, forHTTPHeaderField: "Bitwarden-Client-Version")
        return req
    }

    /// Sends `request`, checks the HTTP status code, and decodes the JSON response body.
    ///
    /// - Throws: `APIError.httpError` on non-2xx status codes; `APIError.decodingFailed` on JSON errors.
    /// - Parameter expectedFailures: non-2xx statuses the caller handles; logged at `.info`.
    private func perform<T: Decodable>(request: URLRequest, expectedFailures: Set<Int> = []) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(statusCode: 0, body: "")
        }

        logger.debug("[\(http.statusCode)] \(request.httpMethod ?? "?") \(request.url?.path ?? "")")
        if DebugConfig.isEnabled {
            logger.debug("[debug] perform [\(http.statusCode)] \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "", privacy: .public) responseBytes=\(data.count, privacy: .public)")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Scrub: do not log response body (may contain tokens or error details with PII).
            if expectedFailures.contains(http.statusCode) {
                logger.info("HTTP \(http.statusCode) for \(request.url?.path ?? "unknown") (handled by the caller)")
            } else {
                logger.error("HTTP \(http.statusCode) for \(request.url?.path ?? "unknown")")
            }
            if DebugConfig.isEnabled {
                // Log only top-level JSON keys on error, never values.
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ", ")
                    logger.debug("[debug] error body keys: [\(keys, privacy: .public)]")
                } else {
                    logger.debug("[debug] error body (non-JSON, \(data.count, privacy: .public) bytes)")
                }
            }
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if DebugConfig.isEnabled {
                logger.debug("[debug] decoded \(T.self, privacy: .public) OK")
            }
            return decoded
        } catch {
            logger.error("Decoding failed for \(T.self): \(error.localizedDescription)")
            if DebugConfig.isEnabled {
                logger.debug("[debug] decode error detail: \(error, privacy: .private)")
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ", ")
                    logger.debug("[debug] response body keys: [\(keys, privacy: .public)]")
                } else {
                    let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
                    logger.debug("[debug] response body snippet: \(snippet, privacy: .private)")
                }
            }
            throw APIError.decodingFailed
        }
    }

    /// Sends `request` and checks the HTTP status code, discarding the response body.
    ///
    /// Used for endpoints that return 200/204 with no meaningful response body
    /// (soft-delete, restore, permanent delete). Throws `APIError.httpError` on non-2xx responses.
    private func performEmpty(request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(statusCode: 0, body: "")
        }

        logger.debug("[\(http.statusCode)] \(request.httpMethod ?? "?") \(request.url?.path ?? "")")

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("HTTP \(http.statusCode) for \(request.url?.path ?? "unknown")")
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    /// Sends `request`, checks the HTTP status code, and decodes the body if it holds a `T`.
    ///
    /// For an endpoint whose success does not depend on its answer (restore and the collection
    /// update: Vaultwarden 1.37.4 answers with the cipher, tested, and the official server
    /// source-reviewed, but the operation is done either way). A non-2xx status throws
    /// `APIError.httpError` exactly as `performEmpty` does; a 2xx with an empty or undecodable body
    /// returns nil. Only the path is logged, never the body.
    private func performOptional<T: Decodable>(request: URLRequest) async throws -> T? {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(statusCode: 0, body: "")
        }

        logger.debug("[\(http.statusCode)] \(request.httpMethod ?? "?") \(request.url?.path ?? "")")

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("HTTP \(http.statusCode) for \(request.url?.path ?? "unknown")")
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }

        guard !data.isEmpty, let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            logger.info("No usable \(T.self) in the answer for \(request.url?.path ?? "unknown")")
            return nil
        }
        return decoded
    }

    /// Character set safe for `application/x-www-form-urlencoded` values.
    ///
    /// Must be RFC 3986 unreserved characters only: `A-Z a-z 0-9 - _ . ~`
    /// `.urlQueryAllowed` is intentionally NOT used here because it permits `+`, `=`, and `&`,
    /// which are field separators in form encoding.  In particular, a `+` in a value is decoded
    /// as a space by all HTTP servers — this would silently corrupt a base64 password hash that
    /// contains `+` or ends with `=` padding.
    private static let formValueAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    /// Encodes a `[String: String]` dictionary as `application/x-www-form-urlencoded` data.
    private func formEncoded(_ params: [String: String]) -> Data {
        params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: Self.formValueAllowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: Self.formValueAllowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}
