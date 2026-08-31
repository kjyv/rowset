import NIOCore
import PostgresNIO
import XCTest
@testable import Rowset

final class CellRendererTests: XCTestCase {

    private func cell(
        _ bytes: ByteBuffer?, _ type: PostgresDataType, format: PostgresFormat = .binary
    ) -> PostgresCell {
        PostgresCell(
            bytes: bytes, dataType: type, format: format, columnName: "c", columnIndex: 0)
    }

    private func buffer(_ build: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var value = ByteBuffer()
        build(&value)
        return value
    }

    func testNullCell() {
        let value = CellRenderer.render(cell(nil, .text))
        XCTAssertTrue(value.isNull)
        XCTAssertEqual(value.text, "NULL")
    }

    func testTextFormatIsReadAsIs() {
        var bytes = ByteBuffer()
        bytes.writeString("hello")
        let value = CellRenderer.render(cell(bytes, .int4, format: .text))
        XCTAssertEqual(value.text, "hello")
        XCTAssertFalse(value.isNull)
    }

    func testInt4() {
        let bytes = buffer { $0.writeInteger(Int32(-42)) }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .int4)).text, "-42")
    }

    func testBool() {
        XCTAssertEqual(
            CellRenderer.render(cell(buffer { $0.writeInteger(UInt8(1)) }, .bool)).text, "true")
        XCTAssertEqual(
            CellRenderer.render(cell(buffer { $0.writeInteger(UInt8(0)) }, .bool)).text, "false")
    }

    func testUUID() {
        let uuid = UUID()
        var bytes = ByteBuffer()
        withUnsafeBytes(of: uuid.uuid) { bytes.writeBytes($0) }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .uuid)).text, uuid.uuidString)
    }

    /// 2022-09-02 14:36:20.896927 UTC is 715 444 580 896 927 microseconds after 2000-01-01 UTC.
    func testTimestampKeepsMicroseconds() {
        let microseconds: Int64 = 715_444_580_896_927
        let bytes = buffer { $0.writeInteger(microseconds) }
        let value = CellRenderer.render(cell(bytes, .timestamp))
        XCTAssertEqual(value.text, "2022-09-02 14:36:20.896927")
    }

    func testTimestampBeforeThePostgresEpoch() {
        // One microsecond before 2000-01-01 00:00:00 UTC.
        let bytes = buffer { $0.writeInteger(Int64(-1)) }
        let value = CellRenderer.render(cell(bytes, .timestamp))
        XCTAssertEqual(value.text, "1999-12-31 23:59:59.999999")
    }

    func testTimestamptzShowsAnOffset() {
        let bytes = buffer { $0.writeInteger(Int64(0)) }
        let value = CellRenderer.render(cell(bytes, .timestamptz))
        XCTAssertTrue(value.text.contains("+") || value.text.contains("-"),
                      "expected an offset in \(value.text)")
    }

    func testDate() {
        // 8628 days after 2000-01-01 is 2023-08-16.
        let bytes = buffer { $0.writeInteger(Int32(8_628)) }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .date)).text, "2023-08-16")
    }

    func testTimeOfDay() {
        let microseconds = Int64(((13 * 60) + 45) * 60) * 1_000_000 + 250_000
        let bytes = buffer { $0.writeInteger(microseconds) }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .time)).text, "13:45:00.250000")
    }

    func testInterval() {
        let bytes = buffer {
            $0.writeInteger(Int64(3_600_000_000))  // one hour
            $0.writeInteger(Int32(3))              // three days
            $0.writeInteger(Int32(14))             // one year and two months
        }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .interval)).text,
                       "1 year 2 mons 3 days 01:00:00")
    }

    func testByteaBecomesHex() {
        let bytes = buffer { $0.writeBytes([0x00, 0xff, 0x10]) }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .bytea)).text, "\\x00ff10")
    }

    func testTextArray() {
        // The binary array layout: dimensions, has-null flag, element type, length, lower bound,
        // then each element with its byte count.
        let bytes = buffer { value in
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(0))
            value.writeInteger(UInt32(PostgresDataType.text.rawValue))
            value.writeInteger(Int32(2))
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(1))
            value.writeString("a")
            value.writeInteger(Int32(3))
            value.writeString("b c")
        }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .textArray)).text, "{a,\"b c\"}")
    }

    func testUnknownBinaryTypeFallsBackToAHexDump() {
        let bytes = buffer { $0.writeBytes([0x01, 0x02]) }
        let value = CellRenderer.render(cell(bytes, .point))
        XCTAssertTrue(value.isRaw)
        XCTAssertEqual(value.text, "\\x0102")
    }
}
