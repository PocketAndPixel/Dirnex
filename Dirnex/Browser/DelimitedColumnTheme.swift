import AppKit

/// The colors a CSV or TSV file's columns are drawn in when Quick View shows its source
/// (2026-09-15).
///
/// Coloring by column is what tells one field from the next when a record is a single long line
/// wrapped across the pane — the rest of the source view has nothing lined up to help. The colors are
/// `SyntaxTheme`'s rather than new ones: VS Code's, each already a light/dark pair measured at 4.5:1
/// or better on the text background in both appearances (`SyntaxThemeTests`). Five hues that read as
/// different from one another, repeating from the sixth column, with the first column in the text
/// color so the start of every record reads as ordinary text.
enum DelimitedColumnTheme {
    static let palette: [NSColor?] = [
        nil,
        SyntaxTheme.keyword,
        SyntaxTheme.string,
        SyntaxTheme.typeOrTag,
        SyntaxTheme.comment
    ]

    /// The color for column `column`, or `nil` for the text color.
    static func color(forColumn column: Int) -> NSColor? {
        palette[((column % palette.count) + palette.count) % palette.count]
    }
}
