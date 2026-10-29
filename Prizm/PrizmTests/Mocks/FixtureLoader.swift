import Foundation

/// Loads the JSON fixtures of `PrizmTests/Fixtures` by flat file name (without extension).
///
/// Xcode copies the fixtures flat into the test bundle's resources, and the test host is sandboxed,
/// so they are found with `Bundle(for:)` on a class of the test target, never through `#filePath`
/// (see `Fixtures/README.md`, "Loading the fixtures in tests"). A class is needed for `Bundle(for:)`,
/// and file names must be unique across the target.
final class FixtureLoader {

    struct MissingFixture: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixture \(name).json is not in the test bundle's resources" }
    }

    static func data(named name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLoader.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MissingFixture(name: name)
        }
        return try Data(contentsOf: url)
    }
}
