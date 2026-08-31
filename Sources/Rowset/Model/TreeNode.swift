import Foundation
import Observation

/// One table or view of a database.
struct TableRef: Identifiable, Hashable, Sendable {
    var schema: String
    var name: String
    var isView: Bool

    var id: String { "\(schema).\(name)" }
    var symbolName: String { isView ? "eye" : "tablecells" }
}

/// What a tree row stands for.
enum TreeNodeKind: Hashable, Sendable {
    case schema(name: String)
    case table(schema: String, name: String)
    case view(schema: String, name: String)
    case column(
        schema: String, table: String, name: String, type: String, nullable: Bool,
        position: Int)

    var isTableLike: Bool {
        switch self {
        case .table, .view: true
        default: false
        }
    }

    var canHaveChildren: Bool {
        switch self {
        case .schema, .table, .view: true
        case .column: false
        }
    }

    var symbolName: String {
        switch self {
        case .schema: "folder"
        case .table: "tablecells"
        case .view: "eye"
        case .column: "square.grid.3x1.below.line.grid.1x2"
        }
    }

    var title: String {
        switch self {
        case .schema(let name): name
        case .table(_, let name): name
        case .view(_, let name): name
        case .column(_, _, let name, _, _, _): name
        }
    }

    /// The grey text after the title.
    var detail: String? {
        switch self {
        case .column(_, _, _, let type, let nullable, _): nullable ? type : "\(type), not null"
        case .view: "view"
        default: nil
        }
    }
}

/// One row of the sidebar tree. Children load the first time the row expands.
@MainActor
@Observable
final class TreeNode: Identifiable {
    let id = UUID()
    let kind: TreeNodeKind
    var children: [TreeNode]?
    var isExpanded = false
    var isLoading = false
    var loadError: String?
    /// True when the columns under this table stand in the order of their names.
    ///
    /// The database gives them in the order they were declared, which is right for reading a
    /// table and wrong for finding one column among sixty.
    var sortsColumnsByName = false

    /// Where this column stands in the table. The catalog order is kept, so a sort by name can
    /// always be undone.
    var columnPosition: Int {
        if case .column(_, _, _, _, _, let position) = kind { return position }
        return 0
    }

    init(kind: TreeNodeKind) {
        self.kind = kind
    }

    var isLoaded: Bool { children != nil }
}
