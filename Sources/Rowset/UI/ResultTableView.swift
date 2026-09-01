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
    @Binding var selection: CellSelection?
    /// A column to scroll to once. The grid clears it after the jump.
    @Binding var revealColumn: String?
    /// Runs when you press the space bar, with the row under the selection.
    var onQuickLook: (Int) -> Void = { _ in }
    /// Asks for the whole of a row whose large values the server cut.
    var onNeedFullRow: (Int) async -> Void = { _ in }
    /// Runs when you double click a cell.
    var onOpenValue: () -> Void = {}
    /// Runs when you click a column header. The server does the sorting, so the caller must run
    /// the query again.
    var onSortChange: () -> Void = {}
    /// The tab that owns the edits. `nil` means the grid is read only.
    var editing: QueryTab?

    static let rowHeight: CGFloat = 22

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OverdrawTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.onCellMouseDown = { [weak coordinator] row, column, extend, clicks in
            coordinator?.mouseDown(row: row, column: column, extend: extend, clickCount: clicks)
        }
        tableView.onCellDrag = { [weak coordinator] row, column in
            coordinator?.dragged(row: row, column: column)
        }
        tableView.onCopy = { [weak coordinator] in
            coordinator?.copySelection(includeHeader: false)
        }
        tableView.onDelete = { [weak coordinator] in
            coordinator?.setSelectionToNull()
        }
        tableView.onSpace = { [weak coordinator] in
            coordinator?.openQuickLook()
        }
        tableView.onReturn = { [weak coordinator] in
            coordinator?.editSelection()
        }
        tableView.onCommandReturn = { [weak coordinator] in
            coordinator?.parent.onOpenValue()
        }

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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
        NSTextFieldDelegate
    {
        /// Not private: the table view reaches the callbacks through it.
        var parent: ResultTableView
        weak var tableView: NSTableView?
        weak var cellMenu: NSMenu?
        weak var headerMenu: NSMenu?

        private var shownResultID: UUID?
        private var shownColumnNames: [String] = []
        private var shownSelection: CellSelection?
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
                shownSelection = parent.selection
                tableView.reloadData()
                syncSortDescriptors()
                return
            }

            if shownResultID != parent.result.id {
                shownResultID = parent.result.id
                shownSelection = parent.selection
                tableView.reloadData()
                tableView.scrollRowToVisible(0)
                syncSortDescriptors()
                return
            }

            revealRequestedColumn()

            if shownSelection != parent.selection {
                let previous = shownSelection
                shownSelection = parent.selection
                redraw(previous)
                redraw(parent.selection)
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
                if let mark { self.parent.selection = CellSelection(single: mark) }
            }
        }

        /// Repaints the rows a selection covers, so a click does not reload the whole grid.
        private func redraw(_ selection: CellSelection?) {
            guard let tableView, let selection else { return }
            for row in selection.rows where parent.result.rows.indices.contains(row) {
                tableView.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
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

        /// No cell view. One row view draws the whole row, see `GridRowView`.
        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: GridRowView.identifier, owner: self)
                as? GridRowView ?? GridRowView()
            view.owner = self
            view.rowIndex = row
            return view
        }

        /// What the row at `row` must draw. The row view asks for this while it draws.
        func rowContent(_ row: Int) -> RowContent? {
            guard parent.result.rows.indices.contains(row) else { return nil }
            let resultRow = parent.result.rows[row]

            var selected: ClosedRange<Int>?
            if let selection = parent.selection, selection.rows.contains(resultRow.id) {
                selected = selection.columns
            }

            var values = parent.result.columns.indices.map { resultRow.value(at: $0) }
            var edited: Set<Int> = []

            // A pending edit replaces what the server sent, and the cell is marked.
            if let tab = parent.editing, tab.hasEdits {
                for (index, column) in parent.result.columns.enumerated() {
                    let address = CellAddress(rowID: resultRow.id, columnID: column.id)
                    guard tab.isEdited(address) else { continue }
                    edited.insert(index)
                    if let text = tab.pendingText(at: address) {
                        values[index] = DisplayValue.make(text: text)
                    } else {
                        values[index] = .null
                    }
                }
            }

            return RowContent(values: values, selected: selected, edited: edited)
        }

        // MARK: Clicks

        func mouseDown(row: Int, column: Int, extend: Bool, clickCount: Int) {
            guard let address = address(row: row, column: column) else { return }

            if extend, let current = parent.selection {
                parent.selection = CellSelection(anchor: current.anchor, focus: address)
            } else {
                parent.selection = CellSelection(single: address)
            }

            // A cut value has to be whole before it is shown or changed.
            if parent.editing?.isCut(at: address) == true {
                Task { await parent.onNeedFullRow(address.rowID) }
            }

            guard clickCount >= 2 else { return }

            // A value of more than one line does not fit a cell. The pane takes it.
            if let tab = parent.editing, tab.isEditable, !isMultiline(at: address) {
                beginEdit(row: row, column: column, address: address)
            } else {
                parent.onOpenValue()
            }
        }

        /// Grows the block while you drag. The anchor stays where the drag began.
        func dragged(row: Int, column: Int) {
            guard let address = address(row: row, column: column),
                  let current = parent.selection,
                  current.focus != address
            else { return }
            parent.selection = CellSelection(anchor: current.anchor, focus: address)
        }

        private func address(row: Int, column: Int) -> CellAddress? {
            guard parent.result.rows.indices.contains(row),
                  parent.result.columns.indices.contains(column)
            else { return nil }
            return CellAddress(
                rowID: parent.result.rows[row].id,
                columnID: parent.result.columns[column].id)
        }

        // MARK: Editing a cell

        private var editor: NSTextField?
        private var booleanButton: NSPopUpButton?
        private var editorAddress: CellAddress?

        private func isMultiline(at address: CellAddress) -> Bool {
            guard let value = currentValue(at: address) else { return false }
            return value.contains("\n") || value.count > 200
        }

        /// What a cell holds now, the pending edit first.
        private func currentValue(at address: CellAddress) -> String? {
            if let tab = parent.editing, tab.isEdited(address) {
                return tab.pendingText(at: address)
            }
            guard let value = parent.result.value(at: address) else { return nil }
            return value.isNull ? nil : value.text
        }

        /// Opens an editor over the cell. A boolean gets a menu, because it has three answers at
        /// most and typing one of them is needless work.
        private func beginEdit(row: Int, column: Int, address: CellAddress) {
            guard let tableView else { return }
            endEdit(commit: true)

            if parent.editing?.info(at: address)?.kind == .boolean {
                beginBooleanEdit(row: row, column: column, address: address)
                return
            }

            let field = NSTextField(frame: tableView.frameOfCell(atColumn: column, row: row))
            field.stringValue = currentValue(at: address) ?? ""
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.isBezeled = true
            field.bezelStyle = .squareBezel
            field.drawsBackground = true
            field.delegate = self
            field.lineBreakMode = .byClipping
            field.usesSingleLineMode = true

            tableView.addSubview(field)
            tableView.window?.makeFirstResponder(field)
            editor = field
            editorAddress = address
        }

        /// A menu of true, false, and NULL where the column takes one.
        private func beginBooleanEdit(row: Int, column: Int, address: CellAddress) {
            guard let tableView, let tab = parent.editing else { return }

            let button = NSPopUpButton(
                frame: tableView.frameOfCell(atColumn: column, row: row), pullsDown: false)
            button.addItems(withTitles: ["true", "false"])
            if tab.acceptsNull(at: address) { button.addItem(withTitle: "NULL") }

            let current = currentValue(at: address)
            button.selectItem(withTitle: current.map { $0.lowercased() == "true" ? "true" : "false" }
                ?? "NULL")

            button.target = self
            button.action = #selector(booleanChosen(_:))
            tableView.addSubview(button)
            booleanButton = button
            editorAddress = address
            button.performClick(nil)
        }

        @objc private func booleanChosen(_ sender: NSPopUpButton) {
            guard let address = editorAddress, let tab = parent.editing else { return }
            let title = sender.titleOfSelectedItem ?? "false"
            tab.setEdit(title == "NULL" ? nil : title, at: address)
            redraw(CellSelection(single: address))

            sender.removeFromSuperview()
            booleanButton = nil
            editorAddress = nil
            tableView?.window?.makeFirstResponder(tableView)
        }

        /// Takes the editor away, and keeps what you typed when it fits the column.
        ///
        /// A value that does not fit stops here. The field stays open with the text in red, so a
        /// wrong number never reaches the SQL and never disappears either.
        @discardableResult
        func endEdit(commit: Bool) -> Bool {
            endEdit(commit: commit, keepOpenOnBadValue: true)
        }

        /// Takes the editor away, and keeps what you typed when it fits the column.
        ///
        /// While you are still typing, a value that does not fit holds the field open with the
        /// text in red. Once the field has lost the keyboard there is nothing to hold open, so a
        /// bad value is dropped and the cell keeps what it had.
        @discardableResult
        func endEdit(commit: Bool, keepOpenOnBadValue: Bool) -> Bool {
            if let button = booleanButton {
                button.removeFromSuperview()
                booleanButton = nil
                editorAddress = nil
                return true
            }

            guard let field = editor, let address = editorAddress else { return true }

            if commit, let tab = parent.editing {
                let kind = tab.info(at: address)?.kind ?? .text

                if ValueValidator.isValid(field.stringValue, for: kind) {
                    // A cell that held NULL and was left empty was not changed. Only the delete
                    // key writes NULL, and the value pane writes an empty text.
                    let wasNull = parent.result.value(at: address)?.isNull ?? false
                    if !(wasNull && field.stringValue.isEmpty) {
                        tab.setEdit(field.stringValue, at: address)
                    }
                    redraw(CellSelection(single: address))
                } else if keepOpenOnBadValue {
                    field.textColor = .systemRed
                    field.toolTip = ValueValidator.message(for: kind)
                    NSSound.beep()
                    return false
                } else {
                    NSSound.beep()
                }
            }

            editor = nil
            editorAddress = nil
            field.removeFromSuperview()
            tableView?.window?.makeFirstResponder(tableView)
            return true
        }

        /// Starts an edit on the cell of the selection.
        ///
        /// A short value opens a field in the cell. A value of more than one line does not fit
        /// there, so the value pane opens and starts its own edit.
        func editSelection() {
            guard let tab = parent.editing, tab.isEditable,
                  let address = parent.selection?.focus,
                  let row = parent.result.rows.firstIndex(where: { $0.id == address.rowID }),
                  let column = parent.result.columns.firstIndex(
                    where: { $0.id == address.columnID })
            else {
                NSSound.beep()
                return
            }

            // The editor must hold the whole value, or a commit would cut the rest away.
            if tab.isCut(at: address) {
                Task { [weak self] in
                    await self?.parent.onNeedFullRow(address.rowID)
                    self?.editSelection()
                }
                return
            }

            if isMultiline(at: address) {
                parent.onOpenValue()
                tab.paneEditRequests += 1
            } else {
                beginEdit(row: row, column: column, address: address)
            }
        }

        /// Opens the whole row view on the row of the selection.
        func openQuickLook() {
            guard let rowID = parent.selection?.focus.rowID,
                  parent.result.row(id: rowID) != nil
            else { return }
            parent.onQuickLook(rowID)
        }

        /// Sets every cell of the block to NULL, where the column takes one.
        ///
        /// A column that takes no NULL is left alone. Deleting the text of a cell is a different
        /// thing: that gives an empty string, which is a value.
        func setSelectionToNull() {
            guard let tab = parent.editing, tab.isEditable, let selection = parent.selection
            else { return }

            var changed = false
            for rowID in selection.rows {
                guard parent.result.row(id: rowID) != nil else { continue }
                for columnID in selection.columns {
                    guard parent.result.column(id: columnID) != nil else { continue }
                    let address = CellAddress(rowID: rowID, columnID: columnID)
                    guard tab.acceptsNull(at: address) else { continue }
                    tab.setEdit(nil, at: address)
                    changed = true
                }
            }

            if changed {
                redraw(selection)
            } else {
                NSSound.beep()
            }
        }

        /// The field lost the keyboard, so the edit ends here.
        ///
        /// Without this a click somewhere else left the field sitting over the cell, empty and
        /// doing nothing, until Escape took it away.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard editor != nil else { return }
            endEdit(commit: true, keepOpenOnBadValue: false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
            -> Bool
        {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                endEdit(commit: true)
                return true
            case #selector(NSResponder.insertTab(_:)):
                endEdit(commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                endEdit(commit: false)
                return true
            default:
                return false
            }
        }

        /// Puts the block on the clipboard in every table format.
        ///
        /// A cut value is fetched whole first. Copying the first three hundred characters of a
        /// document and calling it the value would be worse than slow.
        func copySelection(includeHeader: Bool) {
            Task { [weak self] in
                await self?.fetchCutRowsOfSelection()
                guard let self, let block = selectedBlock(includeHeader: includeHeader) else {
                    return
                }
                Clipboard.writeTable(block, hasHeader: includeHeader)
            }
        }

        private func fetchCutRowsOfSelection() async {
            guard let selection = parent.selection else { return }
            for rowID in selection.rows {
                guard let row = parent.result.row(id: rowID),
                      row.values.contains(where: \.isCut)
                else { continue }
                await parent.onNeedFullRow(rowID)
            }
        }

        /// Puts the block on the clipboard as text only, for a text editor.
        func copySelectionAsText(format: ClipboardFormat, includeHeader: Bool) {
            Task { [weak self] in
                await self?.fetchCutRowsOfSelection()
                guard let self, let block = selectedBlock(includeHeader: includeHeader) else {
                    return
                }
                Clipboard.write(ClipboardFormatter.text(block, format: format))
            }
        }

        private func selectedBlock(includeHeader: Bool) -> [[String]]? {
            guard let selection = parent.selection else { return nil }
            let block = parent.result.block(selection, includeHeader: includeHeader)
            return block.isEmpty ? nil : block
        }

        // MARK: Sorting

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isWritingSortDescriptors else { return }

            if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
                parent.sortOrder = [
                    ColumnComparator(
                        columnName: key,
                        order: descriptor.ascending ? .forward : .reverse)
                ]
            } else {
                parent.sortOrder = []
            }
            parent.onSortChange()
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

                add(menu, "Sort Ascending") { self.sort(by: name, ascending: true) }
                add(menu, "Sort Descending") { self.sort(by: name, ascending: false) }
                menu.addItem(.separator())

                add(menu, "Copy Column Name “\(name)”") { Clipboard.write(name) }
            }
            let allNames = parent.result.headerLine
            add(menu, "Copy All Column Names") { Clipboard.write(allNames) }
        }

        private func buildCellMenu(_ menu: NSMenu) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            let column = tableView.clickedColumn

            // A right click outside the block moves the block onto that cell.
            if let address = address(row: row, column: column),
               parent.selection?.contains(row: address.rowID, column: address.columnID) != true {
                parent.selection = CellSelection(single: address)
            }

            guard let selection = parent.selection else { return }
            let count = selection.cellCount
            let what = selection.isSingleCell ? "Value" : "\(count) Cells"

            add(menu, "Copy \(what)") { self.copySelection(includeHeader: false) }
            add(menu, "Copy with Header") { self.copySelection(includeHeader: true) }
            menu.addItem(.separator())
            add(menu, "Copy as CSV Text") {
                self.copySelectionAsText(format: .csv, includeHeader: true)
            }
            add(menu, "Copy as Tab Separated Text") {
                self.copySelectionAsText(format: .tsv, includeHeader: true)
            }
            menu.addItem(.separator())
            add(menu, "Select All") { self.selectAll() }
        }

        /// Sorts on one column, the way a click on its header does.
        private func sort(by column: String, ascending: Bool) {
            parent.sortOrder = [
                ColumnComparator(columnName: column, order: ascending ? .forward : .reverse)
            ]
            parent.onSortChange()
        }

        /// Picks every cell of the result.
        func selectAll() {
            guard let firstRow = parent.result.rows.first,
                  let lastRow = parent.result.rows.last,
                  let firstColumn = parent.result.columns.first,
                  let lastColumn = parent.result.columns.last
            else { return }
            parent.selection = CellSelection(
                anchor: CellAddress(rowID: firstRow.id, columnID: firstColumn.id),
                focus: CellAddress(rowID: lastRow.id, columnID: lastColumn.id))
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

/// What one row must draw.
struct RowContent {
    var values: [DisplayValue]
    var selected: ClosedRange<Int>?
    /// The cells that hold a change you have not sent.
    var edited: Set<Int>
}

/// One row of the grid. It draws every cell of the row itself.
///
/// A view per cell was the reason the grid stuttered. The table built thousands of `NSView`
/// objects, and each one drew its string through TextKit, which builds a whole text layout for
/// every call. One view per row plus Core Text removes both costs. A sideways scroll now redraws
/// views that already exist, so no white band appears.
final class GridRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("RowsetGridRow")

    weak var owner: ResultTableView.Coordinator?
    var rowIndex = -1

    /// The font of the grid.
    ///
    /// The system font reads better than a monospaced one for names and sentences. The digits
    /// keep one width, so a column of numbers still lines up.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    private static let italicFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 12) ?? font
    }()

    /// One dictionary per look. Building these per cell would allocate on every scroll step.
    private static let normalAttributes: [NSAttributedString.Key: Any] =
        [.font: font, .foregroundColor: NSColor.labelColor]
    private static let nullAttributes: [NSAttributedString.Key: Any] =
        [.font: italicFont, .foregroundColor: NSColor.secondaryLabelColor]
    private static let rawAttributes: [NSAttributedString.Key: Any] =
        [.font: font, .foregroundColor: NSColor.systemOrange]

    private static let leftInset: CGFloat = 6
    private static let rightInset: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawContent(in: dirtyRect)
    }

    private func drawContent(in dirtyRect: NSRect) {
        guard let owner,
              let tableView = owner.tableView,
              let content = owner.rowContent(rowIndex),
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        // Only the columns that touch the dirty area need any work.
        let columns = tableView.columnIndexes(in: dirtyRect)
        guard !columns.isEmpty else { return }

        context.saveGState()
        // Core Text draws upward from the baseline. This view is flipped, so turn the page over
        // once for the whole row instead of once per cell.
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let ascent = Self.font.ascender
        let descent = -Self.font.descender
        let baseline = ((bounds.height - (ascent + descent)) / 2 + descent).rounded()

        for column in columns {
            guard content.values.indices.contains(column) else { continue }
            let frame = tableView.rect(ofColumn: column)

            if content.edited.contains(column) {
                context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.30).cgColor)
                context.fill(CGRect(x: frame.minX, y: 0, width: frame.width, height: bounds.height))
            }

            if content.selected?.contains(column) == true {
                context.setFillColor(
                    NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor)
                context.fill(CGRect(x: frame.minX, y: 0, width: frame.width, height: bounds.height))
            }

            context.setFillColor(NSColor.gridColor.cgColor)
            context.fill(CGRect(x: frame.maxX - 1, y: 0, width: 1, height: bounds.height))

            let available = frame.width - Self.leftInset - Self.rightInset
            guard available > 4 else { continue }

            let value = content.values[column]
            let text = value.isNull ? "NULL" : value.preview
            guard !text.isEmpty else { continue }

            let attributes = value.isNull
                ? Self.nullAttributes
                : (value.isRaw ? Self.rawAttributes : Self.normalAttributes)

            guard let line = Self.line(for: text, attributes: attributes, width: available)
            else { continue }

            context.saveGState()
            context.clip(to: CGRect(
                x: frame.minX + Self.leftInset, y: 0, width: available, height: bounds.height))
            context.textPosition = CGPoint(x: frame.minX + Self.leftInset, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        context.restoreGState()
    }

    /// Builds one line of text and cuts it with an ellipsis when it does not fit.
    private static func line(
        for text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat
    ) -> CTLine? {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) else { return line }

        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? line
    }
}

enum Clipboard {
    /// The type that names comma separated text on the pasteboard.
    static let csvType = NSPasteboard.PasteboardType("public.comma-separated-values-text")

    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Writes a block of cells in every format a table reader knows.
    ///
    /// Plain text alone was not enough. Tab separated text is correct, but nothing on the
    /// pasteboard said it was a table, so Numbers put the whole block into one cell. The item now
    /// carries four types, and the receiving app takes the first one it understands:
    ///
    /// - `html`, a real table. Numbers, Excel, Word and Mail all read it, and a value may hold a
    ///   comma, a tab or a line break without any risk.
    /// - `tabularText`, the type macOS uses for tabular data.
    /// - comma separated text, for a reader that asks for CSV.
    /// - plain text, tab separated, as the last resort.
    static func writeTable(_ rows: [[String]], hasHeader: Bool) {
        guard !rows.isEmpty else { return }

        let item = NSPasteboardItem()
        item.setString(ClipboardFormatter.html(rows, hasHeader: hasHeader), forType: .html)
        item.setString(ClipboardFormatter.tsv(rows), forType: .tabularText)
        item.setString(ClipboardFormatter.csv(rows), forType: csvType)
        item.setString(ClipboardFormatter.tsv(rows), forType: .string)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}

/// A table that handles its own mouse and prepares many more rows than the window shows.
///
/// AppKit only builds the cells it is about to draw. On a fast scroll it then builds them while
/// you drag, and the grid stutters. `prepareContent` widens the band that AppKit fills, so the
/// rows are ready before they arrive. The cost is memory for the extra cell views.
final class OverdrawTableView: NSTableView {
    /// How far above and below the window AppKit prepares, in points.
    /// At a row height of 20 this is about 100 rows on each side. One row is one view now, so
    /// this band is cheap.
    static let verticalOverdraw: CGFloat = 2_000

    /// How far left and right AppKit renders ahead, in points.
    /// A row view already spans the whole table, so this only fills the layer in advance.
    static let horizontalOverdraw: CGFloat = 900

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(
            in: rect.insetBy(dx: -Self.horizontalOverdraw, dy: -Self.verticalOverdraw))
    }

    // MARK: - Mouse and keyboard

    var onCellMouseDown: ((_ row: Int, _ column: Int, _ extend: Bool, _ clicks: Int) -> Void)?
    var onCellDrag: ((_ row: Int, _ column: Int) -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Picks a cell, then follows the pointer until the button comes up.
    ///
    /// `NSTableView` selects whole rows, so the cell block is this app's own work. The tracking
    /// loop keeps the drag inside one mouse down, which is what lets a block grow.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0 else {
            super.mouseDown(with: event)
            return
        }

        onCellMouseDown?(row, column, event.modifierFlags.contains(.shift), event.clickCount)
        guard event.clickCount == 1 else { return }

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let dragPoint = convert(next.locationInWindow, from: nil)
            let dragRow = self.row(at: dragPoint)
            let dragColumn = self.column(at: dragPoint)
            guard dragRow >= 0, dragColumn >= 0 else { continue }
            onCellDrag?(dragRow, dragColumn)
        }
    }

    /// Command-C reaches here through the responder chain.
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    /// The delete key sets the cells you picked to NULL, where the column allows one.
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]  // delete, forward delete
        if deleteKeys.contains(event.keyCode), onDelete != nil {
            onDelete?()
            return
        }
        // The space bar opens the whole row, the way the Finder opens a file.
        if event.keyCode == 49, onSpace != nil {
            onSpace?()
            return
        }

        if event.keyCode == 36 {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command, onCommandReturn != nil {
                onCommandReturn?()
                return
            }
            if modifiers.isEmpty, onReturn != nil {
                onReturn?()
                return
            }
        }

        super.keyDown(with: event)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}
