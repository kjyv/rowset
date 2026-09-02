import SwiftUI

/// The sheet that edits one bookmark.
struct BookmarkEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Bookmark
    @State private var profiles: [AWSProfile] = []
    @State private var testState: TestState = .idle
    /// The password is not part of the bookmark. It lives in the login keychain.
    @State private var password = ""
    @State private var didLoadPassword = false

    private let onSave: (Bookmark) -> Void

    enum TestState: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    init(bookmark: Bookmark, onSave: @escaping (Bookmark) -> Void) {
        _draft = State(initialValue: bookmark)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connection")
                .font(.headline)
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("concrete testing"))
                    Picker("Kind", selection: $draft.driver) {
                        ForEach(Driver.allCases, id: \.self) { driver in
                            Text(driver.label).tag(driver)
                        }
                    }
                }

                if draft.driver == .sqlite {
                    sqliteSection
                } else {
                    postgresSections
                }
            }
            .formStyle(.grouped)

            testResult

            Divider()

            buttons
                .padding(16)
        }
        .frame(width: 560, height: draft.driver == .sqlite ? 400 : 660)
        .task {
            if !didLoadPassword {
                didLoadPassword = true
                password = KeychainStore.password(for: draft.id) ?? ""
            }
            profiles = AWSProfiles.load()
            if draft.awsProfile.isEmpty, let first = profiles.first {
                draft.awsProfile = first.name
                if let region = first.region { draft.awsRegion = region }
            }
        }
        .onChange(of: draft.awsProfile) { _, newValue in
            if let profile = profiles.first(where: { $0.name == newValue }),
               let region = profile.region {
                draft.awsRegion = region
            }
        }
    }

    /// A SQLite database is one file, so it needs no server and no sign-in.
    @ViewBuilder
    private var sqliteSection: some View {
        Section("Database file") {
            HStack {
                TextField("File", text: $draft.filePath, prompt: Text("~/data/app.sqlite"))
                Button("Choose…") { chooseFile() }
            }
        }
        Section {
            Text("A SQLite database is one file on this machine. Rowset opens it for reading and "
                + "writing, and waits up to three seconds when another program holds it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a SQLite database file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.filePath = url.path
        if draft.name.isEmpty { draft.name = url.deletingPathExtension().lastPathComponent }
    }

    @ViewBuilder
    private var postgresSections: some View {
                Section("Server") {
                    TextField("Host", text: $draft.host, prompt: Text(hostPrompt))
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    TextField("Database", text: $draft.database, prompt: Text("cube_testing"))
                    TextField("User", text: $draft.username, prompt: Text(userPrompt))
                }

                Section("Authentication") {
                    Picker("Method", selection: $draft.authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.label).tag(method)
                        }
                    }

                    switch draft.authMethod {
                    case .awsIAM:
                        Picker("Profile", selection: $draft.awsProfile) {
                            if draft.awsProfile.isEmpty {
                                Text("Choose a profile").tag("")
                            }
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(profile.name)
                            }
                            if !draft.awsProfile.isEmpty,
                               !profiles.contains(where: { $0.name == draft.awsProfile }) {
                                Text("\(draft.awsProfile) (not in ~/.aws/config)")
                                    .tag(draft.awsProfile)
                            }
                        }
                        TextField("Region", text: $draft.awsRegion, prompt: Text("eu-central-1"))

                    case .password:
                        SecureField("Password", text: $password)
                    }

                    Picker("Encryption", selection: $draft.sslMode) {
                        ForEach(SSLMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section {
                    Text(authNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
    }

    private var buttons: some View {
        HStack {
                Button("Test Connection") { runTest() }
                    .disabled(!draft.isComplete || testState == .running)
                if testState == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let bookmark = normalized()
                    if bookmark.authMethod == .password {
                        KeychainStore.setPassword(password, for: bookmark.id)
                    } else {
                        KeychainStore.removePassword(for: bookmark.id)
                    }
                    onSave(bookmark)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
        }
    }

    private var hostPrompt: String {
        draft.authMethod == .awsIAM
            ? "name.eu-central-1.rds.amazonaws.com"
            : "localhost"
    }

    private var userPrompt: String {
        draft.authMethod == .awsIAM ? "cube_testing_iam_owner" : "postgres"
    }

    private var authNote: String {
        switch draft.authMethod {
        case .awsIAM:
            "The password is an IAM auth token. The AWS CLI creates it at every connect. "
                + "Nothing secret is stored in the bookmark file."
        case .password:
            "The password goes into your login keychain, not into the bookmark file."
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle, .running:
            EmptyView()
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .padding(.horizontal, 20)
                .textSelection(.enabled)
        case .failed(let message):
            ScrollView {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .padding(.horizontal, 20)
        }
    }

    private func normalized() -> Bookmark {
        var copy = draft
        copy.filePath = (copy.filePath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespaces)
        copy.host = copy.host.trimmingCharacters(in: .whitespaces)
        copy.database = copy.database.trimmingCharacters(in: .whitespaces)
        copy.username = copy.username.trimmingCharacters(in: .whitespaces)
        copy.awsRegion = copy.awsRegion.trimmingCharacters(in: .whitespaces)
        return copy
    }

    private func runTest() {
        let bookmark = normalized()
        // The test needs the password that is on screen, not the one on disk.
        if bookmark.authMethod == .password {
            KeychainStore.setPassword(password, for: bookmark.id)
        }
        testState = .running
        let statement = bookmark.driver == .sqlite
            ? "SELECT 'SQLite ' || sqlite_version()"
            : "SELECT version()"
        Task {
            let session = DatabaseSessionFactory.session(for: bookmark)
            do {
                try await session.connect()
                let result = try await session.query(statement, maxRows: 1)
                await session.close()
                let version = result.rows.first?.values.first?.text ?? "connected"
                testState = .passed(String(version.prefix(80)))
            } catch {
                await session.close()
                testState = .failed(DatabaseErrorText.describe(error))
            }
        }
    }
}
