import Foundation

// MARK: - SSHKeyMaterial

/// The three values of an SSH key item, written together (openspec change
/// `ssh-key-import-and-generation`, design D2).
///
/// - `privateKey`: unencrypted OpenSSH private key text (`openssh-key-v1`), `\n` line endings,
///   trailing newline.
/// - `publicKey`: OpenSSH public key text without comment, `ssh-ed25519 <base64>`.
/// - `fingerprint`: `SHA256:` + unpadded base64 of the SHA-256 of the public key blob, as
///   `ssh-keygen -l` prints it.
///
/// Its description never contains key text (design D7), so it is safe in logs and test output.
nonisolated struct SSHKeyMaterial: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let privateKey: String
    let publicKey: String
    let fingerprint: String

    var description: String { "SSHKeyMaterial(redacted)" }
    var debugDescription: String { description }
}

// MARK: - SSHKeyError

/// Why Prizm refused an SSH private key it was asked to import, one case per check of design D4.
/// Carries no key text.
nonisolated enum SSHKeyError: Error, Equatable, Sendable {
    /// Not an OpenSSH private key at all: no armour, not base64, or larger than 16 KiB.
    case notOpenSSHKey
    /// An OpenSSH key protected by a passphrase. Prizm cannot decrypt it without new crypto code.
    case passphraseProtected
    /// A key in another format (PEM, PKCS#8, PuTTY) or a file with more than one key.
    case unsupportedFormat(SSHKeyFormat)
    /// A key type other than Ed25519: its name ("RSA", "ECDSA", "DSA"), or nil for a type Prizm does
    /// not know. Never the raw type text of the input.
    case unsupportedKeyType(String?)
    /// A key that lives on a security key such as a YubiKey (`sk-…` types).
    case securityKey
    /// The key's structure is broken: a length that runs past the end, unequal check integers,
    /// wrong padding, or bytes after the key.
    case damaged
    /// The public key does not belong to the private key.
    case inconsistent
    /// The system could not generate a key.
    case generationFailed

    /// Plain language plus a next step; shown in the create sheet and announced by VoiceOver.
    var userMessage: String {
        switch self {
        case .notOpenSSHKey:
            return "This is not an OpenSSH private key. Copy the whole key, from \"-----BEGIN OPENSSH PRIVATE KEY-----\" to the END line."
        case .passphraseProtected:
            return "This key is protected by a passphrase, which Prizm can't import yet. Remove the passphrase with \"ssh-keygen -p\" and import it again."
        case .unsupportedFormat(.multipleKeys):
            return "This file holds more than one key. Prizm can import one OpenSSH private key at a time. Export the key you need with \"ssh-keygen\" and import it again."
        case .unsupportedFormat(let format):
            let found = format.name.map { "This key is in \($0) format. " } ?? ""
            return found + "Prizm can import only OpenSSH private keys. Convert the key with \"ssh-keygen\" and import it again."
        case .unsupportedKeyType(let name):
            let found = name.map { "This key's type is \($0). " } ?? ""
            return found + "Prizm can import only Ed25519 keys for now. Use an Ed25519 key, or generate a new one."
        case .securityKey:
            return "This key belongs to a security key, such as a YubiKey, and can't be stored in a vault. Generate a new key instead."
        case .damaged:
            return "This key is damaged and can't be imported. Copy it again from its original file."
        case .inconsistent:
            return "The public key in this file does not belong to its private key, so Prizm won't import it."
        case .generationFailed:
            return "Prizm could not generate a key. Try again."
        }
    }
}

// MARK: - SSHKeyFormat

/// The key formats Prizm recognises but does not import, named in the refusal.
nonisolated enum SSHKeyFormat: Equatable, Sendable {
    /// `-----BEGIN RSA PRIVATE KEY-----`, `BEGIN EC PRIVATE KEY` and other PEM armours.
    case pem
    /// `-----BEGIN PRIVATE KEY-----` or `BEGIN ENCRYPTED PRIVATE KEY`.
    case pkcs8
    /// `PuTTY-User-Key-File-…`.
    case putty
    /// An OpenSSH key file with more than one key.
    case multipleKeys
    /// An OpenSSH armour around another container.
    case other

    /// The name shown to the user; nil when there is none to show.
    var name: String? {
        switch self {
        case .pem:   return "PEM"
        case .pkcs8: return "PKCS#8"
        case .putty: return "PuTTY"
        case .multipleKeys, .other: return nil
        }
    }
}

// MARK: - SSHKeyService

/// Generates, imports and fingerprints SSH keys. Implemented in the Data layer with CryptoKit; the
/// Domain sees only strings (design D2).
nonisolated protocol SSHKeyService: Sendable {
    /// A new Ed25519 key with its public key and fingerprint.
    func generate() throws(SSHKeyError) -> SSHKeyMaterial

    /// Checks an OpenSSH private key and returns it with its public key and fingerprint. The private
    /// key text is a new armour of the checked bytes (70-column base64, `\n` line endings, trailing
    /// newline); the bytes, comment included, are unchanged.
    func parse(privateKeyText: String) throws(SSHKeyError) -> SSHKeyMaterial

    /// The fingerprint of an OpenSSH public key text (`<type> <base64> [comment]`), or nil when the
    /// text does not have that form.
    func fingerprint(forPublicKey publicKey: String) -> String?
}
