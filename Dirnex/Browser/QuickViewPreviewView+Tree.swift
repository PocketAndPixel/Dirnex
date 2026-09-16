import AppKit
import DirnexCore

/// Quick View's tree backend: a JSON, XML or property-list file drawn as a tree of its values — or,
/// when it is a list of like records, in the table a CSV gets (JSON 2026-09-15, XML 2026-09-16).
///
/// JSON's shape was the user's pick of three: a tree for every file, with a JSON Lines file or a
/// top-level array of objects in the table instead, sorting, filter and all. XML's was the same pick
/// again, with the records being the root element's children, and a property list read as keys and
/// values rather than as its elements. Each family is the rendered style of its own dual-style kind
/// (`QuickViewDualStyleKind.json`, `.xml`), opens as the tree, and remembers its choice apart, so `1`
/// here shows the source without turning every CSV into text.
///
/// The parse is `DirnexCore`'s (`JSONDocument`, `XMLTree`, `PropertyListTree`). Measured before any of
/// this was wired, in a release build: the 1 487 JSON files in this Mac's home folder in 46 ms, the
/// slowest 6 ms; and the 4 707 XML-family files under `~/Dev`, `~/Documents`, `~/Downloads`,
/// `~/Library/Preferences`, `/etc` and `/opt/homebrew/etc` in 2.4 s with every label, path and a
/// filter worked out as well, the slowest 12 ms. Every whole file read to the same values as Python's
/// `json`, `expat` and `plistlib` read.
extension QuickViewPreviewView {
    /// Show `url` as a tree or a table, standing the other backends down.
    ///
    /// Off the main actor and behind the one `loadToken`, like the table's read. Which surface a file
    /// takes is known only once it is read, so whichever of the two is up stays up until the file lands,
    /// and the other is put away then. A file that is not JSON or XML after all falls back to its text.
    func showTree(_ url: URL) {
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        standDownWeb()
        loadToken += 1
        let token = loadToken
        flipGate.isLoading = true
        let format: TreeFormat = Self.isJSON(url) ? .json : .xml
        Task { [weak self] in
            let scan = await BlockingWork.run {
                TreeScan.read(url, format: format)
            }
            guard let self, token == loadToken else { return }
            switch scan {
            case let .tree(document):
                standDownTable()
                let surface = ensureTreeSurface()
                surface.isHidden = false
                surface.show(document)
                treeShowsRecords = false
            case let .records(table, isTruncated):
                standDownTree()
                let surface = ensureTableSurface()
                surface.isHidden = false
                surface.show(table, isTruncated: isTruncated)
                treeShowsRecords = true
            case nil:
                standDownTable()
                standDownTree()
                treeShowsRecords = false
                showText(url)
            }
            refreshCaption()
            contentDidLoad()
        }
    }

    /// What the detached read produces, crossing back as one `Sendable` value.
    enum TreeScan: Sendable {
        case tree(any TreeDocument)
        case records(DelimitedTable, isTruncated: Bool)

        /// Blocking; call it off the main thread. `nil` for a file that should be shown as text.
        ///
        /// A binary property list, which `TextPreview` refuses on its NULs, is read as the XML it
        /// converts to — the text the source view shows for it.
        static func read(_ url: URL, format: TreeFormat) -> TreeScan? {
            let document: (any TreeDocument)?
            let isTruncated: Bool
            switch format {
            case .json:
                guard let preview = TextPreview.read(contentsOf: url) else { return nil }
                document = JSONDocument.parse(preview.text, isTruncated: preview.isTruncated)
                isTruncated = preview.isTruncated
            case .xml:
                guard let preview = TextPreview.read(contentsOf: url)
                    ?? TextPreview.readBinaryPropertyList(contentsOf: url)
                else { return nil }
                document = XMLTree.document(from: preview.text, isTruncated: preview.isTruncated)
                isTruncated = preview.isTruncated
            }
            guard let document else { return nil }
            if let table = document.recordTable(columnLimit: QuickViewPreviewView.tableColumnLimit) {
                return .records(table, isTruncated: isTruncated)
            }
            return .tree(document)
        }
    }

    /// The table or tree on screen that View ▸ Filter would filter, or `nil` when the surface is showing
    /// anything else — the one predicate the command and its menu item both ask.
    var filterableSurface: (any QuickViewFilterHost)? {
        if let filterableTable { return filterableTable }
        guard placeholderCard?.isHidden != false,
              let treeSurface, !treeSurface.isHidden, treeSurface.document != nil
        else { return nil }
        return treeSurface
    }

    func standDownTree() {
        treeSurface?.isHidden = true
        treeSurface?.clearDocument()
    }

    /// The caption as the header draws it: a JSON or XML file that turned out to be a list of records is
    /// on screen as a table, and the header says "Table" rather than "Tree".
    func captionForHeader(_ caption: QuickViewCaption?) -> QuickViewCaption? {
        guard var caption, caption.styleKind == .json || caption.styleKind == .xml, treeShowsRecords else {
            return caption
        }
        caption.styleKind = .table
        return caption
    }

    private func ensureTreeSurface() -> QuickViewTreeView {
        if let treeSurface { return treeSurface }
        let surface = QuickViewTreeView(layoutDefaults: tableLayoutDefaults)
        pin(surface, inside: content)
        treeSurface = surface
        return surface
    }
}

/// Which reader a file drawn as a tree goes to.
enum TreeFormat: Sendable {
    case json
    /// XML, and a property list, which is XML too.
    case xml
}
