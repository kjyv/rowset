import AppKit
import Observation
import SwiftUI

/// Carries a find request from the pane header down to the text view.
@MainActor
@Observable
final class FindRequest {
    private(set) var counter = 0

    func show() { counter += 1 }
}

/// Shows the whole value of the cell you clicked.
///
/// The grid draws a short preview, so this pane is the place to read a long string. It formats a
/// JSON value and keeps the key order that the server sent.
struct ValueInspectorView: View {
    let column: ResultColumn?
    let value: DisplayValue?
    let onClose: () -> Void
    /// The tab and the cell to write back to. `nil` means the pane only reads.
    var editing: (tab: QueryTab, address: CellAddress)?

    @State private var formatJSON = true
    @State private var lastEditRequest: EditRequest?
    @State private var findRequest = FindRequest()
    @State private var draft = ""
    @State private var isEditing = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        .onChange(of: value) { _, _ in
            isEditing = false
            validationMessage = nil
        }
        // The Return key of the grid asks the pane to start an edit, for a value that has more
        // than one line and does not fit a cell.
        //
        // Only a count that goes up is a request. The pane has no cell to write to until you pick
        // one, so the first cell you pick moves the count from none to zero. Reading that as a
        // request opened the editor on the first click of every table, and the editor shows the
        // plain text, neither formatted nor coloured.
        .onChange(of: editRequest, initial: true) { _, new in
            let previous = lastEditRequest
            lastEditRequest = new
            guard let new, let previous, previous.tab == new.tab, new.count > previous.count,
                  let value
            else { return }
            draft = value.isNull ? "" : value.text
            validationMessage = nil
            isEditing = true
        }
    }

    /// Names one ask for an edit: which tab asked, and how many times it has asked.
    ///
    /// The tab belongs in it. A tab switch reuses this view, and the count of the next tab says
    /// nothing about the count of the last one.
    struct EditRequest: Equatable {
        var tab: QueryTab.ID
        var count: Int
    }

    private var editRequest: EditRequest? {
        guard let editing else { return nil }
        return EditRequest(tab: editing.tab.id, count: editing.tab.paneEditRequests)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)

            Text(column?.name ?? "Value")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if let column {
                Text(column.typeName.lowercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if value?.isTruncated == true {
                Label("cut at \(DisplayValue.characterLimit) characters", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if isEditing {
                Button("Cancel") { isEditing = false; validationMessage = nil }
                    .font(.caption)
                Button("Apply") { applyEdit() }
                    .font(.caption)
                    .keyboardShortcut(.return, modifiers: .command)
            } else if editing != nil, value != nil {
                Button {
                    draft = value?.isNull == true ? "" : (value?.text ?? "")
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Change this value")
            }

            if isJSON {
                Toggle("Format", isOn: $formatJSON)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            Button {
                findRequest.show()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .disabled(value == nil || value?.isNull == true)
            .help("Search in this value (Command-F)")

            Button {
                Clipboard.write(value?.isNull == true ? "" : (value?.text ?? ""))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(value == nil)
            .help("Copy the whole value")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide this pane")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var isJSON: Bool { value?.readsAsJSON == true }

    private func applyEdit() {
        guard let editing else { return }
        let kind = editing.tab.info(at: editing.address)?.kind ?? .text

        guard ValueValidator.isValid(draft, for: kind) else {
            validationMessage = ValueValidator.message(for: kind)
            return
        }

        validationMessage = nil
        editing.tab.setEdit(draft, at: editing.address)
        isEditing = false
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            EditableValueView(text: $draft)
        } else if let value {
            if value.isNull {
                Text("NULL")
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SyntaxTextView(
                    text: displayText(for: value), isJSON: isJSON, findRequest: findRequest)
            }
        } else {
            Text("Click a cell to read its whole value. Double click to open this pane.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func displayText(for value: DisplayValue) -> String {
        value.readableText(formatted: formatJSON)
    }
}

/// A text area you can type in. The value pane uses it for a value of more than one line, which
/// does not fit a cell of the grid.
private struct EditableValueView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text, !context.coordinator.isTyping
        else { return }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isTyping = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isTyping = true
            text.wrappedValue = textView.string
            isTyping = false
        }
    }
}
