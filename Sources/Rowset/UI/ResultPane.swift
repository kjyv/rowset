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
                        onClose: { model.isInspectorVisible = false },
                        editing: inspectorTarget)
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

    /// The grid, with the page widget floating at its own bottom edge.
    ///
    /// The widget belongs to the grid and not to the pane. On the pane it sat at the bottom of
    /// the value view once that opened, which is not where the rows are.
    private var grid: some View {
        table
            .overlay(alignment: .bottom) {
                if tab.showsPageBar {
                    PageBar(model: model, tab: tab)
                        .padding(.bottom, 14)
                }
            }
    }

    private var table: some View {
        tableView
            .sheet(isPresented: showsRowInspector) {
                RowInspectorSheet(
                    result: result,
                    rowID: $tab.quickLookRow,
                    onClose: { tab.quickLookRow = nil })
            }
    }

    /// The whole row view is open while the tab names a row for it.
    private var showsRowInspector: Binding<Bool> {
        Binding(
            get: { tab.quickLookRow != nil },
            set: { if !$0 { tab.quickLookRow = nil } })
    }

    private var tableView: some View {
        ResultTableView(
            result: result,
            sortOrder: $tab.sortOrder,
            selection: $tab.selection,
            revealColumn: $tab.revealColumn,
            onQuickLook: { tab.quickLookRow = $0 },
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
            // The icon shows what the button does, not what the pane is doing. A filled band
            // means the click brings the pane, and a plain rectangle means it takes it away.
            Image(systemName: model.isInspectorVisible
                  ? "rectangle"
                  : "rectangle.bottomthird.inset.filled")
        }
        .buttonStyle(.borderless)
        .help(model.isInspectorVisible ? "Hide the value pane" : "Show the value pane")
    }
}
