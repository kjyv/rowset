import Foundation
import SQLite3

/// Holds one open SQLite database file.
///
/// It uses the SQLite that macOS ships, through the C API, so the app carries no extra
/// dependency for it. One connection serves the whole app, the same as the Postgres side, and the
/// actor keeps the calls to it in order.
actor SQLiteSession: DatabaseSession {
    let bookmark: Bookmark

    private var handle: OpaquePointer?
    private let openHandle = HandleBox()

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
    }

    var isOpen: Bool { handle != nil }

    // MARK: - Lifecycle

    func connect() async throws {
        guard handle == nil else { return }

        let path = bookmark.filePath
        guard !path.isEmpty else { throw SQLiteError.noFile }
        guard FileManager.default.fileExists(atPath: path) else {
            throw SQLiteError.fileMissing(path)
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(opened)
            throw SQLiteError.open(path: path, message: message)
        }

        // Wait rather than fail when another program holds the file.
        sqlite3_busy_timeout(opened, 3_000)
        handle = opened
        openHandle.set(opened)
    }

    func close() async {
        guard let handle else { return }
        // Clear the box first. A cancel must not reach a handle that is on its way out.
        openHandle.set(nil)
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    /// Stops the statement that runs now.
    ///
    /// `sqlite3_step` holds the actor for the whole statement, so this never waits for isolation.
    /// SQLite documents `sqlite3_interrupt` as safe from another thread.
    nonisolated func cancelRunningQuery() async {
        openHandle.interrupt()
    }

    // MARK: - Queries

    /// Runs one statement. The app splits a console into statements and sends them one by one,
    /// which is what `sqlite3_prepare_v2` reads: it compiles the first statement of the text.
    func query(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn] = []
    ) async throws -> ResultSet {
        guard let handle else { throw SessionError.notConnected }

        let start = DispatchTime.now()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.statement(message(handle))
        }
        defer { sqlite3_finalize(statement) }

        var result = ResultSet()
        result.columns = expectedColumns

        var index = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                // An interrupt arrives as the step result or as the handle's error code.
                if step == SQLITE_INTERRUPT || sqlite3_errcode(handle) == SQLITE_INTERRUPT {
                    throw QueryCanceled()
                }
                throw SQLiteError.statement(message(handle))
            }

            if index >= maxRows {
                result.truncated = true
                break
            }
            if index == 0 { result.columns = columns(of: statement) }
            result.rows.append(ResultRow(id: index, values: values(of: statement)))
            index += 1
        }

        // A statement that gave no row still names its columns, unlike the Postgres wire format.
        if result.rows.isEmpty, let statement {
            let named = columns(of: statement)
            if !named.isEmpty { result.columns = named }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        result.duration = Double(elapsed) / 1_000_000_000
        return result
    }

    func runTransaction(_ statements: [String]) async throws {
        guard !statements.isEmpty else { return }
        guard handle != nil else { throw SessionError.notConnected }

        _ = try await query("BEGIN", maxRows: 0, expectedColumns: [])
        do {
            for (index, sql) in statements.enumerated() {
                let result = try await query(sql, maxRows: 2, expectedColumns: [])
                guard result.rows.count == 1 else {
                    throw SessionError.wrongRowCount(
                        statement: index + 1, count: result.rows.count)
                }
            }
        } catch {
            _ = try? await query("ROLLBACK", maxRows: 0, expectedColumns: [])
            throw error
        }
        _ = try await query("COMMIT", maxRows: 0, expectedColumns: [])
    }

    // MARK: - Reading a row

    private func columns(of statement: OpaquePointer?) -> [ResultColumn] {
        let count = Int(sqlite3_column_count(statement))
        return (0..<count).map { index in
            let position = Int32(index)
            let name = sqlite3_column_name(statement, position).map { String(cString: $0) } ?? ""
            // The declared type is what the table says. A view or an expression declares none,
            // and then the type of the value itself is the best answer there is.
            let declared = sqlite3_column_decltype(statement, position)
                .map { String(cString: $0) }
            return ResultColumn(
                id: index,
                name: name,
                typeName: declared ?? Self.typeName(sqlite3_column_type(statement, position)))
        }
    }

    private func values(of statement: OpaquePointer?) -> [DisplayValue] {
        let count = Int(sqlite3_column_count(statement))
        return (0..<count).map { index in
            let position = Int32(index)
            switch sqlite3_column_type(statement, position) {
            case SQLITE_NULL:
                return .null

            case SQLITE_INTEGER:
                return .make(text: String(sqlite3_column_int64(statement, position)))

            case SQLITE_FLOAT:
                return .make(text: String(sqlite3_column_double(statement, position)))

            case SQLITE_BLOB:
                let bytes = Int(sqlite3_column_bytes(statement, position))
                guard let raw = sqlite3_column_blob(statement, position), bytes > 0 else {
                    return .make(text: "\\x", isRaw: true)
                }
                let data = Data(bytes: raw, count: bytes)
                return .make(
                    text: "\\x" + data.map { String(format: "%02x", $0) }.joined(), isRaw: true)

            default:
                let text = sqlite3_column_text(statement, position)
                    .map { String(cString: $0) } ?? ""
                let declared = sqlite3_column_decltype(statement, position)
                    .map { String(cString: $0).lowercased() } ?? ""
                return .make(text: text, isJSON: declared.contains("json"))
            }
        }
    }

    /// The name of a value type, for a column whose table declares none.
    private static func typeName(_ type: Int32) -> String {
        switch type {
        case SQLITE_INTEGER: "integer"
        case SQLITE_FLOAT: "real"
        case SQLITE_BLOB: "blob"
        case SQLITE_NULL: "null"
        default: "text"
        }
    }

    private func message(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

enum SQLiteError: LocalizedError {
    case noFile
    case fileMissing(String)
    case open(path: String, message: String)
    case statement(String)

    var errorDescription: String? {
        switch self {
        case .noFile:
            "This connection names no database file."
        case .fileMissing(let path):
            "There is no file at \(path)."
        case .open(let path, let message):
            "Cannot open \(path). \(message)"
        case .statement(let message):
            message
        }
    }
}

/// Holds the open handle where a call from another thread can reach it.
///
/// The session actor is busy for the whole statement, so `cancelRunningQuery` cannot read its
/// state. The lock keeps `sqlite3_interrupt` from meeting a handle that `close` is discarding.
private final class HandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    func set(_ value: OpaquePointer?) {
        lock.lock()
        defer { lock.unlock() }
        handle = value
    }

    func interrupt() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        sqlite3_interrupt(handle)
    }
}
