import SwiftUI

/// The grid with the value inspector below it. Both tab types use this.
struct ResultPane: View {
    @Bindable var tab: QueryTab
    let result: ResultSet

    var body: some View {
        if tab.isInspectorVisible {
            VSplitView {
                grid.frame(minHeight: 120)
                ValueInspectorView(
                    column: tab.selectedColumn,
                    value: tab.selectedValue,
                    onClose: { tab.isInspectorVisible = false })
                    .frame(minHeight: 70, idealHeight: 190)
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ResultTableView(
            result: result,
            sortOrder: $tab.sortOrder,
            selectedCell: $tab.selectedCell,
            revealColumn: $tab.revealColumn,
            onOpenValue: { tab.isInspectorVisible = true })
    }
}

/// The button that brings the inspector back.
struct InspectorToggle: View {
    @Bindable var tab: QueryTab

    var body: some View {
        Button {
            tab.isInspectorVisible.toggle()
        } label: {
            Image(systemName: tab.isInspectorVisible
                  ? "rectangle.bottomthird.inset.filled"
                  : "rectangle")
        }
        .buttonStyle(.borderless)
        .help(tab.isInspectorVisible ? "Hide the value pane" : "Show the value pane")
    }
}
