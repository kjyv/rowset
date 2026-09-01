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
    /// `nil` in a file written before the pane belonged to the tab.
    var showsValuePane: Bool?
    var rowLimit: Int = 50

    var isSQLTab: Bool { schema == nil || table == nil }

    init(
        bookmarkID: UUID,
        schema: String? = nil,
        table: String? = nil,
        filterText: String = "",
        orderByText: String = "",
        sqlText: String = "",
        bufferID: UUID? = nil,
        showsValuePane: Bool? = nil,
        rowLimit: Int = 50
    ) {
        self.bookmarkID = bookmarkID
        self.schema = schema
        self.table = table
        self.filterText = filterText
        self.orderByText = orderByText
        self.sqlText = sqlText
        self.bufferID = bufferID
        self.showsValuePane = showsValuePane
        self.rowLimit = rowLimit
    }

    /// Reads the file field by field, and takes the default for a key that is missing.
    ///
    /// The synthesized reader wants every key of a value that is not optional, so one field added
    /// later would throw away every tab of every saved session. Only the bookmark is worth an
    /// error: a tab that reads half way is still the tab you left.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmarkID = try container.decode(UUID.self, forKey: .bookmarkID)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        table = try container.decodeIfPresent(String.self, forKey: .table)
        filterText = try container.decodeIfPresent(String.self, forKey: .filterText) ?? ""
        orderByText = try container.decodeIfPresent(String.self, forKey: .orderByText) ?? ""
        sqlText = try container.decodeIfPresent(String.self, forKey: .sqlText) ?? ""
        bufferID = try container.decodeIfPresent(UUID.self, forKey: .bufferID)
        showsValuePane = try container.decodeIfPresent(Bool.self, forKey: .showsValuePane)
        rowLimit = try container.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 50
    }
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
    var inspectorHeight: Double = 190
    var sidebarVisible: Bool = true

    func nodes(for bookmarkID: UUID) -> [NodePath] {
        expandedNodes[bookmarkID.uuidString] ?? []
    }

    init(
        expandedBookmarks: [UUID] = [],
        expandedNodes: [String: [NodePath]] = [:],
        tabs: [TabState] = [],
        selectedTabIndex: Int? = nil,
        inspectorHeight: Double = 190,
        sidebarVisible: Bool = true
    ) {
        self.expandedBookmarks = expandedBookmarks
        self.expandedNodes = expandedNodes
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.inspectorHeight = inspectorHeight
        self.sidebarVisible = sidebarVisible
    }

    /// Reads the file field by field, for the same reason `TabState` does.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expandedBookmarks =
            try container.decodeIfPresent([UUID].self, forKey: .expandedBookmarks) ?? []
        expandedNodes =
            try container.decodeIfPresent([String: [NodePath]].self, forKey: .expandedNodes) ?? [:]
        tabs = try container.decodeIfPresent([TabState].self, forKey: .tabs) ?? []
        selectedTabIndex = try container.decodeIfPresent(Int.self, forKey: .selectedTabIndex)
        inspectorHeight =
            try container.decodeIfPresent(Double.self, forKey: .inspectorHeight) ?? 190
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
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
