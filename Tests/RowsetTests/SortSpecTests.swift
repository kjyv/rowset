import XCTest
@testable import Rowset

final class SortSpecTests: XCTestCase {

    func testReadsAColumnAndADirection() {
        XCTAssertEqual(SortSpec.parse("created_at DESC"),
                       SortSpec(column: "created_at", ascending: false))
        XCTAssertEqual(SortSpec.parse("created_at ASC"),
                       SortSpec(column: "created_at", ascending: true))
    }

    func testTakesTheDirectionInAnyCase() {
        XCTAssertEqual(SortSpec.parse("slug desc"), SortSpec(column: "slug", ascending: false))
    }

    func testAColumnAloneSortsUp() {
        XCTAssertEqual(SortSpec.parse("slug"), SortSpec(column: "slug", ascending: true))
    }

    func testIgnoresTheSpaceAroundTheText() {
        XCTAssertEqual(SortSpec.parse("  slug   DESC  "),
                       SortSpec(column: "slug", ascending: false))
    }

    func testDropsTheQuotesOfAnIdentifier() {
        XCTAssertEqual(SortSpec.parse("\"slug\" ASC"), SortSpec(column: "slug", ascending: true))
    }

    func testRefusesANameWithASpace() {
        XCTAssertNil(SortSpec.parse("\"odd name\" ASC"))
    }

    /// The header arrow needs one column. Anything else still runs, but without an arrow.
    func testRefusesMoreThanOneColumn() {
        XCTAssertNil(SortSpec.parse("created_at DESC, id"))
        XCTAssertNil(SortSpec.parse("created_at, id"))
    }

    func testRefusesAnExpression() {
        XCTAssertNil(SortSpec.parse("lower(slug) ASC"))
        XCTAssertNil(SortSpec.parse("created_at NULLS LAST"))
    }

    func testRefusesEmptyText() {
        XCTAssertNil(SortSpec.parse(""))
        XCTAssertNil(SortSpec.parse("   "))
    }

    func testTextRoundTrips() {
        let spec = SortSpec(column: "created_at", ascending: false)
        XCTAssertEqual(spec.text, "created_at DESC")
        XCTAssertEqual(SortSpec.parse(spec.text), spec)
    }
}
