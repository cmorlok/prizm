import XCTest
@testable import Prizm

/// `JSONValue` holds server data Prizm does not model, so what it keeps and where it deviates is
/// pinned here: integers and doubles stay apart, bools are not numbers, null is not absent.
/// The limit rows (`1.0`, `1e2`, `-0`, numbers above `Int64.max`) document what the decoder does;
/// they were first observed on Linux swift-foundation and must hold on the Mac as well.
final class JSONValueTests: XCTestCase {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encodedObject(_ value: JSONValue) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    func testIntegersAndDoublesStayApart() throws {
        XCTAssertEqual(try decode("[1, 0.1, -7, 2.5]"), .array([.int(1), .double(0.1), .int(-7), .double(2.5)]))
        XCTAssertNotEqual(JSONValue.int(1), JSONValue.double(1))
    }

    func testBoolsAndNumbersStayApart() throws {
        XCTAssertEqual(try decode("[true, false, 1, 0]"),
                       .array([.bool(true), .bool(false), .int(1), .int(0)]))
    }

    func testNullDecodesAndReencodesAsNull() throws {
        let value = try decode(#"{"present":null}"#)
        XCTAssertEqual(value, .object(["present": .null]))

        let encoded = try XCTUnwrap(try encodedObject(value) as? [String: Any])
        XCTAssertEqual(encoded.count, 1)
        XCTAssertTrue(encoded["present"] is NSNull, "null must stay present, not become absent")
        XCTAssertNotEqual(JSONValue.object(["present": .null]), JSONValue.object([:]))
    }

    func testNestingAndUnicodeSurvive() throws {
        let json = #"{"a":[{"b":["éé 😀","a/b",{"c":[]}]}],"e":""}"#
        let value = try decode(json)

        XCTAssertEqual(value, .object([
            "a": .array([.object(["b": .array([.string("éé 😀"), .string("a/b"), .object(["c": .array([])])])])]),
            "e": .string(""),
        ]))
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    /// The documented limits of reading numbers as `Int64` first. These values are equal as JSON
    /// numbers, not byte-identical; real preserved data is EncStrings and ISO dates, not numbers.
    func testNumberNormalisationLimits() throws {
        let normalised = try decode("[1.0, 1e2, -0, 9223372036854775807, 9223372036854775808]")

        guard case .array(let items) = normalised, items.count == 5 else {
            return XCTFail("Expected five numbers")
        }
        XCTAssertEqual(items[0], .int(1), "1.0 decodes as an integer")
        XCTAssertEqual(items[1], .int(100), "1e2 decodes as an integer")
        XCTAssertEqual(items[2], .int(0), "-0 decodes as an integer 0")
        XCTAssertEqual(items[3], .int(Int64.max), "Int64.max stays exact")
        guard case .double = items[4] else {
            return XCTFail("A number above Int64.max becomes a (lossy) double")
        }
    }

    /// A number that fits no Swift number type is not read at all: the decode throws instead of
    /// keeping it as text. Real preserved data never looks like this; the test pins what the header
    /// of `JSONValue.swift` says, so a decode that must not fail (`try`) is known to fail here.
    func testNumberNoSwiftTypeHolds_failsTheDecode() {
        for json in ["1e999", "-1e999", "[1, 1e999]", #"{"n":1e999}"#] {
            XCTAssertThrowsError(try decode(json), "\(json) is not representable") { error in
                XCTAssertTrue(error is DecodingError, "Expected a DecodingError, got \(type(of: error))")
            }
        }
    }

    /// Nesting within `JSONValue.maxNesting` round-trips byte for byte on a cooperative-pool thread.
    /// The real decode of a sync runs on an actor, so it runs on such a thread too; its stack is far
    /// smaller than the main thread's.
    func testNestingWithinTheLimit_roundTripsOnAPoolThread() async throws {
        let depth = JSONValue.maxNesting - 4
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let objects = String(repeating: #"{"a":"#, count: depth) + "0" + String(repeating: "}", count: depth)

        let results = try await Task.detached { () -> [Bool] in
            try [arrays, objects].map { json in
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
                let encoded = try JSONEncoder().encode(value)
                return String(decoding: encoded, as: UTF8.self) == json
            }
        }.value

        XCTAssertEqual(results, [true, true], "depth \(depth) comes back byte for byte, arrays and objects")
    }

    /// Nesting just under the cap of Foundation's decoder (512) used to recurse through
    /// `JSONValue.init` until the pool thread's stack ran out and the process died. It is refused
    /// with a `DecodingError` instead.
    func testNestingBeyondTheLimit_isRefusedOnAPoolThreadInsteadOfCrashing() async {
        let depth = 500
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let objects = String(repeating: #"{"a":"#, count: depth) + "0" + String(repeating: "}", count: depth)

        let refused = await Task.detached { () -> [Bool] in
            [arrays, objects].map { json in
                do {
                    _ = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
                    return false
                } catch {
                    return error is DecodingError
                }
            }
        }.value

        XCTAssertEqual(refused, [true, true], "depth \(depth) throws a DecodingError, arrays and objects")
    }

    /// Hostile nesting must fail the decode, not crash the process. At this depth the decode fails
    /// whichever of Foundation's cap (512 levels at the time of writing) and `JSONValue.maxNesting`
    /// comes first; the limit of `JSONValue` itself is pinned by the two tests above.
    func testNestingBeyondTheDecoderCapThrows() {
        let depth = 513
        let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)

        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertTrue(error is DecodingError, "Expected a DecodingError, got \(type(of: error))")
        }
    }
}
