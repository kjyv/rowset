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
