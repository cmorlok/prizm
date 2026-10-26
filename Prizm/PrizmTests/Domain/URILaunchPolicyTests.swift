import XCTest
@testable import Prizm

/// "Open in browser" opens only allow-listed schemes, adds `http://` to scheme-less addresses, and
/// never opens regular-expression patterns (openspec change safe-uri-launch).
@MainActor
final class URILaunchPolicyTests: XCTestCase {

    private func launch(_ uri: String, _ match: URIMatchType? = nil) -> String? {
        URILaunchPolicy.launchURL(for: LoginURI(uri: uri, matchType: match))?.absoluteString
    }

    // MARK: - 1.1 Allow-list (D1)

    func testAllowedSchemes_inMixedCase_open() {
        let allowed = ["HTTPS://example.com", "Http://example.com", "SSH://git.example.com", "ftp://files.example.com",
                       "sFTP://files.example.com", "irc://irc.example.com", "VNC://screen.example.com",
                       "rdp://desktop.example.com", "MS-RD:full%20address=s:desktop.example.com",
                       "chrome://settings", "iosapp://com.example.app", "androidapp://com.example.app"]
        for uri in allowed {
            XCTAssertEqual(launch(uri), uri, "\(uri) is on the allow-list")
        }
    }

    func testOtherSchemes_neverOpen() {
        for uri in ["file:///Applications/Calculator.app", "smb://server/share", "javascript:alert(1)",
                    "data:text/html,<b>x</b>", "x-custom://run", "x-custom-app://run"] {
            XCTAssertNil(launch(uri), "\(uri) must not be launched")
        }
    }

    // MARK: - D2 Scheme-less URIs

    func testSchemeless_withDomain_getsHttp() {
        XCTAssertEqual(launch("example.com/login"), "http://example.com/login")
        XCTAssertEqual(launch("localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(launch("192.0.2.1/admin"), "http://192.0.2.1/admin")
        XCTAssertEqual(launch("  example.com  "), "http://example.com", "Trimmed")
    }

    func testSchemeless_withoutDomain_doesNotOpen() {
        XCTAssertNil(launch("nas"))
        XCTAssertNil(launch(""))
        XCTAssertNil(launch("   "))
    }

    /// A raw `@` in an `ms-rd:` link makes the `http://` candidate parse with a host, so it opens as
    /// http to that host, as the official clients' tldts-based check does. Not a security issue:
    /// the result is http. The exact string differs by platform: macOS Foundation treats the colons
    /// in the user-info part as invalid and percent-encodes the "%" (to "%2520"), so the test checks
    /// the decision, not the serialisation.
    func testMsRdWithAtSign_opensAsHttpLikeTheOfficialClients() throws {
        let url = try XCTUnwrap(URILaunchPolicy.launchURL(for: LoginURI(
            uri: "ms-rd:full%20address=s:192.168.1.10:3389&username=s:bob@corp.com", matchType: nil)))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host(percentEncoded: false), "corp.com")
    }

    // MARK: - D3 Regular expressions

    func testRegularExpressionURI_neverOpens() {
        XCTAssertNil(launch("https://example.com", .regularExpression))
        XCTAssertNil(launch(#"^https://.*\.example\.com/.*$"#, .regularExpression))
        XCTAssertEqual(launch("https://example.com", .exact), "https://example.com")
    }

    // MARK: - 2.2 Handler check (D4, Presentation)

    func testLaunchTarget_withoutHandler_hasNoButton() {
        let uri = LoginURI(uri: "androidapp://com.example.app", matchType: nil)
        XCTAssertNil(URILaunchTarget.url(for: uri, hasHandler: { _ in false }))
        XCTAssertEqual(URILaunchTarget.url(for: uri, hasHandler: { _ in true })?.absoluteString,
                       "androidapp://com.example.app")
    }

    func testLaunchTarget_disallowedScheme_isNeverCheckedForAHandler() {
        var checked: [URL] = []
        let uri = LoginURI(uri: "file:///etc/hosts", matchType: nil)
        XCTAssertNil(URILaunchTarget.url(for: uri, hasHandler: { checked.append($0); return true }))
        XCTAssertEqual(checked, [], "The allow-list in Domain decides first")
    }
}
