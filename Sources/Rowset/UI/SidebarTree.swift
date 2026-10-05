import AppKit

/// What one sidebar row draws. Two equal values draw the same row.
struct SidebarLook: Equatable {
    enum Style: Equatable {
        /// A section title, such as "Connections".
        case header
        case bookmark
        /// A schema, table, view or column, and a table of the filter result.
        case row
        /// A grey line such as "Loading…".
        case note
        /// A red message, which can run over several lines.
        case error
        /// The "Connect" button under a closed connection.
        case link
    }

    enum Tint: Equatable {
        case secondary, green, orange, red
    }

    var style: Style
    var title: String
    /// The grey text beside the title, or under it for a bookmark.
    var detail: String?
    var symbol: String?
    var tint: Tint = .secondary
    var isBusy = false
}

/// One row of the sidebar outline.
///
/// `NSOutlineView` keeps its rows by object identity, so the same row keeps the same object for
/// as long as it lives.
@MainActor
final class SidebarItem: NSObject {
    enum Kind {
        case header
        case bookmark(Bookmark)
        case node(TreeNode, ConnectionModel)
        case table(TableRef, ConnectionModel)
        case note
        case connect(bookmarkID: UUID)
    }

    let key: String
    fileprivate(set) var kind: Kind
    fileprivate(set) var look: SidebarLook
    /// The rows under this one, also while it is closed. AppKit asks for them when it closes a
    /// row above, and a missing child at that point is a crash.
    fileprivate(set) var children: [SidebarItem] = []
    fileprivate(set) var isExpandable = false
    /// True when the model holds this row open.
    fileprivate(set) var wantsExpanded = false

    fileprivate init(key: String, kind: Kind, look: SidebarLook) {
        self.key = key
        self.kind = kind
        self.look = look
    }

    /// The selection this row stands for, or `nil` for a row you cannot select.
    var selection: SidebarSelection? {
        switch kind {
        case .bookmark(let bookmark): .bookmark(bookmark.id)
        case .node(let node, let connection): .node(id: node.id, bookmarkID: connection.id)
        case .table(let table, let connection): .filterResult(id: table.id, bookmarkID: connection.id)
        case .header, .note, .connect: nil
        }
    }
}

/// The rows of the sidebar, built from the model.
@MainActor
final class SidebarTree {
    private(set) var roots: [SidebarItem] = []
    /// An empty row for a question about a child that does not exist.
    let placeholder = SidebarItem(key: "placeholder", kind: .note, look: SidebarLook(style: .note, title: ""))
    private var items: [String: SidebarItem] = [:]
    private var built: Set<String> = []

    /// Reads the model and brings every row up to date. A row that is still there keeps its
    /// object.
    func rebuild(from model: AppModel) {
        built = []
        if model.sidebarFilter.isEmpty {
            let header = item(
                "connections", .header, SidebarLook(style: .header, title: "Connections"))
            header.isExpandable = true
            header.wantsExpanded = true
            header.children = model.store.bookmarks.map { bookmarkItem($0, model: model) }
            roots = [header]
        } else {
            roots = filterItems(model)
        }
        items = items.filter { built.contains($0.key) }
    }

    func item(key: String) -> SidebarItem? {
        items[key]
    }

    func item(for selection: SidebarSelection) -> SidebarItem? {
        switch selection {
        case .bookmark(let id): items[Self.bookmarkKey(id)]
        case .node(let id, _): items[Self.nodeKey(id)]
        case .filterResult(let id, let bookmarkID): items[Self.tableKey(id, bookmarkID: bookmarkID)]
        }
    }

    // MARK: - Keys

    private static func bookmarkKey(_ id: UUID) -> String { "bookmark/\(id)" }
    private static func nodeKey(_ id: UUID) -> String { "node/\(id)" }
    private static func tableKey(_ id: String, bookmarkID: UUID) -> String {
        "table/\(bookmarkID)/\(id)"
    }

    // MARK: - Rows

    private func item(_ key: String, _ kind: SidebarItem.Kind, _ look: SidebarLook) -> SidebarItem {
        built.insert(key)
        if let existing = items[key] {
            existing.kind = kind
            existing.look = look
            return existing
        }
        let created = SidebarItem(key: key, kind: kind, look: look)
        items[key] = created
        return created
    }

    /// One line under a row. A row has at most one, so the parent names it.
    private func note(
        under parentKey: String, _ text: String, style: SidebarLook.Style = .note,
        symbol: String? = nil
    ) -> SidebarItem {
        item("\(parentKey)/note", .note, SidebarLook(style: style, title: text, symbol: symbol))
    }

    private func bookmarkItem(_ bookmark: Bookmark, model: AppModel) -> SidebarItem {
        let key = Self.bookmarkKey(bookmark.id)
        let connection = model.connection(id: bookmark.id)
        let state = connection?.state ?? .disconnected

        let row = item(key, .bookmark(bookmark), SidebarLook(
            style: .bookmark,
            title: bookmark.displayName,
            detail: bookmark.subtitle,
            symbol: "cylinder.split.1x2",
            tint: Self.tint(for: state),
            isBusy: state.isBusy))
        row.isExpandable = true
        row.wantsExpanded = connection?.isExpanded ?? false

        switch (state, connection) {
        case (.connected, let connection?):
            row.children = connection.schemas.isEmpty
                ? [note(under: key, "No schema")]
                : connection.schemas.map { nodeItem($0, connection: connection) }
        case (.connecting, _):
            row.children = [note(under: key, "Connecting…", symbol: "hourglass")]
        case (.failed(let message), _):
            row.children = [note(under: key, message, style: .error)]
        default:
            row.children = [item(
                "\(key)/note", .connect(bookmarkID: bookmark.id),
                SidebarLook(style: .link, title: "Connect"))]
        }
        return row
    }

    private func nodeItem(_ node: TreeNode, connection: ConnectionModel) -> SidebarItem {
        let key = Self.nodeKey(node.id)
        let row = item(key, .node(node, connection), SidebarLook(
            style: .row,
            title: node.kind.title,
            detail: node.kind.detail,
            symbol: node.kind.symbolName,
            isBusy: node.isLoading))
        row.isExpandable = node.kind.canHaveChildren
        row.wantsExpanded = node.isExpanded

        guard node.kind.canHaveChildren else {
            row.children = []
            return row
        }
        if let children = node.children {
            row.children = children.isEmpty
                ? [note(under: key, "Empty")]
                : children.map { nodeItem($0, connection: connection) }
        } else if let error = node.loadError {
            row.children = [note(under: key, error, style: .error)]
        } else {
            row.children = [note(under: key, "Loading…", symbol: "hourglass")]
        }
        return row
    }

    /// The tables that match, under the name of the connection they belong to.
    ///
    /// The name matters: two databases often hold a table of the same name.
    private func filterItems(_ model: AppModel) -> [SidebarItem] {
        let connections = model.connectedConnections
        guard !connections.isEmpty else {
            return [note(under: "filter", "Open a connection to search its tables.")]
        }

        return connections.map { connection in
            let key = "filter/\(connection.id)"
            let group = item(
                key, .header,
                SidebarLook(style: .header, title: connection.bookmark.displayName))
            group.isExpandable = true
            group.wantsExpanded = true

            let matches = connection.tables(matching: model.sidebarFilter)
            group.children = matches.isEmpty
                ? [note(under: key, "No table matches")]
                : matches.map { table in
                    item(
                        Self.tableKey(table.id, bookmarkID: connection.id),
                        .table(table, connection),
                        SidebarLook(
                            style: .row, title: table.name, detail: table.schema,
                            symbol: table.symbolName))
                }
            return group
        }
    }

    private static func tint(for state: ConnectionModel.State) -> SidebarLook.Tint {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}
