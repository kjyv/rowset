import Foundation

/// Reads JSON text into tokens.
///
/// It is a lexer and not a parser, for the same reason `SQLLexer` is one: colouring asks what a
/// piece of text is, never what it means. It keeps one piece of structure, a stack of the open
/// braces and brackets, because that is what tells the name of a field from a plain string.
///
/// Broken text still gives tokens. The pane shows what the server sent, and a value that does not
/// parse is exactly the value a reader wants to look at.
enum JSONLexer {

    /// The words JSON allows on their own.
    private static let words: Set<String> = ["true", "false", "null"]

    static func tokens(in text: String) -> [SyntaxToken] {
        let characters = Array(text)
        let source = text as NSString
        var tokens: [SyntaxToken] = []

        /// The open containers, innermost last. `true` for an object, `false` for an array.
        var containers: [Bool] = []
        /// True while the next string of an object is its field name and not a value.
        var expectsKey = false

        var index = 0
        var offset = 0

        func width(_ character: Character) -> Int { String(character).utf16.count }

        func append(_ kind: SyntaxKind, from start: Int, to end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            tokens.append(SyntaxToken(range: range, kind: kind, text: source.substring(with: range)))
        }

        while index < characters.count {
            let character = characters[index]
            let start = offset

            if character.isWhitespace {
                index += 1
                offset += width(character)
                continue
            }

            // A string. Its closing quote is the first one that carries no backslash.
            if character == "\"" {
                index += 1
                offset += 1
                while index < characters.count {
                    if characters[index] == "\\", index + 1 < characters.count {
                        offset += width(characters[index]) + width(characters[index + 1])
                        index += 2
                        continue
                    }
                    let inner = characters[index]
                    index += 1
                    offset += width(inner)
                    if inner == "\"" { break }
                }
                append(expectsKey ? .key : .string, from: start, to: offset)
                continue
            }

            if character == "-" || character.isNumber {
                index += 1
                offset += width(character)
                while index < characters.count {
                    let inner = characters[index]
                    let belongs = inner.isNumber || inner == "." || inner == "e" || inner == "E"
                        || inner == "+" || inner == "-"
                    guard belongs else { break }
                    index += 1
                    offset += width(inner)
                }
                append(.number, from: start, to: offset)
                continue
            }

            if character.isLetter {
                while index < characters.count, characters[index].isLetter {
                    offset += width(characters[index])
                    index += 1
                }
                let range = NSRange(location: start, length: offset - start)
                let word = source.substring(with: range)
                append(words.contains(word) ? .keyword : .identifier, from: start, to: offset)
                continue
            }

            switch character {
            case "{":
                containers.append(true)
                expectsKey = true
            case "[":
                containers.append(false)
                expectsKey = false
            case "}", "]":
                if !containers.isEmpty { containers.removeLast() }
                expectsKey = false
            case ":":
                expectsKey = false
            case ",":
                expectsKey = containers.last == true
            default:
                break
            }

            index += 1
            offset += width(character)
            append(.punctuation, from: start, to: offset)
        }

        return tokens
    }
}
