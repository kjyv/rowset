import SwiftUI

/// The page widget that floats over the grid.
///
/// It shows which rows are on screen and how many there are in all. The count is not asked for
/// until you press it, because a count over a large table is a real query. Until then the number
/// carries a plus, which the extra row of every page pays for.
struct PageBar: View {
    let model: AppModel
    @Bindable var tab: QueryTab

    /// The page sizes the menu offers.
    static let pageSizes = [25, 50, 100, 200, 500, 1000]

    // MARK: - One widget, two owners
    //
    // A table tab pages its own query. A console pages the statement it ran, wrapped in a SELECT.
    // The three calls below are the only place the two differ.

    private func goTo(_ offset: Int) async {
        switch tab.kind {
        case .table: await model.goToPage(offset: offset, in: tab)
        case .sql: await model.goToStatementPage(offset: offset, in: tab)
        }
    }

    private func count() async {
        switch tab.kind {
        case .table: await model.countRows(in: tab)
        case .sql: await model.countStatementRows(in: tab)
        }
    }

    private func reload() async {
        switch tab.kind {
        case .table: await model.reloadTable(tab)
        case .sql: await model.goToStatementPage(offset: 0, in: tab)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            step(
                "chevron.left.to.line", help: "First page",
                enabled: !tab.isFirstPage
            ) {
                await goTo(0)
            }

            step(
                "chevron.left", help: "Previous page",
                enabled: !tab.isFirstPage
            ) {
                await goTo(tab.pageOffset - tab.rowLimit)
            }

            rangeMenu

            totalButton

            step(
                "chevron.right", help: "Next page",
                enabled: !tab.isLastPage
            ) {
                await goTo(tab.pageOffset + tab.rowLimit)
            }

            step(
                "chevron.right.to.line", help: "Last page",
                enabled: !tab.isLastPage
            ) {
                if tab.lastPageOffset == nil { await count() }
                guard let last = tab.lastPageOffset else { return }
                await goTo(last)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
    }

    private func step(
        _ symbol: String, help: String, enabled: Bool, action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || tab.isRunning)
        .help(help)
    }

    /// The rows on screen, and a menu that changes how many fit on a page.
    private var rangeMenu: some View {
        Menu {
            ForEach(Self.pageSizes, id: \.self) { size in
                Button {
                    tab.rowLimit = size
                    Task { await reload() }
                } label: {
                    if size == tab.rowLimit {
                        Label("\(size) rows a page", systemImage: "checkmark")
                    } else {
                        Text("\(size) rows a page")
                    }
                }
            }
        } label: {
            Text(tab.pageRange)
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How many rows fit on a page")
    }

    /// The total. A plus means the count has not run yet.
    private var totalButton: some View {
        Button {
            Task { await count() }
        } label: {
            HStack(spacing: 4) {
                Text("of \(tab.totalDescription)")
                    .monospacedDigit()
                if tab.isCounting {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(tab.totalRows != nil || tab.isCounting)
        .help(tab.totalRows == nil ? "Count every row the filter matches" : "The whole count")
    }
}
