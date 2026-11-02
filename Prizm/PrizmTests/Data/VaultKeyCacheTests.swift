import XCTest
@testable import Prizm

/// Tests for `VaultKeyCache` actor — populate/lookup/record/clear lifecycle of key sources
/// (fix-org-attachment-key, D1/D2).
final class VaultKeyCacheTests: XCTestCase {

    private var sut: VaultKeyCache!

    override func setUp() async throws {
        sut = VaultKeyCache()
    }

    func test_populate_thenLookup_returnsSource() async {
        let key = Data(repeating: 0xAB, count: 64)
        await sut.populate(sources: [
            "keyed": .itemKey(key),
            "shared": .organization(orgId: "org-1"),
            "mine": .personal
        ])
        let keyed = await sut.source(for: "keyed")
        let shared = await sut.source(for: "shared")
        let mine = await sut.source(for: "mine")
        XCTAssertEqual(keyed, .itemKey(key))
        XCTAssertEqual(shared, .organization(orgId: "org-1"))
        XCTAssertEqual(mine, .personal)
        let itemKey = await sut.key(for: "keyed")
        XCTAssertEqual(itemKey, key)
        let noItemKey = await sut.key(for: "shared")
        XCTAssertNil(noItemKey, "Only own item keys are stored as bytes")
    }

    func test_lookup_unknownCipherId_returnsNil() async {
        await sut.populate(sources: ["cipher-1": .personal])
        let result = await sut.source(for: "cipher-999")
        XCTAssertNil(result)
    }

    func test_record_addsOneEntry_keepingTheOthers() async {
        await sut.populate(sources: ["old": .personal])
        await sut.record(.organization(orgId: "org-1"), for: "new", ifStillCurrent: { true })
        let old = await sut.source(for: "old")
        let new = await sut.source(for: "new")
        XCTAssertEqual(old, .personal)
        XCTAssertEqual(new, .organization(orgId: "org-1"))
    }

    /// A create that finishes after a lock must not leave its key source in the next session
    /// (review of fix-org-attachment-key, 2026-10-30). The session check is the gate's, made inside
    /// the actor in the write's turn (lock-state-machine, task 1.2); the refused item key is zeroed.
    func test_record_afterTheSessionEnded_isIgnored_andZeroesTheKey() async {
        let zeroed = ZeroedKeys()
        await sut.setZeroedObserver { bytes, inPlace in zeroed.append(bytes, inPlace) }
        let gate = SessionGateImpl()
        let token = gate.begin()
        gate.end()

        await sut.record(.itemKey(Data(repeating: 0x05, count: 64)), for: "late",
                         ifStillCurrent: { gate.isCurrent(token) })

        let late = await sut.source(for: "late")
        XCTAssertNil(late)
        XCTAssertEqual(zeroed.all.map(\.bytes), [Data(count: 64)])
    }

    func test_clear_makesAllLookupsReturnNil() async {
        await sut.populate(sources: [
            "cipher-1": .itemKey(Data(repeating: 0x01, count: 64)),
            "cipher-2": .personal
        ])
        await sut.clear()
        let r1 = await sut.source(for: "cipher-1")
        let r2 = await sut.source(for: "cipher-2")
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func test_clear_zeroesItemKeysInPlace() async {
        await sut.populate(sources: ["keyed": .itemKey(Data(repeating: 0x07, count: 64)), "mine": .personal])
        let zeroed = ZeroedKeys()
        await sut.setZeroedObserver { bytes, inPlace in zeroed.append(bytes, inPlace) }

        await sut.clear()

        let seen = zeroed.all
        XCTAssertEqual(seen.count, 1, "Only the own item key has bytes to zero")
        XCTAssertTrue(seen.allSatisfy { $0.inPlace && $0.bytes.allSatisfy { $0 == 0 } })
    }

    // MARK: - Lock fence (lock-state-machine, design D8, gap 6)

    /// A sync whose session ended after its last lock check writes no sources and no item keys.
    func test_populateIfStillCurrent_staleSession_writesNothingAndZeroesTheKeys() async {
        let zeroed = ZeroedKeys()
        await sut.setZeroedObserver { bytes, inPlace in zeroed.append(bytes, inPlace) }

        let written = await sut.populate(sources: ["keyed": .itemKey(Data(repeating: 0x07, count: 64)), "mine": .personal],
                                         ifStillCurrent: { false })

        XCTAssertFalse(written)
        let keyed = await sut.source(for: "keyed")
        let mine = await sut.source(for: "mine")
        XCTAssertNil(keyed)
        XCTAssertNil(mine)
        XCTAssertEqual(zeroed.all.count, 1, "the refused item key is zeroed")
        XCTAssertTrue(zeroed.all.allSatisfy { $0.bytes.allSatisfy { $0 == 0 } })
    }

    func test_populateIfStillCurrent_currentSession_writes() async {
        let written = await sut.populate(sources: ["mine": .personal], ifStillCurrent: { true })
        XCTAssertTrue(written)
        let mine = await sut.source(for: "mine")
        XCTAssertEqual(mine, .personal)
    }

    /// The check runs inside the cache, in the same turn as the write: a gate ended before the
    /// call is seen even though the caller's own check passed earlier.
    func test_populateIfStillCurrent_followsTheGateAtTheWrite() async {
        let gate = SessionGateImpl()
        let token = gate.begin()
        XCTAssertTrue(gate.isCurrent(token), "the caller's earlier check passes")
        gate.end()
        let written = await sut.populate(sources: ["mine": .personal], ifStillCurrent: { gate.isCurrent(token) })
        XCTAssertFalse(written)
    }

    func test_populate_replacesExistingEntries() async {
        await sut.populate(sources: ["cipher-1": .personal])
        await sut.populate(sources: ["cipher-1": .organization(orgId: "org-1")])
        let result = await sut.source(for: "cipher-1")
        XCTAssertEqual(result, .organization(orgId: "org-1"))
    }

    func test_populate_emptyClearsExistingEntries() async {
        await sut.populate(sources: ["cipher-1": .personal])
        await sut.populate(sources: [:])
        let result = await sut.source(for: "cipher-1")
        XCTAssertNil(result)
    }

    func test_clear_slicedKey_preservesOutstandingCopy() async {
        let bytes = Data((0..<96).map { UInt8($0) })
        let key = bytes[16..<80]
        await sut.populate(sources: ["sliced": .itemKey(key)])
        let outstanding = await sut.key(for: "sliced")
        await sut.clear()
        await sut.clear()
        let cleared = await sut.key(for: "sliced")
        XCTAssertNil(cleared)
        XCTAssertEqual(outstanding, key)
    }
}

/// Collects what the zeroing observer reports.
private final class ZeroedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(bytes: Data, inPlace: Bool)] = []
    func append(_ bytes: Data, _ inPlace: Bool) { lock.withLock { entries.append((bytes, inPlace)) } }
    var all: [(bytes: Data, inPlace: Bool)] { lock.withLock { entries } }
}
