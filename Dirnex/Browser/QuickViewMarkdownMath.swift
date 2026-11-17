import Foundation

/// The rules a rendered Markdown page draws its math with (PLAN.md §M39 ▸ Slice 8).
///
/// The core turns TeX into MathML (`TeXMath`) and writes three classes for this side to style,
/// each one a fact WebKit was seen to need on 2026-11-14 rather than a choice of look:
///
/// - **`math-display`** wraps a display formula, a `span` in a paragraph and a `div` for a
///   ```` ```math ```` fence. WebKit lays out `<math display="block">` but will not scroll it, so a
///   formula wider than the window ran off the page (1 169 points of page in a 420-point window);
///   the wrapper scrolls instead, as a code fence does.
/// - **`math-aligned`** is an `aligned` environment's table. WebKit's own stylesheet pads every cell
///   on both sides, which put 6 points between `a` and the `= b` aligned on it at the page's size;
///   the pairs sit close and each pair is spaced from the next.
/// - **`math-unknown`** is a command outside the subset, drawn as its own text. It takes GitHub's
///   danger red, as MathJax draws an undefined command red on GitHub: `#D1242F` scores 5.24:1 on
///   this page's white and `#F85149` 4.97:1 on its `#1E1E1E`, which `QuickViewMarkdownMathTests`
///   keeps.
enum QuickViewMarkdownMath {
    /// The unknown command's color, light then dark.
    static let unknownColor = (light: "#D1242F", dark: "#F85149")

    static let rules = """
    :root {
      --math-unknown: \(unknownColor.light);
    }
    @media (prefers-color-scheme: dark) {
    :root {
      --math-unknown: \(unknownColor.dark);
    }
    }
    .math-display {
      display: block;
      overflow-x: auto;
      overflow-y: hidden;
      margin: 0.6em 0;
    }
    div.math-display { margin: 0 0 0.9em; }
    mtable.math-aligned > mtr > mtd { padding-left: 0; padding-right: 0; }
    mtable.math-aligned > mtr > mtd:nth-child(even):not(:last-child) { padding-right: 2em; }
    .math-unknown { color: var(--math-unknown); }
    """
}
