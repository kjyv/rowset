import AppKit
import SwiftUI

/// The editor of a query tab.
///
/// It colours the text and marks the statement the caret is in, both from `SQLLexer`. SwiftUI
/// `TextEditor` offers neither the caret position nor a way to colour a range, so this is an
/// `NSTextView`.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Where the caret sits, so the app knows which statement to run.
    @Binding var caret: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, caret: $caret) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = true
        textView.isRichText = false
        textView.font = SyntaxStyle.font
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.string = text

        context.coordinator.textView = textView
        context.coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView

        if textView.string != text, !context.coordinator.isTyping {
            textView.string = text
            context.coordinator.restyle()
        }
    }

    /// What the editor adds to the shared style.
    @MainActor
    enum Style {
        /// The band behind the statement the caret is in.
        static let currentStatement = NSColor.controlAccentColor.withAlphaComponent(0.12)
    }

    /// Which way a key moves the lines of the selection.
    enum Move {
        case deeper
        case shallower
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let caret: Binding<Int>
        weak var textView: NSTextView?
        var isTyping = false

        init(text: Binding<String>, caret: Binding<Int>) {
            self.text = text
            self.caret = caret
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isTyping = true
            text.wrappedValue = textView.string
            isTyping = false
            restyle()
        }

        /// Sends Tab and Shift-Tab to `LineIndenter`.
        ///
        /// Both keys always count as handled. Shift-Tab on a line with no indent would otherwise
        /// move the keyboard to another view, which loses the place in the query.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let move = Self.move(for: selector, event: NSApp.currentEvent) else {
                return false
            }
            apply(move, in: textView)
            return true
        }

        /// Which way a key moves the lines, or `nil` for a key that belongs to the text view.
        ///
        /// The key decides, not the selector alone. The standard key bindings turn Shift-Tab
        /// into `insertBacktab:`, but the key also arrives as `insertTab:` with the Shift flag
        /// on it. Both mean dedent, so the Shift flag of the key wins over the selector.
        static func move(for selector: Selector, event: NSEvent?) -> Move? {
            let isTab = selector == #selector(NSResponder.insertTab(_:))
            let isBacktab = selector == #selector(NSResponder.insertBacktab(_:))
            guard isTab || isBacktab else { return nil }

            let shift = event?.type == .keyDown && event?.modifierFlags.contains(.shift) == true
            return isBacktab || shift ? .shallower : .deeper
        }

        /// Moves the lines of the selection one step, and writes the edit into the view.
        ///
        /// The pair of `shouldChangeText` and `didChangeText` puts the edit on the undo stack and
        /// tells the delegate, which then writes the text back to the tab and colours it again.
        private func apply(_ move: Move, in textView: NSTextView) {
            let selection = textView.selectedRange()
            let edit = move == .deeper
                ? LineIndenter.indent(textView.string, selection: selection)
                : LineIndenter.dedent(textView.string, selection: selection)

            guard let edit,
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement)
            else { return }

            textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(edit.selection)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            caret.wrappedValue = textView.selectedRange().location
            restyle()
        }

        /// Colours every token and marks the statement the caret is in.
        ///
        /// The whole text is styled at once. A query fits on a screen or two, so the cost is not
        /// worth a smaller update.
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let source = textView.string

            storage.beginEditing()
            storage.setAttributes(
                [.font: SyntaxStyle.font, .foregroundColor: NSColor.labelColor], range: full)

            // The band goes on first, so a colour sits over it and not under it.
            let statements = SQLStatementSplitter.statements(in: source)
            let location = min(textView.selectedRange().location, storage.length)
            if let current = SQLStatementSplitter.statement(at: location, in: statements),
               current.range.upperBound <= storage.length {
                storage.addAttribute(
                    .backgroundColor, value: Style.currentStatement, range: current.range)
            }

            SyntaxStyle.paint(SQLLexer.tokens(in: source), in: storage)

            storage.endEditing()
        }
    }
}
