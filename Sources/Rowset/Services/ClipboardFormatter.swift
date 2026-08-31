import Foundation

/// How a block of cells reaches the clipboard.
enum ClipboardFormat: Sendable {
    /// Tab separated. This is what a spreadsheet expects from the clipboard.
    case tsv
    /// Comma separated, quoted after RFC 4180.
    case csv
}

/// Turns a block of cells into text.
enum ClipboardFormatter {

    static func text(_ rows: [[String]], format: ClipboardFormat) -> String {
        switch format {
        case .tsv: tsv(rows)
        case .csv: csv(rows)
        }
    }

    /// Tab separated. A tab or a line break inside a value becomes a space, because the format
    /// has no way to hold one.
    static func tsv(_ rows: [[String]]) -> String {
        rows
            .map { row in row.map(flatten).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// Comma separated after RFC 4180. A value keeps its line breaks inside quotes.
    static func csv(_ rows: [[String]]) -> String {
        rows
            .map { row in row.map(quote).joined(separator: ",") }
            .joined(separator: "\n")
    }

    private static func flatten(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func quote(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
