import SwiftUI

/// The left column: the bookmark list and, under each open bookmark, the database tree.
struct SidebarView: View {
    @Bindable var model: AppModel

    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SidebarOutline(model: model)
                // Command-F belongs to the sidebar only while the keyboard is in it. Every
                // editor in the window uses that key for its own find bar.
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
                Task { await model.deleteConnection(bookmarkID: id) }
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
