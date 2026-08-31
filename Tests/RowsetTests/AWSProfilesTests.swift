import XCTest
@testable import Rowset

final class AWSProfilesTests: XCTestCase {

    private let sample = """
        [default]
        sso_session = session
        region = eu-central-1

        # a comment
        [sso-session session]
        sso_start_url = https://example.awsapps.com/start
        region = us-east-1

        [profile AlcemyElevatedAccess-211125624762]
        sso_session = session
        region = eu-central-1

        [profile no-region]
        sso_session = session
        """

    func testReadsDefaultAndNamedProfiles() {
        let profiles = AWSProfiles.parse(sample)
        XCTAssertEqual(
            profiles.map(\.name),
            ["default", "AlcemyElevatedAccess-211125624762", "no-region"])
    }

    func testSkipsSSOSessionSections() {
        let profiles = AWSProfiles.parse(sample)
        XCTAssertFalse(profiles.contains { $0.name.contains("sso-session") })
    }

    func testReadsTheRegionOfEachProfile() {
        let profiles = AWSProfiles.parse(sample)
        XCTAssertEqual(profiles.first { $0.name == "default" }?.region, "eu-central-1")
        XCTAssertEqual(
            profiles.first { $0.name == "AlcemyElevatedAccess-211125624762" }?.region,
            "eu-central-1")
        XCTAssertNil(profiles.first { $0.name == "no-region" }?.region)
    }

    func testRegionOfAnSSOSessionDoesNotLeakIntoAProfile() {
        // The `region` under `[sso-session session]` must not land on `[default]`.
        let profiles = AWSProfiles.parse(sample)
        XCTAssertEqual(profiles.first { $0.name == "default" }?.region, "eu-central-1")
    }

    func testEmptyFileGivesNoProfile() {
        XCTAssertTrue(AWSProfiles.parse("").isEmpty)
    }
}
