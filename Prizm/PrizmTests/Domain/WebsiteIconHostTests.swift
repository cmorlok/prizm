import XCTest
@testable import Prizm

/// fix-website-icons-privacy, design D3: which website URIs produce an icon request, and for which
/// host. Ported from the official rules (`build-cipher-icon.ts`), with the dot and `.onion`/`.i2p`
/// checks on the host.
final class WebsiteIconHostTests: XCTestCase {

    private func host(_ uri: String) -> String? { WebsiteIconHost.host(for: uri) }

    func testSpecTable() {
        XCTAssertEqual(host("https://www.example.com/login"), "www.example.com")
        XCTAssertEqual(host("example.com/login"), "example.com")
        XCTAssertNil(host("ssh://git.example.com"))
        XCTAssertNil(host("ftp://files.example.com"))
        XCTAssertNil(host("androidapp://com.example.app"))
        XCTAssertNil(host("http://localhost:8080"))
        XCTAssertNil(host("http://localhost:8080/a.php"))
        XCTAssertNil(host("http://nas"))
        XCTAssertNil(host("http://nas/index.html"))
        XCTAssertNil(host("http://abcdef.onion/login"))
        XCTAssertNil(host("https://site.i2p"))
        XCTAssertEqual(host("https://192.0.2.10"), "192.0.2.10")
        XCTAssertEqual(host("https://bücher.de"), "xn--bcher-kva.de")
        XCTAssertEqual(host("mailto:x@y.com"), "y.com")
    }

    func testCaseAndWhitespace() {
        XCTAssertEqual(host("HTTPS://WWW.Example.COM/Login"), "www.example.com")
        XCTAssertEqual(host("  https://example.com  "), "example.com")
        XCTAssertNil(host("IOSAPP://com.example.app"))
        XCTAssertNil(host("AndroidApp://com.example.app"))
        XCTAssertNil(host("https://ABC.ONION"))
        XCTAssertNil(host("https://site.I2P./x"))
    }

    func testTrailingDots() {
        XCTAssertNil(host("http://nas."), "a trailing dot alone does not make a dotted host")
        XCTAssertEqual(host("https://example.com./x"), "example.com", "one cache key and path per site")
    }

    /// Security review 2026-10-30: a host of dots only, or with an empty label, is not a website.
    func testEmptyLabels_areNotAHost() {
        XCTAssertNil(host("http://../"))
        XCTAssertNil(host("http://.../x"))
        XCTAssertNil(host("http://a..b/"))
        XCTAssertNil(host("http://.example.com/"))
    }

    /// One rule for every view: the first website URI of a login (code review 2026-10-30).
    func testHostOfAnItem_isTheFirstLoginURIsHost() {
        let login = VaultItem(id: "1", name: "x", isFavorite: false, isDeleted: false,
                              creationDate: Date(), revisionDate: Date(),
                              content: .login(LoginContent(username: nil, password: nil,
                                                           uris: [LoginURI(uri: "https://www.example.com/a", matchType: nil)],
                                                           totp: nil, notes: nil, customFields: [])))
        XCTAssertEqual(WebsiteIconHost.host(for: login), "www.example.com")
    }

    func testEmptyAndNonWebsites() {
        XCTAssertNil(host(""))
        XCTAssertNil(host("   "))
        XCTAssertNil(host("."))
        XCTAssertNil(host("httpx://example.com"), "only http and https, stricter than TS")
        XCTAssertNil(host("rdp://desktop.example.com"))
        XCTAssertNil(host("file:///Users/me/a.txt"))
        XCTAssertNil(host("https://"))
    }

    func testPortAndUserinfo_areNotPartOfTheHost() {
        XCTAssertEqual(host("https://example.com:8443/x"), "example.com")
        XCTAssertEqual(host("https://user:pass@example.com/x"), "example.com")
    }
}
