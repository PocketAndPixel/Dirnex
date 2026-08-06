import AppKit
import DirnexCore

/// The `<html>` wrapper and the stylesheet a rendered Markdown document is drawn with
/// (PLAN.md §M18 ▸ Slice 3).
///
/// `DirnexCore` emits a **fragment** carrying class names and never a colour, for the reason M17
/// separates `SyntaxToken.Kind` from `SyntaxTheme`: the core says what a thing *is*, and only the
/// app knows which appearance is on screen. This is the other half.
///
/// ## The page switches appearance by itself
///
/// The plan had this re-generated on `viewDidChangeEffectiveAppearance`. Probed instead
/// (2026-08-06, against a real `WKWebView`): **`prefers-color-scheme` tracks the web view's
/// effective appearance with no `color-scheme` declaration of any kind, and re-evaluates live when
/// that appearance changes, with no reload.** So the stylesheet carries *both* palettes under one
/// media query and a light/dark flip costs nothing — where a re-render would have thrown away the
/// user's reading position every time the system crossed sunset.
///
/// ## Every colour here was measured, and two obvious choices are wrong
///
/// Measured in both appearances against the page background, with alpha composited (docs/NOTES.md:
/// the muted label colours carry alpha, and reading them without compositing scores them at 21:1):
///
/// - **`.windowBackgroundColor` and `.controlBackgroundColor` are byte-identical to
///   `.textBackgroundColor`** — `#FFFFFF` light, `#1E1E1E` dark. Either as a code-fence fill draws
///   an invisible box, which is the first thing anybody would reach for.
/// - **A fence must not be filled at all.** `.underPageBackgroundColor` is `#A1A1A1` in light and
///   drops the syntax palette to 1.77–3.31:1; even the gentle `#E6E6E6` that
///   `.quaternaryLabelColor` composites to takes `typeOrTag` from 4.59:1 to **3.68:1**. M17
///   authored that palette against `.textBackgroundColor` and it clears AA there, so the fence keeps
///   the page's own background and is delimited by a **border** instead. The fill is kept for
///   *inline* `<code>`, which carries no coloured spans — only `.textColor`, at ~18:1 over it.
/// - `.gridColor` inverts: `#E6E6E6` in light but `#1A1A1A` in dark, *darker* than the page it would
///   sit on (1.04:1). `.separatorColor` is the one that behaves in both (1.25 / 1.34:1).
/// - `.linkColor` clears AA in both — `#0068DA` at 5.26:1, `#419CFF` at 5.89:1 — so links take the
///   system's own, which is what every other text surface in the app draws.
///
/// `@MainActor` because it resolves `NSColor`s through a drawing appearance and borrows the source
/// view's truncation sentence; it runs on the load, not on the detached render, and is a few dozen
/// colour resolutions and a string join.
@MainActor
enum QuickViewMarkdownStyle {
    /// The whole page: the fragment, wrapped, with both palettes and the rules that use them.
    ///
    /// `isTruncated` is not decoration. `TextPreview` reads 4 MB and its own doc comment states the
    /// obligation — "a preview that silently ends early is a preview that lies" — and a *rendered*
    /// document is where that lie is easiest to tell, because a page has no visible end for the
    /// reader to notice missing. The source view draws the same sentence as a floating strip.
    static func document(body: String, isTruncated: Bool = false) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(palette(for: .aqua, selector: ":root"))
        @media (prefers-color-scheme: dark) {
        \(palette(for: .darkAqua, selector: ":root"))
        }
        \(rules)
        </style>
        </head>
        <body>
        \(body)
        \(isTruncated ? truncationNotice : "")
        </body>
        </html>
        """
    }

    /// The "first 4 MB of this file" line, in the *same* words the source view uses.
    ///
    /// Escaped rather than interpolated raw: the sentence is translated, so its text is not this
    /// file's to predict, and a language whose phrasing carries an `&` would otherwise write a
    /// broken entity into the page. Only the three characters that can end an element's text —
    /// there is no attribute here to escape a quote for.
    private static var truncationNotice: String {
        let text = QuickViewTextView.truncationText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<p class=\"truncated\">\(text)</p>"
    }

    // MARK: - The palette

    /// One appearance's colours as custom properties, so the rules below are written once.
    private static func palette(for appearance: NSAppearance.Name, selector: String) -> String {
        guard let appearance = NSAppearance(named: appearance) else { return "" }
        let background = resolved(.textBackgroundColor, in: appearance)
        var lines = [
            "--background: \(hex(background));",
            "--text: \(hex(resolved(.textColor, in: appearance)));",
            "--muted: \(hex(flattened(.secondaryLabelColor, over: background, in: appearance)));",
            "--faint: \(hex(flattened(.tertiaryLabelColor, over: background, in: appearance)));",
            "--rule: \(hex(flattened(.separatorColor, over: background, in: appearance)));",
            "--link: \(hex(resolved(.linkColor, in: appearance)));",
            "--code-fill: \(hex(flattened(.quaternaryLabelColor, over: background, in: appearance)));"
        ]
        // One rule per token kind, from the core's own class name rather than a second spelling of
        // it — the whole reason `MarkdownDocument.tokenClass` is public. A kind added later arrives
        // here automatically, and `SyntaxTheme.color(for:)` is a compiler-checked switch, so it
        // cannot arrive uncoloured.
        for kind in SyntaxToken.Kind.allCases {
            guard let name = MarkdownDocument.tokenClass(for: kind),
                  let colour = SyntaxTheme.color(for: kind)
            else { continue }
            lines.append("--\(name): \(hex(resolved(colour, in: appearance)));")
        }
        return selector + " {\n" + lines.map { "  " + $0 }.joined(separator: "\n") + "\n}"
    }

    /// `colour` as it resolves in `appearance`, in sRGB.
    ///
    /// `performAsCurrentDrawingAppearance` rather than reading the colour directly: a dynamic
    /// `NSColor` answers for whichever appearance is current, and this file has to ask it for the
    /// one that is *not* on screen — which is the only way a two-palette stylesheet can exist.
    private static func resolved(_ colour: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = colour
        appearance.performAsCurrentDrawingAppearance {
            out = colour.usingColorSpace(.sRGB) ?? colour
        }
        return out
    }

    /// `colour` resolved and then **composited** over `background`, which is what the eye sees.
    /// The muted label colours are black or white at 10–55 % alpha, so the raw value is useless: it
    /// reads as pure black in light mode, at 21:1 against a background it is nowhere near.
    private static func flattened(
        _ colour: NSColor,
        over background: NSColor,
        in appearance: NSAppearance
    ) -> NSColor {
        let front = resolved(colour, in: appearance)
        let alpha = front.alphaComponent
        return NSColor(
            srgbRed: front.redComponent * alpha + background.redComponent * (1 - alpha),
            green: front.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: front.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private static func hex(_ colour: NSColor) -> String {
        let srgb = colour.usingColorSpace(.sRGB) ?? colour
        return String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }

    // MARK: - The rules

    /// Prose at the *same* size the source view draws, so `1` and `2` are two renderings of one
    /// file rather than two zoom levels. The families come from the CSS generics because the system
    /// fonts have no usable name — `NSFont.systemFont` is `.AppleSystemUIFont`, which no stylesheet
    /// can ask for — so only the size is read from AppKit.
    private static var rules: String {
        let text = NSFont.systemFontSize
        let small = NSFont.smallSystemFontSize
        return """
        body {
          margin: 0;
          padding: 16px 20px 48px;
          background: var(--background);
          color: var(--text);
          font-family: -apple-system, system-ui, sans-serif;
          font-size: \(text)px;
          line-height: 1.5;
          -webkit-text-size-adjust: none;
          overflow-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 600; }
        h1 { font-size: 1.8em; border-bottom: 1px solid var(--rule); padding-bottom: 0.2em; }
        h2 { font-size: 1.45em; border-bottom: 1px solid var(--rule); padding-bottom: 0.2em; }
        h3 { font-size: 1.2em; }
        h4 { font-size: 1.05em; }
        h5, h6 { font-size: 1em; color: var(--muted); }
        :first-child { margin-top: 0; }
        p { margin: 0 0 0.85em; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        img { max-width: 100%; height: auto; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 1.6em 0; }
        blockquote {
          margin: 0 0 0.85em;
          padding: 0 0 0 1em;
          border-left: 3px solid var(--faint);
          color: var(--muted);
        }
        ul, ol { margin: 0 0 0.85em; padding-left: 1.6em; }
        li { margin: 0.15em 0; }
        li > ul, li > ol { margin-bottom: 0; }
        ul.task-list { list-style: none; padding-left: 0.3em; }
        ul.task-list ul { list-style: disc; padding-left: 1.6em; }
        li.task { list-style: none; }
        li.task input { margin-right: 0.4em; }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: \(small)px;
        }
        :not(pre) > code {
          background: var(--code-fill);
          border-radius: 4px;
          padding: 0.1em 0.35em;
        }
        pre {
          margin: 0 0 0.9em;
          padding: 10px 12px;
          border: 1px solid var(--rule);
          border-radius: 6px;
          overflow-x: auto;
        }
        pre code { display: block; white-space: pre; }
        table { border-collapse: collapse; margin: 0 0 0.9em; display: block; overflow-x: auto; }
        th, td { border: 1px solid var(--rule); padding: 5px 10px; text-align: left; }
        th { font-weight: 600; }
        td.align-left, th.align-left { text-align: left; }
        td.align-center, th.align-center { text-align: center; }
        td.align-right, th.align-right { text-align: right; }
        table.front-matter { color: var(--muted); font-size: \(small)px; }
        table.front-matter th { font-weight: 500; white-space: nowrap; vertical-align: top; }
        nav.toc {
          margin: 0 0 1.4em;
          padding: 8px 12px;
          border: 1px solid var(--rule);
          border-radius: 6px;
        }
        nav.toc ul { margin: 0; padding-left: 1.2em; list-style: none; }
        nav.toc > ul { padding-left: 0; }
        nav.toc li { margin: 0.1em 0; }
        p.truncated {
          margin: 1.6em 0 0;
          padding-top: 0.8em;
          border-top: 1px solid var(--rule);
          color: var(--muted);
          font-size: \(small)px;
        }
        \(tokenRules)
        """
    }

    /// One rule per coloured span, named by the core and coloured by `SyntaxTheme` — the same table
    /// the source view uses, so the same fence looks the same on `1` and on `2`.
    private static var tokenRules: String {
        SyntaxToken.Kind.allCases
            .compactMap { MarkdownDocument.tokenClass(for: $0) }
            .map { ".\($0) { color: var(--\($0)); }" }
            .joined(separator: "\n")
    }
}
