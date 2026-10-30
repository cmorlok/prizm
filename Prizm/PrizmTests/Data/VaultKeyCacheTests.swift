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
        let generation = await sut.generation
        await sut.record(.organization(orgId: "org-1"), for: "new", ifGeneration: generation)
        let old = await sut.source(for: "old")
        let new = await sut.source(for: "new")
        XCTAssertEqual(old, .personal)
        XCTAssertEqual(new, .organization(orgId: "org-1"))
    }

    /// A create that finishes after a lock must not leave its key source in the next session
    /// (review of fix-org-attachment-key, 2026-10-30).
    func test_record_fromBeforeAClear_isIgnored() async {
        let generation = await sut.generation
        await sut.clear()
        await sut.record(.itemKey(Data(repeating: 0x05, count: 64)), for: "late", ifGeneration: generation)
        let late = await sut.source(for: "late")
        XCTAssertNil(late)
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
