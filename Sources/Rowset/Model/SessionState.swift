import Foundation

/// One row of the tree that was open.
struct NodePath: Codable, Hashable, Sendable {
    var schema: String
    /// `nil` means the schema row itself.
    var table: String?
}

/// One tab that was open.
struct TabState: Codable, Sendable {
    var bookmarkID: UUID
    /// `nil` for a query tab.
    var schema: String?
    var table: String?
    var filterText: String = ""
    var orderByText: String = ""
    var sqlText: String = ""
    var bufferID: UUID?
    var showsConsole: Bool = false
    var rowLimit: Int = 50

    var isSQLTab: Bool { schema == nil || table == nil }
}

/// What the window looked like when you closed it.
///
/// The window frame is not here. AppKit stores that under the autosave name.
struct SessionState: Codable, Sendable {
    var expandedBookmarks: [UUID] = []
    /// The open tree rows of each connection, by the text form of its id.
    var expandedNodes: [String: [NodePath]] = [:]
    var tabs: [TabState] = []
    var selectedTabIndex: Int?
    var inspectorVisible: Bool = true
    var inspectorHeight: Double = 190
    var sidebarVisible: Bool = true

    func nodes(for bookmarkID: UUID) -> [NodePath] {
        expandedNodes[bookmarkID.uuidString] ?? []
    }
}

/// Reads and writes the session file.
///
/// The file sits beside `bookmarks.json` and holds no secret. A write waits a moment, because the
/// state changes on every click and the disk does not need each one.
@MainActor
final class SessionStore {
    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rowset/session.json")
    }

    func load() -> SessionState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return SessionState() }
        return state
    }

    /// Writes after a short wait, so a burst of clicks costs one write.
    func save(_ state: SessionState) {
        pendingSave?.cancel()
        pendingSave = Task { [fileURL] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(state, to: fileURL)
        }
    }

    /// Writes at once. The app calls this when it closes.
    func saveNow(_ state: SessionState) {
        pendingSave?.cancel()
        pendingSave = nil
        Self.write(state, to: fileURL)
    }

    private static func write(_ state: SessionState, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            // A lost session is not worth an alert. The bookmarks are in their own file.
        }
    }
}
