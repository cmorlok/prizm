import Foundation

/// Decides which stored website URIs may be opened, and as what (openspec change safe-uri-launch).
///
/// Security goal: "Open in browser" must not launch arbitrary schemes from vault data, which other
/// organization members can write: `file:` opens local files and apps, `smb:` mounts shares,
/// custom schemes trigger whatever app registered them. Only the official clients' allow-list is
/// launched. Intentionally NOT done: checking that an allowed address is safe to visit; that is the
/// browser's job, as in the official clients.
nonisolated enum URILaunchPolicy {

    /// Schemes the official clients launch from cipher URIs, matched case-insensitively as prefixes:
    /// `UrlType.CipherUri` in `clients/libs/common/src/platform/misc/safe-urls.ts`.
    static let allowedPrefixes = [
        "https://", "http://", "ssh://", "ftp://", "sftp://", "irc://", "vnc://",
        "rdp://", "ms-rd:", "chrome://", "iosapp://", "androidapp://",
    ]

    /// The URL to open for `uri`, or nil when it must not be opened.
    ///
    /// - Regular-expression URIs are patterns, not addresses (`login-uri.view.ts`, `canLaunch`).
    /// - A URI without `://` whose host is `localhost`, an IP address or contains a dot gets
    ///   `http://` in front, as the TS clients' `launchUri` does. Their domain check uses a public
    ///   suffix list; this approximation also accepts unknown top-level domains (design D2).
    static func launchURL(for uri: LoginURI) -> URL? {
        guard uri.matchType != .regularExpression else { return nil }
        let trimmed = uri.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if !trimmed.contains("://"), let prefixed = URL(string: "http://" + trimmed),
           let host = prefixed.host(percentEncoded: false), hasDomain(host) {
            candidate = "http://" + trimmed
        }

        let lowercased = candidate.lowercased()
        guard allowedPrefixes.contains(where: { lowercased.hasPrefix($0) }) else { return nil }
        return URL(string: candidate)
    }

    private static func hasDomain(_ host: String) -> Bool {
        host.lowercased() == "localhost" || host.contains(".") || host.contains(":")  // ":" = IPv6
    }
}
