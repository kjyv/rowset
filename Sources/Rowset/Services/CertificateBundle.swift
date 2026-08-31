import Foundation

/// Finds the AWS RDS root certificate bundle.
///
/// The app normally reads it from its own bundle. A test run has no app bundle, so the lookup
/// also accepts a path in `ROWSET_CA_BUNDLE` and the bundle that holds this code.
enum CertificateBundle {
    private final class Token {}

    static let resourceName = "rds-global-bundle"

    static func rdsRootsPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["ROWSET_CA_BUNDLE"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        for bundle in [Bundle.main, Bundle(for: Token.self)] {
            if let path = bundle.path(forResource: resourceName, ofType: "pem") {
                return path
            }
        }
        return nil
    }
}
