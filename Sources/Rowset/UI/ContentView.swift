import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 520)
        } detail: {
            DetailView(model: model)
        }
        .sheet(item: $model.editedBookmark) { bookmark in
            BookmarkEditor(bookmark: bookmark) { saved in
                model.store.upsert(saved)
                Task { await model.forget(bookmarkID: saved.id) }
                model.selectedBookmarkID = saved.id
            }
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
            if !model.tabs.isEmpty {
                TabBarView(model: model)
                Divider()
            }

            if let tab = model.selectedTab {
                switch tab.kind {
                case .table:
                    TableTabView(model: model, tab: tab)
                        .id(tab.id)
                case .sql:
                    SQLTabView(model: model, tab: tab)
                        .id(tab.id)
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
