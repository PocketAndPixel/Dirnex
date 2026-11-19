import AppKit
import DirnexCore

/// The Comment column on an SMB server's list of shares (PLAN.md §M40 Slice 8): the server's own
/// description of each share (`NetCommentStr`, ``FileEntry/comment``), which M35 parsed and nothing
/// showed.
///
/// **On a flat list it takes the place of Size and Date.** A share row has neither, since a share is
/// measured only once it is mounted, so both columns drew a dash on every row. They are hidden rather
/// than removed, which keeps their widths and order in the tab's stored layout exactly as the user
/// left them, and the Comment column is given the room they took, so Name does not move.
///
/// **In a tree it sits beside them**, paid for out of Name as the size bar is: the rows beneath an
/// expanded share are files on its mount, and their sizes and dates are the point of the tree.
extension PanelViewController {
    /// Whether the pane lists an SMB server's shares, the one listing whose rows carry a comment.
    var showsShareComments: Bool {
        panel.path.backend.isSMBServer
    }

    /// Whether every row is a share, so Size and Date would be dashes throughout: a flat list of
    /// shares rather than a tree, whose deeper rows are files.
    var commentReplacesSizeAndDate: Bool {
        showsShareComments && !panel.isTree
    }

    private static var commentIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(Column.comment.rawValue)
    }

    /// The columns a flat list of shares hides for the Comment column.
    private static let replacedColumns: [Column] = [.size, .date]

    var isCommentColumnInstalled: Bool {
        tableView.column(withIdentifier: Self.commentIdentifier) >= 0
    }

    /// What the Comment column takes out of Name, for the layout capture to give back
    /// (`contextualColumnFootprint`): its own width and spacing, less the room of the columns it
    /// hides. Zero on a flat list, where it takes exactly the room Size and Date leave; read from the
    /// live widths, so a column the user has dragged since is still counted right.
    var commentColumnFootprint: CGFloat {
        let index = tableView.column(withIdentifier: Self.commentIdentifier)
        guard index >= 0 else { return 0 }
        let spacing = tableView.intercellSpacing.width
        let hidden = tableView.tableColumns.filter(\.isHidden).reduce(0) { $0 + $1.width + spacing }
        return tableView.tableColumns[index].width + spacing - hidden
    }

    /// Put the Comment column, and Size and Date, in the shape this listing wants. Run on every
    /// reload and after a tab's layout is applied; a no-op when the shape is already right.
    func updateCommentColumn() {
        let wantsColumn = showsShareComments
        let hidesReplaced = commentReplacesSizeAndDate
        let hidesNow = Self.replacedColumns.contains { tableColumn(for: $0)?.isHidden == true }
        guard wantsColumn != isCommentColumnInstalled || hidesReplaced != hidesNow else { return }
        removeCommentColumn()
        guard wantsColumn else { return }
        withColumnLayoutGuard { installCommentColumn(replacing: hidesReplaced) }
    }

    /// Take the Comment column out and show Size and Date again, giving Name back what the column
    /// took. `applyColumnLayout` runs it first, so the stored order is laid out over the user's own
    /// columns alone, as it is for the size bar.
    func removeCommentColumn() {
        withColumnLayoutGuard {
            let index = tableView.column(withIdentifier: Self.commentIdentifier)
            if index >= 0 { tableView.removeTableColumn(tableView.tableColumns[index]) }
            for column in Self.replacedColumns {
                tableColumn(for: column)?.isHidden = false
            }
        }
    }

    private func installCommentColumn(replacing: Bool) {
        let spacing = tableView.intercellSpacing.width
        let column = NSTableColumn(identifier: Self.commentIdentifier)
        column.title = Column.comment.title
        column.minWidth = Column.comment.minWidth
        if replacing {
            let replaced = Self.replacedColumns.compactMap { tableColumn(for: $0) }
            for tableColumn in replaced {
                tableColumn.isHidden = true
            }
            // The room the two took, less the one spacing the new column brings with it.
            let room = replaced.reduce(0) { $0 + $1.width + spacing } - spacing
            column.width = max(Column.comment.minWidth, room)
        } else {
            column.width = Column.comment.defaultWidth
        }
        tableView.addTableColumn(column)
        // Straight after Name: in a tree that keeps Size and Date where they stood, since Name pays
        // for the column, and on a flat list there is nothing else beside it.
        let nameIndex = tableView.column(
            withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue)
        )
        if nameIndex >= 0 {
            tableView.moveColumn(tableView.tableColumns.count - 1, toColumn: nameIndex + 1)
        }
    }

    private func tableColumn(for column: Column) -> NSTableColumn? {
        let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        return index >= 0 ? tableView.tableColumns[index] : nil
    }

    /// Run `body` without its resize and move notifications reading as the user's own drags, which
    /// would rewrite the tab's stored columns (`setSizeBarColumnInstalled` gives the reason), then fit
    /// Name to the pane, which pays for or is refunded the difference.
    private func withColumnLayoutGuard(_ body: () -> Void) {
        let wasApplyingLayout = isApplyingColumnLayout
        isApplyingColumnLayout = true
        defer {
            isApplyingColumnLayout = wasApplyingLayout
            fitNameColumnToPane()
        }
        body()
    }
}
