import XCTest
@testable import Prizm

/// Upload rollback, download URL handling, server messages and the item record from the server's
/// answers (openspec change `fix-attachment-transfer-flow`, design D1–D3, D5, D6).
@MainActor
final class AttachmentTransferFlowTests: XCTestCase {

    private var sut: AttachmentRepositoryImpl!
    private var api: MockPrizmAPIClient!
    private var vault: MockVaultRepository!
    private var applier: RecordingAttachmentRecordApplier!

    private let cipherKey = Data(repeating: 0xAB, count: 32) + Data(repeating: 0xCD, count: 32)
    private let cipherId = "cipher-abc"
    private let data = Data("file bytes".utf8)

    override func setUp() async throws {
        api = MockPrizmAPIClient()
        vault = MockVaultRepository()
        applier = RecordingAttachmentRecordApplier()
        sut = AttachmentRepositoryImpl(apiClient: api, crypto: PrizmCryptoServiceImpl(), vaultRepository: vault,
                                       recordApplier: applier)
        let item = VaultItem(id: cipherId, name: "Item", isFavorite: false, isDeleted: false,
                             creationDate: Date(), revisionDate: Date(),
                             content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
        await vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
    }

    private func upload() async throws -> Attachment {
        try await sut.upload(cipherId: cipherId, fileName: "doc.pdf", data: data, cipherKey: cipherKey)
    }

    private func record(id: String = "cipher-abc") throws -> RawCipher {
        try JSONDecoder().decode(RawCipher.self, from: Data(
            #"{"id":"\#(id)","type":2,"name":"2.x|y|z","favorite":false,"revisionDate":"2026-10-30T10:00:00.000Z"}"#.utf8))
    }

    // MARK: - D1 Rollback

    func testUploadFails_deletesTheNewRecord_andRethrows() async {
        api.uploadBitwardenHostedShouldThrow = URLError(.networkConnectionLost)
        do {
            _ = try await upload()
            XCTFail("The upload error must be reported")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "The original error")
        }
        XCTAssertEqual(api.deleteAttachmentCallCount, 1)
        XCTAssertEqual(api.lastDeletedAttachmentId, "att-123")
        XCTAssertEqual(vault.updateAttachmentsCallCount, 0, "Nothing is added locally")
    }

    /// The calling task is cancelled while the file upload runs; the rollback still goes out,
    /// uncancelled.
    func testUploadCancelled_stillDeletesTheNewRecord() async throws {
        api.uploadBitwardenHostedDelay = .seconds(10)
        let task = Task { try await upload() }
        while api.uploadBitwardenHostedCallCount == 0 { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("The cancellation must be reported")
        } catch {
            XCTAssertTrue(error is CancellationError, "Got \(error)")
        }
        XCTAssertEqual(api.deleteAttachmentCallCount, 1)
        XCTAssertEqual(api.deleteAttachmentSawCancellation, false, "The rollback runs in its own task")
    }

    /// Vaultwarden deletes the record itself on a size mismatch, so the rollback finds it gone.
    func testRollbackFindsTheRecordGone_reportsOnlyTheUploadError() async {
        for gone in [APIError.httpError(statusCode: 400, body: #"{"message":"Attachment doesn't exist","object":"error"}"#),
                     APIError.httpError(statusCode: 404, body: "")] {
            api.uploadBitwardenHostedShouldThrow = URLError(.networkConnectionLost)
            api.deleteAttachmentShouldThrow = gone
            do {
                _ = try await upload()
                XCTFail("The upload error must be reported")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "For \(gone): got \(error)")
            }
        }
    }

    func testRollbackFails_reportsTheRecordLeftBehind() async {
        api.uploadBitwardenHostedShouldThrow = URLError(.notConnectedToInternet)
        api.deleteAttachmentShouldThrow = URLError(.notConnectedToInternet)
        do {
            _ = try await upload()
            XCTFail("The failure must be reported")
        } catch AttachmentError.uploadFailedRecordLeft {
            // expected
        } catch {
            XCTFail("Expected uploadFailedRecordLeft, got \(error)")
        }
        XCTAssertEqual(AttachmentError.uploadFailedRecordLeft.errorDescription,
                       "Upload failed. A broken attachment entry may remain; delete it from the item.")
    }

    func testMetadataFails_sendsNoDelete() async {
        api.createAttachmentMetadataShouldThrow = URLError(.timedOut)
        _ = try? await upload()
        XCTAssertEqual(api.deleteAttachmentCallCount, 0)
        XCTAssertEqual(api.uploadBitwardenHostedCallCount, 0)
    }

    // MARK: - D3 Server messages

    func testMetadata400WithMessage_isServerRejected() async {
        api.createAttachmentMetadataShouldThrow = APIError.httpError(
            statusCode: 400, body: #"{"message":"You must have premium status to use attachments.","object":"error"}"#)
        do {
            _ = try await upload()
            XCTFail("The rejection must be reported")
        } catch let error as AttachmentError {
            XCTAssertEqual(error.errorDescription,
                           "The server rejected the upload: You must have premium status to use attachments.")
        } catch {
            XCTFail("Expected serverRejected, got \(error)")
        }
    }

    func testFileUpload400WithMessage_isServerRejected_afterTheRollback() async {
        api.uploadBitwardenHostedShouldThrow = APIError.httpError(
            statusCode: 400, body: #"{"message":"Attachment storage limit reached! Delete some attachments to free up space"}"#)
        do {
            _ = try await upload()
            XCTFail("The rejection must be reported")
        } catch AttachmentError.serverRejected(let message) {
            XCTAssertEqual(message, "Attachment storage limit reached! Delete some attachments to free up space")
        } catch {
            XCTFail("Expected serverRejected, got \(error)")
        }
        XCTAssertEqual(api.deleteAttachmentCallCount, 1, "Vaultwarden checks the limit after creating the record")
    }

    func test400WithoutJSON_staysAnHTTPError() async {
        api.createAttachmentMetadataShouldThrow = APIError.httpError(statusCode: 400, body: "<html>Bad Request</html>")
        do {
            _ = try await upload()
            XCTFail("The error must be reported")
        } catch {
            XCTAssertEqual(error as? APIError, .httpError(statusCode: 400, body: "<html>Bad Request</html>"))
        }
    }

    // MARK: - D6 Multipart file name

    func testDirectUpload_namesThePartWithTheEncryptedFileName() async throws {
        _ = try await upload()
        let sentName = try XCTUnwrap(api.lastUploadedFileName)
        XCTAssertEqual(sentName, api.lastAttachmentMetadataRequest?.fileName)
        XCTAssertTrue(sentName.hasPrefix("2."), "An EncString, never the plaintext name")
    }

    // MARK: - D5 Item record from the answers

    func testUpload_takesTheItemFromTheV2Answer() async throws {
        let cipher = try record()
        api.createAttachmentMetadataResponse = AttachmentMetadataResponse(
            attachmentId: "att-123", url: "https://x", fileUploadType: 0, cipherResponse: cipher)
        applier.result = true

        _ = try await upload()

        XCTAssertEqual(applier.applied.map(\.id), [cipherId])
        XCTAssertEqual(vault.updateAttachmentsCallCount, 0, "LegacyAttachmentListPatch is not used")
    }

    func testUpload_withoutItemInTheAnswer_patchesTheListLocally() async throws {
        _ = try await upload()

        XCTAssertTrue(applier.applied.isEmpty)
        XCTAssertEqual(vault.updateAttachmentsCallCount, 1)
        XCTAssertEqual(vault.lastUpdatedAttachments?.map(\.id), ["att-123"])
    }

    func testUpload_answerItemThatCannotBeApplied_fallsBackToTheLocalPatch() async throws {
        api.createAttachmentMetadataResponse = AttachmentMetadataResponse(
            attachmentId: "att-123", url: "https://x", fileUploadType: 0, cipherResponse: try record())
        applier.result = false

        _ = try await upload()

        XCTAssertEqual(vault.updateAttachmentsCallCount, 1)
    }

    func testDelete_takesTheItemFromTheAnswer() async throws {
        api.deleteAttachmentResponse = try record()
        applier.result = true

        try await sut.delete(cipherId: cipherId, attachmentId: "att-1")

        XCTAssertEqual(applier.applied.map(\.id), [cipherId])
        XCTAssertEqual(vault.updateAttachmentsCallCount, 0)
    }

    func testDelete_withEmptyAnswer_patchesTheListLocally() async throws {
        try await sut.delete(cipherId: cipherId, attachmentId: "att-1")

        XCTAssertTrue(applier.applied.isEmpty)
        XCTAssertEqual(vault.updateAttachmentsCallCount, 1)
    }

    func testDelete_answerForAnotherItem_isNotApplied() async throws {
        api.deleteAttachmentResponse = try record(id: "other")
        applier.result = true

        try await sut.delete(cipherId: cipherId, attachmentId: "att-1")

        XCTAssertTrue(applier.applied.isEmpty)
        XCTAssertEqual(vault.updateAttachmentsCallCount, 1)
    }

    // MARK: - D2 Fresh download URL

    private let attachment = Attachment(id: "att-1", fileName: "doc.pdf", encryptedKey: "2.k|k|k", size: 3,
                                        sizeName: "3 B", url: "https://sync.example.com/old")

    func testDownload_fetchesAFreshURLFirst_evenWithASyncURL() async {
        _ = try? await sut.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
        XCTAssertEqual(api.fetchAttachmentDownloadURLCallCount, 1)
        XCTAssertEqual(api.downloadedURLs, [URL(string: "https://cdn.example.com/download-signed")!])
    }

    func testDownload_freshURL404_usesTheSyncURL() async {
        api.fetchAttachmentDownloadURLShouldThrow = APIError.httpError(statusCode: 404, body: "")
        _ = try? await sut.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
        XCTAssertEqual(api.downloadedURLs, [URL(string: "https://sync.example.com/old")!])
    }

    func testDownload_blob404_isFileMissingOnServer_withoutRetry() async {
        api.downloadBlobShouldThrow = APIError.httpError(statusCode: 404, body: "")
        do {
            _ = try await sut.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
            XCTFail("A missing file must be reported")
        } catch AttachmentError.fileMissingOnServer {
            // expected
        } catch {
            XCTFail("Expected fileMissingOnServer, got \(error)")
        }
        XCTAssertEqual(api.downloadBlobCallCount, 1)
        XCTAssertEqual(api.fetchAttachmentDownloadURLCallCount, 1)
    }

    /// Vaultwarden answers 400 "Attachment doesn't exist" for a record deleted elsewhere (D2 step 5).
    func testDownload_freshURL400_isDownloadFailed() async {
        api.fetchAttachmentDownloadURLShouldThrow = APIError.httpError(
            statusCode: 400, body: #"{"message":"Attachment doesn't exist"}"#)
        do {
            _ = try await sut.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
            XCTFail("The failure must be reported")
        } catch AttachmentError.downloadFailed {
            // expected
        } catch {
            XCTFail("Expected downloadFailed, got \(error)")
        }
        XCTAssertEqual(api.downloadBlobCallCount, 0)
    }

    /// Offline or an unreadable answer on the URL request is a plain download failure (D2 step 5),
    /// not the system's error text.
    func testDownload_freshURLOffline_isDownloadFailed() async {
        api.fetchAttachmentDownloadURLShouldThrow = URLError(.notConnectedToInternet)
        do {
            _ = try await sut.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
            XCTFail("The failure must be reported")
        } catch AttachmentError.downloadFailed {
            // expected
        } catch {
            XCTFail("Expected downloadFailed, got \(error)")
        }
        XCTAssertEqual(api.downloadBlobCallCount, 0)
    }

    func testDownload_blob403_failsWithoutALoop() async {
        api.downloadBlobShouldThrow = APIError.httpError(statusCode: 403, body: "")
        do {
            _ = try await sut.download(cipherId: cipherId, attachment: attachment, cipherKey: cipherKey)
            XCTFail("The failure must be reported")
        } catch AttachmentError.downloadFailed {
            // expected
        } catch {
            XCTFail("Expected downloadFailed, got \(error)")
        }
        XCTAssertEqual(api.downloadBlobCallCount, 1)
        XCTAssertEqual(api.fetchAttachmentDownloadURLCallCount, 1)
    }
}

/// Records the records `AttachmentRepositoryImpl` hands over and answers with `result`.
final class RecordingAttachmentRecordApplier: AttachmentRecordApplying, @unchecked Sendable {
    var result = true
    private(set) var applied: [RawCipher] = []

    func applyAttachmentChange(record: RawCipher, for cipherId: String) async -> Bool {
        applied.append(record)
        return result
    }
}
