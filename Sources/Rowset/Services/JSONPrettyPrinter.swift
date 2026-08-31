import Foundation

/// Formats JSON text without parsing it into a dictionary.
///
/// `JSONSerialization` loses the order of the object keys, and a database row reads much better
/// when the keys keep the order the server sent. This scanner walks the characters and only adds
/// line breaks and indentation, so the order survives.
enum JSONPrettyPrinter {

    /// The app does not format a value larger than this. A very large document costs more to lay
    /// out than it helps to read.
    static let characterLimit = 400_000

    /// True when the text starts like a JSON object or array.
    static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    /// Returns the formatted text, or `nil` when the text is not JSON or is too large.
    static func format(_ text: String, indent: String = "  ") -> String? {
        guard looksLikeJSON(text), text.count <= characterLimit else { return nil }

        var out = ""
        out.reserveCapacity(text.count + text.count / 4)

        var depth = 0
        var inString = false
        var escaped = false
        var pendingNewline = false

        func newline(_ level: Int) {
            out.append("\n")
            for _ in 0..<level { out.append(indent) }
        }

        for character in text {
            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character.isWhitespace { continue }

            if pendingNewline, character != "}", character != "]" {
                newline(depth)
            }
            pendingNewline = false

            switch character {
            case "\"":
                inString = true
                out.append(character)
            case "{", "[":
                out.append(character)
                depth += 1
                pendingNewline = true
            case "}", "]":
                depth = max(0, depth - 1)
                // An empty object or array stays on one line.
                if let last = out.last, last != "{", last != "[" {
                    newline(depth)
                }
                out.append(character)
            case ",":
                out.append(character)
                pendingNewline = true
            case ":":
                out.append(": ")
            default:
                out.append(character)
            }
        }

        return out
    }
}
