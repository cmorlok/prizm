import AppKit
import Synchronization
import os.log

// MARK: - FaviconLoader

/// Loads website icons from the signed-in server's icon service (fix-website-icons-privacy).
///
/// URL format: `{iconsBase}/{host}/icon.png`, where `iconsBase` is the account's
/// `ServerEnvironment.iconsURL` (`{base}/icons`, or the icons override). There is no default: the
/// Constitution's "Server URL" rule forbids a fallback to a bitwarden.com endpoint, so an
/// unconfigured loader sends nothing (design D1).
///
/// - Security goal: website host names reach only the user's own server. The session has no disk
///   cache and no cookies, and requests carry no credentials (D4). A redirect to another origin is
///   followed only when the user turned on "Allow icons from other services" (D5).
/// - Caching: an in-memory `NSCache` per session; `reset()` empties it on lock and sign-out, and a
///   request that outlives a reset is dropped (generation counter).
/// - Failures are silent: callers fall back to the item type's symbol (FR-009).
actor FaviconLoader {

    // MARK: - State

    private var session: URLSession
    /// The configured base, behind a lock so `configure` is synchronous: `RootViewModel` sets it
    /// before the vault is shown and clears it as a lock starts (code review 2026-10-30).
    private let base = Mutex<URL?>(nil)
    nonisolated var iconsBase: URL? { base.withLock { $0 } }
    /// Read by tests: the number of resets.
    private(set) var generation = 0
    private let protocolClasses: [AnyClass]
    private let defaultsSuiteName: String?
    private let logger = Logger(subsystem: "com.prizm", category: "FaviconLoader")
    private let cache = NSCache<NSString, NSImage>()
    /// One request per host: rows of the same site ask at the same time after an unlock.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// "Show website icons" as last seen, so turning it off resets the loader once.
    private var showedIcons: Bool
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    // MARK: - Init

    /// - Parameters:
    ///   - defaultsSuiteName: the `UserDefaults` suite the two icon settings are read from; `nil`
    ///     for `.standard`. A name, not a store, because a store is not `Sendable`.
    ///   - protocolClasses: URL protocols for tests; empty in the app.
    init(defaultsSuiteName: String? = nil, protocolClasses: [AnyClass] = []) {
        self.defaultsSuiteName = defaultsSuiteName
        self.protocolClasses = protocolClasses
        self.session = URLSession(configuration: Self.makeConfiguration(protocolClasses: protocolClasses))
        self.showedIcons = WebsiteIconSettings.showsIcons(in: Self.store(defaultsSuiteName))
        // The views stop asking while icons are off, so the loader itself drops what it holds when
        // the setting is turned off (D2; code review 2026-10-30). `object: nil`: the notification
        // names the store instance that changed, which need not be the one opened here.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.settingsChanged() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    private static func store(_ suiteName: String?) -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private var showsIcons: Bool { WebsiteIconSettings.showsIcons(in: Self.store(defaultsSuiteName)) }

    /// An ephemeral configuration without URL cache and cookies, so no icon response is kept on disk
    /// or in a shared cache, and none is sent with a cookie (D4).
    static func makeConfiguration(protocolClasses: [AnyClass]) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    // MARK: - Lifecycle

    /// Sets the icons base of the signed-in account, or `nil` (locked, signed out, UI-test mode).
    nonisolated func configure(iconsBase: URL?) {
        base.withLock { $0 = iconsBase }
    }

    /// Empties the cache, cancels running requests and makes any request still in flight drop its
    /// result. Called on lock, on sign-out and when icons are turned off.
    func reset() {
        generation += 1
        cache.removeAllObjects()
        inFlight.removeAll()
        session.invalidateAndCancel()
        session = URLSession(configuration: Self.makeConfiguration(protocolClasses: protocolClasses))
    }

    private func settingsChanged() {
        let shows = showsIcons
        if showedIcons, !shows { reset() }
        showedIcons = shows
    }

    // MARK: - Loading

    /// Returns the icon for `host` (from `WebsiteIconHost`), or `nil` on any failure, when no server
    /// is configured, or when website icons are off.
    func favicon(for host: String) async -> NSImage? {
        guard showsIcons, let iconsBase else { return nil }
        if let cached = cache.object(forKey: host as NSString) { return cached }
        if let running = inFlight[host] { return await running.value }

        let task = Task { await fetch(host: host, iconsBase: iconsBase, started: generation) }
        inFlight[host] = task
        let image = await task.value
        if inFlight[host] == task { inFlight[host] = nil }
        return image
    }

    private func fetch(host: String, iconsBase: URL, started: Int) async -> NSImage? {
        let url = iconsBase.appendingPathComponent(host).appendingPathComponent("icon.png")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10
        let policy = IconRedirectPolicy(
            iconsBase: iconsBase,
            allowsOtherServices: { [defaultsSuiteName] in
                WebsiteIconSettings.allowsOtherServices(in: Self.store(defaultsSuiteName))
            })

        do {
            let (data, response) = try await session.data(for: request, delegate: policy)
            // Dropped when a reset ran or icons were turned off while this request ran.
            guard started == generation, showsIcons else { return nil }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else {
                return nil
            }
            cache.setObject(image, forKey: host as NSString)
            return image
        } catch {
            logger.debug("Icon fetch failed: \(ErrorLog.describe(error), privacy: .public)")
            return nil
        }
    }
}

// MARK: - IconRedirectPolicy

/// Decides whether an icon request may follow a redirect (fix-website-icons-privacy, design D5).
///
/// - Security goal: a server whose admin set an external icon service (Vaultwarden `ICON_SERVICE`)
///   answers with a redirect; following it would send the website's host name and the user's IP
///   address to that service. A redirect within the server's own origin (scheme, host and port) is
///   followed; one to any other origin only when the user allowed other services. A refused
///   redirect leaves its 3xx response as the result, so no icon is shown.
nonisolated final class IconRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {

    private let origin: Origin?
    private let allowsOtherServices: @Sendable () -> Bool

    init(iconsBase: URL, allowsOtherServices: @escaping @Sendable () -> Bool) {
        self.origin = Origin(iconsBase)
        self.allowsOtherServices = allowsOtherServices
    }

    // The completion-handler form: the async form of this delegate method crashes the Swift 6.2
    // compiler while emitting its Objective-C thunk.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(follows(request) ? request : nil)
    }

    /// Another origin needs the user's permission and `https`: a redirect to plain `http` would send
    /// the website host over the network in clear text (code review 2026-10-30).
    func follows(_ request: URLRequest) -> Bool {
        guard let target = request.url else { return false }
        if let origin, Origin(target) == origin { return true }
        return target.scheme?.lowercased() == "https" && allowsOtherServices()
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        }
    }
}
