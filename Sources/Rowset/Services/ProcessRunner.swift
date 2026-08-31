import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String

    var succeeded: Bool { exitCode == 0 }

    /// The message to show when a command fails.
    var failureMessage: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        return "The command exited with code \(exitCode)."
    }
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(path: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let underlying):
            "Could not start \(path). \(underlying)"
        }
    }
}

/// Runs a command and collects its output.
///
/// The whole run happens on one background queue. Both pipes are read at the same time, because a
/// command that writes a lot to stderr blocks when nobody reads that pipe.
enum ProcessRunner {

    static func run(
        executable: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                var environment = ProcessInfo.processInfo.environment
                // Keep the AWS CLI from starting a pager. A pager would never return.
                environment["AWS_PAGER"] = ""
                environment.merge(extraEnvironment) { _, new in new }
                process.environment = environment

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: ProcessRunnerError.launchFailed(
                            path: executable.path, underlying: error.localizedDescription))
                    return
                }

                var outputData = Data()
                var errorData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(decoding: outputData, as: UTF8.self),
                    standardError: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }
}
