import Foundation
@testable import Prizm

/// Test double for `PrizmAPIClientProtocol`.
///
/// Configure stubs before calling the SUT; inspect recorded calls after.
actor MockPrizmAPIClient: PrizmAPIClientProtocol {

    // MARK: - Configuration state
    // nonisolated(unsafe) allows tests to read/write without await — safe in single-threaded tests.

    nonisolated(unsafe) var baseURL: URL?
    nonisolated(unsafe) var storedAccessToken: String?

    // MARK: - Stubs: preLogin

    nonisolated(unsafe) var preLoginResponse: PreLoginResponse?
    nonisolated(unsafe) var preLoginShouldThrow: Error?
    /// The email of every prelogin request, in order.
    nonisolated(unsafe) var preLoginEmails: [String] = []

    // MARK: - Stubs: identityToken

    nonisolated(unsafe) var tokenResponse: TokenResponse?
    nonisolated(unsafe) var tokenShouldThrow: Error?
    nonisolated(unsafe) var tokenTwoFactorProviders: [Int]?
    /// The `username` (email) of every token request, in order.
    nonisolated(unsafe) var identityTokenEmails: [String] = []

    // MARK: - Stubs: fetchSync

    nonisolated(unsafe) var syncResponse: SyncResponse?
    nonisolated(unsafe) var syncShouldThrow: Error?
    nonisolated(unsafe) var syncDelay: TimeInterval = 0

    // MARK: - Stubs: refreshAccessToken

    nonisolated(unsafe) var refreshResponse: String?
    nonisolated(unsafe) var refreshShouldThrow: Error?

    // MARK: - Stubs: updateCipher

    nonisolated(unsafe) var updateCipherResponse: RawCipher?
    nonisolated(unsafe) var updateCipherShouldThrow: Error?
    nonisolated(unsafe) var updateCipherCallCount: Int = 0
    nonisolated(unsafe) var lastUpdatedCipherId: String?

    // MARK: - Call order

    /// Every write and refresh request in the order it started, for example
    /// `["delete c1", "GET c1", "PUT c1"]`. Entries: "PUT <id>" (updateCipher), "collections <id>",
    /// "GET <id>" (getCipher), "partial <id>", "delete <id>", "restore <id>" and "move".
    nonisolated(unsafe) var callLog: [String] = []

    // MARK: - Protocol conformance

    func setBaseURL(_ url: URL) {
        baseURL = url
    }

    func setAccessToken(_ token: String) {
        storedAccessToken = token
    }

    func clearAccessToken() {
        storedAccessToken = nil
    }

    func preLogin(email: String) async throws -> PreLoginResponse {
        preLoginEmails.append(email)
        if let err = preLoginShouldThrow { throw err }
        return preLoginResponse ?? PreLoginResponse(
            kdf: 0, kdfIterations: 600_000, kdfMemory: nil, kdfParallelism: nil
        )
    }

    /// Runs while the token request is "in flight", to let a test lock in exactly that moment.
    nonisolated(unsafe) var whileRequestingToken: (@MainActor () async -> Void)?

    func identityToken(
        email:             String,
        passwordHash:      String,
        deviceIdentifier:  String,
        twoFactorToken:    String?,
        twoFactorProvider: Int?,
        twoFactorRemember: Bool
    ) async throws -> TokenResponse {
        identityTokenEmails.append(email)
        await whileRequestingToken?()
        if let err = tokenShouldThrow { throw err }

        if let providers = tokenTwoFactorProviders, tokenResponse == nil {
            return TokenResponse(
                accessToken:        "",
                refreshToken:       nil,
                tokenType:          "Bearer",
                expiresIn:          0,
                key:                nil,
                privateKey:         nil,
                kdf:                nil,
                kdfIterations:      nil,
                kdfMemory:          nil,
                kdfParallelism:     nil,
                twoFactorToken:     nil,
                twoFactorProviders: providers,
                userId:             nil,
                email:              nil,
                name:               nil
            )
        }

        guard let resp = tokenResponse else {
            throw APIError.baseURLNotSet
        }
        return resp
    }

    /// Runs while the sync request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileFetchingSync: (@Sendable () async -> Void)?

    func fetchSync() async throws -> SyncResponse {
        await whileFetchingSync?()
        if syncDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(syncDelay * 1_000_000_000))
        }
        if let err = syncShouldThrow { throw err }
        return syncResponse ?? SyncResponse(
            profile: RawProfile(
                id: "pid", email: "test@example.com", name: nil,
                key: "2.k==", privateKey: nil
            ),
            ciphers: [],
            folders: []
        )
    }

    func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?) {
        if let err = refreshShouldThrow { throw err }
        let token = refreshResponse ?? "refreshed-access-token"
        storedAccessToken = token
        return (token, nil)
    }

    nonisolated(unsafe) var lastUpdatedCipher: RawCipher?

    /// Runs while an update request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileUpdatingCipher: (@Sendable () async -> Void)?

    func updateCipher(id: String, cipher: RawCipher) async throws -> RawCipher {
        callLog.append("PUT \(id)")
        updateCipherCallCount += 1
        lastUpdatedCipherId = id
        lastUpdatedCipher = cipher
        await whileUpdatingCipher?()
        if let err = updateCipherShouldThrow { throw err }
        return updateCipherResponse ?? cipher
    }

    // MARK: - Stubs: updateCipherCollections

    nonisolated(unsafe) var updateCipherCollectionsCallCount = 0
    nonisolated(unsafe) var lastUpdatedCipherCollections: (id: String, collectionIds: [String])?

    /// Runs while the collections request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileUpdatingCollections: (@Sendable () async -> Void)?

    /// The cipher the collections request answers with; nil is an answer without a decodable
    /// cipher (the default, which older tests rely on).
    nonisolated(unsafe) var updateCipherCollectionsResponse: RawCipher?
    nonisolated(unsafe) var updateCipherCollectionsShouldThrow: Error?
    /// The `unavailable` flag of the answer: the user lost access through the change.
    nonisolated(unsafe) var updateCipherCollectionsUnavailable = false

    func updateCipherCollections(id: String, collectionIds: [String]) async throws -> CipherCollectionsResult {
        callLog.append("collections \(id)")
        updateCipherCollectionsCallCount += 1
        lastUpdatedCipherCollections = (id, collectionIds)
        await whileUpdatingCollections?()
        if let err = updateCipherCollectionsShouldThrow { throw err }
        return CipherCollectionsResult(unavailable: updateCipherCollectionsUnavailable,
                                       cipher: updateCipherCollectionsResponse)
    }

    // MARK: - Stubs: createCipher

    nonisolated(unsafe) var createCipherResponse: RawCipher?
    nonisolated(unsafe) var createCipherShouldThrow: Error?
    nonisolated(unsafe) var createCipherCallCount: Int = 0
    /// The cipher the last `createCipher` was called with, recorded before any throw.
    nonisolated(unsafe) var lastCreatedCipher: RawCipher?
    /// Runs while a create request (personal or org) is "in flight", for example to lock the vault.
    nonisolated(unsafe) var whileCreatingCipher: (@Sendable () async -> Void)?

    func createCipher(cipher: RawCipher) async throws -> RawCipher {
        createCipherCallCount += 1
        lastCreatedCipher = cipher
        await whileCreatingCipher?()
        if let err = createCipherShouldThrow { throw err }
        return createCipherResponse ?? cipher
    }

    // MARK: - Stubs: createOrgCipher

    nonisolated(unsafe) var createOrgCipherResponse: RawCipher?
    nonisolated(unsafe) var createOrgCipherCallCount: Int = 0
    /// The cipher the last `createOrgCipher` was called with, recorded before any throw.
    nonisolated(unsafe) var lastCreatedOrgCipher: RawCipher?

    func createOrgCipher(cipher: RawCipher) async throws -> RawCipher {
        createOrgCipherCallCount += 1
        lastCreatedOrgCipher = cipher
        await whileCreatingCipher?()
        if let err = createCipherShouldThrow { throw err }
        return createOrgCipherResponse ?? cipher
    }

    // MARK: - Stubs: softDeleteCipher

    nonisolated(unsafe) var softDeleteShouldThrow: Error?
    nonisolated(unsafe) var softDeleteCallCount: Int = 0
    nonisolated(unsafe) var lastSoftDeletedId: String?
    /// Runs while the soft-delete request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileSoftDeletingCipher: (@Sendable () async -> Void)?

    func softDeleteCipher(id: String) async throws {
        callLog.append("delete \(id)")
        softDeleteCallCount += 1
        lastSoftDeletedId = id
        await whileSoftDeletingCipher?()
        if let err = softDeleteShouldThrow { throw err }
    }

    // MARK: - Stubs: permanentDeleteCipher

    nonisolated(unsafe) var permanentDeleteShouldThrow: Error?
    nonisolated(unsafe) var permanentDeleteCallCount: Int = 0
    nonisolated(unsafe) var lastPermanentDeletedId: String?
    /// Runs while the permanent-delete request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileDeletingCipher: (@Sendable () async -> Void)?

    func permanentDeleteCipher(id: String) async throws {
        permanentDeleteCallCount += 1
        lastPermanentDeletedId = id
        await whileDeletingCipher?()
        if let err = permanentDeleteShouldThrow { throw err }
    }

    // MARK: - Stubs: permanentDeleteCiphers (bulk)

    nonisolated(unsafe) var bulkDeleteCalls: [[String]] = []
    /// Throws on the call with this index (0-based), to simulate a failing chunk.
    nonisolated(unsafe) var bulkDeleteFailsOnCall: Int?
    /// Runs while a bulk delete request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileDeletingCiphers: (@Sendable () async -> Void)?

    func permanentDeleteCiphers(ids: [String]) async throws {
        bulkDeleteCalls.append(ids)
        await whileDeletingCiphers?()
        if bulkDeleteFailsOnCall == bulkDeleteCalls.count - 1 {
            throw APIError.httpError(statusCode: 400, body: "")
        }
    }

    // MARK: - Stubs: restoreCipher

    nonisolated(unsafe) var restoreShouldThrow: Error?
    nonisolated(unsafe) var restoreCallCount: Int = 0
    nonisolated(unsafe) var lastRestoredId: String?
    /// Runs while the restore request is "in flight", for example to lock the vault meanwhile.
    nonisolated(unsafe) var whileRestoringCipher: (@Sendable () async -> Void)?

    /// The cipher the restore answers with; nil is an answer without a decodable cipher.
    nonisolated(unsafe) var restoreCipherResponse: RawCipher?

    func restoreCipher(id: String) async throws -> RawCipher? {
        callLog.append("restore \(id)")
        restoreCallCount += 1
        lastRestoredId = id
        await whileRestoringCipher?()
        if let err = restoreShouldThrow { throw err }
        return restoreCipherResponse
    }

    // MARK: - Stubs: getCipher

    /// The answer per item id. An id without an entry throws, so a test that does not stub the
    /// refresh sees a failed refresh (logged, nothing changed) and needs no change.
    nonisolated(unsafe) var getCipherResponses: [String: RawCipher] = [:]
    nonisolated(unsafe) var getCipherShouldThrow: Error?
    /// The ids `getCipher` was called with, in order, recorded before any throw.
    nonisolated(unsafe) var getCipherCalls: [String] = []
    /// Runs while a GET is "in flight", for example to lock the vault or to hold the request.
    nonisolated(unsafe) var whileGettingCipher: (@Sendable () async -> Void)?
    /// The same, told which item is fetched, for a test that must hold or release one item's GET.
    nonisolated(unsafe) var whileGettingCipherById: (@Sendable (String) async -> Void)?

    func getCipher(id: String) async throws -> RawCipher {
        callLog.append("GET \(id)")
        getCipherCalls.append(id)
        await whileGettingCipherById?(id)
        await whileGettingCipher?()
        if let err = getCipherShouldThrow { throw err }
        guard let answer = getCipherResponses[id] else {
            throw APIError.httpError(statusCode: 404, body: "")
        }
        return answer
    }

    // MARK: - Stubs: attachment endpoints

    nonisolated(unsafe) var createAttachmentMetadataResponse: AttachmentMetadataResponse?
    nonisolated(unsafe) var createAttachmentMetadataShouldThrow: Error?
    nonisolated(unsafe) var createAttachmentMetadataCallCount: Int = 0
    nonisolated(unsafe) var lastAttachmentMetadataRequest: AttachmentMetadataRequest?

    func createAttachmentMetadata(cipherId: String, body: AttachmentMetadataRequest) async throws -> AttachmentMetadataResponse {
        createAttachmentMetadataCallCount += 1
        lastAttachmentMetadataRequest = body
        if let err = createAttachmentMetadataShouldThrow { throw err }
        return createAttachmentMetadataResponse ?? AttachmentMetadataResponse(
            attachmentId: "att-123",
            url: "https://cdn.example.com/upload-signed",
            fileUploadType: 0
        )
    }

    nonisolated(unsafe) var uploadBitwardenHostedShouldThrow: Error?
    nonisolated(unsafe) var uploadBitwardenHostedCallCount: Int = 0
    nonisolated(unsafe) var lastUploadedCipherId: String?
    nonisolated(unsafe) var lastUploadedAttachmentId: String?
    nonisolated(unsafe) var lastUploadedFileName: String?
    /// How long the upload takes; a cancelled caller ends it with `CancellationError`.
    nonisolated(unsafe) var uploadBitwardenHostedDelay: Duration?

    /// The encrypted file of the last direct upload, as sent.
    nonisolated(unsafe) var lastUploadedBlob: Data?

    func uploadAttachmentBitwardenHosted(cipherId: String, attachmentId: String, encryptedFileName: String,
                                         encryptedBlob: Data) async throws {
        uploadBitwardenHostedCallCount += 1
        lastUploadedCipherId = cipherId
        lastUploadedAttachmentId = attachmentId
        lastUploadedFileName = encryptedFileName
        // A copy: the repository zeroes its buffer after the upload.
        lastUploadedBlob = Data(Array(encryptedBlob))
        if let delay = uploadBitwardenHostedDelay { try await Task.sleep(for: delay) }
        if let err = uploadBitwardenHostedShouldThrow { throw err }
    }

    nonisolated(unsafe) var uploadAzureShouldThrow: Error?
    nonisolated(unsafe) var uploadAzureCallCount: Int = 0
    nonisolated(unsafe) var lastAzureSignedURL: URL?

    func uploadAttachmentAzure(signedURL: URL, encryptedBlob: Data) async throws {
        uploadAzureCallCount += 1
        lastAzureSignedURL = signedURL
        if let err = uploadAzureShouldThrow { throw err }
    }

    nonisolated(unsafe) var fetchAttachmentDownloadURLResponse: AttachmentDownloadResponse?
    nonisolated(unsafe) var fetchAttachmentDownloadURLShouldThrow: Error?
    nonisolated(unsafe) var fetchAttachmentDownloadURLCallCount: Int = 0

    func fetchAttachmentDownloadURL(cipherId: String, attachmentId: String) async throws -> AttachmentDownloadResponse {
        fetchAttachmentDownloadURLCallCount += 1
        if let err = fetchAttachmentDownloadURLShouldThrow { throw err }
        return fetchAttachmentDownloadURLResponse ?? AttachmentDownloadResponse(url: "https://cdn.example.com/download-signed")
    }

    nonisolated(unsafe) var deleteAttachmentShouldThrow: Error?
    nonisolated(unsafe) var deleteAttachmentCallCount: Int = 0
    nonisolated(unsafe) var lastDeletedAttachmentId: String?
    /// The item the delete answers with; nil is an empty answer (older servers).
    nonisolated(unsafe) var deleteAttachmentResponse: RawCipher?

    /// Whether the last delete ran in a cancelled task.
    nonisolated(unsafe) var deleteAttachmentSawCancellation: Bool?

    func deleteAttachment(cipherId: String, attachmentId: String) async throws -> RawCipher? {
        deleteAttachmentCallCount += 1
        lastDeletedAttachmentId = attachmentId
        deleteAttachmentSawCancellation = Task.isCancelled
        if let err = deleteAttachmentShouldThrow { throw err }
        return deleteAttachmentResponse
    }

    nonisolated(unsafe) var downloadBlobResult: Data = Data()
    nonisolated(unsafe) var downloadBlobShouldThrow: Error?
    nonisolated(unsafe) var downloadBlobCallCount: Int = 0

    /// Every URL a download was attempted from, in order.
    nonisolated(unsafe) var downloadedURLs: [URL] = []

    func downloadBlob(from url: URL) async throws -> Data {
        downloadBlobCallCount += 1
        downloadedURLs.append(url)
        if let err = downloadBlobShouldThrow { throw err }
        return downloadBlobResult
    }



    // MARK: - Stubs: Collection CRUD

    nonisolated(unsafe) var createCollectionResponse: RawCollection?
    nonisolated(unsafe) var createCollectionShouldThrow: Error?
    nonisolated(unsafe) var createCollectionCallCount: Int = 0
    nonisolated(unsafe) var lastCreateCollectionOrgId: String?
    nonisolated(unsafe) var lastCreateCollectionEncryptedName: String?

    /// Order of collection calls, e.g. ["details col-1", "rename col-1"].
    nonisolated(unsafe) var collectionCalls: [String] = []
    nonisolated(unsafe) var lastCollectionWriteRequest: CollectionWriteRequest?
    /// The access details answer; by default an empty access list.
    nonisolated(unsafe) var collectionAccessDetails: CollectionAccessDetailsResponse?
    nonisolated(unsafe) var collectionAccessDetailsError: Error?

    func getCollectionAccessDetails(organizationId: String, id: String) async throws -> CollectionAccessDetailsResponse {
        collectionCalls.append("details \(id)")
        if let err = collectionAccessDetailsError { throw err }
        return collectionAccessDetails ?? CollectionAccessDetailsResponse(
            id: id, organizationId: organizationId, name: "2.n|iv|mac", externalId: nil, users: [], groups: []
        )
    }

    func createCollection(organizationId: String, request: CollectionWriteRequest) async throws -> RawCollection {
        createCollectionCallCount += 1
        collectionCalls.append("create")
        lastCreateCollectionOrgId = organizationId
        lastCreateCollectionEncryptedName = request.name
        lastCollectionWriteRequest = request
        if let err = createCollectionShouldThrow { throw err }
        return createCollectionResponse ?? RawCollection(
            id: "col-\(UUID().uuidString.prefix(8))", organizationId: organizationId, name: request.name
        )
    }

    nonisolated(unsafe) var renameCollectionResponse: RawCollection?
    nonisolated(unsafe) var renameCollectionShouldThrow: Error?
    nonisolated(unsafe) var renameCollectionCallCount: Int = 0

    func renameCollection(id: String, organizationId: String, request: CollectionWriteRequest) async throws -> RawCollection {
        renameCollectionCallCount += 1
        collectionCalls.append("rename \(id)")
        lastCollectionWriteRequest = request
        if let err = renameCollectionShouldThrow { throw err }
        return renameCollectionResponse ?? RawCollection(
            id: id, organizationId: organizationId, name: request.name
        )
    }

    nonisolated(unsafe) var deleteCollectionShouldThrow: Error?
    nonisolated(unsafe) var deleteCollectionCallCount: Int = 0
    nonisolated(unsafe) var lastDeleteCollectionId: String?

    func deleteCollection(id: String, organizationId: String) async throws {
        deleteCollectionCallCount += 1
        lastDeleteCollectionId = id
        if let err = deleteCollectionShouldThrow { throw err }
    }

    // MARK: - Stubs: Folder CRUD

    nonisolated(unsafe) var createFolderResponse: RawFolder?
    nonisolated(unsafe) var createFolderShouldThrow: Error?

    func createFolder(encryptedName: String) async throws -> RawFolder {
        if let err = createFolderShouldThrow { throw err }
        return createFolderResponse ?? RawFolder(id: UUID().uuidString, name: encryptedName, revisionDate: nil)
    }

    nonisolated(unsafe) var updateFolderResponse: RawFolder?
    nonisolated(unsafe) var updateFolderShouldThrow: Error?

    func updateFolder(id: String, encryptedName: String) async throws -> RawFolder {
        if let err = updateFolderShouldThrow { throw err }
        return updateFolderResponse ?? RawFolder(id: id, name: encryptedName, revisionDate: nil)
    }

    nonisolated(unsafe) var deleteFolderShouldThrow: Error?

    func deleteFolder(id: String) async throws {
        if let err = deleteFolderShouldThrow { throw err }
    }

    // MARK: - Stubs: Cipher partial / move

    nonisolated(unsafe) var updateCipherPartialShouldThrow: Error?
    nonisolated(unsafe) var partialUpdates: [(id: String, folderId: String?, favorite: Bool)] = []
    /// The server's answer; by default it echoes the request, as a server that saved it does.
    nonisolated(unsafe) var partialUpdateResponse: PartialCipherResponse?
    /// Runs while the request is "in flight", to simulate a sync replacing the cache meanwhile.
    nonisolated(unsafe) var whilePartialUpdateInFlight: (@Sendable () async -> Void)?

    func updateCipherPartial(id: String, folderId: String?, favorite: Bool) async throws -> PartialCipherResponse {
        callLog.append("partial \(id)")
        if let err = updateCipherPartialShouldThrow { throw err }
        partialUpdates.append((id, folderId, favorite))
        await whilePartialUpdateInFlight?()
        return partialUpdateResponse ?? PartialCipherResponse(favorite: favorite, folderId: .some(folderId))
    }

    nonisolated(unsafe) var moveCiphersShouldThrow: Error?
    nonisolated(unsafe) var moveCalls: [(ids: [String], folderId: String?)] = []

    func moveCiphersToFolder(ids: [String], folderId: String?) async throws {
        callLog.append("move")
        if let err = moveCiphersShouldThrow { throw err }
        moveCalls.append((ids, folderId))
    }

}
