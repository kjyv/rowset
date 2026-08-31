import Foundation

/// One profile from `~/.aws/config`.
struct AWSProfile: Identifiable, Hashable, Sendable {
    var name: String
    var region: String?

    var id: String { name }
}

/// Reads the profile names out of the AWS config file.
///
/// The app only needs the names for a picker. The AWS CLI resolves everything else.
enum AWSProfiles {
    static func configURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws/config")
    }

    static func load(from url: URL? = nil) -> [AWSProfile] {
        let target = url ?? configURL()
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Parses the INI sections. `[default]` and `[profile name]` become profiles.
    /// `[sso-session name]` and every other section type is skipped.
    static func parse(_ text: String) -> [AWSProfile] {
        var profiles: [AWSProfile] = []
        var current: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if header == "default" {
                    current = "default"
                    profiles.append(AWSProfile(name: "default", region: nil))
                } else if header.hasPrefix("profile ") {
                    let name = String(header.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
                    current = name
                    profiles.append(AWSProfile(name: name, region: nil))
                } else {
                    current = nil
                }
                continue
            }

            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "region", let index = profiles.indices.last {
                profiles[index].region = value
            }
        }

        return profiles
    }
}
