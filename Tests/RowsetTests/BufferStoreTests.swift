import XCTest
@testable import Rowset

final class SQLBufferTitleTests: XCTestCase {

    private func title(_ text: String) -> String {
        SQLBuffer(text: text).title
    }

    func testTheFirstLineNamesTheBuffer() {
        XCTAssertEqual(title("SELECT * FROM batch\nWHERE id = 1"), "SELECT * FROM batch")
    }

    func testEmptyLinesAtTheTopAreSkipped() {
        XCTAssertEqual(title("\n\n   \nSELECT 1"), "SELECT 1")
    }

    func testAnEmptyBufferSaysSo() {
        XCTAssertEqual(title(""), "Empty query")
        XCTAssertEqual(title("\n\n   "), "Empty query")
    }

    func testALongLineIsCut() {
        let long = String(repeating: "a", count: 80)
        let result = title(long)
        XCTAssertEqual(result.count, 45, "44 characters and an ellipsis")
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testTheNameFollowsTheText() {
        var buffer = SQLBuffer(text: "SELECT 1")
        XCTAssertEqual(buffer.title, "SELECT 1")
        buffer.text = "SELECT 2"
        XCTAssertEqual(buffer.title, "SELECT 2", "no rename needed, the text is the name")
    }
}

@MainActor
final class BufferStoreTests: XCTestCase {

    private func store() -> BufferStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rowset-buffers-\(UUID().uuidString).json")
        return BufferStore(fileURL: url)
    }

    func testANewStoreHoldsNothing() {
        XCTAssertTrue(store().buffers(for: UUID()).isEmpty)
    }

    func testABufferBelongsToOneConnection() {
        let store = store()
        let first = UUID()
        let second = UUID()

        store.create(for: first, text: "SELECT 1")
        XCTAssertEqual(store.buffers(for: first).count, 1)
        XCTAssertTrue(store.buffers(for: second).isEmpty, "another database sees nothing of it")
    }

    func testTheTextIsWrittenBack() {
        let store = store()
        let connection = UUID()
        let buffer = store.create(for: connection, text: "SELECT 1")

        store.setText("SELECT 2", id: buffer.id, for: connection)
        XCTAssertEqual(store.buffer(id: buffer.id, for: connection)?.text, "SELECT 2")
    }

    func testTheOneYouTouchedLastComesFirst() async throws {
        let store = store()
        let connection = UUID()
        let first = store.create(for: connection, text: "one")
        let second = store.create(for: connection, text: "two")

        try await Task.sleep(for: .milliseconds(10))
        store.setText("one again", id: first.id, for: connection)

        XCTAssertEqual(store.buffers(for: connection).map(\.id), [first.id, second.id])
    }

    func testAnUnchangedTextDoesNotChangeTheOrder() async throws {
        let store = store()
        let connection = UUID()
        let first = store.create(for: connection, text: "one")
        try await Task.sleep(for: .milliseconds(10))
        let second = store.create(for: connection, text: "two")

        store.setText("one", id: first.id, for: connection)
        XCTAssertEqual(
            store.buffers(for: connection).map(\.id), [second.id, first.id],
            "writing the same text is not a change")
    }

    func testDeleting() {
        let store = store()
        let connection = UUID()
        let buffer = store.create(for: connection, text: "one")
        store.create(for: connection, text: "two")

        store.delete(id: buffer.id, for: connection)
        XCTAssertEqual(store.buffers(for: connection).count, 1)
        XCTAssertNil(store.buffer(id: buffer.id, for: connection))
    }

    func testDroppingAConnectionDropsItsBuffers() {
        let store = store()
        let connection = UUID()
        store.create(for: connection, text: "one")
        store.removeAll(for: connection)
        XCTAssertTrue(store.buffers(for: connection).isEmpty)
    }

    func testWritingAndReadingTheFile() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rowset-buffers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let connection = UUID()
        let first = BufferStore(fileURL: url)
        let buffer = first.create(for: connection, text: "SELECT 1")
        first.saveNow()

        let second = BufferStore(fileURL: url)
        XCTAssertEqual(second.buffers(for: connection).count, 1)
        XCTAssertEqual(second.buffer(id: buffer.id, for: connection)?.text, "SELECT 1")
    }

    func testABrokenFileLeavesAnEmptyStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rowset-buffers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(BufferStore(fileURL: url).buffers(for: UUID()).isEmpty)
    }
}
