import AppKit
import SwiftUI

@main
struct RowsetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .background(WindowAccessor(autosaveName: "RowsetMainWindow"))
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in
                    model.saveSessionNow()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    model.editedBookmark = Bookmark()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Query Tab") {
                    if let connection = model.activeConnection {
                        model.openSQLTab(connection: connection)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.activeConnection == nil)
            }

            // `.saveItem` holds the standard Close item, and that one owns Command-W. Adding a
            // second item with the same key let the system keep the standard one, so Command-W
            // closed the window. Replacing the group takes the key over.
            CommandGroup(replacing: .saveItem) {
                Button(model.selectedTabID == nil ? "Close Window" : "Close Tab") {
                    if let id = model.selectedTabID {
                        model.closeTab(id: id)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}
