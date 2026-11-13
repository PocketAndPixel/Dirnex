import AppKit
import DirnexCore

/// The app's half of GitHub alerts and footnotes in a rendered Markdown page (PLAN.md §M39 ▸
/// Slice 6): an alert's title in the user's language, and the rules both are drawn with.
///
/// The core emits GitHub's own classes (`markdown-alert markdown-alert-note`, `footnotes`) and never
/// a color, for the reason `QuickViewMarkdownStyle` gives; these rules are spliced into the same
/// `<style>` block.
///
/// ## The colors are GitHub's, and clear 4.5:1 here
///
/// An alert's kind is told apart by its color first, so the palette is GitHub's (Primer's `fg`
/// accent, success, done, attention and danger), which is what the file's author saw. Measured
/// against this page's own backgrounds rather than GitHub's, since `.textBackgroundColor` is
/// `#FFFFFF` and `#1E1E1E` where GitHub's dark page is `#0D1117`: every title color scores 4.87:1 to
/// 5.24:1 in light and 4.97:1 to 6.60:1 in dark, which `QuickViewMarkdownAlertTests` keeps.
///
/// ## The icons are SF Symbols
///
/// GitHub draws an Octicon beside each title. These are the system's own symbols instead, drawn
/// once into a PNG and used as a CSS mask, so each takes the title's color in either appearance and
/// the page needs no third-party artwork.
enum QuickViewMarkdownAlerts {
    /// The title an alert draws above its text, in the user's language. GitHub draws it in English
    /// whatever the reader's; these follow the words the technical-writing guides use in each
    /// language, so the five read as a set.
    ///
    /// Not main-actor bound: it is called from the detached render, and a catalog lookup is safe
    /// from any thread.
    static func title(_ kind: MarkdownAlertKind) -> String {
        switch kind {
        case .note:
            String(
                localized: "Note",
                comment: "Quick View: title of a Markdown note box, written > [!NOTE]"
            )
        case .tip:
            String(
                localized: "Tip",
                comment: "Quick View: title of a Markdown tip box, written > [!TIP]"
            )
        case .important:
            String(
                localized: "Important",
                comment: "Quick View: title of a Markdown box, written > [!IMPORTANT]"
            )
        case .warning:
            String(
                localized: "Warning",
                comment: "Quick View: title of a Markdown warning box, written > [!WARNING]"
            )
        case .caution:
            String(
                localized: "Caution",
                comment: "Quick View: title of a Markdown caution box, written > [!CAUTION]"
            )
        }
    }

    /// GitHub's title and border color for each kind, light then dark.
    static func color(_ kind: MarkdownAlertKind) -> (light: String, dark: String) {
        switch kind {
        case .note: ("#0969DA", "#4493F8")
        case .tip: ("#1A7F37", "#3FB950")
        case .important: ("#8250DF", "#AB7DF8")
        case .warning: ("#9A6700", "#D29922")
        case .caution: ("#D1242F", "#F85149")
        }
    }

    /// The SF Symbol drawn beside each kind's title, chosen to read as GitHub's Octicon does.
    static func symbol(_ kind: MarkdownAlertKind) -> String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }

    // MARK: - The stylesheet

    /// The rules alerts and footnotes are drawn with. Built once: the icons are drawn on first use.
    @MainActor
    static let rules: String = {
        let kinds = MarkdownAlertKind.allCases
        let light = kinds.map { "  --alert-\($0.rawValue): \(color($0).light);" }
        let dark = kinds.map { "  --alert-\($0.rawValue): \(color($0).dark);" }
        let perKind = kinds.map { kind -> String in
            let icon = iconMask(symbol(kind)).map { "\n  --alert-icon: url(\"\($0)\");" } ?? ""
            return ".markdown-alert-\(kind.rawValue) {\n  --alert-color: var(--alert-\(kind.rawValue));\(icon)\n}"
        }
        return """
        :root {
        \(light.joined(separator: "\n"))
        }
        @media (prefers-color-scheme: dark) {
        :root {
        \(dark.joined(separator: "\n"))
        }
        }
        .markdown-alert {
          margin: 0 0 0.85em;
          padding: 0.4em 1em;
          border-left: 3px solid var(--alert-color);
        }
        .markdown-alert > :last-child { margin-bottom: 0; }
        .markdown-alert-title {
          display: flex;
          align-items: center;
          margin: 0 0 0.35em;
          font-weight: 600;
          color: var(--alert-color);
        }
        .markdown-alert-title::before {
          content: "";
          flex: none;
          width: 1em;
          height: 1em;
          margin-right: 0.45em;
          background-color: currentColor;
          -webkit-mask: var(--alert-icon) center / contain no-repeat;
          mask: var(--alert-icon) center / contain no-repeat;
        }
        \(perKind.joined(separator: "\n"))
        sup { line-height: 0; }
        section.footnotes {
          margin: 2em 0 0;
          padding-top: 0.6em;
          border-top: 1px solid var(--rule);
          color: var(--muted);
          font-size: \(NSFont.smallSystemFontSize)px;
        }
        section.footnotes ol { margin: 0; padding-left: 1.6em; }
        section.footnotes li p { margin: 0 0 0.4em; }
        a.footnote-backref { margin-left: 0.15em; }
        """
    }()

    /// `symbol` drawn black on clear into a PNG, as a `data:` URI, for a CSS mask: only its alpha is
    /// read, and the title's color shows through it. Drawn at 32 points, twice the size it is shown
    /// at, so it stays sharp on a Retina screen.
    @MainActor
    static func iconMask(_ symbol: String) -> String? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        let size = NSSize(width: ceil(image.size.width), height: ceil(image.size.height))
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(size.width),
                  pixelsHigh: Int(size.height),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
