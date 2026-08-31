import AppKit
import SwiftUI

/// A one-line text field that completes column names while you type.
///
/// SwiftUI `TextField` has no completion. `NSTextField` has one: the field editor asks its
/// delegate for the words that match, and it draws the list. This view wires that up and calls
/// `complete` after every character you add.
struct CompletingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    /// The words to offer. The filter field passes the column names of the open table.
    var completions: [String] = []
    /// SQL words to offer beside the column names, for example `NULL` and `AND`.
    var keywords: [String] = []
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.removeReturnMonitor()
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // `isBordered` and `isBezeled` exclude each other. `isBordered = true` draws a plain
        // one pixel rectangle. The rounded bezel is what SwiftUI calls `.roundedBorder`.
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.installReturnMonitor(for: field)
        return field
    }

    /// Reports the real height of the field and takes the offered width.
    ///
    /// Without this, SwiftUI reads the size from AppKit and the row grows taller than the field.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSTextField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingTextField
        /// Blocks the loop that starts when a completion writes into the field.
        private var isCompleting = false
        private var lastLength = 0

        private var returnMonitor: Any?

        init(_ parent: CompletingTextField) {
            self.parent = parent
        }

        /// Runs the query on Return, whatever else is on screen.
        ///
        /// The completion list takes the key events of the field editor, so a Return that should
        /// run the query only closed the list. The monitor sees the key first.
        func installReturnMonitor(for field: NSTextField) {
            guard returnMonitor == nil else { return }
            returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak field] event in
                // `NSEvent` is not `Sendable`, so the isolated part answers with a flag only.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let field, let window = field.window, window.isKeyWindow,
                          let editor = field.currentEditor(),
                          window.firstResponder === editor,
                          event.keyCode == 36 || event.keyCode == 76
                    else { return false }

                    self.parent.text = field.stringValue
                    self.parent.onSubmit()
                    return true
                }
                return handled ? nil : event
            }
        }

        func removeReturnMonitor() {
            if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
            returnMonitor = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.stringValue
            parent.text = value

            guard !isCompleting else { return }

            // Offer a completion only while the text grows. A completion during a delete would
            // put back the character you just removed.
            let isGrowing = value.count > lastLength
            lastLength = value.count
            guard isGrowing, let editor = field.currentEditor() as? NSTextView else { return }

            isCompleting = true
            editor.complete(nil)
            isCompleting = false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            lastLength = field.stringValue.count
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>
        ) -> [String] {
            let matches = CompletionEngine.tails(
                in: textView.string,
                partialWordRange: charRange,
                candidates: parent.completions,
                keywords: parent.keywords)
            // -1 means no item is chosen, so AppKit shows the list and writes nothing. With an
            // item chosen it would rewrite what you typed, and a `N` for NULL became the `n` of a
            // column named `name`.
            index.pointee = -1
            return matches
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }

    }
}

/// The part of the completion that does not need AppKit.
///
/// AppKit picks the partial word with its own rules, and it breaks a name such as `created_at` at
/// the underscore. These functions read the whole name out of the text and return only the part
/// that AppKit must add, so the field ends with the full column name.
enum CompletionEngine {

    /// Returns the endings to offer for the word under the caret.
    ///
    /// The answer keeps the letters exactly as you typed them. Without that rule, a `N` for
    /// `NULL` turned into the `n` of a column named `name`, and `NULL` became unreachable.
    static func tails(
        in text: String,
        partialWordRange: NSRange,
        candidates: [String],
        keywords: [String] = []
    ) -> [String] {
        let all = text as NSString
        let end = partialWordRange.location + partialWordRange.length
        guard partialWordRange.location >= 0, partialWordRange.length >= 0, end <= all.length
        else { return [] }

        let start = identifierStart(in: all, before: partialWordRange.location)
        // Inside 'a text literal' a column name means nothing.
        guard !isInsideStringLiteral(all, before: start) else { return [] }

        let typed = all.substring(with: NSRange(location: start, length: end - start))
        guard !typed.isEmpty else { return [] }

        let prefix = typed.lowercased()
        // AppKit replaces only its own range. Keep those characters as the user wrote them.
        let keptPrefix = String(typed.suffix(partialWordRange.length))

        func matching(_ list: [String]) -> [String] {
            list.filter { $0.lowercased().hasPrefix(prefix) && $0.count > typed.count }.sorted()
        }

        // A word in capitals is almost always SQL, so offer the SQL words first.
        let ordered = isAllCapitals(typed)
            ? matching(keywords) + matching(candidates)
            : matching(candidates) + matching(keywords)

        return ordered.map { keptPrefix + String($0.dropFirst(typed.count)) }
    }

    private static func isAllCapitals(_ text: String) -> Bool {
        text.contains(where: { $0.isLetter }) && text == text.uppercased()
    }

    /// True when the caret sits between two single quotes.
    ///
    /// Postgres writes a quote inside a literal as two quotes, and the count handles that on its
    /// own: two quotes flip the state twice.
    static func isInsideStringLiteral(_ text: NSString, before location: Int) -> Bool {
        var inside = false
        for index in 0..<min(location, text.length) where text.character(at: index) == 39 {
            inside.toggle()
        }
        return inside
    }

    /// Walks back over the letters, the digits and the underscores of one name.
    static func identifierStart(in text: NSString, before location: Int) -> Int {
        var start = min(max(location, 0), text.length)
        while start > 0 {
            let character = text.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character) else { break }
            let isNamePart = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
            guard isNamePart else { break }
            start -= 1
        }
        return start
    }
}

/// The SQL words that the two fields offer beside the column names.
enum SQLKeywords {
    static let filter = [
        "ALL", "AND", "ANY", "ASC", "BETWEEN", "DESC", "EXISTS", "FALSE", "ILIKE", "IN", "IS",
        "LIKE", "NOT", "NULL", "OR", "SIMILAR", "TRUE",
    ]

    static let orderBy = ["ASC", "DESC", "FIRST", "LAST", "NULLS"]
}
