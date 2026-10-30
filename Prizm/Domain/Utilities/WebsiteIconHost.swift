import Foundation

/// Turns a login's website URI into the host its icon is requested for, or `nil` when the URI is not
/// a website (fix-website-icons-privacy, design D3).
///
/// The rules of the official clients (`clients/libs/common/src/vault/icon/build-cipher-icon.ts:36-84`)
/// with three deliberate differences: only `http` and `https` count (TS also accepts `httpx://`); the
/// dot is required in the host, not anywhere in the URI, so dot-less intranet hosts such as
/// `http://nas/index.html` are not sent; and `.onion`/`.i2p` are checked on the host, so they are
/// also caught with a path.
nonisolated enum WebsiteIconHost {

    /// The host of a login's first website address, for every view that shows an icon.
    static func host(for item: VaultItem) -> String? {
        guard case .login(let login) = item.content, let first = login.firstAddress else { return nil }
        return host(for: first)
    }

    static func host(for uri: String) -> String? {
        var text = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("androidapp://") || lowered.hasPrefix("iosapp://") { return nil }
        // A scheme-less URI with a dot is a website (as TS does, `mailto:x@y.com` included).
        if !text.contains("://") {
            guard text.contains(".") else { return nil }
            text = "http://" + text
        }
        let scheme = text.prefix { $0 != ":" }.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        // `encodedHost` is the host as it goes on the wire: IDNA (punycode) for a non-ASCII name.
        guard let encoded = URLComponents(string: text)?.encodedHost?.lowercased(), !encoded.isEmpty else {
            return nil
        }
        let bare = encoded.hasSuffix(".") ? String(encoded.dropLast()) : encoded
        // At least two labels, none empty: "..", "a..b" and ".example.com" are not hosts
        // (security review 2026-10-30).
        let labels = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }
        guard !bare.hasSuffix(".onion"), !bare.hasSuffix(".i2p") else { return nil }
        // Without the trailing dot: one request path and one cache key per site.
        return bare
    }
}
