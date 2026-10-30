import XCTest
import AppKit
@testable import Prizm

/// fix-website-icons-privacy: where icon requests go (D1), the settings (D2), the memory-only cache
/// (D4) and the redirect check (D5). The stub fails the test for any request to a host it does not
/// expect, so "no request to another host" is checked on every test.
@MainActor
final class FaviconLoaderTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let base = URL(string: "https://vault.example.com/icons")!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "FaviconLoaderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        IconStub.reset()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        IconStub.reset()
        try await super.tearDown()
    }

    private func makeLoader() -> FaviconLoader {
        FaviconLoader(defaultsSuiteName: suiteName, protocolClasses: [IconStub.self])
    }

    private static let png: Data = {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    // MARK: - D1: the server's icons URL only

    func testConfigured_requestsTheServersIconURL_withoutCredentials() async throws {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()
        loader.configure(iconsBase: base)

        let image = await loader.favicon(for: "github.com")

        XCTAssertNotNil(image)
        let request = try XCTUnwrap(IconStub.requests.first)
        XCTAssertEqual(IconStub.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://vault.example.com/icons/github.com/icon.png")
        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["Cookie"])
        XCTAssertTrue(headers.keys.filter { $0.hasPrefix("Bitwarden-Client") }.isEmpty)
    }

    func testUnconfigured_sendsNothing() async {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()

        let image = await loader.favicon(for: "github.com")

        XCTAssertNil(image)
        XCTAssertTrue(IconStub.requests.isEmpty)
    }

    func testConfiguredWithNil_afterLock_sendsNothing() async {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()
        loader.configure(iconsBase: base)
        loader.configure(iconsBase: nil)
        await loader.reset()

        let image = await loader.favicon(for: "github.com")

        XCTAssertNil(image)
        XCTAssertTrue(IconStub.requests.isEmpty)
    }

    func testIconsOverride_isUsedAsGiven() async throws {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()
        loader.configure(iconsBase: URL(string: "https://icons.example.net")!)

        _ = await loader.favicon(for: "github.com")

        XCTAssertEqual(IconStub.requests.first?.url?.absoluteString, "https://icons.example.net/github.com/icon.png")
    }

    // MARK: - D2: settings

    func testSettingsDefaults() {
        XCTAssertTrue(WebsiteIconSettings.showsIcons(in: defaults))
        XCTAssertFalse(WebsiteIconSettings.allowsOtherServices(in: defaults))
        XCTAssertEqual(WebsiteIconSettings.showIconsKey, "icons.showWebsiteIcons")
        XCTAssertEqual(WebsiteIconSettings.allowOtherServicesKey, "icons.allowOtherServices")
    }

    func testIconsOff_sendsNothing_andEmptiesTheCache() async throws {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()
        loader.configure(iconsBase: base)
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 1)

        defaults.set(false, forKey: WebsiteIconSettings.showIconsKey)
        // The loader resets from a notification task; turning icons on again before it ran would
        // skip the reset (fix-favicon-test-race).
        let deadline = ContinuousClock.now + .seconds(2)
        while await loader.generation == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let resets = await loader.generation
        XCTAssertEqual(resets, 1, "the loader never reset after icons were turned off")
        let off = await loader.favicon(for: "github.com")
        XCTAssertNil(off)
        XCTAssertEqual(IconStub.requests.count, 1, "no request while icons are off")

        defaults.set(true, forKey: WebsiteIconSettings.showIconsKey)
        let on = await loader.favicon(for: "github.com")
        XCTAssertNotNil(on)
        XCTAssertEqual(IconStub.requests.count, 2, "the cache was emptied, so the icon is fetched again")
    }

    /// Code review 2026-10-30: the app never calls the loader while icons are off, so the loader
    /// itself must notice the switch and drop what it holds.
    func testTurningIconsOff_resetsTheLoader() async throws {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()
        loader.configure(iconsBase: base)
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 1)

        defaults.set(false, forKey: WebsiteIconSettings.showIconsKey)
        let deadline = ContinuousClock.now + .seconds(2)
        while await loader.generation == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let generation = await loader.generation
        XCTAssertEqual(generation, 1, "turning icons off resets the loader")

        defaults.set(true, forKey: WebsiteIconSettings.showIconsKey)
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 2, "the icon was not kept")
    }

    /// A request still running when icons are turned off does not fill the cache.
    func testRequestFinishingAfterIconsOff_isNotCached() async {
        IconStub.answer = { _ in .ok(Self.png) }
        IconStub.delay = 0.3
        let loader = makeLoader()
        loader.configure(iconsBase: base)
        let pending = Task { await loader.favicon(for: "github.com") }
        try? await Task.sleep(for: .milliseconds(100))
        defaults.set(false, forKey: WebsiteIconSettings.showIconsKey)
        let result = await pending.value
        XCTAssertNil(result)
        IconStub.delay = 0
        defaults.set(true, forKey: WebsiteIconSettings.showIconsKey)
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 2)
    }

    /// Rows of the same site ask at the same time after an unlock: one request per host.
    func testConcurrentRequestsForOneHost_sendOneRequest() async {
        IconStub.answer = { _ in .ok(Self.png) }
        IconStub.delay = 0.2
        let loader = makeLoader()
        loader.configure(iconsBase: base)
        async let a = loader.favicon(for: "github.com")
        async let b = loader.favicon(for: "github.com")
        async let c = loader.favicon(for: "github.com")
        let results = await [a, b, c]
        XCTAssertEqual(results.compactMap { $0 }.count, 3)
        XCTAssertEqual(IconStub.requests.count, 1)
    }

    // MARK: - D4: memory only

    func testSessionConfiguration_hasNoDiskCacheAndNoCookies() {
        let configuration = FaviconLoader.makeConfiguration(protocolClasses: [])
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testRepeatedRequest_comesFromTheMemoryCache() async {
        IconStub.answer = { _ in .ok(Self.png) }
        let loader = makeLoader()
        loader.configure(iconsBase: base)
        _ = await loader.favicon(for: "github.com")
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 1)

        await loader.reset()
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 2, "reset empties the cache")
    }

    func testResetDuringARequest_leavesTheCacheEmpty() async {
        IconStub.answer = { _ in .ok(Self.png) }
        IconStub.delay = 0.5
        let loader = makeLoader()
        loader.configure(iconsBase: base)

        let pending = Task { await loader.favicon(for: "github.com") }
        try? await Task.sleep(for: .milliseconds(150))
        await loader.reset()
        _ = await pending.value

        IconStub.delay = 0
        _ = await loader.favicon(for: "github.com")
        XCTAssertEqual(IconStub.requests.count, 2, "the icon of the request that outlived the reset was not cached")
    }

    // MARK: - D5: redirects

    func testRedirectToAnotherHost_isRefusedByDefault() async {
        IconStub.answer = { request in
            request.url?.host == "vault.example.com"
                ? .redirect("https://icons.bitwarden.net/github.com/icon.png")
                : .ok(Self.png)
        }
        let loader = makeLoader()
        loader.configure(iconsBase: base)

        let image = await loader.favicon(for: "github.com")

        XCTAssertNil(image)
        XCTAssertEqual(IconStub.requests.compactMap { $0.url?.host }, ["vault.example.com"])
    }

    func testRedirectToAnotherHost_isFollowedWhenAllowed() async {
        IconStub.answer = { request in
            request.url?.host == "vault.example.com"
                ? .redirect("https://icons.bitwarden.net/github.com/icon.png")
                : .ok(Self.png)
        }
        defaults.set(true, forKey: WebsiteIconSettings.allowOtherServicesKey)
        let loader = makeLoader()
        loader.configure(iconsBase: base)

        let image = await loader.favicon(for: "github.com")

        XCTAssertNotNil(image)
        XCTAssertEqual(IconStub.requests.compactMap { $0.url?.host }, ["vault.example.com", "icons.bitwarden.net"])
    }

    func testRedirectWithinTheServer_isFollowed() async {
        IconStub.answer = { request in
            request.url?.path == "/icons/github.com/icon.png"
                ? .redirect("https://vault.example.com/icons/cache/github.com.png")
                : .ok(Self.png)
        }
        let loader = makeLoader()
        loader.configure(iconsBase: base)

        let image = await loader.favicon(for: "github.com")

        XCTAssertNotNil(image)
        XCTAssertEqual(IconStub.requests.count, 2)
    }

    /// Code review 2026-10-30: even with other services allowed, an https server's redirect to plain
    /// http is not followed (the host would go over the network in clear text).
    func testRedirectToPlainHTTP_isRefusedEvenWhenAllowed() async {
        IconStub.answer = { request in
            request.url?.host == "vault.example.com" ? .redirect("http://icons.example.net/github.com.png") : .ok(Self.png)
        }
        defaults.set(true, forKey: WebsiteIconSettings.allowOtherServicesKey)
        let loader = makeLoader()
        loader.configure(iconsBase: base)

        let image = await loader.favicon(for: "github.com")

        XCTAssertNil(image)
        XCTAssertEqual(IconStub.requests.count, 1)
    }

    func testRedirectToAnotherPortOrScheme_countsAsAnotherService() async {
        for target in ["https://vault.example.com:8443/x.png", "http://vault.example.com/x.png"] {
            IconStub.reset()
            IconStub.answer = { request in
                request.url?.absoluteString == "https://vault.example.com/icons/github.com/icon.png"
                    ? .redirect(target) : .ok(Self.png)
            }
            let loader = makeLoader()
            loader.configure(iconsBase: base)

            let image = await loader.favicon(for: "github.com")

            XCTAssertNil(image, target)
            XCTAssertEqual(IconStub.requests.count, 1, target)
        }
    }
}

/// Answers icon requests from a closure; can redirect and delay. Static state, as `StubURLProtocol`.
nonisolated final class IconStub: URLProtocol, @unchecked Sendable {

    enum Answer {
        case ok(Data)
        case status(Int)
        case redirect(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _answer: (URLRequest) -> Answer = { _ in .status(404) }
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _delay: TimeInterval = 0

    static var answer: (URLRequest) -> Answer {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }
    static var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    static func reset() {
        lock.withLock { _answer = { _ in .status(404) }; _requests = []; _delay = 0 }
    }

    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.lock.withLock { Self._requests.append(request) }
        let answer = Self.answer(request)
        let respond = { [weak self] in
            guard let self, !self.cancelled, let url = request.url else { return }
            switch answer {
            case .ok(let data):
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "image/png"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            case .status(let code):
                let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
            case .redirect(let location):
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": location])!
                self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!),
                                         redirectResponse: response)
                // If the session refuses the redirect, the 302 itself is the result.
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        let delay = Self.delay
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() { cancelled = true }
}
