import Foundation

/// Where the app keeps the files it writes.
///
/// `ROWSET_SUPPORT_DIR` moves all of them somewhere else for one launch. The screenshot script
/// uses that, so it opens a demo database without touching the connections you work with.
enum SupportDirectory {
    static func url() -> URL {
        let environment = ProcessInfo.processInfo.environment["ROWSET_SUPPORT_DIR"]
        if let environment, !environment.isEmpty {
            return URL(fileURLWithPath: environment, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rowset")
    }

    static func file(_ name: String) -> URL {
        url().appending(path: name)
    }
}
