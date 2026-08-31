import XCTest
@testable import Rowset

final class CompletionEngineTests: XCTestCase {

    private let columns = ["created_at", "updated_at", "slug", "article_identifier", "article_name"]

    /// AppKit breaks a name at the underscore, so it offers only the last part as the word.
    /// The engine must still complete the whole name.
    func testCompletesAcrossAnUnderscore() {
        // Text "created_a", AppKit reports the word "a" at index 8.
        let tails = CompletionEngine.tails(
            in: "created_a",
            partialWordRange: NSRange(location: 8, length: 1),
            candidates: columns)
        // AppKit replaces its own range, so the answer covers that range and its ending.
        // Replacing "a" with "at" in "created_a" gives "created_at".
        XCTAssertEqual(tails, ["at"])
    }

    func testCompletesASimpleWord() {
        let tails = CompletionEngine.tails(
            in: "sl", partialWordRange: NSRange(location: 0, length: 2), candidates: columns)
        XCTAssertEqual(tails, ["slug"], "the range covers the whole word, so the answer does too")
    }

    func testOffersEveryMatchInOrder() {
        let tails = CompletionEngine.tails(
            in: "article_", partialWordRange: NSRange(location: 8, length: 0), candidates: columns)
        XCTAssertEqual(tails, ["identifier", "name"])
    }

    func testIgnoresTheCaseOfTheTypedText() {
        let tails = CompletionEngine.tails(
            in: "SL", partialWordRange: NSRange(location: 0, length: 2), candidates: columns)
        XCTAssertEqual(tails, ["SLug"], "the letters you typed keep their case")
    }

    /// A capital N must stay a capital N. Otherwise NULL turns into the n of a column name.
    func testKeepsTheCaseOfTheTypedLetters() {
        let tails = CompletionEngine.tails(
            in: "temp = N",
            partialWordRange: NSRange(location: 7, length: 1),
            candidates: ["name", "nickname"],
            keywords: SQLKeywords.filter)
        XCTAssertTrue(tails.contains("NULL"), "NULL must be reachable")
        XCTAssertTrue(tails.allSatisfy { $0.hasPrefix("N") }, "every answer keeps the capital N")
        // A word in capitals lists the SQL words before the column names.
        XCTAssertEqual(Array(tails.prefix(2)), ["NOT", "NULL"])
    }

    func testOffersSQLWordsBesideTheColumns() {
        let tails = CompletionEngine.tails(
            in: "is", partialWordRange: NSRange(location: 0, length: 2),
            candidates: ["issued_at"], keywords: SQLKeywords.filter)
        XCTAssertEqual(tails, ["issued_at"], "a lower case word offers the columns first")
    }

    func testOffersNothingInsideATextLiteral() {
        // "slug = 'cre" — inside the quotes a column name means nothing.
        let tails = CompletionEngine.tails(
            in: "slug = 'cre", partialWordRange: NSRange(location: 8, length: 3),
            candidates: columns)
        XCTAssertTrue(tails.isEmpty)
    }

    func testCompletesAgainAfterAClosedLiteral() {
        let text = "slug = 'x' AND cre"
        let tails = CompletionEngine.tails(
            in: text, partialWordRange: NSRange(location: 15, length: 3), candidates: columns)
        XCTAssertEqual(tails, ["created_at"])
    }

    func testStartsANewWordAfterAnOperator() {
        // "slug = cre" — the name starts after the space, not at the beginning of the line.
        let text = "slug = cre"
        let tails = CompletionEngine.tails(
            in: text, partialWordRange: NSRange(location: 7, length: 3), candidates: columns)
        XCTAssertEqual(tails, ["created_at"])
    }

    func testOffersNothingForAnExactName() {
        let tails = CompletionEngine.tails(
            in: "slug", partialWordRange: NSRange(location: 0, length: 4), candidates: columns)
        XCTAssertTrue(tails.isEmpty, "the name is already complete")
    }

    func testOffersNothingForAnEmptyWord() {
        XCTAssertTrue(CompletionEngine.tails(
            in: "", partialWordRange: NSRange(location: 0, length: 0), candidates: columns).isEmpty)
    }

    func testOffersNothingForAnUnknownWord() {
        let tails = CompletionEngine.tails(
            in: "zzz", partialWordRange: NSRange(location: 0, length: 3), candidates: columns)
        XCTAssertTrue(tails.isEmpty)
    }

    func testSurvivesARangeOutsideTheText() {
        let tails = CompletionEngine.tails(
            in: "ab", partialWordRange: NSRange(location: 5, length: 3), candidates: columns)
        XCTAssertTrue(tails.isEmpty)
    }

    func testIdentifierStartStopsAtAQuote() {
        let text = "slug = 'cre" as NSString
        XCTAssertEqual(CompletionEngine.identifierStart(in: text, before: 11), 8)
    }

    func testFindsATextLiteral() {
        XCTAssertTrue(CompletionEngine.isInsideStringLiteral("slug = 'cre" as NSString, before: 8))
        XCTAssertFalse(CompletionEngine.isInsideStringLiteral("slug = 'x' AND " as NSString, before: 15))
        // Postgres writes one quote inside a literal as two quotes.
        XCTAssertTrue(CompletionEngine.isInsideStringLiteral("a = 'it''s " as NSString, before: 11))
    }
}

final class FilterExampleTests: XCTestCase {

    private func column(_ name: String, _ type: String) -> ResultColumn {
        ResultColumn(id: 0, name: name, typeName: type)
    }

    func testReadsTheTypeFamily() {
        XCTAssertEqual(FilterExample.family(of: "character varying"), .text)
        XCTAssertEqual(FilterExample.family(of: "text"), .text)
        XCTAssertEqual(FilterExample.family(of: "timestamp with time zone"), .time)
        XCTAssertEqual(FilterExample.family(of: "date"), .time)
        XCTAssertEqual(FilterExample.family(of: "integer"), .number)
        XCTAssertEqual(FilterExample.family(of: "double precision"), .number)
        XCTAssertEqual(FilterExample.family(of: "boolean"), .boolean)
        XCTAssertEqual(FilterExample.family(of: "jsonb"), .other)
    }

    func testPrefersATextColumn() {
        let picked = FilterExample.pick(from: [
            column("created_at", "timestamp with time zone"),
            column("count", "integer"),
            column("slug", "character varying"),
        ])
        XCTAssertEqual(picked?.name, "slug")
    }

    func testFallsBackToATimeColumn() {
        let picked = FilterExample.pick(from: [
            column("count", "integer"),
            column("created_at", "timestamp with time zone"),
        ])
        XCTAssertEqual(picked?.name, "created_at")
    }

    func testBuildsAnExamplePerFamily() {
        XCTAssertEqual(FilterExample.text(for: column("slug", "text")), "slug = 'value'")
        XCTAssertEqual(
            FilterExample.text(for: column("created_at", "timestamp with time zone")),
            "created_at > '2024-01-01'")
        XCTAssertEqual(FilterExample.text(for: column("n", "integer")), "n = 0")
        XCTAssertEqual(FilterExample.text(for: column("ok", "boolean")), "ok IS TRUE")
        XCTAssertEqual(FilterExample.text(for: column("payload", "jsonb")), "payload IS NOT NULL")
    }

    func testNoColumnGivesNoPick() {
        XCTAssertNil(FilterExample.pick(from: []))
    }
}
