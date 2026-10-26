#if DEBUG
import Foundation

/// Test states for XCUITest, so UI journeys can run without a server or a real login.
///
/// Enabled only by a `--ui-test-*` launch argument and compiled out of Release builds
/// (`#if DEBUG`), so a shipping password manager contains no test backdoor. The fixtures use
/// made-up names and RFC 6238 test secrets, never real credentials. In every state the app uses
/// in-memory keychains (`UITestKeychains.swift`), so a test that locks or signs out cannot touch
/// the developer's stored login (openspec change `fix-ui-test-target`, design D1–D3).
enum UITestFixtures {

    /// The app state a UI test asks for at launch.
    enum LaunchState: Equatable {
        /// `--ui-test-vault`: unlocked, with the seeded in-memory vault.
        case vault
        /// `--ui-test-locked`: the unlock screen for the fixture account.
        case locked
        /// `--ui-test-signed-out`: the login screen.
        case signedOut
    }

    static let launchArgument = "--ui-test-vault"

    /// When several states are given, the most restrictive wins: a test that asks for "signed out"
    /// must never see a seeded or locked session.
    static func launchState(from arguments: [String]) -> LaunchState? {
        if arguments.contains("--ui-test-signed-out") { return .signedOut }
        if arguments.contains("--ui-test-locked") { return .locked }
        if arguments.contains(launchArgument) { return .vault }
        return nil
    }

    static var launchState: LaunchState? { launchState(from: CommandLine.arguments) }

    /// True when the seeded vault should be shown unlocked.
    static var isEnabled: Bool { launchState == .vault }

    /// Keeps a UI test run from changing the developer's Touch ID setting.
    ///
    /// The unlock screen checks `biometricUnlockEnabled` from `UserDefaults.standard`, and when no
    /// biometric item exists (always the case with the in-memory keychain) it writes `false` back,
    /// which would switch off the developer's real Touch ID unlock. Values in the volatile argument
    /// domain take precedence over the stored ones and are never written to disk, so Touch ID
    /// reads as off and enrollment as already offered for this launch only. Other preferences (for
    /// example password generator options) are not isolated; see design.md, Risks.
    static func isolateBiometricDefaults(_ defaults: UserDefaults = .standard) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["biometricUnlockEnabled"] = false
        arguments["biometricEnrollmentPromptShown"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: - Fixture account

    static let accountUserId = "uitest-user"
    static let accountEmail = "uitest@example.com"
    /// `.invalid` is reserved (RFC 2606), so an accidental request can never reach a real host.
    static let serverURL = URL(string: "https://vault.uitest.invalid")!

    /// The in-memory keychain for a launch state. In `vault` and `locked` it holds the fixture
    /// account's non-secret entries (user id, email, server), so the unlock screen and the lock
    /// journey show that account. It holds no keys or tokens: unlocking with a password cannot
    /// succeed, which the journeys that need it report as skipped.
    static func keychain(for state: LaunchState) -> InMemoryKeychainService {
        let keychain = InMemoryKeychainService()
        guard state != .signedOut else { return keychain }
        let environment = (try? JSONEncoder().encode(ServerEnvironment(base: serverURL))) ?? Data()
        try? keychain.write(data: Data(accountUserId.utf8), key: KeychainKey.activeUserId)
        try? keychain.write(data: Data(accountEmail.utf8), key: KeychainKey.user(accountUserId, "email"))
        try? keychain.write(data: environment, key: KeychainKey.user(accountUserId, "serverEnvironment"))
        return keychain
    }

    /// With `--ui-test-open-codes`, start on the Codes list with its first item selected.
    static var opensOnCodes: Bool { CommandLine.arguments.contains("--ui-test-open-codes") }

    /// RFC 6238 Appendix B secret "12345678901234567890" in base32.
    static let rfcSeed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    /// With `--ui-test-no-codes`, every sample item has no TOTP seed (to see the empty state).
    static var withoutSeeds: Bool { CommandLine.arguments.contains("--ui-test-no-codes") }

    /// With `--ui-test-org-folders`, the vault also has a folder "Work" and an organization item
    /// filed in it (org-items-in-personal-folders). Off by default, so the sidebar the other
    /// journeys walk through is unchanged.
    static var withOrgFolders: Bool { CommandLine.arguments.contains("--ui-test-org-folders") }

    static var folders: [Folder] { withOrgFolders ? [Folder(id: "work", name: "Work")] : [] }
    static var organizations: [Organization] {
        withOrgFolders ? [Organization(id: "org-acme", name: "Acme", role: .user, membershipId: .known("m-uitest"))] : []
    }
    static var collections: [OrgCollection] {
        withOrgFolders ? [OrgCollection(id: "col-shared", organizationId: "org-acme", name: "Shared")] : []
    }

    static var items: [VaultItem] {
        let all = seededItems + (withOrgFolders ? [orgItemInFolder] : [])
        guard withoutSeeds else { return all }
        return all.map { item in
            guard case .login = item.content else { return item }
            return login(id: item.id, name: item.name, totp: nil, isDeleted: item.isDeleted,
                         isFavorite: item.isFavorite, attachments: item.attachments)
        }
    }

    /// alpha to zeta are used by VerificationCodeJourneyTests; the rest (design D3) by the other
    /// journeys. There is deliberately no SSH key, so that category stays empty, and the new items
    /// have no TOTP seed, so the Codes list is unchanged.
    private static var seededItems: [VaultItem] {
        [
            login(id: "alpha", name: "Alpha Bank", totp: rfcSeed),
            login(id: "beta", name: "Beta Mail",
                  totp: "otpauth://totp/Beta:me?secret=\(rfcSeed)&digits=8&period=60&algorithm=SHA256"),
            login(id: "gamma", name: "Gamma No Seed", totp: nil, uris: [
                // safe-uri-launch: a scheme that must not get an open button, and a scheme-less address.
                LoginURI(uri: "file:///Applications/Calculator.app", matchType: nil),
                LoginURI(uri: "example.com/login", matchType: nil),
            ]),
            login(id: "delta", name: "Delta Bad Seed", totp: "not-a-seed!"),
            login(id: "zeta", name: "Zeta Trashed", totp: rfcSeed, isDeleted: true),
            login(id: "kappa", name: "Kappa Login", totp: nil, isFavorite: true, attachments: [
                Attachment(id: "att1", fileName: "kappa-notes.txt", encryptedKey: "", size: 1024,
                           sizeName: "1 KB", url: nil, isUploadIncomplete: false),
            ]),
            item(id: "card1", name: "Test Card", content: .card(CardContent(
                cardholderName: "Test Holder", brand: "Visa", number: "4111111111111111",
                expMonth: "12", expYear: "2030", code: "123", notes: nil, customFields: []
            ))),
            item(id: "ident1", name: "Test Identity", content: .identity(IdentityContent(
                title: nil, firstName: "Test", middleName: nil, lastName: "Person", address1: nil,
                address2: nil, address3: nil, city: nil, state: nil, postalCode: nil, country: nil,
                company: nil, email: "person@example.com", phone: nil, ssn: nil, username: nil,
                passportNumber: nil, licenseNumber: nil, notes: nil, customFields: []
            ))),
            item(id: "note1", name: "Test Note", content: .secureNote(SecureNoteContent(
                notes: "A secure note for UI tests.", customFields: []
            ))),
        ]
    }

    private static var orgItemInFolder: VaultItem {
        VaultItem(
            id: "omega", name: "Omega Shared", isFavorite: false, isDeleted: false,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            content: .secureNote(SecureNoteContent(notes: "shared", customFields: [])),
            folderId: "work", organizationId: "org-acme", collectionIds: ["col-shared"]
        )
    }

    private static func login(
        id: String, name: String, totp: String?, isDeleted: Bool = false,
        isFavorite: Bool = false, attachments: [Attachment] = [], uris: [LoginURI] = []
    ) -> VaultItem {
        item(id: id, name: name, isDeleted: isDeleted, isFavorite: isFavorite, attachments: attachments,
             content: .login(LoginContent(
                 username: "user-\(id)", password: "pw-\(id)", uris: uris, totp: totp, notes: nil, customFields: []
             )))
    }

    private static func item(
        id: String, name: String, isDeleted: Bool = false, isFavorite: Bool = false,
        attachments: [Attachment] = [], content: ItemContent
    ) -> VaultItem {
        VaultItem(
            id: id, name: name, isFavorite: isFavorite, isDeleted: isDeleted,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            content: content, attachments: attachments
        )
    }
}
#endif
