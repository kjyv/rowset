import SwiftUI

/// The left column: the bookmark list and, under each open bookmark, the database tree.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedBookmarkID) {
                Section("Connections") {
                    ForEach(model.store.bookmarks) { bookmark in
                        BookmarkSection(model: model, bookmark: bookmark)
                            .tag(bookmark.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            toolbar
        }
        .task { model.syncConnections() }
        .onChange(of: model.store.bookmarks) { _, _ in model.syncConnections() }
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
                Task { await model.forget(bookmarkID: id) }
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

            Spacer()

            if let error = model.store.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
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

    @State private var isExpanded = false

    private var connection: ConnectionModel? { model.connection(id: bookmark.id) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            label
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, let connection, connection.state == .disconnected else { return }
            Task { await model.connect(to: bookmark.id) }
        }
        .contextMenu {
            Button("Connect") { Task { await model.connect(to: bookmark.id) } }
            Button("Disconnect") { Task { await model.disconnect(bookmarkID: bookmark.id) } }
            Button("Refresh") { Task { await connection?.refresh() } }
            Divider()
            Button("New Query Tab") {
                if let connection { model.openSQLTab(connection: connection) }
            }
            .disabled(connection?.state.isConnected != true)
            Divider()
            Button("Edit…") { model.editedBookmark = bookmark }
            Button("Delete", role: .destructive) {
                Task { await model.forget(bookmarkID: bookmark.id) }
                model.store.remove(id: bookmark.id)
            }
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
                rowLabel
            }
            .onChange(of: node.isExpanded) { _, expanded in
                guard expanded else { return }
                Task { await connection.loadChildren(of: node) }
            }
        } else {
            rowLabel
        }
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            if node.kind.isTableLike {
                Button("Open") { open() }
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
        switch node.kind {
        case .table(let schema, let name), .view(let schema, let name):
            let tab = model.openTable(schema: schema, name: name, connection: connection)
            Task { await model.runTableQuery(tab) }
        default:
            node.isExpanded.toggle()
        }
    }
}
