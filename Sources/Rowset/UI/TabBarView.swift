import SwiftUI

/// The document tab bar. SwiftUI has no such control on macOS, so the app draws its own.
struct TabBarView: View {
    @Bindable var model: AppModel

    var body: some View {
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
        .frame(height: 30)
        .background(.bar)
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
        .frame(height: 30)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
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
