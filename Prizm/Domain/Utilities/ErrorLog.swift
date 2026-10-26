import Foundation

/// An error that can describe itself for public logs without any message, body or user data.
nonisolated protocol LogSafeError: Error {
    var logDescription: String { get }
}

/// Log-safe descriptions of errors (openspec change server-error-texts, design D2).
///
/// Security goal: public log entries (`privacy: .public`) are readable by any process on the Mac
/// and end up in sysdiagnose archives, so they must not carry what an error's message can carry:
/// a server response body, a quoted e-mail address, a decoded value, a file path.
/// What is intentionally NOT done: logging `localizedDescription`, even for "harmless" errors. The
/// status, URL error code or type and case identify the failing path; debug mode covers the rest.
nonisolated enum ErrorLog {

    static func describe(_ error: Error) -> String {
        if let safe = error as? LogSafeError { return safe.logDescription }
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        // For a Swift error the bridge gives the type name and a per-case code, without associated
        // values; for an Objective-C error its domain and code. Errors whose details matter for
        // diagnosis (a status code) conform to `LogSafeError` instead.
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }
}
