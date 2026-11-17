import AppKit
import DirnexCore

/// The rules an exported Markdown page adds to the preview's (PLAN.md §M39 ▸ Slice 12): a reading
/// width in a browser window, and a page that prints. The PDF is that page printed, so the second
/// half is what draws it, and a browser printing the HTML file reads the same rules.
///
/// ## What paper changes, measured
///
/// Probed 2026-11-14 by printing a page to PDF through `WKWebView.printOperation` headlessly:
///
/// - **A CSS mask is not applied on paper.** An alert's icon, the title's color through an SF Symbol
///   mask on screen, printed as a square of that color with the black symbol drawn over it, with the
///   mask as a shorthand, as longhands, and with `print-color-adjust: exact` alike. A symbol already
///   drawn in the color, as a background, printed as on screen. So each kind gets its icon pre-tinted
///   in its light color, and print uses it in place of the mask.
/// - **Backgrounds print only when asked** (`WKPreferences.shouldPrintBackgrounds`), or the inline
///   code's fill and that icon vanish. `MarkdownExportPDF` asks.
/// - **`@media print` applies**, and a box that scrolls on screen is cut at the paper's edge, so a
///   code block wraps and nothing scrolls. `NSPrintInfo.scalingFactor` was honored but at 1.25 laid a
///   page sideways across two sheets, so the text is sized here instead: the preview's 13 px is
///   9.75 pt on paper, and a page is read at 11.
@MainActor
enum QuickViewMarkdownExportStyle {
    /// The point size printed body text takes, and code, footnotes and front matter beside it.
    static let printTextSize = "11pt"
    static let printSmallSize = "9.5pt"

    /// GitHub's reading width for a rendered file, centered, so a line does not run the width of a
    /// browser window. The preview's pane is never that wide, so it never needed one.
    static let readingWidth = 980

    static var rules: String {
        """
        body { max-width: \(readingWidth)px; margin: 0 auto; }
        @media print {
          body { max-width: none; padding: 0; font-size: \(printTextSize); }
          code, table.front-matter, section.footnotes, p.truncated { font-size: \(printSmallSize); }
          pre, table, .math-display { overflow: visible; }
          pre code { white-space: pre-wrap; overflow-wrap: anywhere; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid; }
          img, svg, tr { break-inside: avoid; }
          .markdown-alert-title::before {
            background: var(--alert-print-icon) center / contain no-repeat;
            -webkit-mask: none;
            mask: none;
          }
        \(alertPrintIcons)
        }
        """
    }

    /// Each alert kind's symbol drawn in its light title color, as the property print draws it from.
    private static var alertPrintIcons: String {
        MarkdownAlertKind.allCases.compactMap { kind -> String? in
            guard let tint = PanelPalette.color(fromHex: QuickViewMarkdownAlerts.color(kind).light),
                  let icon = QuickViewMarkdownAlerts.iconMask(
                      QuickViewMarkdownAlerts.symbol(kind),
                      tint: tint
                  )
            else { return nil }
            return "  .markdown-alert-\(kind.rawValue) { --alert-print-icon: url(\"\(icon)\"); }"
        }.joined(separator: "\n")
    }
}
