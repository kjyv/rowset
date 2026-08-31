import Foundation
import Observation

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

    /// The connection this row belongs to.
    var bookmarkID: UUID {
        switch self {
        case .bookmark(let id): id
        case .node(_, let bookmarkID): bookmarkID
        }
    }
}

/// The state of the whole window.
@MainActor
@Observable
final class AppModel {
    let store = BookmarkStore()
    private let sessionStore = SessionStore()

    var connections: [UUID: ConnectionModel] = [:]
    var tabs: [QueryTab] = []
    var selectedTabID: QueryTab.ID? { didSet { saveSession() } }
    var sidebarSelection: SidebarSelection?

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

    /// Whether the sidebar shows. Without this there is no way back once it closes, because the
    /// window carries no toolbar and so no toggle of its own.
    var isSidebarVisible = true { didSet { saveSession() } }

    /// The value pane belongs to the window, so every tab shows it the same way.
    var isInspectorVisible = true { didSet { saveSession() } }
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
        isInspectorVisible = state.inspectorVisible
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
                tab.sqlText = tabState.sqlText
            }
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
            inspectorVisible: isInspectorVisible,
            inspectorHeight: inspectorHeight,
            sidebarVisible: isSidebarVisible)
    }

    func saveSession() {
        guard isRestored else { return }
        sessionStore.save(currentSessionState())
    }

    func saveSessionNow() {
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

    func disconnect(bookmarkID: UUID) async {
        guard let model = connections[bookmarkID] else { return }
        await model.disconnect()
        tabs.removeAll { $0.connectionID == bookmarkID }
        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.first?.id
        }
    }

    /// Drops the cached connection so the next connect picks up the edited fields.
    func forget(bookmarkID: UUID) async {
        await disconnect(bookmarkID: bookmarkID)
        connections[bookmarkID] = nil
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
        tab.sqlText = "SELECT 1;"
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

    var selectedTab: QueryTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The connection that a new SQL tab or a new query belongs to.
    var activeConnection: ConnectionModel? {
        if let selectedTab { return connections[selectedTab.connectionID] }
        if let activeBookmarkID { return connections[activeBookmarkID] }
        return nil
    }
}
