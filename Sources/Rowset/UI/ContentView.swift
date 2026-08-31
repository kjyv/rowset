import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.isSidebarVisible ? .all : .detailOnly },
            set: { model.isSidebarVisible = $0 != .detailOnly })
    }

    var body: some View {
        // NavigationSplitView puts the window buttons on the sidebar by itself. Only the detail
        // column keeps a strip of its own at the top, and that one is taken away below.
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 520)
        } detail: {
            DetailView(model: model)
        }
        .background(TitlebarTabBar(model: model))
        .sheet(item: $model.editedBookmark) { bookmark in
            BookmarkEditor(bookmark: bookmark) { saved in
                model.store.upsert(saved)
                Task { await model.forget(bookmarkID: saved.id) }
                model.selectedBookmarkID = saved.id
            }
        }
        .sheet(item: $model.pendingWrite) { write in
            SQLPreviewSheet(
                write: write,
                onCancel: { model.pendingWrite = nil },
                onRun: { Task { await model.commitWrite(write) } })
        }
        .sheet(item: $model.ssoPrompt) { prompt in
            SSOLoginSheet(prompt: prompt) {
                model.ssoPrompt = nil
            }
        }
    }
}

/// The right side: the tab bar over the open tab.
struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {

            if let tab = model.selectedTab {
                switch tab.kind {
                // No `.id(tab.id)` here. The tab object owns the view state, so SwiftUI reuses
                // the view instead of building the whole grid again on every tab switch.
                case .table:
                    TableTabView(model: model, tab: tab)
                case .sql:
                    SQLTabView(model: model, tab: tab)
                }
            } else {
                EmptyDetailView(model: model)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

struct EmptyDetailView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No table is open")
                .font(.title3)
            Text("Connect to a bookmark on the left, then double click a table.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
