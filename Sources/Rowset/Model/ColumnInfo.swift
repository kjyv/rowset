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
    /// What the declaration allows, as in `varchar(50)`. `nil` means no limit was given.
    var maximumLength: Int? = nil

    var kind: ColumnKind { ColumnKind.of(typeName) }

    /// True when one value of this column could be large.
    ///
    /// This is what the declaration allows, not what the rows hold. It decides which columns the
    /// grid asks for the size of, and the sizes that come back then decide which are read whole.
    ///
    /// A `varchar` with no length is the same as `text` inside Postgres and can hold megabytes,
    /// so only a bounded one counts as small.
    var isLarge: Bool {
        let name = typeName.lowercased()

        if name.contains("json") || name == "array" || name == "text"
            || name == "bytea" || name == "xml" {
            return true
        }

        if name.contains("char") {
            guard let maximumLength else { return true }
            return maximumLength > Self.inlineValueSize
        }

        return false
    }

    /// The largest value Postgres keeps in the row itself.
    ///
    /// A larger one goes to the value store beside the table, and reading it then costs a second
    /// lookup. That lookup is the whole expense of opening a wide table. A value this small comes
    /// with the row and costs nothing more, so a column that cannot exceed it is never cut.
    static let inlineValueSize = 2048
}
