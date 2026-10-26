import AppKit
import Foundation
import Observation
import os.log

// MARK: - ClipboardService

/// Every Copy button and menu command goes through one app-wide service (openspec change
/// clipboard-hardening).
///
/// Security goal: a copied password or code is hidden from clipboard history and does not stay on
/// the clipboard longer than the user's chosen delay, nor beyond lock, sign-out or quit.
/// Intentionally NOT done: other processes can read the pasteboard during the delay, and
/// Universal Clipboard (Handoff) is not blocked; macOS offers no way to prevent either. Text the
/// user selects and copies with ⌘C is copied by the system, not by this service.
@MainActor
protocol ClipboardService: AnyObject {
    /// Puts `value` on the clipboard, hidden from clipboard history, and schedules the clear.
    func copy(_ value: String)
    /// Clears the clipboard now if it still holds the value Prizm put there; returns whether it did.
    @discardableResult
    func clearIfOwned() -> Bool
}

// MARK: - ClipboardClearDelay

/// How long a copied secret stays on the clipboard. The options are those of the official clients;
/// Prizm keeps its 30-second default (the official default is 5 minutes).
nonisolated enum ClipboardClearDelay: String, CaseIterable, Identifiable {
    case never, seconds10, seconds20, seconds30, minutes1, minutes2, minutes5

    static let defaultsKey = "clipboard.clearDelay"
    static let defaultValue: ClipboardClearDelay = .seconds30

    var id: String { rawValue }

    /// Nil for `.never`: no timer. Lock, sign-out and quit still clear.
    var duration: Duration? {
        switch self {
        case .never:     return nil
        case .seconds10: return .seconds(10)
        case .seconds20: return .seconds(20)
        case .seconds30: return .seconds(30)
        case .minutes1:  return .seconds(60)
        case .minutes2:  return .seconds(120)
        case .minutes5:  return .seconds(300)
        }
    }

    var label: String {
        switch self {
        case .never:     return "Never"
        case .seconds10: return "10 seconds"
        case .seconds20: return "20 seconds"
        case .seconds30: return "30 seconds"
        case .minutes1:  return "1 minute"
        case .minutes2:  return "2 minutes"
        case .minutes5:  return "5 minutes"
        }
    }

    static func current(in defaults: UserDefaults) -> ClipboardClearDelay {
        defaults.string(forKey: defaultsKey).flatMap(ClipboardClearDelay.init(rawValue:)) ?? defaultValue
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

// MARK: - Pasteboard access

/// The pasteboard operations the service needs, so tests can use a double.
@MainActor
protocol PasteboardWriting: AnyObject {
    var changeCount: Int { get }
    /// Replaces the contents with `value`, flagged as concealed; returns the new change count.
    func writeConcealed(_ value: String) -> Int
    func clear()
}

/// `NSPasteboard` with the nspasteboard.org concealed marker.
@MainActor
final class SystemPasteboard: PasteboardWriting {
    /// Pasteboard type from the nspasteboard.org convention (http://nspasteboard.org). Clipboard
    /// managers that honor it, such as most password-aware ones, skip items carrying it.
    nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func writeConcealed(_ value: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // The marker's value is ignored by consumers; only its presence matters.
        pasteboard.setString("", forType: Self.concealedType)
        return pasteboard.changeCount
    }

    func clear() {
        pasteboard.clearContents()
    }
}

// MARK: - ClipboardServiceImpl

/// Created once by `AppContainer`. `@Observable` only so SwiftUI views deep in the edit sheet can
/// reach the one instance through the environment (`EditFieldRow`).
@Observable
@MainActor
final class ClipboardServiceImpl: ClipboardService {

    @ObservationIgnored private let pasteboard: any PasteboardWriting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "com.prizm", category: "Clipboard")

    /// The pasteboard's change count right after our last write. The secret itself is not kept:
    /// "still ours" means nothing else has written since (the official clients' rule too).
    @ObservationIgnored private var ownedChangeCount: Int?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(pasteboard: any PasteboardWriting = SystemPasteboard(),
         defaults: UserDefaults = .standard,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.sleep = sleep
    }

    func copy(_ value: String) {
        clearTask?.cancel()
        clearTask = nil
        let owned = pasteboard.writeConcealed(value)
        ownedChangeCount = owned
        guard let delay = ClipboardClearDelay.current(in: defaults).duration else { return }
        clearTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }  // cancelled by a newer copy
            guard let self, self.ownedChangeCount == owned else { return }
            if self.clearIfOwned() { self.logger.debug("Clipboard auto-cleared") }
        }
    }

    @discardableResult
    func clearIfOwned() -> Bool {
        clearTask?.cancel()
        clearTask = nil
        defer { ownedChangeCount = nil }
        guard let owned = ownedChangeCount, pasteboard.changeCount == owned else { return false }
        pasteboard.clear()
        return true
    }
}
