import XCTest
@testable import Prizm

/// The attachment requests and answers at the HTTP level (openspec change
/// `fix-attachment-transfer-flow`, D5 and D6): what `PrizmAPIClientImpl` sends and how it reads the
/// servers' answers, including the empty answer of older servers.
final class AttachmentTransferWireTests: XCTestCase {

    private var client: PrizmAPIClientImpl!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token-1")
    }

    private static let item = #"{"id":"c1","type":2,"name":"2.x|y|z","favorite":false,"revisionDate":"2026-10-30T10:00:00.000Z"}"#

    // MARK: - D6 Multipart file name

    func testDirectUpload_namesThePartWithTheEncryptedFileName() async throws {
        StubURLProtocol.responder = { _ in .status(200) }

        try await client.uploadAttachmentBitwardenHosted(cipherId: "c1", attachmentId: "a1",
                                                         encryptedFileName: "2.iv|ct|mac",
                                                         encryptedBlob: Data([1, 2, 3]))

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.path, "/api/ciphers/c1/attachment/a1")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains(#"Content-Disposition: form-data; name="data"; filename="2.iv|ct|mac""#), body)
    }

    // MARK: - D5 Item in the answers

    func testV2Answer_carriesTheItem() async throws {
        StubURLProtocol.responder = { _ in
            .status(200, body: Data(#"{"attachmentId":"a1","url":"https://x","fileUploadType":0,"cipherResponse":\#(Self.item)}"#.utf8))
        }
        let body = AttachmentMetadataRequest(fileName: "2.f|f|f", key: "2.k|k|k", fileSize: 65, adminRequest: false)

        let answer = try await client.createAttachmentMetadata(cipherId: "c1", body: body)

        XCTAssertEqual(answer.attachmentId, "a1")
        XCTAssertEqual(answer.cipherResponse?.id, "c1")
    }

    func testDeleteAnswer_carriesTheItem() async throws {
        StubURLProtocol.responder = { _ in .status(200, body: Data(#"{"cipher":\#(Self.item)}"#.utf8)) }

        let answer = try await client.deleteAttachment(cipherId: "c1", attachmentId: "a1")

        XCTAssertEqual(answer?.id, "c1")
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "DELETE")
    }

    func testDeleteAnswer_empty200_isNoItem() async throws {
        StubURLProtocol.responder = { _ in .status(200) }

        let answer = try await client.deleteAttachment(cipherId: "c1", attachmentId: "a1")

        XCTAssertNil(answer, "Older servers answer with an empty body")
    }
}
