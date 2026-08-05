import Foundation

/// How Quick View draws a file that can honestly be shown two ways (PLAN.md §M16): as the bytes
/// somebody wrote, or as the document those bytes describe.
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the twin of `RowDensity`
/// and `SizeVizDisplayMode`, and the same division `TextPreview`'s own doc comment draws: the core
/// decodes bytes, the app decides which surface they land on.
///
/// Only HTML offers both today (`QuickViewPreviewView.isRenderableHTML`). Everything else has one
/// honest rendering and ignores this entirely — a photograph has no source, and a `.txt` has no
/// document.
enum QuickViewRenderStyle: String, CaseIterable, Identifiable {
    /// The file's own text, in the same monospaced, selectable view every other text file gets.
    case source
    /// The document the file describes, rendered in-process.
    case rendered

    var id: String { rawValue }

    /// The default, and the milestone's headline decision: a file manager shows you the file.
    /// A rendered page hides exactly what a user opening `index.html` in a *file manager* most
    /// often wants to see, and `2` is one key away.
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
    /// crowd it, so each style names only itself and the digit says which key.
    var headerLabel: String {
        switch self {
        case .source:
            String(
                localized: "Source",
                comment: "Quick View header, short name for the source style"
            )
        case .rendered:
            String(
                localized: "Page",
                comment: "Quick View header, short name for the rendered style"
            )
        }
    }
}
