import Foundation
import XCTest

/// A `URLProtocol` that records every request and answers from a test-provided responder, so
/// `PrizmAPIClientImpl` can be tested at the HTTP level (paths, bodies, headers, status handling).
///
/// Use `StubURLProtocol.makeSession()` for the client under test. State is static, so tests that
/// use it call `reset()` in `setUp`; test classes run their tests one after another.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct RecordedRequest {
        let method: String?
        let url: URL?
        let headers: [String: String]
        let body: Data?
        /// The request's own idle time-out, in seconds.
        let timeoutInterval: TimeInterval

        /// The body decoded as a JSON object, or nil.
        var jsonBody: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    enum Response {
        case status(Int, body: Data = Data())
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responder: (URLRequest) -> Response = { _ in .status(500) }
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []

    /// Decides the answer for each request.
    static var responder: (URLRequest) -> Response {
        get { lock.withLock { _responder } }
        set { lock.withLock { _responder = newValue } }
    }

    /// Every request sent so far, in order.
    static var requests: [RecordedRequest] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _requests = []
            _responder = { _ in .status(500) }
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(
            method: request.httpMethod,
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.readAll),
            timeoutInterval: request.timeoutInterval
        )
        Self.lock.withLock { Self._requests.append(recorded) }
        // Guard (fix-empty-trash, D5): POST /ciphers/purge deletes the user's whole vault. No test
        // may ever build a request to a purge path.
        if request.url?.path.hasSuffix("/purge") == true {
            XCTFail("Request to a purge path: \(request.httpMethod ?? "?") \(request.url?.path ?? "")")
        }

        switch Self.responder(request) {
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands the body to a protocol as a stream.
    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
