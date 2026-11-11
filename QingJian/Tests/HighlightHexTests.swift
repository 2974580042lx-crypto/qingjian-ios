import XCTest
@testable import DeepSeekCore

final class HighlightHexTests: XCTestCase {
    func testAcceptsShortAndFullHEX() {
        XCTAssertEqual(HighlightHex.normalized(" #fc0 \n"), "#FFCC00")
        XCTAssertEqual(HighlightHex.normalized("a1b2c3"), "#A1B2C3")
        XCTAssertEqual(HighlightHex.rgb("#000000"), 0)
        XCTAssertEqual(HighlightHex.rgb("FFFFFF"), 0xFFFFFF)
    }
    func testRejectsInvalidOrIncompleteValuesWithoutGuessing() {
        for value in ["", "#", "FFN000", "#12345", "#12345678", "##123456", "１２３", "red"] {
            XCTAssertNil(HighlightHex.normalized(value), value)
        }
    }
}
