import Foundation

// LEGACY(Bitwarden server < v2024.6.0): remove when those versions are no longer supported

/// The collection-change route of official servers that predate `PUT /ciphers/{id}/collections_v2`
/// (openspec change `fix-collection-assignment`, design D5a).
///
/// Bitwarden server v2024.1.0 to v2024.5.0 serve only `PUT /ciphers/{id}/collections`; it takes the
/// same body and answers with the cipher. `PrizmAPIClientImpl.updateCipherCollections` uses it only
/// when `collections_v2` answers 405, or 404 with an empty body: the route is missing. A 404 with an
/// error body is the server's "not found or not allowed" (for example an item with hidden passwords)
/// and is surfaced, so the fallback never bypasses a check the newer route makes. Vaultwarden has
/// `collections_v2` since 1.32.0 at least and never reaches this.
nonisolated enum LegacyCipherCollectionsEndpoint {
    /// Path below the server's base URL.
    static func path(id: String) -> String { "api/ciphers/\(id)/collections" }

    /// Whether the `collections_v2` failure means the server does not have that route.
    static func isFallback(for error: Error) -> Bool {
        guard case APIError.httpError(let statusCode, let body) = error else { return false }
        return statusCode == 405
            || (statusCode == 404 && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
