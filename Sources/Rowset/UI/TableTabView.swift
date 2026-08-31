import SwiftUI

/// A tab that shows the rows of one table.
struct TableTabView: View {
    let model: AppModel
    @Bindable var tab: QueryTab

    @State private var sortOrder: [ColumnComparator] = []
    @State private var limitText = ""

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
            Divider()
            statusBar
        }
        .task {
            limitText = String(tab.rowLimit)
            if tab.result == nil, tab.errorText == nil {
                await model.runTableQuery(tab)
            }
        }
        .onChange(of: sortOrder) { _, newValue in
            let spec = newValue.first?.sortSpec
            guard spec != tab.sort else { return }
            Task { await model.applySort(spec, to: tab) }
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

            Label("WHERE", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("", text: $tab.filterText, prompt: Text("article_identifier = '1004.1'"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { Task { await model.runTableQuery(tab) } }

            Label("ORDER BY", systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(orderByText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tab.sort == nil ? .secondary : .primary)
                .frame(minWidth: 120, alignment: .leading)

            if tab.sort != nil {
                Button {
                    sortOrder = []
                    Task { await model.applySort(nil, to: tab) }
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
            TextField("", text: $limitText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .onSubmit { applyLimit() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var orderByText: String {
        guard let sort = tab.sort else { return "none" }
        return "\(sort.column) \(sort.sqlDirection)"
    }

    private func applyLimit() {
        guard let value = Int(limitText), value > 0 else {
            limitText = String(tab.rowLimit)
            return
        }
        tab.rowLimit = value
        Task { await model.runTableQuery(tab) }
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
                ResultTableView(result: result, sortOrder: $sortOrder)
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
