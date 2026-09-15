import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's JSON backend: a JSON file drawn as a tree of its keys and values — or, when it is a
/// list of like objects, in the table a CSV gets (2026-09-15).
///
/// Asked for as "a table (tree) preview for all types of JSON files, like we have for CSV files". The
/// shape was the user's pick of three: a tree for every file, with a JSON Lines file or a top-level
/// array of objects in the table instead, sorting, filter and all. It is the rendered style of the
/// third dual-style family (`QuickViewDualStyleKind.json`), opens as the tree, and remembers its choice
/// apart from the other two, so `1` here shows the source without turning every CSV into text.
///
/// The parse is `DirnexCore`'s (`JSONDocument`). Measured before any of this was wired, in a release
/// build over the 1 487 JSON files in this Mac's home folder: 46 ms for all of them, the slowest 6 ms
/// (the 4 MB read limit's cut of a 13 MB file, which becomes a table of 20 164 rows), and every whole
/// file read to the same values, top level and table as Python's `json` reads.
extension QuickViewPreviewView {
    /// Show `url` as a tree or a table, standing the other backends down.
    ///
    /// Off the main actor and behind the one `loadToken`, like the table's read. Which surface a JSON
    /// file takes is known only once it is read, so whichever of the two is up stays up until the file
    /// lands, and the other is put away then. A file that is not JSON after all falls back to its
    /// text.
    func showJSON(_ url: URL) {
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        standDownWeb()
        loadToken += 1
        let token = loadToken
        flipGate.isLoading = true
        Task { [weak self] in
            let scan = await BlockingWork.run {
                JSONScan.read(url)
            }
            guard let self, token == loadToken else { return }
            switch scan {
            case let .tree(document):
                standDownTable()
                let surface = ensureJSONTreeSurface()
                surface.isHidden = false
                surface.show(document)
                jsonShowsRecords = false
            case let .records(table, isTruncated):
                standDownJSONTree()
                let surface = ensureTableSurface()
                surface.isHidden = false
                surface.show(table, isTruncated: isTruncated)
                jsonShowsRecords = true
            case nil:
                standDownTable()
                standDownJSONTree()
                jsonShowsRecords = false
                showText(url)
            }
            refreshCaption()
            contentDidLoad()
        }
    }

    /// What the detached read produces, crossing back as one `Sendable` value.
    enum JSONScan: Sendable {
        case tree(JSONDocument)
        case records(DelimitedTable, isTruncated: Bool)

        /// Blocking; call it off the main thread. `nil` for a file that should be shown as text.
        static func read(_ url: URL) -> JSONScan? {
            guard let preview = TextPreview.read(contentsOf: url),
                  let document = JSONDocument.parse(
                      preview.text,
                      isTruncated: preview.isTruncated
                  )
            else { return nil }
            if let table = document.recordTable(columnLimit: QuickViewPreviewView.tableColumnLimit) {
                return .records(table, isTruncated: preview.isTruncated)
            }
            return .tree(document)
        }
    }

    /// The table or JSON tree on screen that View ▸ Filter would filter, or `nil` when the surface is
    /// showing anything else — the one predicate the command and its menu item both ask.
    var filterableSurface: (any QuickViewFilterHost)? {
        if let filterableTable { return filterableTable }
        guard placeholderCard?.isHidden != false,
              let jsonTreeSurface, !jsonTreeSurface.isHidden, jsonTreeSurface.document != nil
        else { return nil }
        return jsonTreeSurface
    }

    func standDownJSONTree() {
        jsonTreeSurface?.isHidden = true
        jsonTreeSurface?.clearDocument()
    }

    /// The caption as the header draws it: a JSON file that turned out to be a list of records is on
    /// screen as a table, and the header says "Table" rather than "Tree".
    func captionForHeader(_ caption: QuickViewCaption?) -> QuickViewCaption? {
        guard var caption, caption.styleKind == .json, jsonShowsRecords else { return caption }
        caption.styleKind = .table
        return caption
    }

    /// Whether `url` is a JSON file this backend draws: by name first, then by conformance to
    /// `public.json`, which `.geojson` and `.xcstrings` declare.
    ///
    /// By name first because most of the family resolves to no registered type on a Mac — probed:
    /// `.jsonl`, `.jsonc`, `.json5`, `.ipynb`, `.har` and `.webmanifest` are dynamic types that conform
    /// to nothing, not even `public.text`, so until this backend they went to Quick Look rather than to
    /// the text preview. `nonisolated` for the reason the table's twin is.
    nonisolated static func isJSON(_ url: URL) -> Bool {
        if jsonFileNames.contains(url.lastPathComponent) { return true }
        if jsonExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .json)
    }

    private nonisolated static let jsonExtensions: Set<String> = [
        "json", "jsonl", "ndjson", "jsonc", "json5", "geojson", "topojson", "webmanifest", "har",
        "ipynb", "xcstrings", "avsc"
    ]

    /// JSON under a name with no JSON extension: Swift Package Manager's lock file, 17 of them on this
    /// Mac.
    private nonisolated static let jsonFileNames: Set<String> = ["Package.resolved"]

    private func ensureJSONTreeSurface() -> QuickViewJSONTreeView {
        if let jsonTreeSurface { return jsonTreeSurface }
        let surface = QuickViewJSONTreeView(layoutDefaults: tableLayoutDefaults)
        pin(surface, inside: content)
        jsonTreeSurface = surface
        return surface
    }
}
