import AppKit
import XCTest
@testable import Prizm

/// A pasteboard double: records writes and lets a test simulate another app copying.
@MainActor
final class FakePasteboard: PasteboardWriting {
    private(set) var changeCount = 0
    private(set) var string: String?
    private(set) var concealed = false

    func writeConcealed(_ value: String) -> Int {
        changeCount += 1
        string = value
        concealed = true
        return changeCount
    }

    func clear() {
        changeCount += 1
        string = nil
        concealed = false
    }

    /// Another app puts something on the clipboard.
    func foreignCopy(_ value: String) {
        changeCount += 1
        string = value
        concealed = false
    }
}

/// A clock whose sleeps end only when the test says so.
@MainActor
final class ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private(set) var requested: [Duration] = []

    var sleep: @MainActor (Duration) async throws -> Void {
        { [unowned self] duration in
            requested.append(duration)
            try await withCheckedThrowingContinuation { waiting.append($0) }
        }
    }

    /// Ends every pending sleep, then lets the woken tasks run.
    func fire() async {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
        for _ in 0..<5 { await Task.yield() }
    }
}

/// One clipboard service for every copy: concealed, cleared after the configured delay, and on
/// lock, sign-out and quit (openspec change clipboard-hardening).
@MainActor
final class ClipboardServiceTests: XCTestCase {

    private var pasteboard: FakePasteboard!
    private var sleeper: ManualSleeper!
    private var defaults: UserDefaults!
    private var sut: ClipboardServiceImpl!

    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ClipboardServiceTests-\(UUID().uuidString)"
        pasteboard = FakePasteboard()
        sleeper = ManualSleeper()
        defaults = UserDefaults(suiteName: suiteName)
        sut = ClipboardServiceImpl(pasteboard: pasteboard, defaults: defaults, sleep: sleeper.sleep)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - 1.3 The service

    func testCopy_writesConcealedAndClearsAfterTheDefaultDelay() async {
        sut.copy("secret")
        XCTAssertEqual(pasteboard.string, "secret")
        XCTAssertTrue(pasteboard.concealed)
        await Task.yield()
        XCTAssertEqual(sleeper.requested, [.seconds(30)], "Default delay: 30 seconds")

        await sleeper.fire()

        XCTAssertNil(pasteboard.string)
    }

    func testCopy_foreignValueMeanwhile_isNotCleared() async {
        sut.copy("secret")
        await Task.yield()
        pasteboard.foreignCopy("someone else's text")

        await sleeper.fire()

        XCTAssertEqual(pasteboard.string, "someone else's text")
    }

    func testCopy_newCopyReplacesThePendingClear() async {
        sut.copy("first")
        await Task.yield()
        sut.copy("second")
        await Task.yield()

        await sleeper.fire()

        XCTAssertNil(pasteboard.string, "The second copy is cleared by its own timer")
        XCTAssertEqual(sleeper.requested.count, 2)
    }

    func testCopy_never_schedulesNothing() async {
        ClipboardClearDelay.never.save(to: defaults)

        sut.copy("secret")
        await Task.yield()

        XCTAssertEqual(sleeper.requested, [])
        XCTAssertEqual(pasteboard.string, "secret")
    }

    func testCopy_usesTheConfiguredDelay() async {
        ClipboardClearDelay.minutes2.save(to: defaults)

        sut.copy("secret")
        await Task.yield()

        XCTAssertEqual(sleeper.requested, [.seconds(120)])
    }

    // MARK: - 4.1 Lock, sign-out, quit

    func testClearIfOwned_clearsOurValue() {
        sut.copy("secret")

        sut.clearIfOwned()

        XCTAssertNil(pasteboard.string)
    }

    func testClearIfOwned_leavesAForeignValue() {
        sut.copy("secret")
        pasteboard.foreignCopy("other")

        sut.clearIfOwned()

        XCTAssertEqual(pasteboard.string, "other")
    }

    func testClearIfOwned_withNever_stillClears() {
        ClipboardClearDelay.never.save(to: defaults)
        sut.copy("secret")

        sut.clearIfOwned()

        XCTAssertNil(pasteboard.string, "\"Never\" is about the timer, not the end of the session")
    }

    // MARK: - 3.1 The setting

    func testDelay_defaultIs30Seconds_andRoundTrips() {
        XCTAssertEqual(ClipboardClearDelay.current(in: defaults), .seconds30)
        for delay in ClipboardClearDelay.allCases {
            delay.save(to: defaults)
            XCTAssertEqual(ClipboardClearDelay.current(in: defaults), delay)
        }
        XCTAssertEqual(ClipboardClearDelay.allCases.map(\.duration),
                       [nil, .seconds(10), .seconds(20), .seconds(30), .seconds(60), .seconds(120), .seconds(300)])
    }

    // MARK: - 1.2 / 2.1 / 2.2 The generator

    /// Before this change, the generator's own clear task was cancelled when its view model went
    /// away (Copy → Use → Save closes the sheet), and the password stayed on the clipboard.
    func testGeneratorCopy_isConcealedAndClearedAfterTheViewModelIsGone() async throws {
        var generator: PasswordGeneratorViewModel? = PasswordGeneratorViewModel(
            provider: MockRandomnessProvider(), defaults: defaults, clipboard: sut)
        let value = try XCTUnwrap(generator?.generatedValue)
        generator?.copyToClipboard()
        XCTAssertEqual(pasteboard.string, value)
        XCTAssertTrue(pasteboard.concealed, "Generator copies must be hidden from clipboard history")

        generator = nil
        await Task.yield()
        await sleeper.fire()

        XCTAssertNil(pasteboard.string, "The clear must not depend on the generator's lifetime")
    }

    // MARK: - The system pasteboard adapter

    func testSystemPasteboard_writesTheConcealedMarker() {
        let named = NSPasteboard(name: NSPasteboard.Name("com.prizm.tests.\(UUID().uuidString)"))
        defer { named.releaseGlobally() }
        let adapter = SystemPasteboard(named)

        let count = adapter.writeConcealed("123456")

        XCTAssertEqual(named.string(forType: .string), "123456")
        XCTAssertTrue(named.types?.contains(SystemPasteboard.concealedType) == true)
        XCTAssertEqual(count, named.changeCount)
        adapter.clear()
        XCTAssertNil(named.string(forType: .string))
    }
}
