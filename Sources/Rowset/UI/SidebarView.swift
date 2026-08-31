import SwiftUI

/// The left column: the bookmark list and, under each open bookmark, the database tree.
struct SidebarView: View {
    @Bindable var model: AppModel

    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.sidebarSelection) {
                if model.sidebarFilter.isEmpty {
                    Section("Connections") {
                        ForEach(model.store.bookmarks) { bookmark in
                            BookmarkSection(model: model, bookmark: bookmark)
                        }
                    }
                } else {
                    filterResults
                }
            }
            .listStyle(.sidebar)
            // The tree and the filter results are two different lists. Without a separate
            // identity SwiftUI reuses the rows, and a connection row stayed drawn over the first
            // result.
            .id(model.sidebarFilter.isEmpty)
            .onKeyPress(.return) {
                model.openSidebarSelection()
                return .handled
            }
            // The double click of a list is its primary action. SwiftUI already owns the
            // double click of the table underneath, so a recognizer of my own never won.
            .contextMenu(forSelectionType: SidebarSelection.self) { _ in
                // Each row carries its own menu, which fits what that row is.
            } primaryAction: { rows in
                model.openSidebarSelection(rows.first)
            }
            // Command-F belongs to the sidebar only while the keyboard is in it. Every editor in
            // the window uses that key for its own find bar.
            .background(SidebarFindKey { isFilterFocused = true })

            Divider()
            toolbar
        }
        // The tree loads one schema at a time, so a filter needs the whole table list first.
        .task(id: model.sidebarFilter) {
            guard !model.sidebarFilter.isEmpty else { return }
            for connection in model.connectedConnections {
                await connection.loadAllTables()
            }
        }
        .task { await model.restoreSession() }
        .onChange(of: model.store.bookmarks) { _, _ in
            model.syncConnections()
            model.saveSession()
        }
    }

    /// The tables that match, under the name of the connection they belong to.
    ///
    /// The name matters: two databases often hold a table of the same name.
    @ViewBuilder
    private var filterResults: some View {
        let connections = model.connectedConnections
        if connections.isEmpty {
            Text("Open a connection to search its tables.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(connections) { connection in
                let matches = connection.tables(matching: model.sidebarFilter)
                Section(connection.bookmark.displayName) {
                    if matches.isEmpty {
                        Text("No table matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { table in
                            FilterResultRow(model: model, connection: connection, table: table)
                                .tag(SidebarSelection.filterResult(
                                    id: table.id, bookmarkID: connection.id))
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                model.editedBookmark = Bookmark()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add a connection")

            Button {
                guard let id = model.selectedBookmarkID else { return }
                Task { await model.forgetEverything(bookmarkID: id) }
                model.store.remove(id: id)
                model.selectedBookmarkID = nil
            } label: {
                Image(systemName: "minus")
            }
            .disabled(model.selectedBookmarkID == nil)
            .help("Remove the selected connection")

            Button {
                guard let id = model.selectedBookmarkID,
                      let bookmark = model.store.bookmarks.first(where: { $0.id == id })
                else { return }
                model.editedBookmark = bookmark
            } label: {
                Image(systemName: "gearshape")
            }
            .disabled(model.selectedBookmarkID == nil)
            .help("Edit the selected connection")

            if let error = model.store.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }

            Divider().frame(height: 14)

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter tables", text: $model.sidebarFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFilterFocused)

            if !model.sidebarFilter.isEmpty {
                Button {
                    model.sidebarFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .help("Clear the filter")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One bookmark row with its tree below.
struct BookmarkSection: View {
    let model: AppModel
    let bookmark: Bookmark

    private var connection: ConnectionModel? { model.connection(id: bookmark.id) }

    /// The open state lives on the connection, so the session file can hold it.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { model.connection(id: bookmark.id)?.isExpanded ?? false },
            set: { model.connection(id: bookmark.id)?.isExpanded = $0 })
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content
        } label: {
            // The menu belongs on the label, not on the group. On the group every table and
            // column underneath inherited it and offered to connect a connection.
            label
                .tag(SidebarSelection.bookmark(bookmark.id))
                .contextMenu { connectionMenu }
        }
        .onChange(of: isExpanded.wrappedValue) { _, expanded in
            model.saveSession()
            guard expanded, let connection, connection.state == .disconnected else { return }
            Task { await model.connect(to: bookmark.id) }
        }
    }

    /// The menu of a connection row. It offers what the state allows, and nothing else.
    @ViewBuilder
    private var connectionMenu: some View {
        let state = connection?.state ?? .disconnected

        switch state {
        case .connected:
            Button("Disconnect") { Task { await model.disconnect(bookmarkID: bookmark.id) } }
            Button("Refresh") { Task { await connection?.refresh() } }
            Divider()
            Button("New Console") {
                if let connection { model.openSQLTab(connection: connection) }
            }
        case .connecting:
            Button("Connecting…") {}
                .disabled(true)
        case .disconnected, .failed:
            Button("Connect") { Task { await model.connect(to: bookmark.id) } }
        }

        Divider()
        Button("Duplicate") { model.duplicate(bookmarkID: bookmark.id) }
        Button("Edit…") { model.editedBookmark = bookmark }
        Button("Delete", role: .destructive) {
            Task { await model.forgetEverything(bookmarkID: bookmark.id) }
            model.store.remove(id: bookmark.id)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.displayName)
                    .lineLimit(1)
                Text(bookmark.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if connection?.state.isBusy == true {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch connection?.state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        default: .secondary
        }
    }

    @ViewBuilder
    private var content: some View {
        if let connection {
            switch connection.state {
            case .connected:
                if connection.schemas.isEmpty {
                    Text("No schema").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(connection.schemas) { node in
                        TreeNodeRow(model: model, connection: connection, node: node)
                    }
                }
            case .connecting:
                Label("Connecting…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(6)
            case .disconnected:
                Button("Connect") { Task { await model.connect(to: bookmark.id) } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// One node of the database tree. Children load the first time the node opens.
struct TreeNodeRow: View {
    let model: AppModel
    let connection: ConnectionModel
    @Bindable var node: TreeNode

    var body: some View {
        if node.kind.canHaveChildren {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("Empty").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(children) { child in
                            TreeNodeRow(model: model, connection: connection, node: child)
                        }
                    }
                } else if let error = node.loadError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
                } else {
                    Label("Loading…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                taggedRowLabel
            }
            .onChange(of: node.isExpanded) { _, expanded in
                model.saveSession()
                guard expanded else { return }
                Task { await connection.loadChildren(of: node) }
            }
        } else {
            taggedRowLabel
        }
    }

    /// Every tree row carries its own tag, so a click selects that row and nothing else.
    private var taggedRowLabel: some View {
        rowLabel.tag(SidebarSelection.node(id: node.id, bookmarkID: connection.id))
    }

    private var rowLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(node.kind.title)
                .lineLimit(1)
            if let detail = node.kind.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if node.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // No tap gesture here. Any gesture on a row swallows the click that selects it, and only
        // the padding above and below the text stayed clickable. SidebarDoubleClick handles the
        // double click on the table underneath instead.
        .contextMenu {
            if node.kind.isTableLike {
                Button("Open") { open() }
            }
            if case .column = node.kind {
                Button("Show in Table") { open() }
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.kind.title, forType: .string)
            }
            if node.kind.canHaveChildren {
                Button("Refresh") {
                    node.children = nil
                    Task { await connection.loadChildren(of: node) }
                }
            }
        }
    }

    private func open() {
        model.open(node, in: connection)
    }
}


/// One table of the filter result. It carries the schema, because two schemas may hold the same
/// table name.
struct FilterResultRow: View {
    let model: AppModel
    let connection: ConnectionModel
    let table: TableRef

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: table.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(table.name)
                .lineLimit(1)
            Text(table.schema)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open") { open() }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(table.name, forType: .string)
            }
        }
    }

    private func open() {
        model.open(table, in: connection)
    }
}
