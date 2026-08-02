import AppKit

/// How tall a file row is drawn, and how big the icon in it (PLAN.md §M15 Slice 1).
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the core picks the
/// state, the app picks the pixels. App-wide like `showHidden` rather than per tab: it is a
/// reading preference, not a question you ask of one directory.
///
/// Three named steps rather than a free number, because the usable range is narrow and was
/// measured rather than guessed: a row's floor is its *text*, and the name label's intrinsic
/// height at the system font is exactly **16.00 pt** — bold included, which matters because a
/// marked row draws bold and has to fit the same box. So a slider would spend most of its travel
/// on values that either clip the glyphs or leave the icon swimming. `.regular` is the 22 pt row
/// and 16 pt icon the app hardcoded before this existed, verbatim, so an untouched install renders
/// byte-identically.
enum RowDensity: String, CaseIterable, Identifiable {
    case compact
    case regular
    case roomy

    var id: String { rawValue }

    /// `NSTableView.rowHeight`: the 16 pt of text plus the breathing room above and below it —
    /// 1 pt each side at `.compact`, 3 at `.regular`, 6 at `.roomy`.
    var rowHeight: CGFloat {
        switch self {
        case .compact: 18
        case .regular: 22
        case .roomy: 28
        }
    }

    /// The name column's icon box, square. It scales with the row rather than staying put, or a
    /// roomy pane would read as a regular one with gaps punched into it.
    var iconSize: CGFloat {
        switch self {
        case .compact: 14
        case .regular: 16
        case .roomy: 20
        }
    }

    /// What the Settings picker shows. Keyed by its English text like every other app literal
    /// (NOTES.md ▸ Localization), so a missing translation falls back to readable English.
    var title: String {
        switch self {
        case .compact:
            String(localized: "Compact", comment: "Row density: the tightest file rows")
        case .regular:
            String(localized: "Regular", comment: "Row density: the default file rows")
        case .roomy:
            String(localized: "Roomy", comment: "Row density: the tallest file rows")
        }
    }
}
