import Foundation

/// Says whether a typed value fits the column it goes into.
///
/// The check runs in the app so a mistake shows at once, and it stays narrow on purpose. A date
/// or an interval goes to the server unchecked, because Postgres reads far more forms of those
/// than any rule here would.
enum ValueValidator {

    /// The words Postgres takes for a boolean.
    static let booleanWords = ["true", "false", "t", "f", "yes", "no", "y", "n", "on", "off", "1", "0"]

    static func isValid(_ text: String, for kind: ColumnKind) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)

        switch kind {
        case .boolean:
            return booleanWords.contains(value.lowercased())

        case .integer:
            var digits = Substring(value)
            if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
            return !digits.isEmpty && digits.allSatisfy(isDigit)

        case .number:
            return isDecimalNumber(value)

        case .uuid:
            return UUID(uuidString: value) != nil

        case .json:
            guard !value.isEmpty else { return false }
            return (try? JSONSerialization.jsonObject(
                with: Data(value.utf8), options: [.fragmentsAllowed])) != nil

        case .temporal, .text:
            return true
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Reads a decimal number the whole way through.
    ///
    /// `Double` and `Decimal` both stop at the first character they cannot use, so `Decimal` read
    /// `4,2` as `4` and called it a number. This walks the text to its end instead.
    private static func isDecimalNumber(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        // Postgres takes NaN for a numeric column.
        if value.lowercased() == "nan" { return true }

        var rest = Substring(value)
        if rest.first == "+" || rest.first == "-" { rest = rest.dropFirst() }

        let mantissa = rest.prefix { isDigit($0) || $0 == "." }
        rest = rest.dropFirst(mantissa.count)
        guard mantissa.filter({ $0 == "." }).count <= 1,
              mantissa.contains(where: isDigit)
        else { return false }

        guard !rest.isEmpty else { return true }
        guard rest.first == "e" || rest.first == "E" else { return false }
        rest = rest.dropFirst()
        if rest.first == "+" || rest.first == "-" { rest = rest.dropFirst() }
        return !rest.isEmpty && rest.allSatisfy(isDigit)
    }

    /// The message to show when a value does not fit.
    static func message(for kind: ColumnKind) -> String {
        switch kind {
        case .boolean: "Type true or false."
        case .integer: "Type a whole number."
        case .number: "Type a number."
        case .uuid: "Type a UUID, for example 0f2c4b0e-5e8b-4e4e-9c2b-2a5f1d3c7a10."
        case .json: "Type valid JSON."
        case .temporal, .text: ""
        }
    }
}
