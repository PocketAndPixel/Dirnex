import Foundation

/// How Quick View draws a file that can honestly be shown two ways (PLAN.md §M16): as the bytes
/// somebody wrote, or as the document those bytes describe.
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the twin of `RowDensity`
/// and `SizeVizDisplayMode`, and the same division `TextPreview`'s own doc comment draws: the core
/// decodes bytes, the app decides which surface they land on.
///
/// Which files offer both is `QuickViewPreviewView.dualStyleKind(of:)` — HTML since §M16, Markdown
/// since §M18, CSV and TSV since 2026-09-15 — and the single predicate is the point: the same
/// question used to be spelled three times. Everything else has one honest rendering and ignores
/// this entirely — a photograph has no source, and a `.txt` has no document.
enum QuickViewRenderStyle: String, CaseIterable, Identifiable {
    /// The file's own text, in the same monospaced, selectable view every other text file gets.
    case source
    /// The document the file describes, rendered in-process — a page, or a table.
    case rendered

    var id: String { rawValue }

    /// The default for a page, and the milestone's headline decision: a file manager shows you the
    /// file. A rendered page hides exactly what a user opening `index.html` in a *file manager* most
    /// often wants to see, and `2` is one key away. A table is the exception, and says why in
    /// `QuickViewDualStyleKind`.
    static let `default` = QuickViewRenderStyle.source

    /// The digit that selects this style — Lister's convention, where the view modes are numbered
    /// from 1 in the order they are listed.
    var digit: String {
        switch self {
        case .source: "1"
        case .rendered: "2"
        }
    }

    /// The style `digit` selects, or `nil` for any other key. Keyed by the *character* rather than
    /// a key code, so a non-US layout and the numeric keypad both work (docs/NOTES.md: letters and
    /// digits arrive with `keyCode == 0` under synthetic input, and layouts move the codes around).
    static func style(forDigit digit: String) -> QuickViewRenderStyle? {
        allCases.first { $0.digit == digit }
    }

    /// What the menu item and the palette show. Keyed by its English text like every other app
    /// literal (NOTES.md ▸ Localization), so a missing translation falls back to readable English.
    var title: String {
        switch self {
        case .source:
            String(
                localized: "View Source",
                comment: "Quick View render style: the file's own text rather than the page it describes"
            )
        case .rendered:
            String(
                localized: "View Rendered Page",
                comment: "Quick View render style: the document the file describes, drawn as a page"
            )
        }
    }

    /// The short form the full-size header draws — a hint that the other style exists at all, in a
    /// strip that already carries the file's name and position. "1 Source · 2 Page" whole would
    /// crowd it, so each style names only itself and the digit says which key. What the rendered
    /// style is called depends on what it renders.
    func headerLabel(for kind: QuickViewDualStyleKind) -> String {
        switch (self, kind) {
        case (.source, _):
            String(
                localized: "Source",
                comment: "Quick View header, short name for the source style"
            )
        case (.rendered, .page):
            String(
                localized: "Page",
                comment: "Quick View header, short name for the rendered style"
            )
        case (.rendered, .table):
            String(
                localized: "Table",
                comment: "Quick View header, short name for a CSV or TSV file drawn as a table of rows and columns"
            )
        }
    }
}

/// The two families of file that offer both styles, and what separates them: what the rendered
/// style is called, and which remembered choice a file follows (2026-09-15).
///
/// They remember separately because their defaults are opposite, and each is right for its family.
/// A page defaults to its source — a file manager shows you the file, and a rendered page hides what
/// someone opening `index.html` here usually wants to see. A table defaults to the table, because the
/// source of a CSV is exactly what nobody can read: every record one long line, wrapped into the pane
/// with nothing lined up. One shared choice would make pressing `1` on a CSV turn every web page into
/// source and pressing `2` on a page turn every CSV into a table, which is not what either key said.
enum QuickViewDualStyleKind: Equatable {
    /// HTML and Markdown: the markup, or the page it describes.
    case page
    /// CSV and TSV: the delimited text, or a table of its rows and columns.
    case table

    /// The style a file of this family opens in until the user picks the other.
    var defaultStyle: QuickViewRenderStyle {
        switch self {
        case .page: .default
        case .table: .rendered
        }
    }
}
