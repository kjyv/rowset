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
}
