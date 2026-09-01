import XCTest
@testable import Rowset

@MainActor
final class ColumnOrderTests: XCTestCase {

    private func columns(_ names: [String]) -> [TreeNode] {
        names.enumerated().map { position, name in
            TreeNode(kind: .column(
                schema: "public", table: "batch", name: name, type: "text", nullable: true,
                position: position))
        }
    }

    private func titles(_ nodes: [TreeNode]) -> [String] {
        nodes.map(\.kind.title)
    }

    /// The database gives the columns in the order they were declared, and that order is right
    /// for reading a table.
    func testTheDefaultKeepsThePositionOfEachColumn() {
        let nodes = columns(["id", "created_at", "batch_index", "amount"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: false)),
            ["id", "created_at", "batch_index", "amount"])
    }

    func testSortingByNameOrdersThem() {
        let nodes = columns(["id", "created_at", "batch_index", "amount"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: true)),
            ["amount", "batch_index", "created_at", "id"])
    }

    /// A name with a number in it must read the way a person would.
    func testNumbersInANameCountAsNumbers() {
        let nodes = columns(["value_10", "value_2", "value_1"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: true)),
            ["value_1", "value_2", "value_10"])
    }

    func testTheCaseOfANameDoesNotSplitTheOrder() {
        let nodes = columns(["Beta", "alpha", "Gamma"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: true)), ["alpha", "Beta", "Gamma"])
    }

    func testAnEmptyListStaysEmpty() {
        XCTAssertTrue(ConnectionModel.ordered([], byName: true).isEmpty)
    }

    /// Sorting by name used to replace the list, which threw the catalog order away. Going back
    /// then changed nothing at all.
    func testTheOrderGoesBackToThePosition() {
        let nodes = columns(["id", "created_at", "batch_index", "amount"])
        let byName = ConnectionModel.ordered(nodes, byName: true)
        XCTAssertEqual(titles(byName), ["amount", "batch_index", "created_at", "id"])

        let back = ConnectionModel.ordered(byName, byName: false)
        XCTAssertEqual(titles(back), ["id", "created_at", "batch_index", "amount"])
    }

    // MARK: - The grid follows the same order

    private func tab(columns names: [String]) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "batch"), rowLimit: 25)
        tab.knownColumns = names.enumerated().map {
            ResultColumn(id: $0.offset, name: $0.element, typeName: "text")
        }
        return tab
    }

    func testThePlainQueryAsksForEveryColumn() {
        let tab = tab(columns: ["id", "created_at", "amount"])
        XCTAssertTrue(tab.selectedColumnNames.isEmpty)
        XCTAssertEqual(SQLBuilder.columnList(tab.selectedColumnNames), "*")
    }

    /// The grid follows a SELECT, so the query has to name the columns in the order it wants.
    func testSortingByNameNamesTheColumnsInOrder() {
        let tab = tab(columns: ["id", "created_at", "amount"])
        tab.sortsColumnsByName = true

        XCTAssertEqual(tab.selectedColumnNames, ["amount", "created_at", "id"])
        XCTAssertEqual(
            SQLBuilder.columnList(tab.selectedColumnNames),
            "\"amount\", \"created_at\", \"id\"")
    }

    func testTheQueryCarriesTheColumnList() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "batch", filter: "", orderBy: "", limit: 26,
            columns: ["amount", "id"])
        XCTAssertTrue(sql.hasPrefix("SELECT \"amount\", \"id\" FROM \"public\".\"batch\""))
    }

    func testAnOddColumnNameIsQuotedInTheList() {
        XCTAssertEqual(SQLBuilder.columnList(["odd name"]), "\"odd name\"")
    }

    func testTheOrderIsRememberedOnTheTable() {
        let table = TreeNode(kind: .table(schema: "public", name: "batch"))
        XCTAssertFalse(table.sortsColumnsByName, "the position is the default")

        table.sortsColumnsByName = true
        XCTAssertTrue(table.sortsColumnsByName)
    }
}

@MainActor
final class LargeValueTests: XCTestCase {

    private func tab(
        _ types: [(String, String)], key: [String] = ["id"], lengths: [String: Int] = [:]
    ) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "truck_data"), rowLimit: 25)
        tab.primaryKey = key
        tab.knownColumns = types.enumerated().map {
            ResultColumn(id: $0.offset, name: $0.element.0, typeName: $0.element.1)
        }
        tab.columnInfo = Dictionary(
            uniqueKeysWithValues: types.map {
                (
                    $0.0,
                    ColumnInfo(
                        name: $0.0, typeName: $0.1, isNullable: true,
                        maximumLength: lengths[$0.0])
                )
            })
        return tab
    }

    func testWhichTypesCountAsLarge() {
        func large(_ type: String, _ length: Int? = nil) -> Bool {
            ColumnInfo(name: "c", typeName: type, isNullable: true, maximumLength: length).isLarge
        }
        XCTAssertTrue(large("jsonb"))
        XCTAssertTrue(large("json"))
        XCTAssertTrue(large("ARRAY"))
        XCTAssertTrue(large("text"))
        XCTAssertTrue(large("bytea"))
        XCTAssertFalse(large("integer"))
        XCTAssertFalse(large("timestamp with time zone"))
        XCTAssertFalse(large("uuid"))
    }

    /// A `varchar` with no length holds as much as a `text`, so the length decides.
    func testTheLengthOfAVarcharDecides() {
        func large(_ length: Int?) -> Bool {
            ColumnInfo(
                name: "c", typeName: "character varying", isNullable: true,
                maximumLength: length
            ).isLarge
        }
        XCTAssertFalse(large(50))
        XCTAssertFalse(large(ColumnInfo.inlineValueSize))
        XCTAssertTrue(large(ColumnInfo.inlineValueSize + 1))
        XCTAssertTrue(large(nil))
    }

    /// Reading a large value is the whole cost, so the query asks for its size instead.
    func testALargeColumnAsksForItsSizeOnly() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        XCTAssertTrue(tab.cutsLargeValues)
        XCTAssertEqual(tab.selectExpressions, [
            "\"id\"",
            "pg_column_size(\"payload\")::text AS \"payload\"",
        ])
    }

    /// Without a key there is no way to ask for the rest of a row, so nothing may be left behind.
    func testATableWithoutAKeyAsksForEverything() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")], key: [])
        XCTAssertFalse(tab.cutsLargeValues)
        XCTAssertTrue(tab.selectExpressions.isEmpty, "an empty list means SELECT *")
    }

    func testATableWithoutALargeColumnAsksForEverything() {
        let tab = tab(
            [("id", "integer"), ("slug", "character varying")], lengths: ["slug": 50])
        XCTAssertFalse(tab.cutsLargeValues)
        XCTAssertTrue(tab.selectExpressions.isEmpty)
    }

    /// The key finds the row again, so the page must carry its value and not its size.
    func testTheKeyColumnIsNeverCut() {
        let tab = tab([("slug", "character varying"), ("payload", "jsonb")], key: ["slug"])
        XCTAssertTrue(tab.cutsLargeValues)
        XCTAssertFalse(tab.cuts("slug"))
        XCTAssertTrue(tab.cuts("payload"))
        XCTAssertEqual(tab.selectExpressions, [
            "\"slug\"",
            "pg_column_size(\"payload\")::text AS \"payload\"",
        ])
    }

    func testASizeBecomesAPlaceholder() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "payload", typeName: "jsonb"),
        ]
        result.rows = [
            ResultRow(id: 0, values: [
                DisplayValue.make(text: "1"), DisplayValue.make(text: "9818"),
            ]),
            ResultRow(id: 1, values: [DisplayValue.make(text: "2"), .null]),
        ]

        tab.markCutValues(in: &result)

        let placeholder = result.rows[0].values[1]
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertTrue(placeholder.isCut, "a click has to fetch the value behind it")
        XCTAssertEqual(placeholder.text, "9.6 kB")

        XCTAssertTrue(result.rows[1].values[1].isNull, "a NULL has no size and stays a NULL")
        XCTAssertFalse(result.rows[1].values[1].isCut)
        XCTAssertFalse(result.rows[0].values[0].isPlaceholder, "a small column keeps its value")
    }

    /// The page itself says which columns are small. The catalog does not: pg_stats reported an
    /// average of twenty bytes for a column whose values run to fifty kilobytes.
    func testTheSizesOfThePageSayWhichColumnsAreWorthReading() {
        let tab = tab([("id", "integer"), ("small", "jsonb"), ("big", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "small", typeName: "jsonb"),
            ResultColumn(id: 2, name: "big", typeName: "jsonb"),
        ]
        result.rows = [
            ResultRow(id: 0, values: [
                DisplayValue.make(text: "1"),
                DisplayValue.make(text: "40"),
                DisplayValue.make(text: "900"),
            ]),
            ResultRow(id: 1, values: [
                DisplayValue.make(text: "2"),
                DisplayValue.make(text: "1900"),
                DisplayValue.make(text: "\(QueryTab.pageByteBudget * 2)"),
            ]),
        ]

        let worthReading = tab.markCutValues(in: &result)
        XCTAssertEqual(worthReading, ["small"], "the sizes of the page decide")
    }

    /// Every value here fits in its row, so reading the column costs nothing at all.
    func testAColumnThatFitsInItsRowsIsAlwaysRead() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "payload", typeName: "jsonb"),
        ]
        result.rows = (0..<1000).map { index in
            ResultRow(id: index, values: [
                DisplayValue.make(text: "\(index)"),
                DisplayValue.make(text: "\(ColumnInfo.inlineValueSize)"),
            ])
        }

        XCTAssertEqual(tab.markCutValues(in: &result), ["payload"])
    }

    /// One value over the inline size no longer holds its whole column back.
    func testOneLargeValueDoesNotHoldTheWholeColumnBack() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "payload", typeName: "jsonb"),
        ]
        result.rows = (0..<3).map { index in
            ResultRow(id: index, values: [
                DisplayValue.make(text: "\(index)"),
                DisplayValue.make(text: index == 2 ? "5000" : "10"),
            ])
        }

        XCTAssertEqual(tab.markCutValues(in: &result), ["payload"])
    }

    /// The cheapest column comes first, and the page stops when it has spent its budget.
    func testThePageSpendsItsBudgetOnTheCheapestColumns() {
        let tab = tab([("id", "integer"), ("a", "jsonb"), ("b", "jsonb"), ("c", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "a", typeName: "jsonb"),
            ResultColumn(id: 2, name: "b", typeName: "jsonb"),
            ResultColumn(id: 3, name: "c", typeName: "jsonb"),
        ]
        let two = QueryTab.pageByteBudget / 2 + 1
        result.rows = [
            ResultRow(id: 0, values: [
                DisplayValue.make(text: "1"),
                DisplayValue.make(text: "\(two)"),
                DisplayValue.make(text: "\(QueryTab.pageByteBudget * 4)"),
                DisplayValue.make(text: "\(two)"),
            ])
        ]

        // Two halves of the budget do not both fit, and the largest never does.
        XCTAssertEqual(tab.markCutValues(in: &result).count, 1)
    }

    func testAColumnOfNullsIsWorthReading() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "payload", typeName: "jsonb"),
        ]
        result.rows = [ResultRow(id: 0, values: [DisplayValue.make(text: "1"), .null])]

        XCTAssertEqual(tab.markCutValues(in: &result), ["payload"], "nothing to hold back")
    }

    func testASizeReadsAtAGlance() {
        XCTAssertEqual(DisplayValue.sizeText(18), "18 B")
        XCTAssertEqual(DisplayValue.sizeText(1024), "1.0 kB")
        XCTAssertEqual(DisplayValue.sizeText(9818), "9.6 kB")
        XCTAssertEqual(DisplayValue.sizeText(3 * 1024 * 1024), "3.0 MB")
    }
}

final class ResultRevisionTests: XCTestCase {

    private func result() -> ResultSet {
        var set = ResultSet()
        set.columns = [ResultColumn(id: 0, name: "payload", typeName: "jsonb")]
        set.rows = [ResultRow(id: 0, values: [.placeholder(bytes: 9818)])]
        return set
    }

    /// A copy of a struct keeps the id, so the id alone cannot say a row changed. The grid used
    /// that id to decide whether to draw again, and a fetched value stayed hidden until the
    /// selection moved.
    func testACopyKeepsTheIdButCountsTheChange() {
        let original = result()
        var changed = original
        changed.rows[0].values = [DisplayValue.make(text: "{\"a\": 1}")]
        changed.revision += 1

        XCTAssertEqual(changed.id, original.id, "the id says nothing about the rows")
        XCTAssertNotEqual(changed.revision, original.revision, "the count does")
    }

    func testAFreshResultStartsAtZero() {
        XCTAssertEqual(ResultSet().revision, 0)
    }
}
