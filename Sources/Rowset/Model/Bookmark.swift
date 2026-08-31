import Foundation

/// How the app protects the connection to the server.
enum SSLMode: String, Codable, CaseIterable, Sendable {
    /// Encrypt and check the server certificate against the bundled RDS root store.
    case verifyFull
    /// Encrypt only. Do not check the server identity. Use this only as a fallback.
    case require

    var label: String {
        switch self {
        case .verifyFull: "verify-full — check the server certificate"
        case .require: "require — encrypt only, no certificate check"
        }
    }
}

/// A saved connection. It holds no secret. The password comes from the AWS CLI at connect time.
struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 5432
    var database: String = ""
    var username: String = ""
    var awsProfile: String = ""
    var awsRegion: String = "eu-central-1"
    var sslMode: SSLMode = .verifyFull

    /// The name to show, with a fallback for a bookmark that has no name yet.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !database.isEmpty { return "\(database)@\(shortHost)" }
        return "New connection"
    }

    /// The first label of the host name. RDS endpoints are too long for a sidebar row.
    var shortHost: String {
        host.split(separator: ".").first.map(String.init) ?? host
    }

    var subtitle: String {
        "\(username)@\(shortHost)/\(database)"
    }

    /// True when every field that a connect needs has a value.
    var isComplete: Bool {
        !host.isEmpty && !database.isEmpty && !username.isEmpty
            && !awsProfile.isEmpty && !awsRegion.isEmpty && port > 0
    }
}
