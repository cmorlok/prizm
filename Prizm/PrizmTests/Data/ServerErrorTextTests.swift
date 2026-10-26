import XCTest
@testable import Prizm

/// Failed requests show the server's message, and public logs never get a body or message
/// (openspec change server-error-texts).
final class ServerErrorTextTests: XCTestCase {

    private func text(_ status: Int, _ body: String) -> String? {
        APIError.httpError(statusCode: status, body: body).errorDescription
    }

    // MARK: - 1.1 Messages (D1)

    func testVaultwardenFullError_showsTheMessage() {
        // Shape of Vaultwarden 1.37.4 `ApiErrorResponse` (src/error.rs).
        let body = #"{"message":"Folder name too long","validationErrors":{"":["Folder name too long"]},"errorModel":{"message":"Folder name too long","object":"error"},"error":"","error_description":"","exceptionMessage":null,"exceptionStackTrace":null,"innerExceptionMessage":null,"object":"error"}"#
        XCTAssertEqual(text(400, body), "Folder name too long")
    }

    func testVaultwardenCompactError_showsTheMessage() {
        XCTAssertEqual(text(404, #"{"message":"Cipher doesn't exist","validationErrors":null,"object":"error"}"#),
                       "Cipher doesn't exist")
    }

    func testBitwardenPascalCaseValidationError_firstValidationErrorWins() {
        let body = #"{"Message":"The model state is invalid.","ValidationErrors":{"Name":["The field Name must be a string with a maximum length of 1000."]},"Object":"error"}"#
        XCTAssertEqual(text(400, body), "The field Name must be a string with a maximum length of 1000.")
    }

    func testIdentityError_usesTheErrorModel() {
        let body = #"{"error":"invalid_grant","error_description":"invalid_username_or_password","ErrorModel":{"Message":"Username or password is incorrect. Try again.","Object":"error"}}"#
        XCTAssertEqual(text(400, body), "Username or password is incorrect. Try again.")
    }

    func testRateLimit_showsTheOfficialText() {
        XCTAssertEqual(text(429, #"{"message":"Too many requests"}"#), "Rate limit exceeded. Try again later.")
    }

    func testHTMLOrEmptyBody_showsOnlyTheStatus() {
        XCTAssertEqual(text(502, "<html><body><h1>502 Bad Gateway</h1>user@example.com</body></html>"),
                       "Server error 502.")
        XCTAssertEqual(text(500, ""), "Server error 500.")
        XCTAssertEqual(text(500, #"{"message":"  ","validationErrors":{"":[""]}}"#), "Server error 500.")
    }

    func testLongMessage_isCut() {
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(text(400, #"{"message":"\#(long)"}"#)?.count, APIError.maxMessageLength)
    }

    // MARK: - 2.1 Log descriptions (D2)

    private enum SampleError: Error {
        case first
        case carries(String)
    }

    func testDescribe_neverContainsBodyOrMessage() {
        let body = #"{"message":"user@example.com already exists"}"#
        XCTAssertEqual(ErrorLog.describe(APIError.httpError(statusCode: 400, body: body)), "HTTP 400")
        XCTAssertEqual(ErrorLog.describe(APIError.decodingFailed), "decodingFailed")
        XCTAssertEqual(ErrorLog.describe(URLError(.timedOut)), "URLError \(URLError.Code.timedOut.rawValue)")

        let carried = ErrorLog.describe(SampleError.carries("user@example.com"))
        XCTAssertFalse(carried.contains("user@example.com"), carried)
        XCTAssertTrue(carried.contains("SampleError"), carried)
        XCTAssertNotEqual(ErrorLog.describe(SampleError.first), carried, "The case is identifiable")
    }

    /// Actors log too (`SyncRepositoryImpl`, `PrizmCryptoServiceImpl`): the conformance must not be
    /// isolated to the main actor, or the status would be lost there.
    func testDescribe_offTheMainActor_keepsTheStatus() async {
        let described = await Task.detached {
            ErrorLog.describe(APIError.httpError(statusCode: 500, body: "x"))
        }.value
        XCTAssertEqual(described, "HTTP 500")
    }

    func testDescribe_keychainErrorKeepsTheStatus() {
        XCTAssertEqual(ErrorLog.describe(KeychainError.unexpectedStatus(-25300)), "KeychainError.unexpectedStatus(-25300)")
    }

    func testDescribe_decodingErrorHasNoValues() {
        struct Payload: Decodable { let email: Int }
        do {
            _ = try JSONDecoder().decode(Payload.self, from: Data(#"{"email":"user@example.com"}"#.utf8))
            XCTFail("Expected a decoding error")
        } catch {
            let described = ErrorLog.describe(error)
            XCTAssertFalse(described.contains("user@example.com"), described)
            XCTAssertFalse(described.contains("email"), described)
        }
    }
}
