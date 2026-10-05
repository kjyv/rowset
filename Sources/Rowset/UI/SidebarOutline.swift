import AppKit
import Observation
import SwiftUI

/// The connection tree of the sidebar, and the filter result in its place.
///
/// This is an `NSOutlineView` and not a SwiftUI `List`. A `List` of nested disclosure groups
/// crashes when a row closes over an open row that AppKit never drew: AppKit asks for the rows
/// under it, and SwiftUI has dropped them already. Here the data source answers for every row,
/// open or closed.
struct SidebarOutline: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let outlineView = SidebarOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        // The find key of the sidebar tells this table from the result grid by the header.
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.backgroundColor = .clear
        outlineView.setAccessibilityLabel("Connections")

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outlineView.onReturn = { [weak coordinator] in
            coordinator?.model.openSidebarSelection()
        }

        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        coordinator.outlineView = outlineView
        coordinator.start()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
        NSMenuDelegate
    {
        let model: AppModel
        weak var outlineView: NSOutlineView?
        private let tree = SidebarTree()

        /// The keys of the rows under each row, as AppKit last heard them. `""` is the root.
        private var shownChildren: [String: [String]] = [:]
        private var shownLooks: [String: SidebarLook] = [:]
        /// True while the code opens, closes or selects rows itself. AppKit reports those like
        /// clicks, and the model must not hear its own state back.
        private var isSyncing = false

        static let bookmarkRowHeight: CGFloat = 36

        init(model: AppModel) {
            self.model = model
        }

        func start() {
            refresh()
            followSelection()
        }

        /// Reads the model, shows what changed, and waits for the next change.
        private func refresh() {
            withObservationTracking {
                tree.rebuild(from: model)
            } onChange: { [weak self] in
                // This runs before the change lands, so the read waits for the next turn.
                Task { @MainActor [weak self] in self?.refresh() }
            }
            apply()
        }

        /// Selects the row the model names, and waits for the next selection.
        private func followSelection() {
            withObservationTracking {
                _ = model.sidebarSelection
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.followSelection() }
            }
            syncSelection()
        }

        /// Tells AppKit what changed since the last call, then opens and selects the rows the
        /// model asks for.
        private func apply() {
            guard let outlineView else { return }

            var children: [String: [String]] = ["": tree.roots.map(\.key)]
            var parents: [String: String] = [:]
            var looks: [String: SidebarLook] = [:]
            func walk(_ items: [SidebarItem], under parent: String) {
                for item in items {
                    children[item.key] = item.children.map(\.key)
                    parents[item.key] = parent
                    looks[item.key] = item.look
                    walk(item.children, under: item.key)
                }
            }
            walk(tree.roots, under: "")

            let changed = Set(children.keys.filter { key in
                shownChildren[key].map { $0 != children[key] } ?? false
            })
            // AppKit reloads everything under a row it reloads, so only the highest count.
            let highest = changed.filter { key in
                var ancestor = parents[key]
                while let current = ancestor {
                    if changed.contains(current) { return false }
                    ancestor = parents[current]
                }
                return true
            }

            isSyncing = true
            defer { isSyncing = false }

            if shownChildren.isEmpty || highest.count > 1 || highest.contains("") {
                outlineView.reloadData()
            } else {
                // A row that is out of sight may still hold its old children inside AppKit.
                // Only a full reload is sure to drop those.
                if let key = highest.first, let item = tree.item(key: key) {
                    if outlineView.row(forItem: item) >= 0 {
                        outlineView.reloadItem(item, reloadChildren: true)
                    } else {
                        outlineView.reloadData()
                    }
                }
                var resized = IndexSet()
                for (key, look) in looks {
                    guard let shown = shownLooks[key], shown != look,
                          let item = tree.item(key: key)
                    else { continue }
                    let row = outlineView.row(forItem: item)
                    guard row >= 0 else { continue }
                    outlineView.reloadItem(item)
                    if look.style == .error || shown.style == .error { resized.insert(row) }
                }
                if !highest.isEmpty {
                    resized = IndexSet(integersIn: 0..<outlineView.numberOfRows)
                }
                if !resized.isEmpty {
                    outlineView.noteHeightOfRows(withIndexesChanged: resized)
                }
            }

            shownChildren = children
            shownLooks = looks
            syncExpansion(tree.roots)
            syncSelection()
        }

        /// Opens and closes rows until the outline matches the model.
        ///
        /// It stops at a closed row. AppKit keeps what lies under it, and the rows there follow
        /// when it opens again.
        private func syncExpansion(_ items: [SidebarItem]) {
            guard let outlineView else { return }
            let wasSyncing = isSyncing
            isSyncing = true
            defer { isSyncing = wasSyncing }

            for item in items where item.isExpandable {
                if item.wantsExpanded {
                    if !outlineView.isItemExpanded(item) { outlineView.expandItem(item) }
                    syncExpansion(item.children)
                } else if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                }
            }
        }

        private func syncSelection() {
            guard let outlineView else { return }
            let wanted = model.sidebarSelection.flatMap { tree.item(for: $0) }
            let row = wanted.map { outlineView.row(forItem: $0) } ?? -1
            guard row != outlineView.selectedRow else { return }

            let wasSyncing = isSyncing
            isSyncing = true
            defer { isSyncing = wasSyncing }
            // A selected row that sits under a closed row stays selected in the model.
            if row >= 0 {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                outlineView.deselectAll(nil)
            }
        }

        // MARK: Data source

        private func children(of item: Any?) -> [SidebarItem] {
            guard let item = item as? SidebarItem else { return tree.roots }
            return item.children
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let children = children(of: item)
            guard children.indices.contains(index) else {
                // `apply` tells AppKit of every change, so this means a bug there. A release
                // build shows an empty row until the next change instead of crashing.
                assertionFailure("The sidebar outline asked for child \(index) of \(children.count)")
                return tree.placeholder
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarItem)?.isExpandable ?? false
        }

        // MARK: Delegate

        func outlineView(
            _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
        ) -> NSView? {
            guard let item = item as? SidebarItem else { return nil }

            let cell: SidebarCellView
            switch item.look.style {
            case .header:
                cell = dequeue(SidebarHeaderCell.identifier) { SidebarHeaderCell() }
            case .bookmark:
                cell = dequeue(SidebarBookmarkCell.identifier) { SidebarBookmarkCell() }
            case .row:
                cell = dequeue(SidebarRowCell.identifier) { SidebarRowCell() }
            case .note:
                cell = dequeue(SidebarNoteCell.identifier) { SidebarNoteCell() }
            case .error:
                cell = dequeue(SidebarErrorCell.identifier) { SidebarErrorCell() }
            case .link:
                let link = dequeue(SidebarLinkCell.identifier) { SidebarLinkCell() }
                if case .connect(let bookmarkID) = item.kind {
                    link.onClick = { [weak self] in
                        guard let self else { return }
                        Task { await self.model.connect(to: bookmarkID) }
                    }
                }
                cell = link
            }
            cell.configure(item.look)
            return cell
        }

        private func dequeue<Cell: SidebarCellView>(
            _ identifier: NSUserInterfaceItemIdentifier, make: () -> Cell
        ) -> Cell {
            outlineView?.makeView(withIdentifier: identifier, owner: self) as? Cell ?? make()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let item = item as? SidebarItem else { return outlineView.rowHeight }
            switch item.look.style {
            case .bookmark:
                return max(outlineView.rowHeight, Self.bookmarkRowHeight)
            case .error:
                let height = SidebarErrorCell.height(
                    of: item.look.title, width: textWidth(of: item, in: outlineView))
                return max(outlineView.rowHeight, height)
            default:
                return outlineView.rowHeight
            }
        }

        /// The width a message has at the depth of its row.
        private func textWidth(of item: SidebarItem, in outlineView: NSOutlineView) -> CGFloat {
            let level = max(outlineView.level(forItem: item), 0)
            let columnWidth = outlineView.tableColumns.first?.width ?? outlineView.bounds.width
            return columnWidth - CGFloat(level + 1) * outlineView.indentationPerLevel - 8
        }

        /// A message wraps again at the new width, so its row takes a new height.
        func outlineViewColumnDidResize(_ notification: Notification) {
            guard let outlineView else { return }
            let rows = (0..<outlineView.numberOfRows).filter {
                (outlineView.item(atRow: $0) as? SidebarItem)?.look.style == .error
            }
            guard !rows.isEmpty else { return }
            outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(rows))
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? SidebarItem)?.look.style == .header
        }

        /// A section title stays open. It has no chevron to close it.
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            (item as? SidebarItem)?.look.style != .header
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            (item as? SidebarItem)?.look.style != .header
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarItem)?.selection != nil
        }

        func outlineView(
            _ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any
        ) -> String? {
            guard let item = item as? SidebarItem, item.selection != nil else { return nil }
            return item.look.title
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outlineView else { return }
            let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem
            model.sidebarSelection = item?.selection
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
            if !isSyncing { write(expanded: true, for: item) }
            // The rows below that the model holds open open with it.
            syncExpansion(item.children)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncing, let outlineView,
                  let item = notification.userInfo?["NSObject"] as? SidebarItem
            else { return }
            // AppKit also reports each open row under the row that closes, after it marked that
            // row closed. Those rows stay open in the model and come back with it. Only Option
            // closes them for good.
            if let parent = outlineView.parent(forItem: item), !outlineView.isItemExpanded(parent),
               NSApp.currentEvent?.modifierFlags.contains(.option) != true {
                return
            }
            write(expanded: false, for: item)
        }

        private func write(expanded: Bool, for item: SidebarItem) {
            switch item.kind {
            case .bookmark(let bookmark):
                model.setExpanded(expanded, bookmarkID: bookmark.id)
            case .node(let node, let connection):
                model.setExpanded(expanded, node: node, in: connection)
            case .header, .table, .note, .connect:
                break
            }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  let selection = item.selection
            else { return }
            // A quick second click on the chevron is not a double click on the row.
            if let event = NSApp.currentEvent {
                let point = outlineView.convert(event.locationInWindow, from: nil)
                if outlineView.frameOfOutlineCell(atRow: row).contains(point) { return }
            }
            model.openSidebarSelection(selection)
        }

        // MARK: Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView,
                  let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem
            else { return }

            switch item.kind {
            case .bookmark(let bookmark):
                buildConnectionMenu(menu, for: bookmark)
            case .node(let node, let connection):
                buildNodeMenu(menu, for: node, in: connection)
            case .table(let table, let connection):
                add(menu, "Open") { self.model.open(table, in: connection) }
                add(menu, "Copy Name") { Clipboard.write(table.name) }
            case .header, .note, .connect:
                break
            }
        }

        /// The menu of a connection row. It offers what the state allows, and nothing else.
        private func buildConnectionMenu(_ menu: NSMenu, for bookmark: Bookmark) {
            let id = bookmark.id
            let connection = model.connection(id: id)

            switch connection?.state ?? .disconnected {
            case .connected:
                add(menu, "Disconnect") { Task { await self.model.disconnect(bookmarkID: id) } }
                add(menu, "Refresh") { Task { await connection?.refresh() } }
                menu.addItem(.separator())
                add(menu, "New Console") {
                    if let connection { self.model.openSQLTab(connection: connection) }
                }
            case .connecting:
                // No action, so the menu shows it greyed out.
                menu.addItem(NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: ""))
            case .disconnected, .failed:
                add(menu, "Connect") { Task { await self.model.connect(to: id) } }
            }

            menu.addItem(.separator())
            add(menu, "Duplicate") { self.model.duplicate(bookmarkID: id) }
            add(menu, "Edit…") { self.model.editedBookmark = bookmark }
            add(menu, "Delete") { Task { await self.model.deleteConnection(bookmarkID: id) } }
        }

        private func buildNodeMenu(
            _ menu: NSMenu, for node: TreeNode, in connection: ConnectionModel
        ) {
            if node.kind.isTableLike {
                add(menu, "Open") { self.model.open(node, in: connection) }
            }
            if case .column = node.kind {
                add(menu, "Show in Table") { self.model.open(node, in: connection) }
            }
            add(menu, "Copy Name") { Clipboard.write(node.kind.title) }

            if node.kind.isTableLike {
                menu.addItem(.separator())
                let title = node.sortsColumnsByName
                    ? "Sort Columns by Position" : "Sort Columns by Name"
                add(menu, title) {
                    let byName = !node.sortsColumnsByName
                    connection.setColumnSorting(byName: byName, on: node)
                    if node.children == nil {
                        Task { await connection.loadChildren(of: node) }
                    }
                    // The tabs of this table follow, so the tree and the grid agree.
                    Task { await self.model.setColumnSorting(byName: byName, forTablesOf: node) }
                }
            }
            if node.kind.canHaveChildren {
                menu.addItem(.separator())
                add(menu, "Refresh") {
                    node.children = nil
                    Task { await connection.loadChildren(of: node) }
                }
            }
        }

        private func add(_ menu: NSMenu, _ title: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = BlockBox(action)
            menu.addItem(item)
        }

        @objc private func runBlock(_ sender: NSMenuItem) {
            (sender.representedObject as? BlockBox)?.run()
        }
    }
}

/// The outline of the sidebar. Return opens the selected row.
final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Caps Lock does not change what Return does.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 36, modifiers.isEmpty, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
    }
}
