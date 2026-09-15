import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's table backend: a CSV or TSV file drawn as rows and columns, with the selected row's
/// full values in a strip underneath (2026-09-15).
///
/// Asked for with a screenshot of a CSV in the text backend. Each record there was one line of about
/// 350 characters, three quoted cells full of commas, wrapped into a pane with nothing lined up. It
/// is the rendered style of the second dual-style family (`QuickViewDualStyleKind.table`), and unlike
/// a page it is where such a file opens: `1` still shows the source, with its columns colored.
///
/// The parse is `DirnexCore`'s (`DelimitedTable`) and keeps only where each cell is, so a preview
/// costs one pass over the bytes — measured at 1 ms for the 3 MB, 18 800-row CSVs on this Mac and
/// 6 ms for a 4 MB file of a million short cells, release build. The `NSTableView` then builds only
/// the rows on screen, which is why this is not an HTML table: WebKit lays out every cell of one.
extension QuickViewPreviewView {
    /// Show `url` as a table, standing the other backends down.
    ///
    /// Off the main actor and behind the one `loadToken`, like every other read here. The previous
    /// table stays on screen until the new one lands, so stepping between two CSVs does not blank
    /// the surface, and the page turn waits for it (`flipGate`). A file that is not a table after all
    /// — an unclosed quote swallowing the rest, more columns than a table should build — falls back
    /// to its text, which falls back in turn to Quick Look for a file that is not text either.
    func showTable(_ url: URL) {
        let surface = ensureTableSurface()
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        standDownWeb()
        surface.isHidden = false
        loadToken += 1
        let token = loadToken
        flipGate.isLoading = true
        let hint = Self.delimiterHint(for: url)
        Task { [weak self] in
            let scan = await BlockingWork.run {
                TableScan.read(url, delimiterHint: hint)
            }
            guard let self, token == loadToken else { return }
            guard let scan else {
                standDownTable()
                showText(url)
                contentDidLoad()
                return
            }
            surface.show(scan.table, isTruncated: scan.isTruncated)
            contentDidLoad()
        }
    }

    /// A parsed table and whether the file ran past the read limit — everything the detached read
    /// produces, crossing back as one `Sendable` value.
    struct TableScan: Sendable {
        let table: DelimitedTable
        let isTruncated: Bool

        /// Blocking; call it off the main thread. `nil` for a file that should be shown as text.
        static func read(_ url: URL, delimiterHint: DelimitedTable.Delimiter?) -> TableScan? {
            guard let preview = TextPreview.read(contentsOf: url),
                  let table = DelimitedTable.parse(
                      preview.text,
                      isTruncated: preview.isTruncated,
                      delimiterHint: delimiterHint
                  ),
                  table.columnCount <= QuickViewPreviewView.tableColumnLimit
            else { return nil }
            return TableScan(table: table, isTruncated: preview.isTruncated)
        }
    }

    /// The most columns a table is built with. Past this the file is shown as text: a column is an
    /// `NSTableColumn` built up front, and a file this wide is a matrix nobody reads by scrolling
    /// sideways through a preview.
    nonisolated static let tableColumnLimit = 1024

    /// The table on screen that View ▸ Filter Table would filter, or `nil` when the surface is showing
    /// anything else — the one predicate the command and its menu item both ask.
    var filterableTable: QuickViewTableView? {
        guard placeholderCard?.isHidden != false,
              let tableSurface, !tableSurface.isHidden, tableSurface.table != nil
        else { return nil }
        return tableSurface
    }

    func standDownTable() {
        tableSurface?.isHidden = true
        tableSurface?.clearTable()
    }

    /// Whether `url` is a delimited-text file this backend draws — by extension first, since a
    /// `.tsv` on a Mac that has never registered one resolves to nothing, then by the two registered
    /// types. `nonisolated` because the source view's read asks it off the main actor.
    nonisolated static func isDelimitedTable(_ url: URL) -> Bool {
        if tableExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText)
    }

    /// The delimiter a file's name promises: tab for a `.tsv` or `.tab`, and nothing for a `.csv`,
    /// whose name is also worn by the semicolon files Excel writes in most of Europe.
    nonisolated static func delimiterHint(for url: URL) -> DelimitedTable.Delimiter? {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "tsv" || pathExtension == "tab" { return .tab }
        guard pathExtension != "csv",
              let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        else { return nil }
        return type.conforms(to: .tabSeparatedText) ? .tab : nil
    }

    private nonisolated static let tableExtensions: Set<String> = ["csv", "tsv", "tab"]

    private func ensureTableSurface() -> QuickViewTableView {
        if let tableSurface { return tableSurface }
        let surface = QuickViewTableView(layoutDefaults: tableLayoutDefaults)
        pin(surface, inside: content)
        tableSurface = surface
        return surface
    }
}
