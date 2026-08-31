import Foundation

/// One cell, ready to show.
struct DisplayValue: Hashable, Sendable {
    var text: String
    var isNull: Bool = false
    /// True when the renderer could not decode the type and fell back to a byte dump.
    var isRaw: Bool = false

    static let null = DisplayValue(text: "NULL", isNull: true)
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
        index < values.count ? values[index] : DisplayValue(text: "", isNull: true)
    }
}

/// The result of one statement.
struct ResultSet: Sendable {
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
}
