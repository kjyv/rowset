import Foundation
import Observation

/// A prompt to renew an expired AWS login.
struct SSOPrompt: Identifiable {
    let id = UUID()
    var profile: String
    var detail: String
}

/// The state of the whole window.
@MainActor
@Observable
final class AppModel {
    let store = BookmarkStore()

    var connections: [UUID: ConnectionModel] = [:]
    var tabs: [QueryTab] = []
    var selectedTabID: QueryTab.ID?
    var selectedBookmarkID: UUID?

    /// The bookmark that the editor sheet edits. `nil` closes the sheet.
    var editedBookmark: Bookmark?
    var ssoPrompt: SSOPrompt?

    private let rowLimitKey = "defaultRowLimit"

    var defaultRowLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: rowLimitKey)
            return stored > 0 ? stored : 50
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: rowLimitKey) }
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
        return tab
    }

    func closeTab(id: QueryTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    var selectedTab: QueryTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The connection that a new SQL tab or a new query belongs to.
    var activeConnection: ConnectionModel? {
        if let selectedTab { return connections[selectedTab.connectionID] }
        if let selectedBookmarkID { return connections[selectedBookmarkID] }
        return nil
    }
}
