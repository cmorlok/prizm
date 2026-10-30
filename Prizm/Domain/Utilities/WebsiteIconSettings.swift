import Foundation

/// The two website-icon settings, stored as UI preferences in `UserDefaults` like the clipboard
/// delay (fix-website-icons-privacy, design D2). `SettingsView` binds the keys with `@AppStorage`;
/// `FaviconLoader` and `FaviconView` read them where they act.
nonisolated enum WebsiteIconSettings {
    /// "Show website icons", default on (as in the official apps).
    static let showIconsKey = "icons.showWebsiteIcons"
    static let showIconsDefault = true
    /// "Allow icons from other services": follow the server's redirect to an outside icon service
    /// (design D5). Default off.
    static let allowOtherServicesKey = "icons.allowOtherServices"
    static let allowOtherServicesDefault = false

    static func showsIcons(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showIconsKey) as? Bool ?? showIconsDefault
    }

    static func allowsOtherServices(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: allowOtherServicesKey) as? Bool ?? allowOtherServicesDefault
    }
}
