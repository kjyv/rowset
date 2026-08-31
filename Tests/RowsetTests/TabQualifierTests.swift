import XCTest
@testable import Rowset

@MainActor
final class TabQualifierTests: XCTestCase {

    private func model(bookmarkCount: Int) -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rowset-qual-\(UUID().uuidString).json")
        let model = AppModel(store: BookmarkStore(fileURL: url))
        for index in 0..<bookmarkCount {
            var bookmark = Bookmark()
            bookmark.name = "database \(index)"
            bookmark.host = "host"
            bookmark.database = "db\(index)"
            bookmark.username = "owner"
            bookmark.awsProfile = "profile"
            model.store.upsert(bookmark)
        }
        return model
    }

    private func tab(
        _ model: AppModel, schema: String, table: String, connection: String
    ) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(),
            connectionName: connection,
            kind: .table(schema: schema, name: table),
            rowLimit: 50)
        model.tabs.append(tab)
        return tab
    }

    func testOneConnectionAndOneTableNeedsNoQualifier() {
        let model = model(bookmarkCount: 1)
        let tab = tab(model, schema: "public", table: "component", connection: "testing")
        XCTAssertNil(model.qualifier(for: tab))
    }

    func testTwoConnectionsNameTheDatabase() {
        let model = model(bookmarkCount: 2)
        let tab = tab(model, schema: "public", table: "component", connection: "testing")
        XCTAssertEqual(model.qualifier(for: tab), "testing")
    }

    func testTwoSchemasWithTheSameTableNameAddTheSchema() {
        let model = model(bookmarkCount: 1)
        let first = tab(model, schema: "public", table: "batch", connection: "testing")
        let second = tab(model, schema: "reporting", table: "batch", connection: "testing")
        XCTAssertEqual(model.qualifier(for: first), "public")
        XCTAssertEqual(model.qualifier(for: second), "reporting")
    }

    func testTheSameSchemaTwiceNeedsNoSchema() {
        let model = model(bookmarkCount: 1)
        let first = tab(model, schema: "public", table: "batch", connection: "testing")
        _ = tab(model, schema: "public", table: "other", connection: "testing")
        XCTAssertNil(model.qualifier(for: first))
    }

    func testBothRulesTogether() {
        let model = model(bookmarkCount: 2)
        let first = tab(model, schema: "public", table: "batch", connection: "testing")
        _ = tab(model, schema: "reporting", table: "batch", connection: "staging")
        XCTAssertEqual(model.qualifier(for: first), "public · testing")
    }

    func testAQueryTabNamesItsDatabase() {
        let model = model(bookmarkCount: 2)
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "staging", kind: .sql, rowLimit: 50)
        model.tabs.append(tab)
        XCTAssertEqual(model.qualifier(for: tab), "staging")
    }
}
