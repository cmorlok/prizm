import XCTest

extension XCTestCase {
    /// A `UserDefaults` store of this test's own, removed when the test ends
    /// (fix-biometric-test-isolation, D2).
    ///
    /// Unit tests are hosted in the app, so `UserDefaults.standard` is the developer's real Prizm
    /// preferences, shared by test classes running in parallel processes. One name per test method
    /// and call site (a test runs in one process at a time; stores made in `setUp` and in the test
    /// body stay apart), emptied at the start too, so a crashed run leaves nothing behind and the
    /// number of suite files stays bounded (code review 2026-10-30; a UUID per call would add a file
    /// on every run).
    func makePrivateDefaults(file: StaticString = #fileID, line: UInt = #line) -> UserDefaults {
        let site = "\(file)\(line)\(name)".filter { $0.isLetter || $0.isNumber }
        let suiteName = "PrizmTests.\(site)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) refused \(suiteName)")
        }
        store.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return store
    }
}
