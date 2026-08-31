import SwiftUI

/// Shown when the AWS SSO session expired. It runs the login command for you.
struct SSOLoginSheet: View {
    let prompt: SSOPrompt
    let onClose: () -> Void

    @State private var isRunning = false
    @State private var output = ""
    @State private var finished = false

    private var command: String { AWSTokenProvider.ssoLoginCommand(profile: prompt.profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The AWS login expired", systemImage: "person.badge.key")
                .font(.headline)

            Text("Profile \(prompt.profile) needs a new SSO login. "
                 + "The button below runs the command and opens your browser.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }

            if !prompt.detail.isEmpty {
                DisclosureGroup("Message from the AWS CLI") {
                    Text(prompt.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Log In") { runLogin() }
                    .disabled(isRunning)
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button(finished ? "Done" : "Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func runLogin() {
        isRunning = true
        output = "Running \(command)…\n"
        Task {
            do {
                let result = try await AWSTokenProvider.ssoLogin(profile: prompt.profile)
                output += result.standardOutput
                output += result.standardError
                finished = result.succeeded
                if result.succeeded {
                    output += "\nLogin finished. Close this window and connect again."
                }
            } catch {
                output += "\n\(error.localizedDescription)"
            }
            isRunning = false
        }
    }
}
