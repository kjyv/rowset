import AppKit
import SwiftUI

/// The result grid.
///
/// This is an `NSTableView` and not a SwiftUI `Table`. SwiftUI gives a cell the height of its
/// text and not the height of the row, so a band above and below every value took no click. It
/// also offers no menu on a column header. `NSTableView` gives exact row geometry, a header menu,
/// column resizing, and it reuses one view per visible cell.
struct ResultTableView: NSViewRepresentable {
    let result: ResultSet
    @Binding var sortOrder: [ColumnComparator]
    @Binding var selectedCell: CellAddress?
    /// A column to scroll to once. The grid clears it after the jump.
    @Binding var revealColumn: String?
    /// Runs when you double click a cell.
    var onOpenValue: () -> Void = {}

    static let rowHeight: CGFloat = 20

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OverdrawTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.action = #selector(Coordinator.cellClicked)
        tableView.doubleAction = #selector(Coordinator.cellDoubleClicked)

        tableView.style = .fullWidth
        tableView.rowHeight = Self.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.usesAlternatingRowBackgroundColors = true
        // No gap at all between the cells. A gap is dead space, and it also leaves a stripe of
        // table background between the selected cell and the column line. The cell draws its own
        // separator on its trailing edge instead.
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = false

        let cellMenu = NSMenu()
        cellMenu.delegate = coordinator
        tableView.menu = cellMenu

        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        tableView.headerView?.menu = headerMenu

        coordinator.tableView = tableView
        coordinator.cellMenu = cellMenu
        coordinator.headerMenu = headerMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private var parent: ResultTableView
        weak var tableView: NSTableView?
        weak var cellMenu: NSMenu?
        weak var headerMenu: NSMenu?

        private var shownResultID: UUID?
        private var shownColumnNames: [String] = []
        private var shownSelection: CellAddress?
        /// Blocks the callback while the code writes the sort descriptors itself.
        private var isWritingSortDescriptors = false

        init(_ parent: ResultTableView) {
            self.parent = parent
        }

        func apply(_ parent: ResultTableView) {
            self.parent = parent
            guard let tableView else { return }

            let names = parent.result.columns.map(\.name)
            if names != shownColumnNames {
                rebuildColumns()
                shownResultID = parent.result.id
                shownSelection = parent.selectedCell
                tableView.reloadData()
                syncSortDescriptors()
                return
            }

            if shownResultID != parent.result.id {
                shownResultID = parent.result.id
                shownSelection = parent.selectedCell
                tableView.reloadData()
                tableView.scrollRowToVisible(0)
                syncSortDescriptors()
                return
            }

            revealRequestedColumn()

            if shownSelection != parent.selectedCell {
                let previous = shownSelection
                shownSelection = parent.selectedCell
                redraw(previous)
                redraw(parent.selectedCell)
            }

            syncSortDescriptors()
        }

        /// Scrolls sideways to the column that the sidebar asked for.
        private func revealRequestedColumn() {
            guard let tableView, let wanted = parent.revealColumn else { return }

            var mark: CellAddress?
            if let index = parent.result.columns.firstIndex(where: { $0.name == wanted }) {
                tableView.scrollColumnToVisible(index)
                // Mark the column, so you find it again among thirty others.
                if let first = parent.result.rows.first {
                    mark = CellAddress(rowID: first.id, columnID: parent.result.columns[index].id)
                }
            }

            // SwiftUI forbids a write while it draws, so the answer waits for the next turn.
            Task { @MainActor in
                self.parent.revealColumn = nil
                if let mark { self.parent.selectedCell = mark }
            }
        }

        /// Repaints one row, so a click does not reload the whole grid.
        private func redraw(_ address: CellAddress?) {
            guard let tableView, let address,
                  let row = parent.result.rows.firstIndex(where: { $0.id == address.rowID })
            else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integersIn: 0..<tableView.tableColumns.count))
        }

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }

            for column in parent.result.columns {
                let tableColumn = NSTableColumn(identifier: .init("col-\(column.id)"))
                tableColumn.title = column.name
                tableColumn.width = 170
                tableColumn.minWidth = 50
                tableColumn.maxWidth = 4_000
                tableColumn.resizingMask = .userResizingMask
                tableColumn.headerToolTip = "\(column.name) — \(column.typeName.lowercased())"
                // The prototype gives the header its sort arrow. The server does the sorting.
                tableColumn.sortDescriptorPrototype =
                    NSSortDescriptor(key: column.name, ascending: true)
                tableView.addTableColumn(tableColumn)
            }
            shownColumnNames = parent.result.columns.map(\.name)
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.result.rows.count
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn),
                  parent.result.rows.indices.contains(row),
                  parent.result.columns.indices.contains(columnIndex)
            else { return nil }

            let resultRow = parent.result.rows[row]
            let column = parent.result.columns[columnIndex]
            let value = resultRow.value(at: columnIndex)

            let cell = tableView.makeView(withIdentifier: GridCellView.identifier, owner: self)
                as? GridCellView ?? GridCellView()

            cell.configure(
                preview: value.preview,
                isNull: value.isNull,
                isRaw: value.isRaw,
                isSelected: parent.selectedCell == CellAddress(rowID: resultRow.id, columnID: column.id))
            return cell
        }

        // MARK: Clicks

        @objc func cellClicked() {
            guard let tableView else { return }
            select(row: tableView.clickedRow, column: tableView.clickedColumn)
        }

        @objc func cellDoubleClicked() {
            guard let tableView else { return }
            guard select(row: tableView.clickedRow, column: tableView.clickedColumn) else { return }
            parent.onOpenValue()
        }

        @discardableResult
        private func select(row: Int, column: Int) -> Bool {
            guard parent.result.rows.indices.contains(row),
                  parent.result.columns.indices.contains(column)
            else { return false }
            parent.selectedCell = CellAddress(
                rowID: parent.result.rows[row].id,
                columnID: parent.result.columns[column].id)
            return true
        }

        // MARK: Sorting

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isWritingSortDescriptors else { return }
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
                parent.sortOrder = []
                return
            }
            parent.sortOrder = [
                ColumnComparator(
                    columnName: key,
                    order: descriptor.ascending ? .forward : .reverse)
            ]
        }

        /// Copies the sort of the tab onto the header, so the arrow matches the query.
        private func syncSortDescriptors() {
            guard let tableView else { return }
            let wanted: [NSSortDescriptor] = parent.sortOrder.prefix(1).map {
                NSSortDescriptor(key: $0.columnName, ascending: $0.order == .forward)
            }
            let current = tableView.sortDescriptors
            let same = current.count == wanted.count
                && zip(current, wanted).allSatisfy { $0.key == $1.key && $0.ascending == $1.ascending }
            guard !same else { return }

            isWritingSortDescriptors = true
            tableView.sortDescriptors = wanted
            isWritingSortDescriptors = false
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                buildHeaderMenu(menu)
            } else {
                buildCellMenu(menu)
            }
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            guard let tableView, let header = tableView.headerView else { return }
            var column = -1
            if let event = NSApp.currentEvent {
                column = header.column(at: header.convert(event.locationInWindow, from: nil))
            }
            if parent.result.columns.indices.contains(column) {
                let name = parent.result.columns[column].name
                add(menu, "Copy Column Name “\(name)”") { Clipboard.write(name) }
            }
            let allNames = parent.result.headerLine
            add(menu, "Copy All Column Names") { Clipboard.write(allNames) }
        }

        private func buildCellMenu(_ menu: NSMenu) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            let column = tableView.clickedColumn
            guard parent.result.rows.indices.contains(row) else { return }

            let resultRow = parent.result.rows[row]
            let result = parent.result

            if parent.result.columns.indices.contains(column) {
                let value = resultRow.value(at: column)
                add(menu, "Copy Value") { Clipboard.write(value.isNull ? "" : value.text) }
            }
            add(menu, "Copy Row") { Clipboard.write(result.line(for: resultRow)) }
            add(menu, "Copy Row with Header") {
                Clipboard.write(result.headerLine + "\n" + result.line(for: resultRow))
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

/// Carries a closure into an `NSMenuItem`.
private final class BlockBox {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { action() }
}

/// One cell. It fills the whole row and the whole column, so no point of the grid is dead and no
/// stripe of background shows between the selection and the column line.
///
/// The cell holds no `NSTextField`. A text field brings Auto Layout, its own drawing and its own
/// tracking, and the table builds one per visible cell on every scroll step. This view draws the
/// string itself with attributes it built once, which is what makes a long scroll smooth.
///
/// The cost is that the text here takes no selection. The value pane reads and copies instead.
private final class GridCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("RowsetGridCell")

    private enum Style: Hashable {
        case normal, null, raw
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let italicFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 12) ?? font
    }()

    private static let lineHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// One dictionary per look. Building these per cell would allocate on every scroll step.
    private static let attributes: [Style: [NSAttributedString.Key: Any]] = [
        .normal: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle,
        ],
        .null: [
            .font: italicFont, .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ],
        .raw: [
            .font: font, .foregroundColor: NSColor.systemOrange, .paragraphStyle: paragraphStyle,
        ],
    ]

    private var text = ""
    private var style: Style = .normal
    private var isSelectedCell = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedCell {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            bounds.fill()
        }

        NSColor.gridColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        guard !text.isEmpty, bounds.width > 14 else { return }
        let top = ((bounds.height - Self.lineHeight) / 2).rounded()
        let textRect = NSRect(
            x: 6, y: top, width: bounds.width - 13, height: Self.lineHeight)
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: Self.attributes[style],
            context: nil)
    }

    func configure(preview: String, isNull: Bool, isRaw: Bool, isSelected: Bool) {
        let newText = isNull ? "NULL" : preview
        let newStyle: Style = isNull ? .null : (isRaw ? .raw : .normal)

        // A reused cell often gets what it already shows. Skip the redraw then.
        guard newText != text || newStyle != style || isSelected != isSelectedCell else { return }
        text = newText
        style = newStyle
        isSelectedCell = isSelected
        needsDisplay = true
    }
}

enum Clipboard {
    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A table that prepares many more rows than the window shows.
///
/// AppKit only builds the cells it is about to draw. On a fast scroll it then builds them while
/// you drag, and the grid stutters. `prepareContent` widens the band that AppKit fills, so the
/// rows are ready before they arrive. The cost is memory for the extra cell views.
final class OverdrawTableView: NSTableView {
    /// How far above and below the window AppKit prepares, in points.
    /// At a row height of 20 this is about 100 rows on each side.
    static let overdraw: CGFloat = 2_000

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect.insetBy(dx: 0, dy: -Self.overdraw))
    }
}
