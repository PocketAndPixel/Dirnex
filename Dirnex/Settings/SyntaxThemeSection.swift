import DirnexCore
import SwiftUI

/// Panels ▸ the syntax theme (PLAN.md §M39 ▸ Slice 10): VS Code's, Xcode's or GitHub's colors for
/// code, wherever Dirnex draws it.
///
/// **With a sample**, because a theme is a choice of colors and a list of three editors' names says
/// none of them. The sample is scanned by the same Swift grammar the source view uses and colored by
/// the same table, so it is what a Swift file will look like rather than a drawing of it, and it
/// sits on the text background every theme is measured against.
struct SyntaxThemeSection: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Section {
            Picker("Syntax colors", selection: $preferences.syntaxTheme) {
                ForEach(SyntaxColorTheme.allCases) { theme in
                    Text(verbatim: theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            SyntaxThemeSample(theme: preferences.syntaxTheme)
        } footer: {
            Text(
                """
                How code is colored in Quick View, in a file’s source and in a rendered page’s code \
                blocks, and in the compare and merge windows. Each theme has a light and a dark \
                version, and follows your Mac’s appearance.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Three lines of Swift in `theme`'s colors.
struct SyntaxThemeSample: View {
    let theme: SyntaxColorTheme

    var body: some View {
        Text(Self.attributed(Self.source, in: theme))
            .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .accessibilityHidden(true)
    }

    /// The sample's text: a comment in the user's language, a declaration with a type and a string,
    /// and a line with a number and three keywords — every kind a source file shows.
    static var source: String {
        let comment = String(
            localized: "Code is drawn in these colors",
            comment: "Settings ▸ Panels: the comment line of the syntax theme's code sample"
        )
        return """
        // \(comment)
        let name: String = "Dirnex"
        if count > 42 { return nil }
        """
    }

    /// `text` with the scanner's tokens in `theme`'s colors, the rest in the text color.
    static func attributed(_ text: String, in theme: SyntaxColorTheme) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = Color(nsColor: .textColor)
        for token in SyntaxHighlighter.tokens(in: text, language: .swift) {
            guard let color = SyntaxTheme.color(for: token.kind, in: theme),
                  let range = Range(
                      NSRange(location: token.offset, length: token.length),
                      in: result
                  )
            else { continue }
            result[range].foregroundColor = Color(nsColor: color)
        }
        return result
    }
}
