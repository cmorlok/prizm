import XCTest
@testable import Prizm

/// Labels for values Prizm keeps but cannot interpret (openspec change
/// `fix-read-mapping-lossless-fields`, design D2 and D3).
@MainActor
final class CustomFieldLabelTests: XCTestCase {

    func testNamelessField_isLabelledUnnamedField() {
        let field = CustomField(name: nil, value: "abc", type: .text, linkedId: nil)
        XCTAssertEqual(field.displayName, "Unnamed field")
        XCTAssertEqual(DraftCustomField(field).displayName, "Unnamed field")
        XCTAssertEqual(CustomField(name: "PIN", value: nil, type: .text, linkedId: nil).displayName, "PIN")
    }

    func testUnknownFieldType_isLabelledUnsupported() {
        let field = CustomField(name: "Future", value: "v9", type: .unknown(9), linkedId: nil)
        XCTAssertEqual(field.unsupportedLabel, "Future (Unsupported field type)")
    }

    func testUnknownLinkedTarget_isUnknownField() {
        XCTAssertEqual(LinkedFieldId.unknown(999).displayName, "Unknown field")
        XCTAssertEqual(LinkedFieldId.unknownDisplayName, "Unknown field")
    }

    func testUnknownMatchRule_isNamedButNeverOffered() {
        XCTAssertEqual(URIMatchType.unknown(7).displayName, "Unknown match rule")
        XCTAssertFalse(URIMatchType.allCases.contains(.unknown(7)))
        XCTAssertEqual(URIMatchType.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])
    }
}
