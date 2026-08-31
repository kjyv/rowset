import Foundation

/// One cell, ready to show.
struct DisplayValue: Hashable, Sendable {
    /// The whole value. The renderer caps it, see `characterLimit`.
    var text: String
    /// A short single-line form for the grid. The grid never draws `text`.
    var preview: String
    var isNull: Bool = false
    /// True when the renderer could not decode the type and fell back to a byte dump.
    var isRaw: Bool = false
    /// True when the column type is `json` or `jsonb`.
    var isJSON: Bool = false
    /// True when the renderer dropped the end of a very long value.
    var isTruncated: Bool = false

    /// The most characters the app keeps for one cell. A row can hold a document, and the grid
    /// must stay fast, so the renderer stops here.
    static let characterLimit = 1_000_000

    /// The most characters the grid preview shows.
    static let previewLimit = 300

    static let null = DisplayValue(text: "NULL", preview: "NULL", isNull: true)

    /// Caps the text, builds the preview, and returns the value.
    static func make(text: String, isRaw: Bool = false, isJSON: Bool = false) -> DisplayValue {
        // `prefix` stops after the limit, so a huge value costs no full scan.
        let capped = String(text.prefix(characterLimit + 1))
        let isTruncated = capped.count > characterLimit
        let kept = isTruncated ? String(capped.prefix(characterLimit)) : capped

        return DisplayValue(
            text: kept,
            preview: makePreview(kept, truncated: isTruncated),
            isNull: false,
            isRaw: isRaw,
            isJSON: isJSON,
            isTruncated: isTruncated)
    }

    /// Collapses every run of white space into one space and stops at `previewLimit`.
    static func makePreview(_ text: String, truncated: Bool) -> String {
        var out = ""
        out.reserveCapacity(previewLimit)
        var lastWasSpace = false
        var reachedLimit = false

        for character in text {
            if out.count >= previewLimit {
                reachedLimit = true
                break
            }
            if character.isWhitespace {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }

        if reachedLimit || truncated { out.append("…") }
        return out
    }
}

/// One column of a result.
struct ResultColumn: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var typeName: String
}

/// One row of a result.
struct ResultRow: Identifiable, Hashable, Sendable {
    var id: Int
    var values: [DisplayValue]

    func value(at index: Int) -> DisplayValue {
        index < values.count ? values[index] : DisplayValue(text: "", preview: "", isNull: true)
    }
}

/// Names one cell of a result.
struct CellAddress: Hashable, Sendable {
    var rowID: Int
    var columnID: Int
}

/// A rectangle of cells.
///
/// The anchor is where the drag started and the focus is where it is now. A shift click moves the
/// focus and leaves the anchor, which is how a block grows.
struct CellSelection: Hashable, Sendable {
    var anchor: CellAddress
    var focus: CellAddress

    init(anchor: CellAddress, focus: CellAddress) {
        self.anchor = anchor
        self.focus = focus
    }

    init(single cell: CellAddress) {
        self.init(anchor: cell, focus: cell)
    }

    var rows: ClosedRange<Int> {
        min(anchor.rowID, focus.rowID)...max(anchor.rowID, focus.rowID)
    }

    var columns: ClosedRange<Int> {
        min(anchor.columnID, focus.columnID)...max(anchor.columnID, focus.columnID)
    }

    var cellCount: Int { rows.count * columns.count }
    var isSingleCell: Bool { cellCount == 1 }

    func contains(row: Int, column: Int) -> Bool {
        rows.contains(row) && columns.contains(column)
    }
}

/// The result of one statement.
struct ResultSet: Sendable, Identifiable {
    /// Names this run. The grid reloads only when the id changes, not on every cell click.
    let id = UUID()
    var columns: [ResultColumn] = []
    var rows: [ResultRow] = []
    /// Seconds the query took, measured in the app.
    var duration: TimeInterval = 0
    /// True when the app stopped reading because it reached the row limit.
    var truncated: Bool = false

    var isEmpty: Bool { rows.isEmpty }

    /// A one-line summary for the status bar.
    var summary: String {
        let count = rows.count
        let noun = count == 1 ? "row" : "rows"
        let limitNote = truncated ? " (limit reached)" : ""
        return String(format: "%d %@%@ in %.3f s", count, noun, limitNote, duration)
    }

    func column(id: Int) -> ResultColumn? {
        columns.first { $0.id == id }
    }

    func row(id: Int) -> ResultRow? {
        rows.first { $0.id == id }
    }

    func value(at address: CellAddress) -> DisplayValue? {
        guard let row = row(id: address.rowID),
              let index = columns.firstIndex(where: { $0.id == address.columnID })
        else { return nil }
        return row.value(at: index)
    }

    /// The column names, separated by tabs.
    var headerLine: String {
        columns.map(\.name).joined(separator: "\t")
    }

    /// The cells of a selection as plain text, NULL as an empty field.
    func block(_ selection: CellSelection, includeHeader: Bool) -> [[String]] {
        let columnRange = selection.columns.clamped(to: 0...max(0, columns.count - 1))
        guard !columns.isEmpty else { return [] }

        var block: [[String]] = []
        if includeHeader {
            block.append(columnRange.map { columns[$0].name })
        }
        for rowID in selection.rows {
            guard let row = row(id: rowID) else { continue }
            block.append(columnRange.map { index in
                let value = row.value(at: index)
                return value.isNull ? "" : value.text
            })
        }
        return block
    }

    /// One row, separated by tabs. A NULL becomes an empty field.
    func line(for row: ResultRow) -> String {
        columns.indices
            .map { index -> String in
                let value = row.value(at: index)
                return value.isNull ? "" : value.text.replacingOccurrences(of: "\t", with: " ")
            }
            .joined(separator: "\t")
    }
}
