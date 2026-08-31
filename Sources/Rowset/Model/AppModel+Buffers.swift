import Foundation

extension AppModel {

    /// The consoles of the connection a tab belongs to.
    func buffers(for tab: QueryTab) -> [SQLBuffer] {
        bufferStore.buffers(for: tab.connectionID)
    }

    /// Writes what you typed back into the console.
    ///
    /// The editor holds the working copy and the store holds the saved one. The store waits half
    /// a second before it writes the file, so typing costs one write and not one per key.
    func persistBuffer(_ tab: QueryTab) {
        guard case .sql = tab.kind, let bufferID = tab.bufferID else { return }
        bufferStore.setText(tab.sqlText, id: bufferID, for: tab.connectionID)
    }

    /// Moves a tab to another console, keeping what you typed in the one you leave.
    func switchBuffer(_ tab: QueryTab, to bufferID: UUID) {
        guard tab.bufferID != bufferID else { return }
        persistBuffer(tab)

        guard let buffer = bufferStore.buffer(id: bufferID, for: tab.connectionID) else { return }
        tab.bufferID = buffer.id
        tab.sqlText = buffer.text
        tab.sqlCaret = 0
        tab.result = nil
        tab.errorText = nil
        saveSession()
    }

    /// Opens a fresh console in this tab.
    func newBuffer(_ tab: QueryTab) {
        persistBuffer(tab)
        guard let connection = connections[tab.connectionID] else { return }

        let buffer = bufferStore.create(for: tab.connectionID, text: defaultSQL(for: connection))
        tab.bufferID = buffer.id
        tab.sqlText = buffer.text
        tab.sqlCaret = 0
        tab.result = nil
        tab.errorText = nil
        saveSession()
    }

    /// Throws the console away and moves to the one you touched before it.
    func deleteBuffer(_ tab: QueryTab) {
        guard let bufferID = tab.bufferID else { return }
        bufferStore.delete(id: bufferID, for: tab.connectionID)

        if let next = bufferStore.buffers(for: tab.connectionID).first {
            tab.bufferID = next.id
            tab.sqlText = next.text
        } else {
            newBuffer(tab)
            return
        }
        tab.sqlCaret = 0
        tab.result = nil
        tab.errorText = nil
        saveSession()
    }

    /// The console a new tab opens: the one you touched last, or a fresh one.
    func adoptBuffer(_ tab: QueryTab, connection: ConnectionModel, preferred: UUID? = nil) {
        if let preferred, let buffer = bufferStore.buffer(id: preferred, for: connection.id) {
            tab.bufferID = buffer.id
            tab.sqlText = buffer.text
            return
        }
        if let latest = bufferStore.buffers(for: connection.id).first {
            tab.bufferID = latest.id
            tab.sqlText = latest.text
            return
        }
        let buffer = bufferStore.create(for: connection.id, text: defaultSQL(for: connection))
        tab.bufferID = buffer.id
        tab.sqlText = buffer.text
    }
}
