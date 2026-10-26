//
//  Config.swift
//  Prizm
//
//  Created by Benjamin Burzan on 16.03.26.
//

import Foundation

// MARK: - Vault lock notification

extension Notification.Name {
    /// Posted on the main thread whenever the vault is locked (sign-out or explicit lock).
    /// `ItemEditViewModel` subscribes to dismiss the edit sheet immediately, without a
    /// confirmation prompt, and clear the `DraftVaultItem` from memory (Constitution §III).
    static let vaultDidLock = Notification.Name("com.prizm.vaultDidLock")

    /// Posted on the main thread whenever the vault is successfully unlocked (password
    /// or biometric). `BiometricUnlockToggleViewModel` subscribes to clear a stale
    /// vault-locked disabled state on the Settings biometric toggle — see #67.
    static let vaultDidUnlock = Notification.Name("com.prizm.vaultDidUnlock")
}

// MARK: - App config

/// How Prizm identifies itself to the server (openspec change client-identification-headers).
/// Sent as headers on every request to the configured server and as token form fields.
nonisolated enum Config {
    /// `Bitwarden-Client-Name` and the token request's `client_id`: the official desktop app's
    /// client type, so both servers treat Prizm as a desktop client.
    static let clientName = "desktop"
    /// `Device-Type` and the token request's `deviceType`: 7 = MacOsDesktop
    /// (`server/src/Core/Enums/DeviceType.cs`). Without the header, Vaultwarden logs events as
    /// "Unknown Browser". The official server takes the device type from the access token's claim
    /// (already 7 through the token request), so there the header matters only before login.
    static let deviceType = 7
    /// `Bitwarden-Client-Version`: the official client version Prizm's API use is tested against.
    /// What it gates: Vaultwarden sends SSH key items (type 5) only to clients >= 2024.12.0. The
    /// official server gates newer features on it (for example v2 encryption at 2025.11.0, item
    /// types 6–8 at 2026.2.0); staying at 2024.12.0 keeps Prizm out of features it does not support.
    static let bitwardenClientVersion = "2024.12.0"

    /// `User-Agent`: Prizm's own version, not the Bitwarden compatibility version.
    static let userAgent = userAgent(
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        osVersion: ProcessInfo.processInfo.operatingSystemVersion
    )

    static func userAgent(appVersion: String, osVersion: OperatingSystemVersion) -> String {
        "Prizm/\(appVersion) (macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion))"
    }
}

/// Gates verbose debug logging throughout the Data layer.
///
/// Enable by adding `--debug-mode` to the Xcode scheme's Run → Arguments section,
/// or by passing it on the command line when launching from Terminal.
///
/// **Never enable in production builds** — debug output may contain field names, cipher counts
/// and HTTP response structure. It never contains key material, tokens, the password hash, the
/// email, two-factor codes or the device identifier; server-provided text is logged as private.
enum DebugConfig {
    // Safe to access from any isolation domain — Bool is Sendable and this is a let constant.
    static nonisolated let isEnabled: Bool = CommandLine.arguments.contains("--debug-mode")
}
