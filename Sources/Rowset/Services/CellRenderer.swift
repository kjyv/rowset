import Foundation
import NIOCore
import PostgresNIO

/// Turns one `PostgresCell` into text for the grid.
///
/// The server sends most values in the binary format, so the app must decode each type. For the
/// types that PostgresNIO already decodes, the renderer calls `cell.decode`. It decodes the date
/// and time types by hand, because Postgres stores microseconds and a `Date` loses some of that
/// precision on the way.
enum CellRenderer {

    /// Seconds between the Unix epoch and the Postgres epoch, which is 2000-01-01 UTC.
    private static let postgresEpoch: TimeInterval = 946_684_800

    private static let utc = TimeZone(secondsFromGMT: 0)!

    /// A fresh calendar for one time zone. A shared, mutable calendar is not thread safe.
    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The name to show in a column header tooltip.
    static func typeName(_ type: PostgresDataType) -> String {
        String(describing: type)
    }

    static func render(_ cell: PostgresCell) -> DisplayValue {
        guard let bytes = cell.bytes else { return .null }
        let isJSON = jsonTypes.contains(cell.dataType)

        if cell.format == .text {
            var buffer = bytes
            let text = buffer.readString(length: buffer.readableBytes) ?? ""
            return DisplayValue.make(text: text, isJSON: isJSON)
        }

        if let text = renderBinary(cell) {
            return DisplayValue.make(text: text, isJSON: isJSON)
        }

        return DisplayValue.make(text: hexDump(bytes), isRaw: true)
    }

    /// The column types that hold JSON. The inspector formats these.
    static let jsonTypes: Set<PostgresDataType> = [.json, .jsonb]

    // MARK: - Binary types

    private static func renderBinary(_ cell: PostgresCell) -> String? {
        switch cell.dataType {
        case .bool:
            return (try? cell.decode(Bool.self)).map { $0 ? "true" : "false" }

        case .int2:
            return (try? cell.decode(Int16.self)).map(String.init)
        case .int4:
            return (try? cell.decode(Int32.self)).map(String.init)
        case .int8:
            return (try? cell.decode(Int64.self)).map(String.init)
        case .oid, .xid, .cid, .regproc:
            return readUInt32(cell).map(String.init)

        case .float4:
            return (try? cell.decode(Float.self)).map { String($0) }
        case .float8:
            return (try? cell.decode(Double.self)).map { String($0) }
        case .numeric:
            return (try? cell.decode(Decimal.self)).map { "\($0)" }

        case .uuid:
            return (try? cell.decode(UUID.self))?.uuidString

        case .text, .varchar, .bpchar, .name, .char, .json, .jsonb, .xml, .unknown:
            return try? cell.decode(String.self)

        case .bool where cell.bytes?.readableBytes == 1:
            return (try? cell.decode(Bool.self)).map { $0 ? "true" : "false" }

        case .bytea:
            return cell.bytes.map(hexDump)

        case .timestamp:
            return readInt64(cell).map { formatTimestamp(microseconds: $0, timeZone: utc, showOffset: false) }
        case .timestamptz:
            return readInt64(cell).map { formatTimestamp(microseconds: $0, timeZone: .current, showOffset: true) }
        case .date:
            return readInt32(cell).map(formatDate(days:))
        case .time:
            return readInt64(cell).map { formatTimeOfDay(microseconds: $0) }
        case .timetz:
            return formatTimeTZ(cell)
        case .interval:
            return formatInterval(cell)

        case .inet, .cidr, .macaddr, .macaddr8, .point, .line, .lseg, .box, .path, .polygon, .circle, .money:
            // These have a binary layout the app does not decode yet.
            return nil

        default:
            if let array = renderArray(cell) { return array }
            // Many extension types, ltree for one, have no fixed OID and send readable text.
            return printableString(cell)
        }
    }

    /// Reads any array, whatever it holds.
    ///
    /// Postgres sends every array the same way: a header, then each element with its own byte
    /// count. Reading that once covers every element type, including the ones PostgresNIO has no
    /// decoder for, such as an array of timestamps.
    ///
    /// The parse must end exactly at the end of the buffer. A type that is no array would leave
    /// bytes over or run out of them, and that is what keeps this from claiming one.
    private static func renderArray(_ cell: PostgresCell) -> String? {
        guard var buffer = cell.bytes,
              let dimensions = buffer.readInteger(as: Int32.self),
              buffer.readInteger(as: Int32.self) != nil,          // the has-null flag
              let elementOID = buffer.readInteger(as: UInt32.self),
              (0...6).contains(dimensions), elementOID != 0
        else { return nil }

        if dimensions == 0 { return buffer.readableBytes == 0 ? "{}" : nil }

        var total = 1
        for _ in 0..<dimensions {
            guard let length = buffer.readInteger(as: Int32.self),
                  buffer.readInteger(as: Int32.self) != nil,      // the lower bound
                  length >= 0
            else { return nil }
            total *= Int(length)
        }
        guard total >= 0, total < 1_000_000 else { return nil }

        let elementType = PostgresDataType(elementOID)
        var parts: [String] = []
        parts.reserveCapacity(total)

        for _ in 0..<total {
            guard let size = buffer.readInteger(as: Int32.self) else { return nil }
            if size < 0 {
                parts.append("NULL")
                continue
            }
            guard let slice = buffer.readSlice(length: Int(size)) else { return nil }
            let element = PostgresCell(
                bytes: slice, dataType: elementType, format: .binary,
                columnName: "", columnIndex: 0)
            parts.append(quoteArrayElement(renderBinary(element) ?? hexDump(slice)))
        }

        guard buffer.readableBytes == 0 else { return nil }
        return join(parts)
    }

    private static func join(_ parts: [String]) -> String {
        "{" + parts.joined(separator: ",") + "}"
    }

    /// Puts an element in quotes when Postgres would, so the text reads back as it was written.
    private static func quoteArrayElement(_ value: String) -> String {
        if value == "NULL" { return value }
        let needsQuotes = value.isEmpty
            || value.contains(where: { ",{}\" \\".contains($0) })
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Date and time

    /// Microseconds since 2000-01-01 UTC.
    private static func formatTimestamp(
        microseconds: Int64, timeZone: TimeZone, showOffset: Bool
    ) -> String {
        let (seconds, fraction) = splitMicroseconds(microseconds)
        let date = Date(timeIntervalSince1970: postgresEpoch + TimeInterval(seconds))

        let parts = calendar(in: timeZone)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        var text = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%06d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, fraction)

        if showOffset {
            text += " " + offsetText(seconds: timeZone.secondsFromGMT(for: date))
        }
        return text
    }

    /// Days since 2000-01-01.
    private static func formatDate(days: Int32) -> String {
        let date = Date(timeIntervalSince1970: postgresEpoch + TimeInterval(days) * 86_400)
        let parts = calendar(in: utc).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Microseconds since midnight.
    private static func formatTimeOfDay(microseconds: Int64) -> String {
        let (seconds, fraction) = splitMicroseconds(microseconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secondsOfMinute = seconds % 60
        return String(format: "%02d:%02d:%02d.%06d", hours, minutes, secondsOfMinute, fraction)
    }

    /// `timetz` is 8 bytes of microseconds and 4 bytes of zone offset, in seconds west of UTC.
    private static func formatTimeTZ(_ cell: PostgresCell) -> String? {
        guard var buffer = cell.bytes,
              let microseconds = buffer.readInteger(as: Int64.self),
              let zoneWest = buffer.readInteger(as: Int32.self)
        else { return nil }
        return formatTimeOfDay(microseconds: microseconds) + offsetText(seconds: -Int(zoneWest))
    }

    /// `interval` is 8 bytes of microseconds, 4 bytes of days and 4 bytes of months.
    private static func formatInterval(_ cell: PostgresCell) -> String? {
        guard var buffer = cell.bytes,
              let microseconds = buffer.readInteger(as: Int64.self),
              let days = buffer.readInteger(as: Int32.self),
              let months = buffer.readInteger(as: Int32.self)
        else { return nil }

        var parts: [String] = []
        let years = months / 12
        let remainingMonths = months % 12
        if years != 0 { parts.append("\(years) \(years == 1 ? "year" : "years")") }
        if remainingMonths != 0 { parts.append("\(remainingMonths) mons") }
        if days != 0 { parts.append("\(days) \(abs(days) == 1 ? "day" : "days")") }

        if microseconds != 0 || parts.isEmpty {
            let negative = microseconds < 0
            let (seconds, fraction) = splitMicroseconds(abs(microseconds))
            var clock = String(
                format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            if fraction != 0 {
                clock += String(format: ".%06d", fraction)
            }
            parts.append(negative ? "-\(clock)" : clock)
        }

        return parts.joined(separator: " ")
    }

    /// Splits into whole seconds and a positive microsecond remainder.
    private static func splitMicroseconds(_ microseconds: Int64) -> (seconds: Int, fraction: Int) {
        var seconds = microseconds / 1_000_000
        var fraction = microseconds % 1_000_000
        if fraction < 0 {
            fraction += 1_000_000
            seconds -= 1
        }
        return (Int(seconds), Int(fraction))
    }

    private static func offsetText(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        return String(format: "%@%02d:%02d", sign, total / 3600, (total % 3600) / 60)
    }

    // MARK: - Fallbacks

    private static func readInt64(_ cell: PostgresCell) -> Int64? {
        var buffer = cell.bytes
        return buffer?.readInteger(as: Int64.self)
    }

    private static func readInt32(_ cell: PostgresCell) -> Int32? {
        var buffer = cell.bytes
        return buffer?.readInteger(as: Int32.self)
    }

    private static func readUInt32(_ cell: PostgresCell) -> UInt32? {
        var buffer = cell.bytes
        return buffer?.readInteger(as: UInt32.self)
    }

    /// Returns the bytes as text, but only when they are printable UTF-8.
    private static func printableString(_ cell: PostgresCell) -> String? {
        guard var buffer = cell.bytes,
              let text = buffer.readString(length: buffer.readableBytes)
        else { return nil }
        let hasControlCharacters = text.unicodeScalars.contains {
            $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r"
        }
        return hasControlCharacters ? nil : text
    }

    private static func hexDump(_ buffer: ByteBuffer) -> String {
        let limit = 512
        let bytes = buffer.readableBytesView
        let shown = bytes.prefix(limit)
        let hex = shown.map { String(format: "%02x", $0) }.joined()
        return bytes.count > limit ? "\\x\(hex)… (\(bytes.count) bytes)" : "\\x\(hex)"
    }
}
