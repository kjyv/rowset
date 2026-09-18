import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

enum SessionError: LocalizedError {
    case notConnected
    case certificateBundleMissing
    case passwordMissing(String)
    case wrongRowCount(statement: Int, count: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "The connection is not open."
        case .certificateBundleMissing:
            "The RDS certificate bundle is missing from the app. "
                + "Run Scripts/fetch-rds-ca.sh and build again."
        case .passwordMissing(let name):
            "No password is saved for \(name). Open the connection and type it again."
        case .wrongRowCount(let statement, let count):
            "Statement \(statement) matched \(count) rows instead of one. "
                + "Nothing was changed. Refresh the table and try again."
        }
    }
}

/// Holds one open connection to one database.
///
/// The app keeps a single connection per bookmark instead of a `PostgresClient` pool. A pool takes
/// one fixed password, but an IAM auth token lasts only 15 minutes, so any connection that a pool
/// opened later would use an expired token. One connection lets the app fetch a new token every
/// time it reconnects.
actor PostgresSession: DatabaseSession {
    let bookmark: Bookmark

    private var connection: PostgresConnection?
    private var nextConnectionID = 1
    /// The server-side process of the open connection. `pg_cancel_backend` names it.
    private var backendPID: Int32?
    /// Carries the catalog reads and the row counts, away from the statements you type.
    private var backgroundConnection: PostgresConnection?
    private var backgroundConnectTask: Task<Void, any Error>?
    private var keepAliveTask: Task<Void, Never>?
    /// How many statements the app waits for now. The keepalive leaves a busy connection alone.
    private var statementsInFlight = 0

    /// How long the connection may sit idle before the app touches it.
    ///
    /// An AWS network load balancer drops an idle flow after 350 seconds, and other paths sooner.
    private static let keepAliveInterval: UInt64 = 60 * NSEC_PER_SEC
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

        let configuration = try await makeConfiguration()

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
        backendPID = try? await readBackendPID(from: opened)
        startKeepAlive()
    }

    private func makeConfiguration() async throws -> PostgresConnection.Configuration {
        PostgresConnection.Configuration(
            host: bookmark.host,
            port: bookmark.port,
            username: bookmark.username,
            password: try await password(),
            database: bookmark.database,
            tls: try makeTLS())
    }

    private func readBackendPID(from connection: PostgresConnection) async throws -> Int32? {
        let stream = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT pg_backend_pid()"), logger: logger)
        for try await row in stream {
            return try row.decode(Int32.self)
        }
        return nil
    }

    func close() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        if let backgroundConnection {
            self.backgroundConnection = nil
            try? await backgroundConnection.close()
        }
        guard let connection else { return }
        self.connection = nil
        backendPID = nil
        try? await connection.close()
    }

    /// The password the server wants.
    ///
    /// An IAM connection asks the AWS CLI for a token that lasts 15 minutes. A password
    /// connection reads the login keychain.
    private func password() async throws -> String {
        switch bookmark.authMethod {
        case .awsIAM:
            return try await AWSTokenProvider.authToken(for: bookmark)
        case .password:
            guard let stored = KeychainStore.password(for: bookmark.id), !stored.isEmpty else {
                throw SessionError.passwordMissing(bookmark.displayName)
            }
            return stored
        }
    }

    private func makeTLS() throws -> PostgresConnection.Configuration.TLS {
        if bookmark.sslMode == .disable { return .disable }

        var configuration = TLSConfiguration.makeClientConfiguration()

        switch bookmark.sslMode {
        case .disable:
            break
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

    // MARK: - Background work

    /// Runs a statement on a connection of its own.
    ///
    /// One connection carries one statement at a time. On the session connection the catalog
    /// reads and the counts would queue behind a long statement, and the sidebar would stop
    /// answering while a query runs. They hold no session state, so another connection serves
    /// them as well.
    func queryInBackground(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn]
    ) async throws -> ResultSet {
        try await connectBackground()
        do {
            return try await runBackgroundQuery(sql, maxRows: maxRows, expectedColumns: expectedColumns)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard backgroundConnection?.isClosed ?? true else { throw error }
            try await connectBackground()
            return try await runBackgroundQuery(sql, maxRows: maxRows, expectedColumns: expectedColumns)
        }
    }

    private func runBackgroundQuery(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn]
    ) async throws -> ResultSet {
        guard let backgroundConnection, !backgroundConnection.isClosed else {
            throw SessionError.notConnected
        }
        return try await read(
            sql, maxRows: maxRows, expectedColumns: expectedColumns, on: backgroundConnection)
    }

    /// Opens the background connection, or joins the open that is already running.
    private func connectBackground() async throws {
        if let backgroundConnection, !backgroundConnection.isClosed { return }
        if let backgroundConnectTask {
            try await backgroundConnectTask.value
            return
        }

        let task = Task { try await self.openBackgroundConnection() }
        backgroundConnectTask = task
        defer { backgroundConnectTask = nil }
        try await task.value
    }

    private func openBackgroundConnection() async throws {
        let id = nextConnectionID
        nextConnectionID += 1

        // Its own token, because an IAM token lasts 15 minutes and this opens long after connect.
        let opened = try await PostgresConnection.connect(
            on: PostgresConnection.defaultEventLoopGroup.any(),
            configuration: try await makeConfiguration(),
            id: id,
            logger: logger)

        if let old = backgroundConnection { try? await old.close() }
        backgroundConnection = opened
    }

    // MARK: - Keepalive

    /// Sends a cheap statement now and then, so an idle connection cannot go stale unnoticed.
    ///
    /// A NAT or a firewall drops an idle flow without telling either end. `isClosed` stays false,
    /// the next statement goes nowhere, and the app waits for the operating system to give up.
    /// That takes over a minute and reads as a timeout although the server is fine. Traffic keeps
    /// the flow, and a failure here closes the connection while nobody waits on it.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepAliveInterval)
                if Task.isCancelled { return }
                await self?.sendKeepAlive()
            }
        }
    }

    private func sendKeepAlive() async {
        if statementsInFlight == 0, let connection, !connection.isClosed {
            if await !ping(connection) {
                logger.info("the keepalive failed, so the connection goes")
                await close()
                return
            }
        }
        if let backgroundConnection, !backgroundConnection.isClosed,
           await !ping(backgroundConnection) {
            logger.info("the keepalive failed, so the background connection goes")
            self.backgroundConnection = nil
            try? await backgroundConnection.close()
        }
    }

    private func ping(_ connection: PostgresConnection) async -> Bool {
        do {
            let stream = try await connection.query(
                PostgresQuery(unsafeSQL: "SELECT 1"), logger: logger)
            for try await _ in stream {}
            return true
        } catch {
            return false
        }
    }

    // MARK: - Cancel

    /// Asks the server to stop the statement that runs now.
    ///
    /// The connection that carries the statement cannot carry the request beside it, so this
    /// opens a second one for `pg_cancel_backend`. PostgresNIO keeps the CancelRequest message of
    /// the wire protocol to itself, along with the backend key it needs.
    nonisolated func cancelRunningQuery() async {
        await sendCancelRequest()
    }

    /// The actor is suspended while it reads the rows, so this runs beside the query it stops.
    ///
    /// A request that cannot go out leaves the connection in a state nobody can name: a statement
    /// may still be sending rows nobody reads. Closing it is what makes the next statement start
    /// clean, and `query` opens a new one by itself.
    private func sendCancelRequest() async {
        guard let backendPID else {
            await close()
            return
        }

        let id = nextConnectionID
        nextConnectionID += 1

        do {
            var configuration = try await makeConfiguration()
            // A stop must not wait as long as a first connect may.
            configuration.options.connectTimeout = .seconds(5)

            let helper = try await PostgresConnection.connect(
                on: PostgresConnection.defaultEventLoopGroup.any(),
                configuration: configuration,
                id: id,
                logger: logger)
            _ = try? await helper.query(
                PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(backendPID))"),
                logger: logger)
            try? await helper.close()
        } catch {
            logger.warning("the cancel request could not open a connection: \(error)")
            await close()
        }
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
            if Self.isCancellation(error) { throw QueryCanceled() }
            // A statement the app stopped must not come back on a fresh connection.
            if Task.isCancelled { throw CancellationError() }
            guard connectionIsGone else { throw error }
            try await connect()
            return try await runQuery(sql, maxRows: maxRows, expectedColumns: expectedColumns)
        }
    }

    /// Postgres answers a statement it stopped with SQLSTATE 57014.
    static func isCancellation(_ error: any Error) -> Bool {
        guard let psql = error as? PSQLError else { return false }
        return psql.serverInfo?[.sqlState] == "57014"
    }

    private var connectionIsGone: Bool {
        guard let connection else { return true }
        return connection.isClosed
    }

    private func runQuery(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn]
    ) async throws -> ResultSet {
        guard let connection, !connection.isClosed else { throw SessionError.notConnected }

        statementsInFlight += 1
        defer { statementsInFlight -= 1 }
        return try await read(sql, maxRows: maxRows, expectedColumns: expectedColumns, on: connection)
    }

    /// Reads the rows of one statement from one connection.
    private func read(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn], on connection: PostgresConnection
    ) async throws -> ResultSet {
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

    /// Runs statements in one transaction. Either every one takes effect or none does.
    ///
    /// Each statement ends with `RETURNING 1`, so a count of the returned rows says whether it
    /// hit the row it aimed at. Anything but one row rolls the whole batch back, which is what
    /// stops a broken key from changing the wrong rows.
    func runTransaction(_ statements: [String]) async throws {
        guard !statements.isEmpty else { return }
        guard let connection, !connection.isClosed else { throw SessionError.notConnected }

        _ = try await connection.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: logger)

        do {
            for (index, sql) in statements.enumerated() {
                let result = try await runQuery(sql, maxRows: 2, expectedColumns: [])
                guard result.rows.count == 1 else {
                    throw SessionError.wrongRowCount(
                        statement: index + 1, count: result.rows.count)
                }
            }
        } catch {
            _ = try? await connection.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: logger)
            throw error
        }

        _ = try await connection.query(PostgresQuery(unsafeSQL: "COMMIT"), logger: logger)
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
