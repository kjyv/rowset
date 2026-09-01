import XCTest
@testable import Rowset

/// Opens a table the way the app opens it, and checks what the grid holds afterwards.
///
/// The other live tests build their statements from the same parts the app uses. This one runs
/// the app itself, so a mistake between the parts cannot hide.
@MainActor
final class LiveGridTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rowset-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func environment(_ key: String) throws -> String {
        guard let found = ProcessInfo.processInfo.environment[key], !found.isEmpty else {
            throw XCTSkip("\(key) is not set")
        }
        return found
    }

    /// An app that keeps its files in a temporary directory, not in the real one.
    private func app() throws -> (AppModel, ConnectionModel) {
        var bookmark = Bookmark()
        bookmark.name = "live"
        bookmark.host = try environment("ROWSET_LIVE_HOST")
        bookmark.database = try environment("ROWSET_LIVE_DB")
        bookmark.username = try environment("ROWSET_LIVE_USER")
        bookmark.awsProfile = try environment("ROWSET_LIVE_PROFILE")
        bookmark.awsRegion = ProcessInfo.processInfo.environment["ROWSET_LIVE_REGION"]
            ?? "eu-central-1"

        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("session.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("buffers.json")))
        let connection = ConnectionModel(bookmark: bookmark)
        model.connections[connection.id] = connection
        return (model, connection)
    }

    /// A column whose values are all small must show its values, not their sizes.
    func testASmallColumnFillsItsCells() async throws {
        let table = try environment("ROWSET_MEASURE_TABLE")
        let limit = Int(ProcessInfo.processInfo.environment["ROWSET_MEASURE_LIMIT"] ?? "") ?? 50
        let (model, connection) = try app()

        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }
        XCTAssertTrue(connection.state.isConnected, "\(connection.state)")

        let tab = model.openTable(schema: "public", name: table, connection: connection)
        tab.rowLimit = limit
        let start = DispatchTime.now()
        await model.runTableQuery(tab)
        let seconds = Double(
            DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        print(String(format: "MEASURE open %@ rows=%d in %.2fs", table, limit, seconds))

        let result = try XCTUnwrap(tab.result)
        XCTAssertFalse(result.rows.isEmpty, "\(table) gave no rows")

        var spent = 0
        for (index, column) in result.columns.enumerated() {
            let values = result.rows.map { $0.value(at: index) }
            let placeholders = values.filter(\.isPlaceholder).count
            guard placeholders > 0 else { continue }
            let total = values.reduce(0) { $0 + ($1.bytes ?? 0) }
            spent += total
            print("MEASURE \(column.name): \(placeholders) stand-ins,"
                + " \(DisplayValue.sizeText(total)) on this page")
            XCTAssertGreaterThan(
                total, QueryTab.pageByteBudget / result.columns.count,
                "\(column.name) is cheap to read, so its cells must show their values")
        }
        print("MEASURE left on the server: \(DisplayValue.sizeText(spent))")
    }
}
