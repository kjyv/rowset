import Foundation

enum AWSAuthError: LocalizedError, Sendable {
    case cliNotFound
    case ssoExpired(profile: String, detail: String)
    case tokenFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The aws command was not found. Install the AWS CLI, then try again."
        case .ssoExpired(let profile, _):
            "The AWS SSO session for profile \(profile) is not valid."
        case .tokenFailed(let detail):
            "The AWS CLI could not create a database auth token.\n\n\(detail)"
        }
    }

    var detail: String {
        switch self {
        case .cliNotFound: ""
        case .ssoExpired(_, let detail): detail
        case .tokenFailed(let detail): detail
        }
    }
}

/// Gets the RDS IAM auth token from the AWS CLI.
///
/// The CLI already handles the SSO token cache, the token refresh and role chaining, so the app
/// does not repeat any of that. The token is the connection password and lasts 15 minutes.
enum AWSTokenProvider {

    /// Where to look for the aws binary.
    ///
    /// A GUI app does not inherit the shell `PATH`, so the search cannot rely on `PATH` alone.
    private static let searchPaths = [
        "/opt/homebrew/bin/aws",
        "/usr/local/bin/aws",
        "/usr/bin/aws",
        "/opt/homebrew/opt/awscli/bin/aws",
    ]

    static func locateCLI() -> URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") {
                let candidate = "\(directory)/aws"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    /// Creates the token that the app sends as the connection password.
    static func authToken(for bookmark: Bookmark) async throws -> String {
        guard let cli = locateCLI() else { throw AWSAuthError.cliNotFound }

        let result = try await ProcessRunner.run(
            executable: cli,
            arguments: [
                "rds", "generate-db-auth-token",
                "--hostname", bookmark.host,
                "--port", String(bookmark.port),
                "--username", bookmark.username,
                "--region", bookmark.awsRegion,
                "--profile", bookmark.awsProfile,
            ])

        guard result.succeeded else {
            let message = result.failureMessage
            if mentionsExpiredLogin(message) {
                throw AWSAuthError.ssoExpired(profile: bookmark.awsProfile, detail: message)
            }
            throw AWSAuthError.tokenFailed(detail: message)
        }

        let token = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AWSAuthError.tokenFailed(detail: "The AWS CLI returned an empty token.")
        }
        return token
    }

    /// Runs `aws sso login` for one profile. The CLI opens the browser.
    static func ssoLogin(profile: String) async throws -> ProcessResult {
        guard let cli = locateCLI() else { throw AWSAuthError.cliNotFound }
        return try await ProcessRunner.run(
            executable: cli, arguments: ["sso", "login", "--profile", profile])
    }

    /// The command to show the user when the login expires.
    static func ssoLoginCommand(profile: String) -> String {
        "aws sso login --profile \(profile)"
    }

    /// Matches the wording that the AWS CLI uses for a missing or expired login.
    static func mentionsExpiredLogin(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let markers = [
            "sso session associated with this profile has expired",
            "token has expired",
            "expiredtoken",
            "error loading sso token",
            "the sso session",
            "unable to locate credentials",
            "refreshwithmfaunsupportederror",
            "sso authorization",
            "please log in",
        ]
        return markers.contains { lowercased.contains($0) }
    }
}
