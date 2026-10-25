import XCTest
@testable import Prizm

/// Guards the app target's bundle identifier (openspec change `fix-app-signing-settings`).
///
/// The identifier went missing once (923fa5b) without any test noticing, because CI builds
/// unsigned and Xcode only insists on it when signing. The unit tests run inside the app
/// (TEST_HOST), so `Bundle.main` here is the built Prizm app. The exact value is not asserted:
/// local builds use the developer's own PRIZM_BUNDLE_IDENTIFIER. CI checks the default.
final class AppBundleConfigurationTests: XCTestCase {

    func test_appBundle_hasBundleIdentifier() throws {
        let identifier = try XCTUnwrap(
            Bundle.main.bundleIdentifier,
            "The app has no CFBundleIdentifier. PRODUCT_BUNDLE_IDENTIFIER must be set for the Prizm target."
        )
        XCTAssertFalse(identifier.isEmpty, "The app's CFBundleIdentifier is empty.")
    }
}
