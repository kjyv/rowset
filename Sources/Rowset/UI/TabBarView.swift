import SwiftUI

/// The document tab bar. SwiftUI has no such control on macOS, so the app draws its own.
struct TabBarView: View {
    @Bindable var model: AppModel

    /// The height of one tab row. The bar material may fill the strip above it, but no tab may.
    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        TabButton(
                            tab: tab,
                            isSelected: tab.id == model.selectedTabID,
                            select: { model.selectedTabID = tab.id },
                            close: { model.closeTab(id: tab.id) })
                        Divider().frame(height: 18)
                    }
                }
            }

            newQueryButton
        }
        .frame(height: TabBarView.height)
    }

    /// The same action as Command-T. A shortcut with no button is a shortcut nobody finds.
    private var newQueryButton: some View {
        Button {
            guard let connection = model.activeConnection else { return }
            model.openSQLTab(connection: connection)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: TabBarView.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.activeConnection == nil)
        .help("New query tab (Command-T)")
    }
}

private struct TabButton: View {
    @Bindable var tab: QueryTab
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
