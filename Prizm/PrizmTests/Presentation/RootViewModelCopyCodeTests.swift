import AppKit
import XCTest
@testable import Prizm

/// "Copy Code" (⌃⌘C) copies the generated code, never the stored seed (FR-016, FR-017).
@MainActor
final class RootViewModelCopyCodeTests: XCTestCase {

    private struct FixedGenerator: GenerateTOTPCodeUseCase {
        func execute(seed: String, at date: Date) async throws -> TOTPCode {
            TOTPCode(digits: "123456", period: 30, secondsRemaining: 12)
        }
    }

    /// Runs `whileGenerating` before returning, to lock the vault while the code is generated.
    /// Its code is not used by any other test.
    private struct InterruptingGenerator: GenerateTOTPCodeUseCase {
        static let code = "975310"
        let whileGenerating: @MainActor () -> Void
        func execute(seed: String, at date: Date) async throws -> TOTPCode {
            await whileGenerating()
            return TOTPCode(digits: Self.code, period: 30, secondsRemaining: 12)
        }
    }

    /// The real generator at the SDK vectors' time (2023-01-01T00:00:00Z), whatever the clock says.
    private struct GeneratorAtSDKTime: GenerateTOTPCodeUseCase {
        func execute(seed: String, at date: Date) async throws -> TOTPCode {
            try await GenerateTOTPCodeUseCaseImpl(crypto: PrizmCryptoServiceImpl())
                .execute(seed: seed, at: Date(timeIntervalSince1970: 1_672_531_200))
        }
    }

    private let validSeed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private var sut: RootViewModel!
    /// The fake pasteboard behind the vault browser's clipboard service.
    private var pasteboard: FakePasteboard!

    override func setUp() async throws {
        try await super.setUp()
        let deps = MockRootDependencies(auth: MockAuthRepository(), vault: MockVaultRepository(), defaults: makePrivateDefaults())
        deps.generateTOTPCode = FixedGenerator()
        sut = RootViewModel(container: deps)
        pasteboard = deps.fakePasteboard
    }

    override func tearDown() async throws {
        try await super.tearDown()
    }

    private func select(totp: String?, username: String? = "alice") async throws {
        let item = VaultItem(
            id: "i1", name: "Acme", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(username: username, password: "pw", uris: [], totp: totp, notes: nil, customFields: []))
        )
        sut.vaultBrowserVM.itemSelection = item
        let deadline = ContinuousClock.now + .milliseconds(500)
        while sut.selectedLogin?.totp != totp, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Copy commands work only while the vault is unlocked. Set after the waits: the login
        // flow's initial state arrives on the main queue and resets `screen` to `.login`.
        sut.screen = .vault
    }

    private func waitForPasteboard(_ expected: String) async throws {
        let deadline = ContinuousClock.now + .milliseconds(500)
        while pasteboard.string != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func test_copyCode_copiesGeneratedCodeWithoutSpace_notTheSeed() async throws {
        try await select(totp: validSeed)
        sut.copySelectedField(.totp)
        try await waitForPasteboard("123456")
        XCTAssertEqual(pasteboard.string, "123456")
        XCTAssertNotEqual(pasteboard.string, validSeed)
    }

    /// A Steam seed copies its five characters, without the display space (totp-parity, D4;
    /// verify 2026-10-31).
    func test_copyCode_steam_copiesTheFiveCharacters() async throws {
        let deps = MockRootDependencies(auth: MockAuthRepository(), vault: MockVaultRepository(), defaults: makePrivateDefaults())
        deps.generateTOTPCode = GeneratorAtSDKTime()
        sut = RootViewModel(container: deps)
        pasteboard = deps.fakePasteboard
        try await select(totp: "steam://HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ")
        sut.copySelectedField(.totp)
        try await waitForPasteboard("7W6CJ")
        XCTAssertEqual(pasteboard.string, "7W6CJ")
    }

    func test_codeAvailable_onlyWhenSeedParses() async throws {
        try await select(totp: validSeed)
        XCTAssertTrue(sut.selectedFieldAvailable(.totp))

        try await select(totp: "otpauth://hotp/x?secret=\(validSeed)&counter=1")
        XCTAssertFalse(sut.selectedFieldAvailable(.totp), "HOTP never gives a valid code")

        try await select(totp: "!!!")
        XCTAssertFalse(sut.selectedFieldAvailable(.totp), "no base32 characters")

        try await select(totp: "steam://\(validSeed)")
        XCTAssertTrue(sut.selectedFieldAvailable(.totp), "Steam codes are supported (totp-parity)")
    }

    func test_codeUnavailable_withNoSeedOrNoSelection() async throws {
        XCTAssertFalse(sut.selectedFieldAvailable(.totp))
        try await select(totp: nil)
        XCTAssertFalse(sut.selectedFieldAvailable(.totp))
        try await select(totp: "   ")
        XCTAssertFalse(sut.selectedFieldAvailable(.totp))
    }

    func test_unusableSeed_copiesNothing() async throws {
        try await select(totp: "!!!")
        sut.copySelectedField(.totp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(pasteboard.string)
    }

    func test_copyField_whileLocked_copiesNothing() async throws {
        let username = "locked-user-\(UUID().uuidString)"
        try await select(totp: validSeed, username: username)
        sut.screen = .unlock

        sut.copySelectedField(.username)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotEqual(pasteboard.string, username)
    }

    func test_copyCode_lockedWhileGenerating_copiesNothing() async throws {
        let deps = MockRootDependencies(auth: MockAuthRepository(), vault: MockVaultRepository(), defaults: makePrivateDefaults())
        sut = RootViewModel(container: deps)
        pasteboard = deps.fakePasteboard
        deps.generateTOTPCode = InterruptingGenerator { [weak self] in self?.sut.screen = .unlock }
        try await select(totp: validSeed)

        sut.copySelectedField(.totp)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotEqual(pasteboard.string, InterruptingGenerator.code,
                          "A code generated across a lock must not be copied")
    }

    func test_otherFields_stillCopyTheirOwnValues() async throws {
        try await select(totp: validSeed, username: "alice")
        sut.copySelectedField(.username)
        try await waitForPasteboard("alice")
        XCTAssertEqual(pasteboard.string, "alice")
    }
}
