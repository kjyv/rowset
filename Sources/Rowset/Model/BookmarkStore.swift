import Foundation
import Observation

/// Reads and writes the bookmark list.
///
/// The file is `~/Library/Application Support/Rowset/bookmarks.json`. It contains no secret,
/// so the app uses a plain file and not the Keychain.
@MainActor
@Observable
final class BookmarkStore {
    private(set) var bookmarks: [Bookmark] = []
    private(set) var loadError: String?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rowset/bookmarks.json")
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            bookmarks = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
            loadError = nil
        } catch {
            loadError = "Could not read \(fileURL.path): \(error.localizedDescription)"
        }
    }

    func upsert(_ bookmark: Bookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        save()
    }

    func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        // A password outlives its bookmark otherwise.
        KeychainStore.removePassword(for: id)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bookmarks).write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Could not write \(fileURL.path): \(error.localizedDescription)"
        }
    }
}
