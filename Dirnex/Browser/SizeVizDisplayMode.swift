import Foundation

/// What the size-visualization column draws for each row: the ncdu-style bar, the folder-share
/// percentage, or both (PLAN.md §M6, §M15 Slice 2). The core measures the bytes and hands over a
/// `SizeBar`; this picks which halves of it reach the pixels — pure presentation, so it lives in
/// the app rather than in `DirnexCore`, the twin of `RowDensity`.
///
/// App-wide (`AppPreferences.sizeVizDisplayMode`) rather than per tab: it is a reading preference,
/// not a question you ask of one directory, so the Settings picker is the one place that writes it
/// and every pane merely follows.
///
/// Default `.bar`. The two-part form is genuinely more legible — the whole tail of a real `~`
/// floors to a stub the number beside it disambiguates (see `SizeBarView`) — but it is also the
/// busiest, so the default is the quiet chart and the number is one setting away for anyone who
/// wants it back.
enum SizeVizDisplayMode: String, CaseIterable, Identifiable {
    case bar
    case percentage
    case both

    var id: String { rawValue }

    /// Whether the ncdu-style bar (its track and fill) is drawn.
    var showsBar: Bool { self != .percentage }

    /// Whether the folder-share percentage is drawn — beside the bar in `.both`, alone in
    /// `.percentage`.
    var showsPercentage: Bool { self != .bar }

    /// What the Settings picker shows. Keyed by its English text like every other app literal
    /// (NOTES.md ▸ Localization), so a missing translation falls back to readable English.
    var title: String {
        switch self {
        case .bar:
            String(
                localized: "Progress bar",
                comment: "Size-viz display mode: the bar alone, no number"
            )
        case .percentage:
            String(
                localized: "Percentage",
                comment: "Size-viz display mode: the folder-share number alone"
            )
        case .both:
            String(localized: "Both", comment: "Size-viz display mode: bar and percentage together")
        }
    }
}
