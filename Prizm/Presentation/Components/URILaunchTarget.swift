import AppKit

/// The URL behind a website row's "Open in browser" button, or nil for no button.
///
/// `URILaunchPolicy` (Domain) is the security control. This adds a UX check: no button when no app
/// on the Mac handles the scheme, for example `androidapp://` (safe-uri-launch, design D4).
enum URILaunchTarget {
    static func url(
        for uri: LoginURI,
        hasHandler: (URL) -> Bool = { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }
    ) -> URL? {
        guard let url = URILaunchPolicy.launchURL(for: uri), hasHandler(url) else { return nil }
        return url
    }
}
