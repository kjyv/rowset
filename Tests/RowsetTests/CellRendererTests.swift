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

    // MARK: - Network addresses

    private func inetBytes(family: UInt8, bits: UInt8, isCIDR: UInt8, _ address: [UInt8])
        -> ByteBuffer
    {
        buffer { value in
            value.writeInteger(family)
            value.writeInteger(bits)
            value.writeInteger(isCIDR)
            value.writeInteger(UInt8(address.count))
            value.writeBytes(address)
        }
    }

    /// What `pg_stat_activity.client_addr` sends.
    func testInetIPv4HidesAFullNetmask() {
        let bytes = inetBytes(family: 2, bits: 32, isCIDR: 0, [10, 0, 19, 244])
        let value = CellRenderer.render(cell(bytes, .inet))
        XCTAssertEqual(value.text, "10.0.19.244")
        XCTAssertFalse(value.isRaw)
    }

    func testInetIPv4ShowsAShorterNetmask() {
        let bytes = inetBytes(family: 2, bits: 24, isCIDR: 0, [192, 168, 1, 5])
        XCTAssertEqual(CellRenderer.render(cell(bytes, .inet)).text, "192.168.1.5/24")
    }

    func testCIDRAlwaysShowsItsNetmask() {
        let bytes = inetBytes(family: 2, bits: 32, isCIDR: 1, [10, 0, 19, 244])
        XCTAssertEqual(CellRenderer.render(cell(bytes, .cidr)).text, "10.0.19.244/32")
    }

    func testInetIPv6() {
        let address: [UInt8] = [
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
        ]
        let bytes = inetBytes(family: 3, bits: 128, isCIDR: 0, address)
        XCTAssertEqual(CellRenderer.render(cell(bytes, .inet)).text, "2001:db8::1")
    }

    func testInetIPv6Loopback() {
        var address = [UInt8](repeating: 0, count: 16)
        address[15] = 1
        let bytes = inetBytes(family: 3, bits: 128, isCIDR: 0, address)
        XCTAssertEqual(CellRenderer.render(cell(bytes, .inet)).text, "::1")
    }

    func testInetIPv6EmbedsAnIPv4Address() {
        let address: [UInt8] = [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 19, 244,
        ]
        let bytes = inetBytes(family: 3, bits: 128, isCIDR: 0, address)
        XCTAssertEqual(CellRenderer.render(cell(bytes, .inet)).text, "::ffff:10.0.19.244")
    }

    func testAnInetArray() {
        let element = inetBytes(family: 2, bits: 32, isCIDR: 0, [10, 0, 19, 244])
        let bytes = buffer { value in
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(0))
            value.writeInteger(UInt32(PostgresDataType.inet.rawValue))
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(element.readableBytes))
            value.writeImmutableBuffer(element)
        }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .inetArray)).text, "{10.0.19.244}")
    }

    /// A length the family does not match is left to the hex dump.
    func testAMalformedInetFallsBackToAHexDump() {
        let bytes = inetBytes(family: 2, bits: 32, isCIDR: 0, [10, 0])
        XCTAssertTrue(CellRenderer.render(cell(bytes, .inet)).isRaw)
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

    /// Postgres sends every array the same way, so one reader covers every element type.
    func testAnArrayOfTimestampsReadsAsTimestamps() {
        // 2022-09-02 14:36:20.896927 UTC and one second later.
        let first: Int64 = 715_444_580_896_927
        let second = first + 1_000_000

        let bytes = buffer { value in
            value.writeInteger(Int32(1))                                    // one dimension
            value.writeInteger(Int32(0))                                    // no null inside
            value.writeInteger(UInt32(PostgresDataType.timestamp.rawValue))
            value.writeInteger(Int32(2))                                    // two elements
            value.writeInteger(Int32(1))                                    // lower bound
            value.writeInteger(Int32(8))
            value.writeInteger(first)
            value.writeInteger(Int32(8))
            value.writeInteger(second)
        }

        XCTAssertEqual(
            CellRenderer.render(cell(bytes, .timestampArray)).text,
            "{\"2022-09-02 14:36:20.896927\",\"2022-09-02 14:36:21.896927\"}")
    }

    func testAnArrayOfSmallIntegers() {
        let bytes = buffer { value in
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(0))
            value.writeInteger(UInt32(PostgresDataType.int2.rawValue))
            value.writeInteger(Int32(3))
            value.writeInteger(Int32(1))
            for element in [Int16(7), 8, 9] {
                value.writeInteger(Int32(2))
                value.writeInteger(element)
            }
        }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .int2Array)).text, "{7,8,9}")
    }

    func testANullInsideAnArray() {
        let bytes = buffer { value in
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(1))
            value.writeInteger(UInt32(PostgresDataType.int4.rawValue))
            value.writeInteger(Int32(2))
            value.writeInteger(Int32(1))
            value.writeInteger(Int32(4))
            value.writeInteger(Int32(5))
            value.writeInteger(Int32(-1))
        }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .int4Array)).text, "{5,NULL}")
    }

    func testAnEmptyArray() {
        let bytes = buffer { value in
            value.writeInteger(Int32(0))
            value.writeInteger(Int32(0))
            value.writeInteger(UInt32(PostgresDataType.int4.rawValue))
        }
        XCTAssertEqual(CellRenderer.render(cell(bytes, .int4Array)).text, "{}")
    }

    /// The reader must not claim a type that is no array. It ends at the end of the buffer or it
    /// gives up.
    func testTheArrayReaderRefusesOtherTypes() {
        let bytes = buffer { $0.writeBytes([0x01, 0x02]) }
        let value = CellRenderer.render(cell(bytes, .point))
        XCTAssertTrue(value.isRaw, "a point is not read as an array")
    }

    func testUnknownBinaryTypeFallsBackToAHexDump() {
        let bytes = buffer { $0.writeBytes([0x01, 0x02]) }
        let value = CellRenderer.render(cell(bytes, .point))
        XCTAssertTrue(value.isRaw)
        XCTAssertEqual(value.text, "\\x0102")
    }
}
