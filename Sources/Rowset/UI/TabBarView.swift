import SwiftUI

/// The document tab bar. SwiftUI has no such control on macOS, so the app draws its own.
struct TabBarView: View {
    @Bindable var model: AppModel

    /// The height of one tab row. The bar material may fill the strip above it, but no tab may.
    static let height: CGFloat = 28

    /// The tab you picked up, and the tab the pointer stands on.
    @State private var dragging: QueryTab.ID?
    @State private var dropTarget: QueryTab.ID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        TabButton(
                            tab: tab,
                            qualifier: model.qualifier(for: tab),
                            isSelected: tab.id == model.selectedTabID,
                            select: { model.selectedTabID = tab.id },
                            close: { model.closeTab(id: tab.id) })
                            // The id of the tab is all the drag carries. The tabs of this
                            // window are the only place it means anything. `onDrag` and not
                            // `draggable`, because the caret needs to know what you picked up
                            // and only this one says so as the drag starts.
                            .onDrag {
                                dragging = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                defer {
                                    dragging = nil
                                    dropTarget = nil
                                }
                                guard let dragged = items.first,
                                      let id = UUID(uuidString: dragged)
                                else { return false }
                                return model.moveTab(id: id, onto: tab.id)
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTarget = tab.id
                                } else if dropTarget == tab.id {
                                    dropTarget = nil
                                }
                            }
                            .overlay(alignment: landsAfter(tab) ? .trailing : .leading) {
                                caret(for: tab)
                            }
                        Divider().frame(height: 18)
                    }
                }
            }

            newQueryButton
        }
        .frame(height: TabBarView.height)
    }

    /// The line that says where the tab you carry is going to land.
    @ViewBuilder
    private func caret(for tab: QueryTab) -> some View {
        if dropTarget == tab.id, let dragging, dragging != tab.id {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 3)
        }
    }

    /// True when the tab you carry lands to the right of this one.
    ///
    /// It follows `moveTab`: a tab that comes from the left goes after the tab you drop it on,
    /// and one that comes from the right goes before it.
    private func landsAfter(_ tab: QueryTab) -> Bool {
        guard let dragging,
              let from = model.tabs.firstIndex(where: { $0.id == dragging }),
              let to = model.tabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        return from < to
    }

    /// The same action as Command-T. A shortcut with no button is a shortcut nobody finds.
    private var newQueryButton: some View {
        Button {
            guard let connection = model.activeConnection else { return }
            model.openSQLTab(connection: connection)
        } label: {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: TabBarView.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.activeConnection == nil)
        .help("New console (Command-T)")
    }
}

private struct TabButton: View {
    @Bindable var tab: QueryTab
    /// The database, and the schema when two tabs share a table name.
    let qualifier: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.kind.symbolName)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)

            if let qualifier {
                Text(qualifier)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if tab.isRunning {
                ProgressView().controlSize(.mini)
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close this tab")
        }
        .padding(.horizontal, 10)
        .frame(height: TabBarView.height)
        .background(alignment: .bottom) {
            // The height is fixed on purpose. Without it SwiftUI stretches the tint into the
            // safe area at the top of the window and the tab bleeds into the title bar strip.
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
                .frame(height: TabBarView.height)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.subtitle)
    }
}
