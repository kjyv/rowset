import SwiftUI

/// The grid with the value pane below it.
///
/// The split is built by hand and not with `VSplitView`, because the app must know the height to
/// write it into the session file and to set it again at the next launch.
struct ResultPane: View {
    let model: AppModel
    @Bindable var tab: QueryTab
    let result: ResultSet
    /// True when a cell of this result may be changed.
    var editable = false
    /// Runs when a column header changes the sort.
    var onSortChange: () -> Void = {}

    @State private var dragStartHeight: Double?

    private static let minimumPaneHeight: Double = 70
    private static let minimumGridHeight: Double = 120

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                grid
                if model.isInspectorVisible {
                    handle
                    ValueInspectorView(
                        column: tab.selectedColumn,
                        value: tab.selectedValue,
                        onClose: { model.isInspectorVisible = false })
                        .frame(height: paneHeight(in: geometry.size.height))
                }
            }
        }
    }

    private func paneHeight(in total: Double) -> Double {
        let largest = max(Self.minimumPaneHeight, total - Self.minimumGridHeight)
        return min(max(model.inspectorHeight, Self.minimumPaneHeight), largest)
    }

    /// The bar you drag to change the height of the pane.
    private var handle: some View {
        ZStack {
            Divider()
            Color.clear.frame(height: 6).contentShape(Rectangle())
        }
        .frame(height: 6)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartHeight ?? model.inspectorHeight
                    dragStartHeight = start
                    model.inspectorHeight = max(
                        Self.minimumPaneHeight, start - value.translation.height)
                }
                .onEnded { _ in dragStartHeight = nil })
    }

    /// The cell the pane may change. A table without a primary key stays read only.
    private var inspectorTarget: (tab: QueryTab, address: CellAddress)? {
        guard editable, let address = tab.selectedCell else { return nil }
        return (tab, address)
    }

    private var grid: some View {
        ResultTableView(
            result: result,
            sortOrder: $tab.sortOrder,
            selection: $tab.selection,
            revealColumn: $tab.revealColumn,
            onOpenValue: { model.isInspectorVisible = true },
            onSortChange: onSortChange,
            editing: editable ? tab : nil)
    }
}

/// The button that shows or hides the value pane.
struct InspectorToggle: View {
    let model: AppModel

    var body: some View {
        Button {
            model.isInspectorVisible.toggle()
        } label: {
            Image(systemName: model.isInspectorVisible
                  ? "rectangle.bottomthird.inset.filled"
                  : "rectangle")
        }
        .buttonStyle(.borderless)
        .help(model.isInspectorVisible ? "Hide the value pane" : "Show the value pane")
    }
}
