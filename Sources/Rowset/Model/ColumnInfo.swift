import Foundation

/// The family a column type belongs to. It decides what an editor accepts.
enum ColumnKind: Sendable, Hashable {
    case boolean
    case integer
    case number
    case uuid
    case json
    /// A date, a time or an interval. The server reads these, so the app does not check them.
    case temporal
    case text

    /// Reads the type name that `information_schema` reports, for example `character varying`.
    static func of(_ typeName: String) -> ColumnKind {
        let name = typeName.lowercased()
        if name.contains("bool") { return .boolean }
        if name == "smallint" || name == "integer" || name == "bigint"
            || name.hasPrefix("int") || name == "serial" || name == "bigserial" {
            return .integer
        }
        if name.contains("numeric") || name.contains("decimal") || name.contains("real")
            || name.contains("double") || name.contains("float") {
            return .number
        }
        if name == "uuid" { return .uuid }
        if name.contains("json") { return .json }
        if name.contains("timestamp") || name.contains("date") || name.contains("time")
            || name.contains("interval") {
            return .temporal
        }
        return .text
    }
}

/// What the catalog says about one column.
struct ColumnInfo: Hashable, Sendable {
    var name: String
    var typeName: String
    var isNullable: Bool

    var kind: ColumnKind { ColumnKind.of(typeName) }

    /// True when one value of this column can be large enough to be worth leaving on the server.
    ///
    /// A grid shows a few hundred characters of a cell. Fetching a JSON document of half a
    /// megabyte to show three hundred characters of it is the whole cost of opening a wide table.
    var isLarge: Bool {
        let name = typeName.lowercased()
        return name.contains("json") || name == "array" || name == "text"
            || name == "bytea" || name == "xml"
    }
}
