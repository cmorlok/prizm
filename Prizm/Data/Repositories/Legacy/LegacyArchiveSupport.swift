import Foundation

// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.10.0): remove when those versions are no longer supported

/// How Prizm treats servers without archive (openspec change `archived-items`, design D5). On a
/// server with archive neither rule changes anything: every record carries the `archivedDate` key,
/// and its archive endpoints never answer 404 without a message.
nonisolated enum LegacyArchiveSupport {

    /// False only when records exist and none carries the `archivedDate` key (Vaultwarden 1.35.4
    /// and older send none). An empty vault counts as supported: there is nothing to tell from,
    /// and the next create answer settles it.
    static func isSupported(records: [RawCipher]) -> Bool {
        records.isEmpty || records.contains { $0.archivedDate != nil }
    }

    /// A 404 without a server message is a server without the endpoint; any other error, a 404
    /// that names its reason (the item is gone or not accessible) among them, passes unchanged.
    static func error(for error: Error) -> Error {
        if case APIError.httpError(statusCode: 404, let body) = error,
           APIError.serverMessage(statusCode: 404, body: body) == nil {
            return VaultError.archiveUnsupported
        }
        return error
    }
}
