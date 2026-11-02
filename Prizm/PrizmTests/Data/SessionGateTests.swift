import XCTest
@testable import Prizm

/// The one lock fence shared by every layer (openspec change lock-state-machine, design D1).
final class SessionGateTests: XCTestCase {

    func testBegin_onAnOpenGate_isCurrent() {
        let gate = SessionGateImpl()
        let token = gate.begin()
        XCTAssertTrue(gate.isCurrent(token))
    }

    func testBegin_twiceInOneEpoch_givesTheSameToken() {
        let gate = SessionGateImpl()
        XCTAssertEqual(gate.begin(), gate.begin())
    }

    func testEnd_makesEveryEarlierTokenStale() {
        let gate = SessionGateImpl()
        let before = gate.begin()
        gate.end()
        XCTAssertFalse(gate.isCurrent(before))
    }

    /// A flow that starts while the lock's teardown runs must not count (challenge finding 1).
    func testBegin_onAClosedGate_isNeverCurrent() {
        let gate = SessionGateImpl()
        gate.end()
        let duringTeardown = gate.begin()
        XCTAssertFalse(gate.isCurrent(duringTeardown))
        gate.open()
        XCTAssertFalse(gate.isCurrent(duringTeardown), "opening must not revive a token handed out while closed")
    }

    func testOpen_startsAFreshEpoch() {
        let gate = SessionGateImpl()
        let before = gate.begin()
        gate.end()
        gate.open()
        let after = gate.begin()
        XCTAssertTrue(gate.isCurrent(after))
        XCTAssertNotEqual(before, after)
    }

    func testOpen_onAnOpenGate_keepsTheCurrentToken() {
        let gate = SessionGateImpl()
        let token = gate.begin()
        gate.open()
        XCTAssertTrue(gate.isCurrent(token))
    }

    func testIsOpen_followsEndAndOpen() {
        let gate = SessionGateImpl()
        XCTAssertTrue(gate.isOpen)
        gate.end()
        XCTAssertFalse(gate.isOpen)
        gate.open()
        XCTAssertTrue(gate.isOpen)
    }

    func testAToken_fromAnotherGate_isNeverCurrent() {
        let gate = SessionGateImpl()
        XCTAssertFalse(gate.isCurrent(SessionGateImpl().begin()))
        XCTAssertFalse(gate.isCurrent(FlowToken()))
    }

    /// Callable from any thread without an await (design D1, Swift 6 isolation).
    func testConcurrentAccess_endsWithTheLastEpoch() async {
        let gate = SessionGateImpl()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i % 2 == 0 { gate.end() } else { gate.open() }
                    _ = gate.isCurrent(gate.begin())
                }
            }
        }
        gate.open()
        XCTAssertTrue(gate.isCurrent(gate.begin()))
        gate.end()
        XCTAssertFalse(gate.isCurrent(gate.begin()))
    }
}
