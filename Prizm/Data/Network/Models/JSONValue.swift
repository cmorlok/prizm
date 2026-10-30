import Foundation

// MARK: - Why this file exists
//
// Other Bitwarden clients store data in a cipher that Prizm does not model (passkeys, password
// history, flags such as `autofillOnPageLoad`, keys a newer server adds). A wire model that decodes
// only the fields Prizm knows and encodes them again silently drops the rest, so a later edit would
// erase it on the server. `JSONValue` holds such data as opaque JSON, and `WireExtras` / `WireWriter`
// move it between a struct's JSON object and an `extras` dictionary without touching it.
//
// Preserved values are server ciphertext (EncStrings) and plain flags or dates. They are never
// decrypted, parsed into typed structs or logged here.
//
// Four limits are deliberate and pinned by `JSONValueTests`:
// - Numbers are read as `Int64` first, then `Double`. `1.0`, `1e2` and `-0` therefore come back as
//   `1`, `100` and `0` (equal as JSON numbers, not as text), and a number above `Int64.max` becomes
//   a lossy `Double`. Real preserved data is not numeric in this way (EncStrings and ISO dates).
// - A number that fits no Swift number type (`1e999`) is not read: the decode throws. Where a
//   value is decoded with `try` (`WireExtras.capture`, `archivedDate`, `passwordHistory`) that
//   fails the record and with it the whole sync; where it is decoded with `try?` (such as
//   `lenientString` and `encryptedFor`) the value is dropped. So "a wrong type never aborts a
//   sync" in the comments of the wire models holds for every JSON type except such a number.
//   No server sends one; keeping it as text would need a number case that stores the digits.
// - Nesting deeper than `JSONValue.maxNesting` levels is refused: the decode throws. `init(from:)`
//   recurses with several stack frames per level and a sync is decoded on a pool thread with a
//   small stack: 500 nested brackets crashed the test host there, so a hostile server could crash
//   the app. `JSONDecoder` alone allows 512 levels. Real preserved data nests three or four.
// - `null` is kept distinct from an absent key. `decodeIfPresent` turns `null` into `nil`, which is
//   why this file decodes with `decode` after a `contains` check wherever the difference matters.

// MARK: - JSONValue

/// Any JSON value, kept exactly as received (see the limits above).
///
/// `nonisolated` + `Sendable`: a decoded record crosses actor boundaries (sync, repository, store)
/// as an immutable value.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Deepest `codingPath` a value may sit at. It counts the keys and indices of the records
    /// around the value too, which leaves about 60 levels for the value itself. The error of a
    /// refused value names the last shape tried, not the depth, because the array attempt below
    /// is a `try?`.
    static let maxNesting = 64

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= Self.maxNesting else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "JSON is nested deeper than \(Self.maxNesting) levels"
            ))
        }
        let container = try decoder.singleValueContainer()
        // Order matters: Bool before numbers (no Bool/number bridging in JSONDecoder, but be
        // explicit), Int64 before Double so integers above 2^53 stay exact.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:             try container.encodeNil()
        case .bool(let value):   try container.encode(value)
        case .int(let value):    try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value):  try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Redaction

/// Wire values print as their type name and nothing else, in `String(describing:)`,
/// `String(reflecting:)`, interpolation and `dump` (Constitution III: secrets must not appear in
/// logs). Ciphertext and plain metadata are not printed either: a log line is no place for a vault
/// record, and the synthesized description of these structs would print every field. Tests compare
/// wire values through key paths, not through their descriptions.
///
/// `nonisolated`: under the module's default main-actor isolation, the default implementations
/// below would be main-actor isolated and fail to compile for nonisolated types.
nonisolated protocol RedactedWireModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}

nonisolated extension RedactedWireModel {
    var description: String { "\(Self.self)(redacted)" }
    var debugDescription: String { description }
    /// No children, so `dump` and the debugger show nothing of the contents either.
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

nonisolated extension JSONValue: RedactedWireModel {}

// MARK: - Dynamic-key coding helpers

/// A coding key built from any string, so a struct can read and write keys it does not know.
nonisolated struct WireKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Reads the part of a JSON object a struct does not model.
nonisolated enum WireExtras {

    /// Every key that is neither `known` nor `excluded`, decoded as opaque JSON. `decode` (not
    /// `decodeIfPresent`) keeps a JSON `null` as `.null`, so it is written back as `null`.
    static func capture(
        from container: KeyedDecodingContainer<WireKey>,
        known: Set<String>,
        excluded: Set<String>
    ) throws -> [String: JSONValue] {
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) && !excluded.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extras
    }

    /// A typed `String` field added after the model shipped. A value of another type must not abort
    /// the whole sync (the sync decodes all ciphers or none), so it is kept as JSON in `extras` and
    /// the typed field stays nil; the writer then emits it unchanged. A JSON `null` stays nil. The
    /// one exception is a number that fits no Swift number type (see the limits above): it is
    /// dropped, not kept.
    static func lenientString(
        _ container: KeyedDecodingContainer<WireKey>,
        _ name: String,
        extras: inout [String: JSONValue]
    ) -> String? {
        let key = WireKey(name)
        guard container.contains(key) else { return nil }
        if let string = try? container.decode(String.self, forKey: key) { return string }
        if let raw = try? container.decode(JSONValue.self, forKey: key), raw != .null { extras[name] = raw }
        return nil
    }
}

/// Writes a struct's typed fields first, then its extras, so a key cannot be forgotten in a
/// hand-written `encode(to:)` and an extras entry can never shadow a typed field.
nonisolated struct WireWriter {
    private var container: KeyedEncodingContainer<WireKey>
    private var written = Set<String>()

    init(_ encoder: Encoder) {
        container = encoder.container(keyedBy: WireKey.self)
    }

    /// Writes `value` under `name` unless it is nil (a typed nil is omitted, as the synthesized
    /// encoder does).
    mutating func put<T: Encodable>(_ value: T?, _ name: String) throws {
        guard let value else { return }
        try container.encode(value, forKey: WireKey(name))
        written.insert(name)
    }

    /// Writes `value` under `name`, and an explicit `null` when it is nil. For the members the
    /// official clients send as `null` and Prizm must not drop: Vaultwarden stores the request
    /// JSON as sent, so an omitted key stays absent on the server (fix-read-mapping-lossless-fields;
    /// live rig 2026-10-30).
    mutating func putOrNull<T: Encodable>(_ value: T?, _ name: String) throws {
        if let value { try container.encode(value, forKey: WireKey(name)) } else { try container.encodeNil(forKey: WireKey(name)) }
        written.insert(name)
    }

    /// Writes every extras entry that is not already written and not excluded.
    mutating func putExtras(_ extras: [String: JSONValue], excluded: Set<String>) throws {
        for (name, value) in extras where !written.contains(name) && !excluded.contains(name) {
            try container.encode(value, forKey: WireKey(name))
        }
    }
}
