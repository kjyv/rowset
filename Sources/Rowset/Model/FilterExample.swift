import Foundation

/// Builds the example that the WHERE field shows when it is empty.
///
/// The example names a real column of the open table, so you can see what to type without a look
/// at the tree.
enum FilterExample {

    /// Picks the column that makes the clearest example.
    ///
    /// A text column reads best. A time column comes next, then a number. Anything is better than
    /// a made-up name.
    static func pick(from columns: [ResultColumn]) -> ResultColumn? {
        let ranked = columns.sorted { left, right in
            rank(left) < rank(right)
        }
        return ranked.first
    }

    private static func rank(_ column: ResultColumn) -> Int {
        switch family(of: column.typeName) {
        case .text: 0
        case .time: 1
        case .number: 2
        case .boolean: 3
        case .other: 4
        }
    }

    static func text(for column: ResultColumn) -> String {
        switch family(of: column.typeName) {
        case .text: "\(column.name) = 'value'"
        case .time: "\(column.name) > '2024-01-01'"
        case .number: "\(column.name) = 0"
        case .boolean: "\(column.name) IS TRUE"
        case .other: "\(column.name) IS NOT NULL"
        }
    }

    enum Family {
        case text, number, time, boolean, other
    }

    /// Reads the type name that `information_schema` reports, for example `character varying`.
    static func family(of typeName: String) -> Family {
        let name = typeName.lowercased()
        if name.contains("char") || name == "text" || name.contains("string") { return .text }
        if name.contains("timestamp") || name.contains("date") || name.contains("time") { return .time }
        if name.contains("int") || name.contains("numeric") || name.contains("decimal")
            || name.contains("real") || name.contains("double") || name.contains("float") {
            return .number
        }
        if name.contains("bool") { return .boolean }
        return .other
    }
}
