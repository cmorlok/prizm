import Foundation
@testable import Prizm

/// A seeded pseudo-random `RandomnessProvider` (SplitMix64) for distribution tests. Unlike
/// `MockRandomnessProvider`, which cycles 0–255 and so yields only 64 distinct 32-bit values, it
/// covers the whole range; the fixed seed keeps every test deterministic. Never a secret source.
final class SeededRandomnessProvider: RandomnessProvider, @unchecked Sendable {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64 (Steele, Lea, Flood 2014), the reference constants.
    private func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    func randomBytes(count: Int) throws -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(count)
        while result.count < count {
            var value = next()
            for _ in 0..<8 where result.count < count {
                result.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }
        return result
    }
}

/// Returns scripted 32-bit values, big-endian, 4 bytes per value; fails when they run out.
final class ScriptedUInt32Provider: RandomnessProvider, @unchecked Sendable {

    struct Exhausted: Error {}

    private var values: [UInt32]
    private(set) var drawn = 0

    init(_ values: [UInt32]) {
        self.values = values
    }

    func randomBytes(count: Int) throws -> [UInt8] {
        precondition(count == 4, "scripted values are 32-bit draws")
        guard !values.isEmpty else { throw Exhausted() }
        let value = values.removeFirst()
        drawn += 1
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
