import CryptoKit
import Foundation

// MARK: - SSHKeyServiceImpl

/// Generates, imports and fingerprints Ed25519 SSH keys in OpenSSH's own formats, with CryptoKit and
/// Foundation only (openspec change `ssh-key-import-and-generation`, design D1–D4).
///
/// - Security goal: every SSH key Prizm stores has a private key, public key and fingerprint that
///   belong together, so other clients and SSH agents never get a pair that does not match; and
///   untrusted input (clipboard, file) cannot crash Prizm or slip a mismatched pair in.
/// - Formats: the private key container `openssh-key-v1` (OpenSSH `PROTOCOL.key`), the public key
///   blob of RFC 8709 §4 (`string "ssh-ed25519"`, `string key`) with the wire encoding of RFC 4251
///   §5, and the fingerprint `SHA256:` + unpadded base64 (RFC 4648 §4) of SHA-256 (FIPS 180-4) over
///   that blob, as `ssh-keygen -l` prints it.
/// - Algorithms: Ed25519 (RFC 8032) from CryptoKit `Curve25519.Signing`, SHA-256 from CryptoKit. No
///   own implementation of either; this file only reads and writes length-prefixed fields.
/// - Intentionally NOT done: passphrase-protected keys (`bcrypt_pbkdf` is not in Apple's frameworks
///   and may not be hand-written, Constitution §III), RSA, ECDSA, PEM and PKCS#8 (design Non-Goals).
///   They are refused with a typed error, never guessed at.
/// - Secrets: key text never reaches a log or an error (`SSHKeyMaterial` prints redacted,
///   `SSHKeyError` carries no input text). Zeroing is best effort: the byte arrays this file holds
///   are zeroed, but CryptoKit's own copy of the key, Foundation temporaries (`Data`, base64
///   strings) and the returned Swift `String`s cannot be, the same limit as the rest of the app
///   (design D7).
nonisolated struct SSHKeyServiceImpl: SSHKeyService {

    enum Format {
        static let maxInputBytes = 16 * 1024
        static let beginLine = "-----BEGIN OPENSSH PRIVATE KEY-----"
        static let endLine = "-----END OPENSSH PRIVATE KEY-----"
        static let magic = Array("openssh-key-v1\0".utf8)
        static let keyType = "ssh-ed25519"
        /// FIDO security key types (`sk-ssh-ed25519@openssh.com`, `sk-ecdsa-…`): the private key
        /// stays on the device, so there is nothing to store in a vault.
        static let securityKeyPrefix = "sk-"
        static let none = "none"
        /// Armour line width `ssh-keygen` writes.
        static let lineWidth = 70
        /// The private section is padded to this block size when it is not encrypted.
        static let blockSize = 8
        static let publicKeyLength = 32
        /// Ed25519 private key in OpenSSH: 32-byte seed followed by the 32-byte public key.
        static let privateKeyLength = 64
    }

    // MARK: - Generate (design D3)

    func generate() throws(SSHKeyError) -> SSHKeyMaterial {
        let key = Curve25519.Signing.PrivateKey()
        var seed = [UInt8](key.rawRepresentation)
        defer { seed.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let publicKey = [UInt8](key.publicKey.rawRepresentation)
        guard seed.count == Format.publicKeyLength, publicKey.count == Format.publicKeyLength else {
            throw .generationFailed
        }
        // Equal check integers let a reader detect a wrong passphrase; random, as OpenSSH writes them.
        var generator = SystemRandomNumberGenerator()
        let check = UInt32.random(in: .min ... .max, using: &generator)

        let blob = Self.publicKeyBlob(publicKey)
        var section = SSHWireWriter()
        section.uint32(check)
        section.uint32(check)
        section.string(Array(Format.keyType.utf8))
        section.string(publicKey)
        section.string(seed + publicKey)
        section.string([])  // empty comment (design Open Question 3)
        section.pad(toMultipleOf: Format.blockSize)
        defer { section.wipe() }

        var container = SSHWireWriter()
        container.raw(Format.magic)
        container.string(Array(Format.none.utf8))
        container.string(Array(Format.none.utf8))
        container.string([])
        container.uint32(1)
        container.string(blob)
        container.string(section.bytes)
        defer { container.wipe() }

        return SSHKeyMaterial(privateKey: Self.armour(container.bytes),
                              publicKey: Self.publicKeyText(blob),
                              fingerprint: Self.fingerprint(ofBlob: blob))
    }

    // MARK: - Import (design D4)

    func parse(privateKeyText: String) throws(SSHKeyError) -> SSHKeyMaterial {
        // Check 0: size, and key formats Prizm recognises but does not import.
        guard privateKeyText.utf8.count <= Format.maxInputBytes else { throw .notOpenSSHKey }
        let text = privateKeyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(Format.beginLine) else {
            throw Self.otherKeyFormat(text).map(SSHKeyError.unsupportedFormat) ?? .notOpenSSHKey
        }

        // Check 1: one armour pair with base64 between the lines.
        guard text.hasSuffix(Format.endLine), text.count > Format.beginLine.count + Format.endLine.count else {
            throw .notOpenSSHKey
        }
        let base64 = text.dropFirst(Format.beginLine.count).dropLast(Format.endLine.count)
        guard !base64.contains("-----") else { throw .notOpenSSHKey }
        guard var decoded = Data(base64Encoded: String(base64.filter { !$0.isWhitespace })).map([UInt8].init) else {
            throw .notOpenSSHKey
        }
        defer { decoded.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }

        // Check 2: magic; a body cut off inside it is damaged, another magic is another format.
        guard decoded.starts(with: Format.magic) else {
            throw Format.magic.starts(with: decoded) ? .damaged : .unsupportedFormat(.other)
        }
        var reader = SSHWireReader(decoded, from: Format.magic.count)
        let cipher = try reader.string()
        let kdf = try reader.string()
        let kdfOptions = try reader.string()

        // Check 3: exactly one key.
        guard try reader.uint32() == 1 else { throw .unsupportedFormat(.multipleKeys) }

        // Check 4: an Ed25519 public key, before the cipher, so an encrypted RSA key is named as RSA.
        let blob = try reader.string()
        let publicKey = try Self.ed25519PublicKey(inBlob: blob)

        // Check 5: not encrypted, and no kdf.
        guard cipher == Array(Format.none.utf8) else { throw .passphraseProtected }
        guard kdf == Array(Format.none.utf8), kdfOptions.isEmpty else { throw .damaged }

        // Check 6: the private section is the last field and a whole number of blocks.
        var section = try reader.string()
        defer { section.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard reader.isAtEnd, !section.isEmpty, section.count % Format.blockSize == 0 else { throw .damaged }

        // Check 7: equal check integers.
        var inner = SSHWireReader(section)
        let check1 = try inner.uint32()
        let check2 = try inner.uint32()
        guard check1 == check2 else { throw .damaged }

        // Check 8: the inner key is the outer one, and the 64-byte private key ends with it.
        guard try inner.string() == Array(Format.keyType.utf8) else { throw .inconsistent }
        let innerPublicKey = try inner.string()
        var privateKey = try inner.string()
        defer { privateKey.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard privateKey.count == Format.privateKeyLength else { throw .damaged }
        guard innerPublicKey == publicKey, Array(privateKey[Format.publicKeyLength...]) == publicKey else {
            throw .inconsistent
        }

        // Check 9: the public key derives from the seed, so the pair belongs together.
        let derived: [UInt8]
        do {
            derived = [UInt8](try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKey[..<Format.publicKeyLength]).publicKey.rawRepresentation)
        } catch {
            throw .damaged
        }
        guard derived == publicKey else { throw .inconsistent }

        // Check 10: a readable comment, then padding 1, 2, 3, … and nothing else.
        _ = try inner.string()
        let padding = Array(inner.remaining)
        guard padding.count < Format.blockSize, padding == (0..<padding.count).map({ UInt8($0 + 1) }) else {
            throw .damaged
        }

        // A new armour of the checked bytes, so OpenSSH and other clients can load what was accepted
        // (design D4, "Stored text"). The bytes, and with them the comment, are unchanged.
        return SSHKeyMaterial(privateKey: Self.armour(decoded),
                              publicKey: Self.publicKeyText(blob),
                              fingerprint: Self.fingerprint(ofBlob: blob))
    }

    // MARK: - Fingerprint

    func fingerprint(forPublicKey publicKey: String) -> String? {
        Self.fingerprint(forPublicKey: publicKey)
    }

    /// Static, so `CipherMapper` can fill in a missing fingerprint without a new dependency
    /// (design D5).
    static func fingerprint(forPublicKey publicKey: String) -> String? {
        let fields = publicKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])).map([UInt8].init) else {
            return nil
        }
        // The blob must name the same key type as the text in front of it, as in authorized_keys.
        var reader = SSHWireReader(blob)
        guard let type = try? reader.string(), type == Array(fields[0].utf8) else { return nil }
        return fingerprint(ofBlob: blob)
    }

    // MARK: - Helpers

    /// The 32-byte key of an `ssh-ed25519` public key blob; throws for another type or shape.
    private static func ed25519PublicKey(inBlob blob: [UInt8]) throws(SSHKeyError) -> [UInt8] {
        var reader = SSHWireReader(blob)
        let type = try reader.string()
        guard type == Array(Format.keyType.utf8) else {
            if type.starts(with: Array(Format.securityKeyPrefix.utf8)) { throw .securityKey }
            throw .unsupportedKeyType(Self.keyTypeName(type))
        }
        let key = try reader.string()
        guard key.count == Format.publicKeyLength, reader.isAtEnd else { throw .damaged }
        return key
    }

    private static func publicKeyBlob(_ key: [UInt8]) -> [UInt8] {
        var writer = SSHWireWriter()
        writer.string(Array(Format.keyType.utf8))
        writer.string(key)
        return writer.bytes
    }

    private static func publicKeyText(_ blob: [UInt8]) -> String {
        "\(Format.keyType) \(Data(blob).base64EncodedString())"
    }

    private static func fingerprint(ofBlob blob: [UInt8]) -> String {
        let hash = Data(SHA256.hash(data: Data(blob))).base64EncodedString()
        return "SHA256:" + hash.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func armour(_ bytes: [UInt8]) -> String {
        let base64 = Data(bytes).base64EncodedString()
        var lines = [Format.beginLine]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: Format.lineWidth, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append(Format.endLine)
        return lines.joined(separator: "\n") + "\n"
    }

    /// PEM, PKCS#8 and PuTTY keys: recognisable, but not importable (design D4, check 0).
    private static func otherKeyFormat(_ text: String) -> SSHKeyFormat? {
        if text.hasPrefix("PuTTY-User-Key-File-") { return .putty }
        if text.hasPrefix("-----BEGIN PRIVATE KEY-----") || text.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
            return .pkcs8
        }
        return text.hasPrefix("-----BEGIN ") ? .pem : nil
    }

    /// A readable name for the key types users meet; nil for any other, so no input text is shown.
    private static func keyTypeName(_ type: [UInt8]) -> String? {
        switch String(decoding: type, as: UTF8.self) {
        case "ssh-rsa": return "RSA"
        case "ssh-dss": return "DSA"
        case let name where name.hasPrefix("ecdsa-sha2-"): return "ECDSA"
        default: return nil
        }
    }
}

// MARK: - Wire encoding (RFC 4251 §5)

/// Reads `uint32` and `string` fields. Every read is bounds-checked against the bytes that remain;
/// a length that runs past the end throws `damaged` instead of trapping (design D4).
private nonisolated struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ bytes: [UInt8], from offset: Int = 0) {
        self.bytes = bytes
        self.offset = min(offset, bytes.count)
    }

    var isAtEnd: Bool { offset == bytes.count }
    var remaining: ArraySlice<UInt8> { bytes[offset...] }

    mutating func uint32() throws(SSHKeyError) -> UInt32 {
        guard bytes.count - offset >= 4 else { throw .damaged }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func string() throws(SSHKeyError) -> [UInt8] {
        let length = Int(try uint32())
        guard length <= bytes.count - offset else { throw .damaged }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }
}

/// Writes `uint32` and `string` fields, and the private section's padding.
private nonisolated struct SSHWireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func raw(_ value: [UInt8]) { bytes += value }

    mutating func uint32(_ value: UInt32) {
        bytes += [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    mutating func string(_ value: [UInt8]) {
        uint32(UInt32(value.count))
        bytes += value
    }

    /// OpenSSH pads with 1, 2, 3, … until the length is a multiple of `blockSize`.
    mutating func pad(toMultipleOf blockSize: Int) {
        var next: UInt8 = 1
        while bytes.count % blockSize != 0 {
            bytes.append(next)
            next += 1
        }
    }

    /// Zeroes the buffer, which may hold the seed.
    mutating func wipe() {
        bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }
}
