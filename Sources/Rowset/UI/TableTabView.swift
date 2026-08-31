import SwiftUI

/// A tab that shows the rows of one table.
struct TableTabView: View {
    let model: AppModel
    @Bindable var tab: QueryTab

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if tab.hasEdits {
                editBar
                Divider()
            }
            content
            Divider()
            statusBar
        }
        // The identity is the tab, so the query runs again when the view moves to another tab.
        .task(id: tab.id) {
            if tab.result == nil, tab.errorText == nil {
                await model.runTableQuery(tab)
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refreshTable(tab) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Fetch this page again")
            .disabled(tab.isRunning)

            Text("WHERE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            CompletingTextField(
                text: $tab.filterText,
                placeholder: tab.filterPlaceholder,
                completions: tab.completionNames,
                keywords: SQLKeywords.filter,
                onSubmit: { Task { await model.reloadTable(tab) } })
                .frame(minWidth: 160)

            Text("ORDER BY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            CompletingTextField(
                text: $tab.orderByText,
                placeholder: tab.orderByPlaceholder,
                completions: tab.completionNames,
                keywords: SQLKeywords.orderBy,
                onSubmit: { Task { await model.resortTable(tab) } })
                .frame(minWidth: 120, maxWidth: 240)

            if !tab.orderByText.isEmpty {
                Button {
                    tab.orderByText = ""
                    Task { await model.resortTable(tab) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove the sort")
            }

            Divider().frame(height: 16)

            consoleButton
            InspectorToggle(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Turns this tab into a console on the query the fields stand for.
    private var consoleButton: some View {
        Button {
            Task { await model.openConsole(on: tab) }
        } label: {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help("Open this query in a console. The tab becomes a console and stays one.")
    }

    /// A header click already wrote the new ORDER BY, so the rows are fetched again.
    ///
    /// The page stays where it was. A new sort orders the same rows, so neither the page nor the
    /// count it counted is wrong.
    private func sortChanged() {
        Task { await model.resortTable(tab) }
    }


    /// The bar that appears once you change a cell.
    private var editBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .foregroundStyle(.orange)
            Text(editSummary)
                .font(.caption)

            Text("Delete sets a cell to NULL")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Discard") { tab.discardEdits() }
                .disabled(tab.isRunning)
            Button("Submit…") { model.prepareWrite(for: tab) }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(tab.isRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.12))
    }

    private var editSummary: String {
        let count = tab.edits.count
        let cells = count == 1 ? "1 cell" : "\(count) cells"
        return "\(cells) changed and not sent"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = tab.errorText {
            QueryErrorView(message: error, statement: tab.lastStatement)
        } else if let result = tab.result {
            if result.columns.isEmpty {
                Text("The query returned no column.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultPane(
                    model: model, tab: tab, result: result, editable: tab.isEditable,
                    onSortChange: sortChanged)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if tab.isRunning {
                ProgressView().controlSize(.small)
                Text("Running…")
            } else if let result = tab.result, tab.errorText == nil {
                Text(result.summary)
            }
            Spacer()
            Text(tab.subtitle)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        // A fixed height on purpose. The spinner is taller than the text beside it, so the bar
        // grew while a query ran, pushed the grid up, and the page widget moved with it.
        .frame(height: 22)
        .background(.bar)
    }
}

/// Shows a failed statement and the message from the server.
struct QueryErrorView: View {
    let message: String
    let statement: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !statement.isEmpty {
                    Text("Statement")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(statement)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
