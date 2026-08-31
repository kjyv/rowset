import SwiftUI

/// A tab that shows the rows of one table.
struct TableTabView: View {
    let model: AppModel
    @Bindable var tab: QueryTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.showsConsole {
                consoleBar
                Divider()
                console
            } else {
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
                Task { await model.runTableQuery(tab) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Run the query again")
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
                onSubmit: { Task { await model.runTableQuery(tab) } })
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
                onSubmit: { Task { await model.runTableQuery(tab) } })
                .frame(minWidth: 120, maxWidth: 240)

            if !tab.orderByText.isEmpty {
                Button {
                    tab.orderByText = ""
                    Task { await model.runTableQuery(tab) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove the sort")
            }

            Divider().frame(height: 16)

            Text("Rows")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            TextField("", text: $tab.rowLimitText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .onSubmit { applyLimit() }

            consoleToggle
            InspectorToggle(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The button that swaps the filter fields for a console.
    private var consoleToggle: some View {
        Button {
            model.toggleConsole(tab)
        } label: {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(tab.showsConsole
              ? "Back to the filter fields"
              : "Open a console on this query")
    }

    // MARK: - Console

    /// The bar of the console, in the place the filter fields had.
    private var consoleBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.runCurrentStatement(tab) }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(tab.isRunning || tab.currentStatement == nil)
            .help("Run the statement the caret is in (Command-Return)")

            Button {
                Task { await model.runAllStatements(tab) }
            } label: {
                Label("Run All", systemImage: "play.square.stack")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(tab.isRunning || tab.sqlStatements.count < 2)
            .help("Run every statement, one after the other (Shift-Command-Return)")

            Button("From Table") { model.resetConsoleFromFilter(tab) }
                .help("Write the query of the filter fields here again")

            Divider().frame(height: 16)

            Text("Rows")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            TextField("", text: $tab.rowLimitText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .onSubmit { applyLimit() }

            Spacer()

            if tab.isRunning {
                ProgressView().controlSize(.small)
            } else if let result = tab.result, tab.errorText == nil {
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            consoleToggle
            InspectorToggle(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The editor over the same grid the filter fields showed.
    private var console: some View {
        VSplitView {
            SQLEditorView(text: $tab.sqlText, caret: $tab.sqlCaret)
                .frame(minHeight: 80, idealHeight: 140)
            VStack(spacing: 0) {
                Divider()
                content
                Divider()
                statusBar
            }
            .frame(minHeight: 160)
        }
    }

    /// A header click already wrote the new ORDER BY, so the rows are fetched again.
    ///
    /// The console owns its own ORDER BY, so a header click changes nothing there. Rewriting the
    /// statement under you would throw away what you wrote.
    private func sortChanged() {
        guard !tab.showsConsole else { return }
        Task { await model.runTableQuery(tab) }
    }

    private func applyLimit() {
        guard let value = Int(tab.rowLimitText), value > 0 else {
            tab.rowLimitText = String(tab.rowLimit)
            return
        }
        tab.rowLimit = value

        if tab.showsConsole {
            Task { await model.runCurrentStatement(tab) }
        } else {
            Task { await model.runTableQuery(tab) }
        }
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
        .padding(.vertical, 5)
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
