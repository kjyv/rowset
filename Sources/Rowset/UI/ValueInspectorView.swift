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
        .onChange(of: editing?.tab.paneEditRequests) { _, _ in
            guard editing != nil, let value else { return }
            draft = value.isNull ? "" : value.text
            validationMessage = nil
            isEditing = true
        }
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

    private var isJSON: Bool {
        if value?.isJSON == true { return true }
        guard let text = value?.text, value?.isNull == false else { return false }
        return JSONPrettyPrinter.looksLikeJSON(text)
    }

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
                ValueTextView(text: displayText(for: value), findRequest: findRequest)
            }
        } else {
            Text("Click a cell to read its whole value. Double click to open this pane.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func displayText(for value: DisplayValue) -> String {
        guard formatJSON, isJSON else { return value.text }
        return JSONPrettyPrinter.format(value.text) ?? value.text
    }
}

/// A read-only scrolling text area with the standard find bar.
///
/// It uses `NSTextView` and not `Text` in a `ScrollView`. SwiftUI lays out the whole string at
/// once, which stalls on a large document. `NSTextView` lays out only what it draws, and it also
/// brings the find bar that Command-F opens.
private struct ValueTextView: NSViewRepresentable {
    let text: String
    let findRequest: FindRequest

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        // The find bar belongs to NSTextView. It gives search, next, previous, and a match count.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView

        if textView.string != text {
            textView.string = text
            textView.scroll(.zero)
        }

        if context.coordinator.lastFindCounter != findRequest.counter {
            context.coordinator.lastFindCounter = findRequest.counter
            context.coordinator.showFindBar()
        }
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var lastFindCounter = 0

        func showFindBar() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }
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
