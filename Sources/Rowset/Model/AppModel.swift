import Foundation
import Observation

/// The statements of an edit, held until you accept them.
///
/// Nothing reaches the server before you have read this.
struct PendingWrite: Identifiable {
    let id = UUID()
    var tabID: UUID
    var statements: [String]
    var rowCount: Int
    var cellCount: Int

    var sql: String { statements.joined(separator: ";\n\n") + ";" }
}

/// A prompt to renew an expired AWS login.
struct SSOPrompt: Identifiable {
    let id = UUID()
    var profile: String
    var detail: String
}

/// What the sidebar has selected.
///
/// A bookmark row and a tree row are different things, so one type names both. Without a tag of
/// its own, a tree row fell back to the row of its connection, and the highlight then covered the
/// whole group.
enum SidebarSelection: Hashable {
    case bookmark(UUID)
    case node(id: UUID, bookmarkID: UUID)
    case filterResult(id: String, bookmarkID: UUID)

    /// The connection this row belongs to.
    var bookmarkID: UUID {
        switch self {
        case .bookmark(let id): id
        case .node(_, let bookmarkID): bookmarkID
        case .filterResult(_, let bookmarkID): bookmarkID
        }
    }
}

/// The state of the whole window.
@MainActor
@Observable
final class AppModel {
    let store: BookmarkStore
    let bufferStore: BufferStore
    private let sessionStore: SessionStore

    init(
        store: BookmarkStore? = nil,
        sessionStore: SessionStore? = nil,
        bufferStore: BufferStore? = nil
    ) {
        self.store = store ?? BookmarkStore()
        self.sessionStore = sessionStore ?? SessionStore()
        self.bufferStore = bufferStore ?? BufferStore()
    }

    var connections: [UUID: ConnectionModel] = [:]
    var tabs: [QueryTab] = []
    var selectedTabID: QueryTab.ID? { didSet { saveSession() } }
    var sidebarSelection: SidebarSelection?
    /// What the sidebar filter holds. An empty value shows the tree.
    var sidebarFilter = ""

    /// The connections that are open, in the order of the bookmark list.
    var connectedConnections: [ConnectionModel] {
        store.bookmarks.compactMap { connections[$0.id] }.filter { $0.state.isConnected }
    }

    /// The connection row itself. The buttons that edit or delete need this one, so a selected
    /// column never puts a delete on its table.
    var selectedBookmarkID: UUID? {
        get {
            if case .bookmark(let id) = sidebarSelection { return id }
            return nil
        }
        set { sidebarSelection = newValue.map { .bookmark($0) } }
    }

    /// The connection of whatever the sidebar has selected, a tree row included.
    var activeBookmarkID: UUID? { sidebarSelection?.bookmarkID }

    /// The bookmark that the editor sheet edits. `nil` closes the sheet.
    var editedBookmark: Bookmark?
    var ssoPrompt: SSOPrompt?
    /// The statements waiting for your word. `nil` closes the sheet.
    var pendingWrite: PendingWrite?

    /// Whether the sidebar shows. Without this there is no way back once it closes, because the
    /// window carries no toolbar and so no toggle of its own.
    var isSidebarVisible = true { didSet { saveSession() } }

    /// The height of the value pane. Each tab decides whether it shows one.
    var inspectorHeight: Double = 190 { didSet { saveSession() } }

    private let rowLimitKey = "defaultRowLimit"

    var defaultRowLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: rowLimitKey)
            return stored > 0 ? stored : 50
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: rowLimitKey) }
    }

    // MARK: - Session

    /// Reads the last session and puts the window back the way you left it.
    func restoreSession() async {
        let state = sessionStore.load()
        inspectorHeight = state.inspectorHeight
        isSidebarVisible = state.sidebarVisible
        syncConnections()

        let known = Set(store.bookmarks.map(\.id))
        let expanded = state.expandedBookmarks.filter { known.contains($0) }

        // Rebuild the tabs first, so a connection finds its work waiting.
        for tabState in state.tabs where known.contains(tabState.bookmarkID) {
            guard let connection = connections[tabState.bookmarkID] else { continue }
            let tab: QueryTab
            if let schema = tabState.schema, let table = tabState.table {
                tab = QueryTab(
                    connectionID: connection.id,
                    connectionName: connection.bookmark.displayName,
                    kind: .table(schema: schema, name: table),
                    rowLimit: tabState.rowLimit)
                tab.filterText = tabState.filterText
                tab.orderByText = tabState.orderByText
            } else {
                tab = QueryTab(
                    connectionID: connection.id,
                    connectionName: connection.bookmark.displayName,
                    kind: .sql,
                    rowLimit: tabState.rowLimit)
                adoptBuffer(tab, connection: connection, preferred: tabState.bufferID)
            }
            tab.measuresValueSize = connection.measuresValueSize
            // A file written before the pane belonged to the tab says nothing about it.
            if let shows = tabState.showsValuePane { tab.showsValuePane = shows }
            tabs.append(tab)
        }
        if let index = state.selectedTabIndex, tabs.indices.contains(index) {
            selectedTabID = tabs[index].id
        } else {
            selectedTabID = tabs.first?.id
        }

        // Open the connections that were open, and the tree rows under them.
        let needed = Set(expanded).union(tabs.map(\.connectionID))
        for bookmarkID in needed {
            guard let connection = connections[bookmarkID] else { continue }
            // Connect first. Opening the row before the connect makes the sidebar start a
            // second connect of its own.
            await connect(to: bookmarkID)
            connection.isExpanded = expanded.contains(bookmarkID)
            await connection.restoreExpansion(state.nodes(for: bookmarkID))
        }

        isRestored = true
        saveSession()
    }

    /// Blocks a write while the restore is still building the state.
    private var isRestored = false

    func currentSessionState() -> SessionState {
        var nodes: [String: [NodePath]] = [:]
        var expanded: [UUID] = []
        for (id, connection) in connections {
            if connection.isExpanded { expanded.append(id) }
            let paths = connection.expandedPaths
            if !paths.isEmpty { nodes[id.uuidString] = paths }
        }

        return SessionState(
            expandedBookmarks: expanded.sorted { $0.uuidString < $1.uuidString },
            expandedNodes: nodes,
            tabs: tabs.map(\.state),
            selectedTabIndex: tabs.firstIndex { $0.id == selectedTabID },
            inspectorHeight: inspectorHeight,
            sidebarVisible: isSidebarVisible)
    }

    func saveSession() {
        guard isRestored else { return }
        sessionStore.save(currentSessionState())
    }

    func saveSessionNow() {
        bufferStore.saveNow()
        guard isRestored else { return }
        sessionStore.saveNow(currentSessionState())
    }

    // MARK: - Connections

    /// Creates a connection model for every bookmark and drops the ones that no longer exist.
    ///
    /// A view must never create one while it draws, so this runs from a task or a change handler.
    func syncConnections() {
        for bookmark in store.bookmarks where connections[bookmark.id] == nil {
            connections[bookmark.id] = ConnectionModel(bookmark: bookmark)
        }
        let liveIDs = Set(store.bookmarks.map(\.id))
        connections = connections.filter { liveIDs.contains($0.key) }
    }

    func connection(id: UUID) -> ConnectionModel? {
        connections[id]
    }

    func connect(to bookmarkID: UUID) async {
        syncConnections()
        guard let model = connections[bookmarkID] else { return }
        await model.connect()
        if let error = model.expiredLogin, case .ssoExpired(let profile, let detail) = error {
            ssoPrompt = SSOPrompt(profile: profile, detail: detail)
        }
    }

    /// Closes the connection and every tab that reads through it.
    ///
    /// The tabs go whether the connection is still there or not. They used to go only inside the
    /// guard below, so a bookmark that was already deleted left its tabs behind.
    func disconnect(bookmarkID: UUID) async {
        if let model = connections[bookmarkID] { await model.disconnect() }
        closeTabs(of: bookmarkID)
    }

    /// Drops the cached connection so the next connect picks up the edited fields.
    func forget(bookmarkID: UUID) async {
        await disconnect(bookmarkID: bookmarkID)
        connections[bookmarkID] = nil
    }

    /// Drops a connection and everything that belonged to it.
    ///
    /// A tab of a connection that is gone can fetch nothing, and its refresh button and its
    /// editor would lie about what is on screen. The saved consoles go last, so a console tab
    /// writes nothing back after they are removed.
    func forgetEverything(bookmarkID: UUID) async {
        await forget(bookmarkID: bookmarkID)
        bufferStore.removeAll(for: bookmarkID)
    }

    /// Deletes a connection: the tabs, the saved consoles, the password and the bookmark.
    ///
    /// One call, in one order. The sidebar used to remove the bookmark itself and leave the rest
    /// to a task. The bookmark went first, `syncConnections` dropped the connection with it, and
    /// the task then found nothing to close.
    func deleteConnection(bookmarkID: UUID) async {
        await forgetEverything(bookmarkID: bookmarkID)
        store.remove(id: bookmarkID)
        if selectedBookmarkID == bookmarkID { sidebarSelection = nil }
    }

    /// Closes every tab of one connection.
    func closeTabs(of bookmarkID: UUID) {
        for tab in tabs where tab.connectionID == bookmarkID {
            closeTab(id: tab.id)
        }
    }

    // MARK: - Tabs

    /// Opens a table tab, or moves to the tab that already shows this table.
    @discardableResult
    func openTable(schema: String, name: String, connection: ConnectionModel) -> QueryTab {
        let kind = QueryTab.Kind.table(schema: schema, name: name)
        if let existing = tabs.first(where: { $0.connectionID == connection.id && $0.kind == kind }) {
            selectedTabID = existing.id
            return existing
        }

        let tab = QueryTab(
            connectionID: connection.id,
            connectionName: connection.bookmark.displayName,
            kind: kind,
            rowLimit: defaultRowLimit)
        tab.measuresValueSize = connection.measuresValueSize
        tabs.append(tab)
        selectedTabID = tab.id
        saveSession()
        return tab
    }

    @discardableResult
    func openSQLTab(connection: ConnectionModel) -> QueryTab {
        let tab = QueryTab(
            connectionID: connection.id,
            connectionName: connection.bookmark.displayName,
            kind: .sql,
            rowLimit: defaultRowLimit)
        tab.measuresValueSize = connection.measuresValueSize
        adoptBuffer(tab, connection: connection)
        tabs.append(tab)
        selectedTabID = tab.id
        saveSession()
        return tab
    }

    func closeTab(id: QueryTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        saveSession()
    }

    /// Moves to the next tab, and wraps around at the end.
    func selectNextTab() { step(by: 1) }

    /// Moves to the tab before this one, and wraps around at the start.
    func selectPreviousTab() { step(by: -1) }

    private func step(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            selectedTabID = tabs.first?.id
            return
        }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    /// The text a tab shows after its name, or `nil` when the name alone is clear.
    ///
    /// Two rules ask for it. More than one connection means a table name says nothing about the
    /// database it came from. Two open tabs of the same table name from different schemas need
    /// the schema as well.
    func qualifier(for tab: QueryTab) -> String? {
        var parts: [String] = []

        if case .table(let schema, let name) = tab.kind, needsSchema(name: name) {
            parts.append(schema)
        }
        if store.bookmarks.count > 1 {
            parts.append(tab.connectionName)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True when another open tab shows the same table name out of another schema.
    private func needsSchema(name: String) -> Bool {
        var schemas: Set<String> = []
        for tab in tabs {
            guard case .table(let schema, let other) = tab.kind, other == name else { continue }
            schemas.insert(schema)
        }
        return schemas.count > 1
    }

    var selectedTab: QueryTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The connection that a new query tab belongs to.
    ///
    /// A query console belongs to a database and not to a table, so an open table tab is not a
    /// condition. Any open connection will do.
    var activeConnection: ConnectionModel? {
        if let selectedTab, let connection = connections[selectedTab.connectionID],
           connection.state.isConnected {
            return connection
        }
        if let activeBookmarkID, let connection = connections[activeBookmarkID],
           connection.state.isConnected {
            return connection
        }
        return connectedConnections.first
    }

    /// Opens what a tree row stands for.
    ///
    /// A double click and the Return key both land here, so the two never drift apart.
    func open(_ node: TreeNode, in connection: ConnectionModel) {
        switch node.kind {
        case .table(let schema, let name), .view(let schema, let name):
            let tab = openTable(schema: schema, name: name, connection: connection)
            Task { await runTableQuery(tab) }

        case .column(let schema, let table, let name, _, _, _):
            // Opens the table, or moves to the tab that already shows it, then jumps sideways
            // to the column you picked.
            let tab = openTable(schema: schema, name: table, connection: connection)
            tab.revealColumn = name
            if tab.result == nil {
                Task { await runTableQuery(tab) }
            }

        case .schema:
            node.isExpanded.toggle()
        }
    }

    func open(_ table: TableRef, in connection: ConnectionModel) {
        let tab = openTable(schema: table.schema, name: table.name, connection: connection)
        Task { await runTableQuery(tab) }
    }

    /// Opens one row of the sidebar. A double click passes the row it hit.
    func openSidebarSelection(_ row: SidebarSelection?) {
        guard let row else { return }
        sidebarSelection = row
        openSidebarSelection()
    }

    /// Opens whatever the sidebar has selected. The Return key calls this.
    func openSidebarSelection() {
        switch sidebarSelection {
        case .bookmark(let id):
            guard let connection = connections[id] else { return }
            connection.isExpanded.toggle()
            if connection.isExpanded, connection.state == .disconnected {
                Task { await connect(to: id) }
            }

        case .node(let nodeID, let bookmarkID):
            guard let connection = connections[bookmarkID],
                  let node = connection.node(id: nodeID)
            else { return }
            open(node, in: connection)

        case .filterResult(let id, let bookmarkID):
            guard let connection = connections[bookmarkID],
                  let table = connection.allTables.first(where: { $0.id == id })
            else { return }
            open(table, in: connection)

        case nil:
            break
        }
    }

    /// Copies a bookmark, so a second database on the same server costs a few keystrokes.
    func duplicate(bookmarkID: UUID) {
        guard let original = store.bookmarks.first(where: { $0.id == bookmarkID }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.displayName) copy"
        // The password is not a field of the bookmark. It lives in the keychain under the id, so
        // a copy with a new id would have none and could not connect.
        if let password = KeychainStore.password(for: bookmarkID) {
            KeychainStore.setPassword(password, for: copy.id)
        }
        store.upsert(copy)
        syncConnections()
        editedBookmark = copy
    }

    /// What a new console starts with.
    ///
    /// The first line is a comment, because the list takes its name from there. A real table name
    /// beats a placeholder, so the console picks one the connection knows.
    ///
    /// The empty line after the comment matters. It keeps the comment out of the statement, so
    /// the band under the caret covers the SELECT alone.
    func defaultSQL(for connection: ConnectionModel) -> String {
        let table = selectedTableRef(in: connection) ?? connection.allTables.first

        guard let table else {
            return """
                -- New console

                SELECT *
                FROM public.your_table
                LIMIT 50;
                """
        }

        return """
            -- \(table.name)

            SELECT *
            FROM \(SQLBuilder.qualifiedName(schema: table.schema, table: table.name))
            LIMIT 50;
            """
    }

    /// The table of the tab in front, when it belongs to this connection.
    private func selectedTableRef(in connection: ConnectionModel) -> TableRef? {
        guard let tab = selectedTab, tab.connectionID == connection.id,
              case .table(let schema, let name) = tab.kind
        else { return nil }
        return TableRef(schema: schema, name: name, isView: false)
    }
}
