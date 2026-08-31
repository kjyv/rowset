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
        // The content owns the window. The traffic lights float over the top of the sidebar and
        // the tab bar fills the strip beside them, the way a Finder toolbar does.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    model.editedBookmark = Bookmark()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Console") {
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
            CommandGroup(after: .sidebar) {
                Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.isSidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Next Tab") { model.selectNextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                    .disabled(model.tabs.count < 2)

                Button("Previous Tab") { model.selectPreviousTab() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(model.tabs.count < 2)
            }

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
