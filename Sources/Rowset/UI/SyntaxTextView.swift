import AppKit
import SwiftUI

/// A read-only scrolling text area that colours JSON.
///
/// It uses `NSTextView` and not `Text` in a `ScrollView`. SwiftUI lays out the whole string at
/// once, which stalls on a large document. `NSTextView` lays out only what it draws, and it also
/// brings the find bar that Command-F opens.
///
/// The value pane and the row view both show a value, so both come here.
struct SyntaxTextView: NSViewRepresentable {
    let text: String
    /// True when the text is JSON, which the view then colours.
    let isJSON: Bool
    /// Set to bring the find bar. The row view shows one value of many and asks for none.
    var findRequest: FindRequest?

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
        textView.font = SyntaxStyle.font
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        // The find bar belongs to NSTextView. It gives search, next, previous, and a match count.
        textView.usesFindBar = findRequest != nil
        textView.isIncrementalSearchingEnabled = findRequest != nil
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView

        if textView.string != text || context.coordinator.paintedJSON != isJSON {
            textView.textStorage?.setAttributedString(painted())
            context.coordinator.paintedJSON = isJSON
            textView.scroll(.zero)
        }

        if let findRequest, context.coordinator.lastFindCounter != findRequest.counter {
            context.coordinator.lastFindCounter = findRequest.counter
            context.coordinator.showFindBar()
        }
    }

    /// The text with its colours, built in one piece.
    ///
    /// The whole string goes in at once, so the view never holds a text that is half painted.
    /// Reading `textStorage` is safe here: only `layoutManager` moves an `NSTextView` back to
    /// TextKit 1, and this view needs TextKit 2 to lay out a large document by the part it draws.
    ///
    /// A cell can hold a large document, so a long one stays plain. `SyntaxStyle.lengthLimit`
    /// says where that starts.
    private func painted() -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: SyntaxStyle.font, .foregroundColor: NSColor.labelColor])
        if isJSON, result.length <= SyntaxStyle.lengthLimit {
            SyntaxStyle.paint(JSONLexer.tokens(in: text), in: result)
        }
        return result
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var lastFindCounter = 0
        /// Whether the text now in the view was painted as JSON.
        var paintedJSON: Bool?

        func showFindBar() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }
    }
}
