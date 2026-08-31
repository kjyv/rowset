import XCTest
@testable import Rowset

final class BookmarkTests: XCTestCase {

    private func decode(_ json: String) throws -> Bookmark {
        try JSONDecoder().decode(Bookmark.self, from: Data(json.utf8))
    }

    /// A file written before the auth method existed must still open.
    func testAFileWithoutAnAuthMethodReadsAsIAM() throws {
        let bookmark = try decode("""
            {
              "id": "0F2C4B0E-5E8B-4E4E-9C2B-2A5F1D3C7A10",
              "name": "concrete testing",
              "host": "name.eu-central-1.rds.amazonaws.com",
              "port": 5432,
              "database": "cube_testing",
              "username": "cube_testing_iam_owner",
              "awsProfile": "AlcemyElevatedAccess-211125624762",
              "awsRegion": "eu-central-1",
              "sslMode": "verifyFull"
            }
            """)
        XCTAssertEqual(bookmark.authMethod, .awsIAM)
        XCTAssertEqual(bookmark.name, "concrete testing")
        XCTAssertEqual(bookmark.database, "cube_testing")
    }

    func testAnAlmostEmptyFileTakesEveryDefault() throws {
        let bookmark = try decode("{}")
        XCTAssertEqual(bookmark.port, 5432)
        XCTAssertEqual(bookmark.awsRegion, "eu-central-1")
        XCTAssertEqual(bookmark.sslMode, .verifyFull)
        XCTAssertEqual(bookmark.authMethod, .awsIAM)
    }

    func testAPasswordBookmarkReadsBack() throws {
        let bookmark = try decode("""
            {"host": "localhost", "database": "app", "username": "postgres",
             "authMethod": "password", "sslMode": "disable"}
            """)
        XCTAssertEqual(bookmark.authMethod, .password)
        XCTAssertEqual(bookmark.sslMode, .disable)
    }

    func testWritingAndReadingKeepsEveryField() throws {
        var bookmark = Bookmark()
        bookmark.name = "local"
        bookmark.host = "localhost"
        bookmark.database = "app"
        bookmark.username = "postgres"
        bookmark.authMethod = .password
        bookmark.sslMode = .disable

        let data = try JSONEncoder().encode(bookmark)
        let read = try JSONDecoder().decode(Bookmark.self, from: data)
        XCTAssertEqual(read, bookmark)
    }

    // MARK: - What a connect needs

    private func passwordBookmark() -> Bookmark {
        var bookmark = Bookmark()
        bookmark.host = "localhost"
        bookmark.database = "app"
        bookmark.username = "postgres"
        bookmark.authMethod = .password
        return bookmark
    }

    func testAPasswordConnectionNeedsNoAWSFields() {
        var bookmark = passwordBookmark()
        bookmark.awsProfile = ""
        bookmark.awsRegion = ""
        XCTAssertTrue(bookmark.isComplete)
    }

    func testAnIAMConnectionNeedsAProfileAndARegion() {
        var bookmark = passwordBookmark()
        bookmark.authMethod = .awsIAM
        bookmark.awsProfile = ""
        XCTAssertFalse(bookmark.isComplete)

        bookmark.awsProfile = "profile"
        XCTAssertTrue(bookmark.isComplete)

        bookmark.awsRegion = ""
        XCTAssertFalse(bookmark.isComplete)
    }

    func testEveryConnectionNeedsAServer() {
        var bookmark = passwordBookmark()
        bookmark.host = ""
        XCTAssertFalse(bookmark.isComplete)

        bookmark = passwordBookmark()
        bookmark.database = ""
        XCTAssertFalse(bookmark.isComplete)

        bookmark = passwordBookmark()
        bookmark.username = ""
        XCTAssertFalse(bookmark.isComplete)

        bookmark = passwordBookmark()
        bookmark.port = 0
        XCTAssertFalse(bookmark.isComplete)
    }

    func testEveryModeAndMethodCarriesALabel() {
        for mode in SSLMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
        }
        for method in AuthMethod.allCases {
            XCTAssertFalse(method.label.isEmpty)
        }
        XCTAssertEqual(SSLMode.allCases.count, 3)
        XCTAssertEqual(AuthMethod.allCases.count, 2)
    }
}
