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

    /// True when this process hosts the unit tests: XCTest sets `XCTestConfigurationFilePath` in the
    /// host app, and no UI-test state was asked for. The app then uses empty in-memory keychains,
    /// so it shows the login screen and never reads the developer's stored login or runs the unlock
    /// screen's Touch ID path, which writes the real preferences (fix-biometric-test-isolation,
    /// code review 2026-10-30).
    static func isUnitTestHost(environment: [String: String], arguments: [String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil && launchState(from: arguments) == nil
    }

    static var isUnitTestHost: Bool {
        isUnitTestHost(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    }

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
        arguments[BiometricPreferenceKey.unlockEnabled] = false
        arguments[BiometricPreferenceKey.enrollmentPromptShown] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: - Stored server records

    /// Keys the seeded records are encrypted under. DEBUG-only and obviously fake: they protect
    /// nothing, exist so a saving journey in the seeded vault has a server record to save over, and
    /// are never compiled into a Release build. Nothing unlocks the crypto service with them yet; see
    /// the note at the seeding call in `RootViewModel`.
    static let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0x5A, count: 32),
        macKey:        Data(repeating: 0xA5, count: 32)
    )
    /// Organization keys by organization id; `org-acme` is the organization of `orgItemInFolder`.
    static let orgKeys: [String: CryptoKeys] = [
        "org-acme": CryptoKeys(
            encryptionKey: Data(repeating: 0x3C, count: 32),
            macKey:        Data(repeating: 0xC3, count: 32)
        )
    ]

    /// One server record per item, built with the create-path mapper under `vaultKeys`, or under the
    /// item's organization key for an organization item, so each maps back to the same item. Saves
    /// in the seeded vault are built over these records.
    static func rawRecords(for items: [VaultItem]) -> [RawCipher] {
        let mapper = CipherMapper()
        // Encrypting fixed values with fixed keys cannot fail, and an organization item without a
        // key here would be a mistake in this fixture: both trap in this DEBUG seam (like
        // `keychain(for:)`) instead of silently seeding a record under the wrong key.
        return items.map { item in
            let keys: CryptoKeys
            if let organizationId = item.organizationId {
                keys = orgKeys[organizationId]!
            } else {
                keys = vaultKeys
            }
            var record = try! mapper.toUnkeyedRawCipher(DraftVaultItem(item), encryptedWith: keys, encryptedFor: "ui-test-seed")
            if let history = passwordHistory[item.id] {
                record = try! withPasswordHistory(record, history, keys: keys)
            }
            // The UI-test vault's records follow the same rule as the server's: each carries its
            // item's revision, which the save path relies on to compare revisions. Re-encoding a
            // fixed record cannot fail, so a failure traps in this DEBUG seam, like the other
            // fixture builders.
            return try! withRevision(record, serverRevisionString(for: item.revisionDate))
        }
    }

    /// Password history entries of the seeded items, newest first (password-history): two that share
    /// a minute, so the sheet's identifiers cannot rely on dates. The item's count must match.
    static let passwordHistory: [String: [(value: String, date: String)]] = [
        "kappa": [("kappa-old-2", "2026-02-01T10:30:00.000Z"), ("kappa-old-1", "2026-02-01T10:30:00.000Z")],
    ]

    private static func withPasswordHistory(_ record: RawCipher, _ entries: [(value: String, date: String)],
                                            keys: CryptoKeys) throws -> RawCipher {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] ?? [:]
        json["passwordHistory"] = try entries.map { entry in
            ["password": try EncString.encrypt(data: Data(entry.value.utf8), keys: keys).toString(),
             "lastUsedDate": entry.date]
        }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// `date` the way Vaultwarden 1.37.4 writes revisions: ISO-8601 UTC with six fractional digits
    /// and `Z`. The sixth digit is always zero because the app compares revisions at millisecond
    /// resolution. The count is rounded because a decimal millisecond can be inexact in a `Double`:
    /// a date built from the reference date, as the ISO-8601 parser does, can land a hair below the
    /// whole millisecond (`1_793_008_800.0019999`), and truncating it would write `.001999Z`.
    ///
    /// The one definition of the stamped format: the unit tests' `RepositoryFixtures` use it too, so
    /// the UI-test vault and the unit tests cannot drift apart on what the revision pre-check parses.
    nonisolated static func serverRevisionString(for date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let wholeSeconds = Int64((Double(milliseconds) / 1000).rounded(.down))
        let fraction = milliseconds - wholeSeconds * 1000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let seconds = formatter.string(from: Date(timeIntervalSince1970: Double(wholeSeconds)))
        // Drop the formatter's trailing "Z" and put the fraction in front of it.
        return String(seconds.dropLast()) + "." + String(format: "%03d", fraction) + "000Z"
    }

    /// `record` with another `revisionDate`. The create path writes none and the wire model has no
    /// setter, so the record is re-made through its JSON. Shared with the unit tests' fixtures, which
    /// report a failure instead of trapping.
    nonisolated static func withRevision(_ record: RawCipher, _ revision: String) throws -> RawCipher {
        let data = try JSONEncoder().encode(record)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "Record \(record.id) did not encode to a JSON object"))
        }
        json["revisionDate"] = revision
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Conflict scenarios

    /// How the UI-test vault answers a save of the edited note, chosen by `--ui-test-conflict=<value>`.
    ///
    /// The seeded vault has no server, so journeys that save are skipped. In every scenario Save
    /// reports that the item changed elsewhere; the scenario decides what the sync that follows finds.
    enum ConflictScenario: String, Equatable {
        /// The sync works and the note has changed (banner: "Synced", reload enabled).
        case synced
        /// The first sync fails, then the next one works like `synced` (banner shows the sync error).
        case syncFailsOnce = "sync-fails-once"
        /// The sync works and the note is gone (banner: item gone, Close).
        case gone
    }

    /// The value of `--ui-test-conflict=`, or nil when it is absent or not a known scenario.
    static func conflictScenario(from arguments: [String]) -> ConflictScenario? {
        let prefix = "--ui-test-conflict="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return ConflictScenario(rawValue: String(argument.dropFirst(prefix.count)))
    }

    static var conflictScenario: ConflictScenario? { conflictScenario(from: CommandLine.arguments) }

    /// The item the scenarios change or remove: the secure note "Test Note".
    static let conflictItemId = "note1"

    /// `conflictItemId` as another device left it: other name and notes, later revision.
    static var changedConflictItem: VaultItem {
        VaultItem(
            id: conflictItemId, name: "Test Note (changed elsewhere)", isFavorite: false, isDeleted: false,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            revisionDate: Date(timeIntervalSince1970: 1_700_000_060),
            content: .secureNote(SecureNoteContent(notes: "Changed on another device.", customFields: []))
        )
    }

    /// The fixture items as the server holds them after the conflicting change.
    static func itemsAfterConflict(_ scenario: ConflictScenario) -> [VaultItem] {
        items.compactMap { item in
            guard item.id == conflictItemId else { return item }
            return scenario == .gone ? nil : changedConflictItem
        }
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
        // Encoding a fixed value and writing to the in-memory keychain cannot fail; a failure here
        // would be a programming error in this DEBUG seam, so it traps instead of being ignored.
        let environment = try! JSONEncoder().encode(ServerEnvironment(base: serverURL))
        try! keychain.write(data: Data(accountUserId.utf8), key: KeychainKey.activeUserId)
        try! keychain.write(data: Data(accountEmail.utf8), key: KeychainKey.user(accountUserId, "email"))
        try! keychain.write(data: environment, key: KeychainKey.user(accountUserId, "serverEnvironment"))
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

    /// `--ui-test-blocked-item`: adds an item Prizm cannot edit, for the journey that checks the
    /// disabled Edit button and its note. Off by default so the other journeys' lists stay unchanged.
    static var withBlockedItem: Bool { CommandLine.arguments.contains("--ui-test-blocked-item") }

    static var folders: [Folder] { withOrgFolders ? [Folder(id: "work", name: "Work")] : [] }
    static var organizations: [Organization] {
        withOrgFolders ? [Organization(id: "org-acme", name: "Acme", role: .user, membershipId: .known("m-uitest"))] : []
    }
    /// "View Only" is read-only for the fixture account, for the collection checkboxes of the edit
    /// sheet (fix-collection-assignment).
    static var collections: [OrgCollection] {
        guard withOrgFolders else { return [] }
        return [
            OrgCollection(id: "col-shared", organizationId: "org-acme", name: "Shared"),
            OrgCollection(id: "col-team", organizationId: "org-acme", name: "Team"),
            OrgCollection(id: "col-view", organizationId: "org-acme", name: "View Only", readOnly: true),
        ]
    }

    static var items: [VaultItem] {
        let all = seededItems + (withOrgFolders ? [orgItemInFolder] : []) + (withBlockedItem ? [blockedItem] : [])
        guard withoutSeeds else { return all }
        return all.map { item in
            guard case .login = item.content else { return item }
            return login(id: item.id, name: item.name, totp: nil, isDeleted: item.isDeleted,
                         isFavorite: item.isFavorite, passwordHistoryCount: item.passwordHistoryCount,
                         attachments: item.attachments)
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
            ], hiddenURICount: 1),  // uri-checksum-validation: one website failed its checksum
            // A counter-based seed: never a valid time-based code, so "unavailable" (totp-parity, D2).
            login(id: "delta", name: "Delta Bad Seed", totp: "otpauth://hotp/Delta:me?secret=\(rfcSeed)&counter=1"),
            login(id: "zeta", name: "Zeta Trashed", totp: rfcSeed, isDeleted: true),
            login(id: "kappa", name: "Kappa Login", totp: nil, isFavorite: true,
                  passwordHistoryCount: passwordHistory["kappa"]?.count ?? 0, attachments: [
                Attachment(id: "att1", fileName: "kappa-notes.txt", encryptedKey: "", size: 1024,
                           sizeName: "1 KB", url: nil),
                // In Prizm's old file layout (fix-attachment-file-format): badge and Convert.
                Attachment(id: "att-legacy", fileName: "kappa-old-report.pdf", encryptedKey: "", size: 1072,
                           sizeName: "1 KB", url: nil, storedInLegacyPrizmFormat: true),
            ], uris: [
                // A second item with websites, so switching from Gamma reuses the Website rows.
                // Without a scheme it has no host, so no UI run asks the icon service for it.
                LoginURI(uri: "kappa.example.com/login", matchType: nil),
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

    /// The organization item `--ui-test-org-folders` adds. Internal so the seam tests can build the
    /// records of a vault that has it.
    static var orgItemInFolder: VaultItem {
        VaultItem(
            id: "omega", name: "Omega Shared", isFavorite: false, isDeleted: false,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            content: .secureNote(SecureNoteContent(notes: "shared", customFields: [])),
            folderId: "work", organizationId: "org-acme", collectionIds: ["col-shared", "col-view"]
        )
    }

    /// The item `--ui-test-blocked-item` adds: a secure note with no TOTP seed, flagged as stored in
    /// a format Prizm cannot write back. Internal so the seam tests can check it.
    static var blockedItem: VaultItem {
        VaultItem(
            id: "theta", name: "Theta Blocked", isFavorite: false, isDeleted: false,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            content: .secureNote(SecureNoteContent(notes: "Kept in a format Prizm cannot edit.", customFields: [])),
            editBlock: .unsupportedFormat
        )
    }

    private static func login(
        id: String, name: String, totp: String?, isDeleted: Bool = false,
        isFavorite: Bool = false, passwordHistoryCount: Int = 0, attachments: [Attachment] = [],
        uris: [LoginURI] = [], hiddenURICount: Int = 0
    ) -> VaultItem {
        item(id: id, name: name, isDeleted: isDeleted, isFavorite: isFavorite, attachments: attachments,
             passwordHistoryCount: passwordHistoryCount,
             content: .login(LoginContent(
                 username: "user-\(id)", password: "pw-\(id)", uris: uris, totp: totp, notes: nil, customFields: [],
                 hiddenURICount: hiddenURICount
             )))
    }

    private static func item(
        id: String, name: String, isDeleted: Bool = false, isFavorite: Bool = false,
        attachments: [Attachment] = [], passwordHistoryCount: Int = 0, content: ItemContent
    ) -> VaultItem {
        VaultItem(
            id: id, name: name, isFavorite: isFavorite, isDeleted: isDeleted,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            content: content, attachments: attachments, passwordHistoryCount: passwordHistoryCount
        )
    }
}

// MARK: - Scripted use cases for the conflict scenarios

/// A save that always fails with `VaultError.conflict`, so a journey can reach the conflict banner
/// without a server. Used only with `--ui-test-conflict=` (see `UITestFixtures.ConflictScenario`);
/// nothing here exists in Release builds.
final class UITestConflictEditUseCase: EditVaultItemUseCase {
    func execute(draft: DraftVaultItem) async throws -> VaultItem {
        throw VaultError.conflict
    }
}

/// The sync that follows a scripted conflict: instead of fetching, it puts the vault in the state
/// the scenario describes (the note changed or removed), or fails once first.
final class UITestConflictSyncUseCase: SyncUseCase {
    private let vault: any VaultRepository
    private let scenario: UITestFixtures.ConflictScenario
    private var hasFailed = false

    init(vault: any VaultRepository, scenario: UITestFixtures.ConflictScenario) {
        self.vault = vault
        self.scenario = scenario
    }

    func execute(progress: @Sendable @escaping (String) -> Void) async throws -> SyncResult {
        if scenario == .syncFailsOnce, !hasFailed {
            hasFailed = true
            throw SyncError.networkUnavailable
        }
        let items = UITestFixtures.itemsAfterConflict(scenario)
        let now = Date()
        await vault.populate(items: items, folders: UITestFixtures.folders,
                             organizations: UITestFixtures.organizations,
                             collections: UITestFixtures.collections, syncedAt: now)
        return SyncResult(syncedAt: now, totalCiphers: items.count, failedDecryptionCount: 0)
    }
}
#endif
