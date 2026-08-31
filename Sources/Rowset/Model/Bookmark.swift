import Foundation

/// How the app proves who it is to the server.
enum AuthMethod: String, Codable, CaseIterable, Sendable {
    /// The AWS CLI creates a short-lived token at every connect.
    case awsIAM
    /// A password that the app keeps in the login keychain.
    case password

    var label: String {
        switch self {
        case .awsIAM: "AWS IAM"
        case .password: "User and password"
        }
    }
}

/// How the app protects the connection to the server.
enum SSLMode: String, Codable, CaseIterable, Sendable {
    /// Encrypt and check the server certificate against the bundled RDS root store.
    case verifyFull
    /// Encrypt only. Do not check the server identity. Use this only as a fallback.
    case require
    /// No encryption. Only for a server on this machine or a private network.
    case disable

    var label: String {
        switch self {
        case .verifyFull: "verify-full — check the server certificate"
        case .require: "require — encrypt only, no certificate check"
        case .disable: "disable — no encryption"
        }
    }
}

/// A saved connection.
///
/// The file holds no secret. An IAM token comes from the AWS CLI at connect time, and a password
/// lives in the login keychain under the id of this bookmark.
struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 5432
    var database: String = ""
    var username: String = ""
    var authMethod: AuthMethod = .awsIAM
    var awsProfile: String = ""
    var awsRegion: String = "eu-central-1"
    var sslMode: SSLMode = .verifyFull

    init() {}

    /// Reads a bookmark, and takes a default for every key the file does not carry.
    ///
    /// A file written before a field existed must still open. Without this, adding `authMethod`
    /// would have made every saved bookmark unreadable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 5432
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .awsIAM
        awsProfile = try container.decodeIfPresent(String.self, forKey: .awsProfile) ?? ""
        awsRegion = try container.decodeIfPresent(String.self, forKey: .awsRegion) ?? "eu-central-1"
        sslMode = try container.decodeIfPresent(SSLMode.self, forKey: .sslMode) ?? .verifyFull
    }

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
    ///
    /// A password connection needs no AWS profile and no region.
    var isComplete: Bool {
        let server = !host.isEmpty && !database.isEmpty && !username.isEmpty && port > 0
        switch authMethod {
        case .awsIAM: return server && !awsProfile.isEmpty && !awsRegion.isEmpty
        case .password: return server
        }
    }
}
