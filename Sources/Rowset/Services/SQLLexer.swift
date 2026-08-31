import Foundation

/// What a piece of SQL text is.
enum SQLTokenKind: Sendable, Hashable {
    case keyword
    case identifier
    /// A name in double quotes.
    case quotedIdentifier
    /// A literal in single quotes, or a dollar quoted body.
    case string
    case number
    /// A placeholder such as `$1`.
    case parameter
    case comment
    case punctuation
}

struct SQLToken: Sendable, Hashable {
    var range: NSRange
    var kind: SQLTokenKind
    var text: String
}

/// Reads SQL text into tokens.
///
/// One pass serves two jobs. Colouring needs to know what each piece is, and telling statements
/// apart needs to know which semicolons are real ones, and both fall out of the same walk.
///
/// This is a lexer and not a parser on purpose. A grammar such as tree-sitter would add a build
/// dependency and buy nothing here, because neither job asks what the words mean. A parser earns
/// its place only for colouring by meaning, such as marking a table apart from a column.
enum SQLLexer {

    /// The words Postgres treats as keywords. The list is not the whole of SQL, only what a
    /// reader wants to see standing out.
    static let keywords: Set<String> = [
        "abort", "add", "all", "alter", "analyze", "and", "any", "as", "asc", "begin", "between",
        "by", "cascade", "case", "cast", "check", "coalesce", "column", "commit", "constraint",
        "create", "cross", "current_date", "current_time", "current_timestamp", "database",
        "declare", "default", "delete", "desc", "distinct", "do", "drop", "else", "end", "except",
        "exists", "explain", "false", "fetch", "filter", "first", "for", "foreign", "from", "full",
        "function", "grant", "group", "having", "if", "ilike", "in", "index", "inner", "insert",
        "intersect", "into", "is", "join", "key", "language", "last", "lateral", "left", "like",
        "limit", "materialized", "not", "null", "nulls", "offset", "on", "only", "or", "order",
        "outer", "over", "partition", "primary", "procedure", "references", "refresh", "rename",
        "replace", "returning", "returns", "revoke", "right", "rollback", "row", "schema",
        "select", "sequence", "set", "similar", "table", "then", "to", "trigger", "true",
        "truncate", "union", "unique", "update", "using", "vacuum", "values", "view", "when",
        "where", "window", "with",
    ]

    static func tokens(in text: String) -> [SQLToken] {
        let characters = Array(text)
        let source = text as NSString
        var tokens: [SQLToken] = []

        var index = 0
        var offset = 0

        func width(_ character: Character) -> Int { String(character).utf16.count }

        func append(_ kind: SQLTokenKind, from start: Int, to end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            tokens.append(SQLToken(range: range, kind: kind, text: source.substring(with: range)))
        }

        while index < characters.count {
            let character = characters[index]
            let start = offset

            // White space carries no token.
            if character.isWhitespace {
                index += 1
                offset += width(character)
                continue
            }

            // A comment to the end of the line.
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                while index < characters.count, !characters[index].isNewline {
                    offset += width(characters[index])
                    index += 1
                }
                append(.comment, from: start, to: offset)
                continue
            }

            // A block comment, which Postgres allows inside a block comment.
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                var depth = 0
                while index < characters.count {
                    if index + 1 < characters.count,
                       characters[index] == "/", characters[index + 1] == "*" {
                        depth += 1
                        offset += 2
                        index += 2
                        continue
                    }
                    if index + 1 < characters.count,
                       characters[index] == "*", characters[index + 1] == "/" {
                        depth -= 1
                        offset += 2
                        index += 2
                        if depth == 0 { break }
                        continue
                    }
                    offset += width(characters[index])
                    index += 1
                }
                append(.comment, from: start, to: offset)
                continue
            }

            // A literal in single quotes. Two quotes in a row are one quote inside the text.
            if character == "'" || character == "\"" {
                let quote = character
                offset += width(character)
                index += 1
                while index < characters.count {
                    let inner = characters[index]
                    offset += width(inner)
                    index += 1
                    if inner == quote {
                        if index < characters.count, characters[index] == quote {
                            offset += width(characters[index])
                            index += 1
                            continue
                        }
                        break
                    }
                }
                append(quote == "'" ? .string : .quotedIdentifier, from: start, to: offset)
                continue
            }

            // A dollar quoted body, or a placeholder such as $1.
            if character == "$" {
                if let tag = dollarTag(characters, at: index) {
                    let marker = Array("$\(tag)$")
                    index += marker.count
                    offset += marker.count
                    while index < characters.count {
                        if characters[index] == "$",
                           index + marker.count <= characters.count,
                           Array(characters[index..<(index + marker.count)]) == marker {
                            offset += marker.count
                            index += marker.count
                            break
                        }
                        offset += width(characters[index])
                        index += 1
                    }
                    append(.string, from: start, to: offset)
                    continue
                }

                offset += width(character)
                index += 1
                while index < characters.count, characters[index].isNumber {
                    offset += width(characters[index])
                    index += 1
                }
                append(.parameter, from: start, to: offset)
                continue
            }

            // A number.
            if character.isNumber {
                while index < characters.count,
                      characters[index].isNumber || characters[index] == "." {
                    offset += width(characters[index])
                    index += 1
                }
                append(.number, from: start, to: offset)
                continue
            }

            // A word: a keyword or a name.
            if character.isLetter || character == "_" {
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" {
                    offset += width(characters[index])
                    index += 1
                }
                let range = NSRange(location: start, length: offset - start)
                let word = source.substring(with: range)
                append(keywords.contains(word.lowercased()) ? .keyword : .identifier,
                       from: start, to: offset)
                _ = range
                continue
            }

            // Anything else is punctuation, the semicolon among it.
            offset += width(character)
            index += 1
            append(.punctuation, from: start, to: offset)
        }

        return tokens
    }

    /// Reads `$tag$` and gives back the tag, or `nil` when this dollar starts no quote.
    static func dollarTag(_ characters: [Character], at start: Int) -> String? {
        var index = start + 1
        var tag = ""
        while index < characters.count {
            let character = characters[index]
            if character == "$" { return tag }
            guard character.isLetter || character.isNumber || character == "_" else { return nil }
            tag.append(character)
            index += 1
        }
        return nil
    }
}
