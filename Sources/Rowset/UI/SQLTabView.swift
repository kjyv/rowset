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
        // The editor holds the working copy. Every change goes back into its buffer, and the
        // store waits half a second before it writes the file.
        .onChange(of: tab.sqlText) { _, _ in model.persistBuffer(tab) }
    }

    private var editor: some View {
        VStack(spacing: 0) {
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

                bufferMenu

                Divider().frame(height: 16)

                InspectorToggle(model: model)

                Spacer()

                if tab.sqlStatements.count > 1 {
                    Text(statementPosition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(tab.connectionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            SQLEditorView(text: $tab.sqlText, caret: $tab.sqlCaret)
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
                ResultPane(model: model, tab: tab, result: result)
                    .overlay(alignment: .bottom) {
                        if tab.showsPageBar {
                            PageBar(model: model, tab: tab)
                                .padding(.bottom, 14)
                        }
                    }
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
        // A fixed height on purpose. The spinner is taller than the text beside it, so the bar
        // grew while a query ran, pushed the grid up, and the page widget moved with it.
        .frame(height: 22)
        .background(.bar)
    }

    /// The list of saved consoles of this connection, and the way to add or drop one.
    ///
    /// A console takes its name from its first line, so switching needs no rename dialog and the
    /// name stays right while you type.
    private var bufferMenu: some View {
        let buffers = model.buffers(for: tab)

        return Menu {
            if buffers.isEmpty {
                Text("No saved console")
            } else {
                ForEach(buffers) { buffer in
                    Button {
                        model.switchBuffer(tab, to: buffer.id)
                    } label: {
                        if buffer.id == tab.bufferID {
                            Label(buffer.title, systemImage: "checkmark")
                        } else {
                            Text(buffer.title)
                        }
                    }
                }
            }

            Divider()

            Button("New Console") { model.newBuffer(tab) }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Delete This Console", role: .destructive) { model.deleteBuffer(tab) }
                .disabled(tab.bufferID == nil)

            Button("Delete All Other Consoles", role: .destructive) {
                model.deleteOtherBuffers(tab)
            }
            .disabled(buffers.count < 2)
        } label: {
            Label(currentBufferTitle, systemImage: "list.bullet.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch to another saved console, or start one")
    }

    private var currentBufferTitle: String {
        let buffers = model.buffers(for: tab)
        guard let id = tab.bufferID,
              let buffer = buffers.first(where: { $0.id == id })
        else { return "Console" }
        return buffer.title
    }

    /// Which of the statements the caret is in, for the bar at the top.
    private var statementPosition: String {
        let statements = tab.sqlStatements
        guard let current = tab.currentStatement,
              let index = statements.firstIndex(of: current)
        else { return "" }
        return "statement \(index + 1) of \(statements.count)"
    }

}
