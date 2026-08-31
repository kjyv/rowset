import SwiftUI

/// A tab with a free-form statement and its result.
struct SQLTabView: View {
    let model: AppModel
    @Bindable var tab: QueryTab

    var body: some View {
        VSplitView {
            editor
                .frame(minHeight: 90, idealHeight: 150)
            VStack(spacing: 0) {
                Divider()
                content
                Divider()
                statusBar
            }
            .frame(minHeight: 160)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.runSQLTab(tab) }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(tab.isRunning
                          || tab.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run the statement (Command-Return)")

                Text("Read at most")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $tab.rowLimitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit { applyLimit() }
                Text("rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                InspectorToggle(tab: tab)

                Spacer()
                Text(tab.connectionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            TextEditor(text: $tab.sqlText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = tab.errorText {
            QueryErrorView(message: error, statement: tab.lastStatement)
        } else if let result = tab.result {
            if result.columns.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("The statement finished and returned no row.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultPane(tab: tab, result: result)
            }
        } else {
            Text("Write a statement, then press Command-Return.")
                .foregroundStyle(.secondary)
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
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func applyLimit() {
        guard let value = Int(tab.rowLimitText), value > 0 else {
            tab.rowLimitText = String(tab.rowLimit)
            return
        }
        tab.rowLimit = value
    }
}
