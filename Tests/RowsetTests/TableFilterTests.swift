import XCTest
@testable import Rowset

@MainActor
final class TableFilterTests: XCTestCase {

    private func connection() -> ConnectionModel {
        var bookmark = Bookmark()
        bookmark.name = "testing"
        bookmark.host = "example.rds.amazonaws.com"
        bookmark.database = "cube_testing"
        bookmark.username = "owner"
        bookmark.awsProfile = "profile"
        return ConnectionModel(bookmark: bookmark)
    }

    func testAnEmptyFilterMatchesNothing() {
        XCTAssertTrue(connection().tables(matching: "").isEmpty)
        XCTAssertTrue(connection().tables(matching: "   ").isEmpty)
    }

    func testTheCatalogQueryLeavesOutTheSystemSchemas() {
        // The SQL holds one backslash, so LIKE reads the underscore as itself.
        XCTAssertTrue(CatalogQueries.allTables(.postgres).contains("NOT LIKE 'pg\\_%'"))
        XCTAssertTrue(CatalogQueries.allTables(.postgres).contains("table_schema <> 'information_schema'"))
        XCTAssertTrue(CatalogQueries.allTables(.postgres).contains("ORDER BY table_schema, table_name"))
    }

    func testATableRefNamesItsSchemaAndTable() {
        let reference = TableRef(schema: "public", name: "component", isView: false)
        XCTAssertEqual(reference.id, "public.component")
        XCTAssertEqual(reference.symbolName, "tablecells")

        let view = TableRef(schema: "public", name: "v_component", isView: true)
        XCTAssertEqual(view.symbolName, "eye")
    }
}

@MainActor
final class BookmarkDuplicateTests: XCTestCase {

    private func temporaryStore() -> BookmarkStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rowset-bookmarks-\(UUID().uuidString).json")
        return BookmarkStore(fileURL: url)
    }

    func testUpsertKeepsTheOriginalAndAddsTheCopy() {
        let store = temporaryStore()
        var original = Bookmark()
        original.name = "concrete testing"
        original.host = "host"
        original.database = "cube_testing"
        original.username = "owner"
        original.awsProfile = "profile"
        store.upsert(original)

        var copy = original
        copy.id = UUID()
        copy.name = "\(original.displayName) copy"
        store.upsert(copy)

        XCTAssertEqual(store.bookmarks.count, 2)
        XCTAssertEqual(store.bookmarks[0].name, "concrete testing")
        XCTAssertEqual(store.bookmarks[1].name, "concrete testing copy")
        XCTAssertNotEqual(store.bookmarks[0].id, store.bookmarks[1].id)
        XCTAssertEqual(store.bookmarks[1].host, original.host, "the copy keeps every field")
        XCTAssertEqual(store.bookmarks[1].database, original.database)
    }
}
