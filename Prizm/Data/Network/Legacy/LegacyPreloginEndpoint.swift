import Foundation

// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.12.0): remove when those versions are no longer supported

/// The prelogin route of servers that predate `POST /identity/accounts/prelogin/password`
/// (openspec change fix-prelogin-identity-endpoint, design D2).
///
/// Vaultwarden 1.32.0–1.35.x and Bitwarden servers before v2025.12.0 serve only
/// `POST /identity/accounts/prelogin`; it takes the same body and returns the same KDF settings.
/// `PrizmAPIClientImpl.preLogin` uses it only when the primary route answers 404 or 405. Any
/// other failure is surfaced, so a broken server is not hidden behind the fallback.
///
/// Intentionally not used: `/api/accounts/prelogin`. Every server that has it also has this
/// identity route, and Vaultwarden 1.37.4 and Bitwarden v2025.1.0 removed it.
nonisolated enum LegacyPreloginEndpoint {
    /// Path below the server's base URL.
    static let path = "identity/accounts/prelogin"

    /// Whether the primary route's failure means the server does not have that route yet.
    static func isFallback(for error: Error) -> Bool {
        guard case APIError.httpError(let statusCode, _) = error else { return false }
        return statusCode == 404 || statusCode == 405
    }
}
