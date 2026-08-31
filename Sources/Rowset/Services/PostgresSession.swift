import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

enum SessionError: LocalizedError {
    case notConnected
    case certificateBundleMissing

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "The connection is not open."
        case .certificateBundleMissing:
            "The RDS certificate bundle is missing from the app. "
                + "Run Scripts/fetch-rds-ca.sh and build again."
        }
    }
}

/// Holds one open connection to one database.
///
/// The app keeps a single connection per bookmark instead of a `PostgresClient` pool. A pool takes
/// one fixed password, but an IAM auth token lasts only 15 minutes, so any connection that a pool
/// opened later would use an expired token. One connection lets the app fetch a new token every
/// time it reconnects.
actor PostgresSession {
    let bookmark: Bookmark

    private var connection: PostgresConnection?
    private var nextConnectionID = 1
    /// The connect that is running now. A second caller joins it instead of opening a rival.
    private var connectTask: Task<Void, any Error>?
    private let logger = Logger(label: "tech.alcemy.Rowset.postgres")

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
    }

    var isOpen: Bool {
        guard let connection else { return false }
        return !connection.isClosed
    }

    // MARK: - Lifecycle

    /// Opens the connection, or joins the connect that is already running.
    ///
    /// Two callers used to race here. Both passed `close` while the field was still empty, both
    /// opened a connection, and the second overwrote the first. PostgresNIO then failed the
    /// assertion `PostgresConnection deinitialized before being closed` and the app stopped.
    func connect() async throws {
        if let connectTask {
            try await connectTask.value
            return
        }

        let task = Task { try await self.openConnection() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    private func openConnection() async throws {
        await close()

        let token = try await AWSTokenProvider.authToken(for: bookmark)
        let configuration = PostgresConnection.Configuration(
            host: bookmark.host,
            port: bookmark.port,
            username: bookmark.username,
            password: token,
            database: bookmark.database,
            tls: try makeTLS())

        let id = nextConnectionID
        nextConnectionID += 1

        let opened = try await PostgresConnection.connect(
            on: PostgresConnection.defaultEventLoopGroup.any(),
            configuration: configuration,
            id: id,
            logger: logger)

        // Never drop a live connection on the floor. Closing it is the caller of this rule.
        await close()
        connection = opened
    }

    func close() async {
        guard let connection else { return }
        self.connection = nil
        try? await connection.close()
    }

    private func makeTLS() throws -> PostgresConnection.Configuration.TLS {
        var configuration = TLSConfiguration.makeClientConfiguration()

        switch bookmark.sslMode {
        case .verifyFull:
            guard let path = CertificateBundle.rdsRootsPath() else {
                throw SessionError.certificateBundleMissing
            }
            configuration.trustRoots = .file(path)
            configuration.certificateVerification = .fullVerification
        case .require:
            configuration.certificateVerification = .none
        }

        return .require(try NIOSSLContext(configuration: configuration))
    }

    // MARK: - Queries

    /// Runs one statement and reads at most `maxRows` rows.
    ///
    /// Reading only part of the stream keeps the SQL tab fast on a large table and needs no rewrite
    /// of the statement, so `EXPLAIN`, `INSERT` and `CREATE` all work as typed.
    func query(_ sql: String, maxRows: Int, expectedColumns: [ResultColumn] = []) async throws -> ResultSet {
        do {
            return try await runQuery(sql, maxRows: maxRows, expectedColumns: expectedColumns)
        } catch {
            guard connectionIsGone else { throw error }
            try await connect()
            return try await runQuery(sql, maxRows: maxRows, expectedColumns: expectedColumns)
        }
    }

    private var connectionIsGone: Bool {
        guard let connection else { return true }
        return connection.isClosed
    }

    private func runQuery(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn]
    ) async throws -> ResultSet {
        guard let connection, !connection.isClosed else { throw SessionError.notConnected }

        let start = DispatchTime.now()
        let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)

        var result = ResultSet()
        // A statement that returns no row carries no column description, so fall back to the
        // columns that the caller already knows from the catalog.
        result.columns = expectedColumns

        var index = 0
        for try await row in stream {
            if index >= maxRows {
                result.truncated = true
                break
            }
            if index == 0 {
                result.columns = row.map {
                    ResultColumn(
                        id: $0.columnIndex,
                        name: $0.columnName,
                        typeName: CellRenderer.typeName($0.dataType))
                }
            }
            result.rows.append(ResultRow(id: index, values: row.map(CellRenderer.render)))
            index += 1
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        result.duration = Double(elapsed) / 1_000_000_000
        return result
    }

    /// Runs a statement and returns the rows as plain strings. The catalog queries use this.
    func queryStrings(_ sql: String, maxRows: Int = 10_000) async throws -> [[String]] {
        let result = try await query(sql, maxRows: maxRows)
        return result.rows.map { row in row.values.map { $0.isNull ? "" : $0.text } }
    }
}

// MARK: - Error text

enum DatabaseErrorText {
    /// Turns a driver error into a message worth showing.
    static func describe(_ error: any Error) -> String {
        if let psql = error as? PSQLError {
            if let info = psql.serverInfo {
                var text = info[.message] ?? String(describing: psql.code)
                if let detail = info[.detail] { text += "\n\(detail)" }
                if let hint = info[.hint] { text += "\nHint: \(hint)" }
                if let position = info[.position] { text += "\nPosition: \(position)" }
                return text
            }
            if let underlying = psql.underlying {
                return "\(psql.code): \(underlying.localizedDescription)"
            }
            return String(describing: psql.code)
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
