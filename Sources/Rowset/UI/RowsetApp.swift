import SwiftUI

@main
struct RowsetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .background(WindowAccessor(autosaveName: "RowsetMainWindow"))
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

            CommandGroup(after: .toolbar) {
                Button("Close Tab") {
                    if let id = model.selectedTabID { model.closeTab(id: id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.selectedTabID == nil)
            }
        }
    }
}
