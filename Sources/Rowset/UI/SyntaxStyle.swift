import AppKit

/// How coloured text looks. One place, so a colour is changed once.
///
/// The SQL editor and the value pane both paint tokens, and both come here for the colour.
@MainActor
enum SyntaxStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: NSColor.systemPurple
        case .string: NSColor.systemRed
        case .number: NSColor.systemTeal
        case .comment: NSColor.secondaryLabelColor
        case .quotedIdentifier, .key: NSColor.systemBlue
        case .parameter: NSColor.systemOrange
        case .identifier, .punctuation: NSColor.labelColor
        }
    }

    /// The longest text this app colours.
    ///
    /// A cell can hold a document of a megabyte. Colouring it means thousands of runs in the text
    /// storage, and the pane would stall on every scroll. Past this length the text stays plain,
    /// which is still readable.
    static let lengthLimit = 200_000

    /// Paints every token of a text, and nothing else.
    ///
    /// The caller sets the plain attributes first. This adds only the colours, so a background
    /// band or another attribute set before it stays.
    static func paint(_ tokens: [SyntaxToken], in storage: NSMutableAttributedString) {
        for token in tokens where token.range.upperBound <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
    }
}
