import Foundation
import Observation

/// One saved editor buffer of a query console.
///
/// A buffer belongs to a connection, so the queries of one database never show up under another.
struct SQLBuffer: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// The name in the list, taken from the text itself.
    ///
    /// A name of its own would need a dialog and a rename. The first line of the query says what
    /// it is, and it stays right while you type.
    var title: String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let firstLine else { return "Empty query" }

        let flattened = firstLine
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\t", with: " ")
        return flattened.count > 44 ? String(flattened.prefix(44)) + "…" : flattened
    }
}

/// Keeps the buffers of every connection.
///
/// The file is `~/Library/Application Support/Rowset/buffers.json`. A query is work, so it
/// outlives the tab that showed it and the session it was typed in.
@MainActor
@Observable
final class BufferStore {
    /// The buffers of each connection, by the text form of its id.
    private(set) var buffers: [String: [SQLBuffer]] = [:]

    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rowset/buffers.json")
    }

    // MARK: - Reading

    /// The buffers of one connection, the one you touched last at the top.
    func buffers(for bookmarkID: UUID) -> [SQLBuffer] {
        (buffers[bookmarkID.uuidString] ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    func buffer(id: UUID, for bookmarkID: UUID) -> SQLBuffer? {
        buffers[bookmarkID.uuidString]?.first { $0.id == id }
    }

    // MARK: - Writing

    @discardableResult
    func create(for bookmarkID: UUID, text: String) -> SQLBuffer {
        let buffer = SQLBuffer(text: text)
        buffers[bookmarkID.uuidString, default: []].append(buffer)
        save()
        return buffer
    }

    /// Writes the text of a buffer. An unchanged text touches nothing, so the order stays put.
    func setText(_ text: String, id: UUID, for bookmarkID: UUID) {
        let key = bookmarkID.uuidString
        guard let index = buffers[key]?.firstIndex(where: { $0.id == id }) else { return }
        guard buffers[key]?[index].text != text else { return }

        buffers[key]?[index].text = text
        buffers[key]?[index].updatedAt = Date()
        save()
    }

    func delete(id: UUID, for bookmarkID: UUID) {
        buffers[bookmarkID.uuidString]?.removeAll { $0.id == id }
        save()
    }

    func removeAll(for bookmarkID: UUID) {
        buffers[bookmarkID.uuidString] = nil
        save()
    }

    // MARK: - The file

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode([String: [SQLBuffer]].self, from: data)
        else { return }
        buffers = stored
    }

    /// Writes after a short wait, so typing costs one write and not one per key.
    private func save() {
        pendingSave?.cancel()
        let snapshot = buffers
        pendingSave = Task { [fileURL] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: fileURL)
        }
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        Self.write(buffers, to: fileURL)
    }

    private static func write(_ buffers: [String: [SQLBuffer]], to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(buffers).write(to: fileURL, options: .atomic)
        } catch {
            // A lost buffer list is not worth an alert. The bookmarks live in their own file.
        }
    }
}
