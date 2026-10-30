import SwiftUI

// MARK: - FaviconView

/// Displays a favicon for a given domain, falling back to a per-type SF Symbol (FR-009, FR-032).
///
/// The image is loaded asynchronously via `FaviconLoader`. If the load fails, the domain is nil or
/// "Show website icons" is off, the SF Symbol for `itemType` is shown instead
/// (fix-website-icons-privacy, D2).
///
/// Usage:
/// ```swift
/// FaviconView(domain: "github.com", itemType: .login, loader: container.faviconLoader)
///     .frame(width: 16, height: 16)
/// ```
struct FaviconView: View {

    let domain:   String?
    let itemType: ItemType
    let loader:   FaviconLoader
    var size:     CGFloat = 16

    @State private var image: NSImage? = nil

    @AppStorage(WebsiteIconSettings.showIconsKey)
    private var showsIcons: Bool = WebsiteIconSettings.showIconsDefault

    /// The `.task(id:)` key: a change of domain or of the setting reloads the icon.
    nonisolated struct TaskKey: Equatable {
        let domain: String?
        let showsIcons: Bool
    }

    /// The host to load, or `nil` when there is none or icons are off.
    nonisolated static func loadTarget(domain: String?, showsIcons: Bool) -> String? {
        showsIcons ? domain : nil
    }

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Image(systemName: itemType.sfSymbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: TaskKey(domain: domain, showsIcons: showsIcons)) {
            // Clears an icon already on screen when the setting is turned off.
            guard let target = Self.loadTarget(domain: domain, showsIcons: showsIcons) else {
                image = nil
                return
            }
            image = await loader.favicon(for: target)
        }
    }
}
