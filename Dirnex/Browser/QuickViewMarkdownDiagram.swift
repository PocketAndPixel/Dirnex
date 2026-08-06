import AppKit
import DirnexCore

/// The app's half of a mermaid diagram (PLAN.md §M18 ▸ Slice 4).
///
/// Three things the core cannot supply, and one reason they live in a single file: **the font size
/// is in all three of them**. The layout measures labels in it, the stylesheet draws them in it, and
/// a disagreement between the two is a diagram whose boxes are the wrong size for their text — with
/// nothing failing, nothing logging, and both suites green. That is the "one rule, two spellings"
/// trap docs/NOTES.md keeps finding, so here there is one spelling and both readers take it from
/// `labelSize`.
///
/// ## The metric
///
/// `DirnexCore` imports no AppKit and a flowchart node's width *is* its label's width, so the
/// measurement is injected (`MarkdownTextMetric`). It is called from the **detached** render task,
/// which the milestone's probe cleared: four concurrent background queues measuring 200 labels
/// twenty times each agreed with the main thread's answers exactly, at ~6 µs a label. A hundred-node
/// diagram is therefore under a millisecond of measurement, against the 4.5 ms this repo's own
/// `PLAN.md` already costs to render.
enum QuickViewMarkdownDiagram {
    /// The one number both halves read. Small system size, so a diagram sits inside the prose
    /// around it rather than shouting over it — the same relationship a code fence has.
    static let labelSize = NSFont.smallSystemFontSize

    /// A font carried across the detached boundary.
    ///
    /// `@unchecked Sendable` is a claim, and this is the one the milestone's probe actually
    /// measured: an `NSFont` is immutable, and four concurrent background queues measuring 200
    /// labels twenty times each produced *zero* disagreements with the main thread. Resolving the
    /// font inside the closure instead would pay a lookup per label to avoid a claim that is true.
    private struct Face: @unchecked Sendable {
        let font: NSFont
    }

    /// The metric handed to the core's layout.
    static var metric: MarkdownTextMetric {
        let face = Face(font: .systemFont(ofSize: labelSize))
        let lineHeight = ceil(face.font.ascender - face.font.descender)
        return MarkdownTextMetric(lineHeight: lineHeight) { text in
            Double((text as NSString).size(withAttributes: [.font: face.font]).width)
        }
    }

    /// What the page says about a diagram type or construct it did not draw.
    ///
    /// The core hands over the bare word — `stateDiagram-v2`, `subgraph` — and the sentence is
    /// written here, because a sentence in `DirnexCore` is a sentence nobody can translate
    /// (docs/NOTES.md ▸ Localization). Saying it at all is the milestone's whole argument for
    /// shipping a *subset*: an undrawn diagram type shows up as somebody asking for it rather than
    /// as a picture that is quietly missing a branch.
    static func describeUndrawn(_ name: String) -> String {
        String(
            localized: "“\(name)” is not drawn in this preview.",
            // `comment:` takes a StaticString, so it can be neither split nor hoisted into a
            // constant (docs/NOTES.md ▸ Localization) — hence one terse line.
            comment: "Quick View: a mermaid diagram type not drawn. %@ is the file's own keyword."
        )
    }

    // MARK: - The stylesheet

    /// The rules a diagram is drawn with.
    ///
    /// Every colour is a custom property `QuickViewMarkdownStyle` already resolves for both
    /// appearances, and every shape takes `currentColor` — which is what makes a diagram follow
    /// light and dark exactly the way the prose around it does, live and with no reload. The core
    /// emits class names and never a colour precisely so that this file can be the only one that
    /// knows which appearance is on screen.
    static var rules: String {
        """
        figure.mermaid-figure { margin: 0 0 1em; }
        svg.mermaid {
          display: block;
          max-width: 100%;
          height: auto;
          color: var(--text);
          overflow: visible;
        }
        .mm-node { fill: none; stroke: currentColor; stroke-width: 1.2; }
        .mm-node-bar { stroke: currentColor; stroke-width: 1.2; }
        .mm-label { fill: currentColor; font-size: \(labelSize)px; }
        .mm-edge { stroke: currentColor; stroke-width: 1.2; }
        .mm-edge-solid { stroke-dasharray: none; }
        .mm-edge-dotted { stroke-dasharray: 4 3; }
        .mm-edge-thick { stroke-width: 2.6; }
        .mm-tip-arrow { fill: currentColor; }
        .mm-tip-cross, .mm-tip-circle { stroke: currentColor; fill: none; stroke-width: 1.4; }
        .mm-edge-label { fill: var(--muted); font-size: \(labelSize - 1)px; }
        .mm-edge-label-start { text-anchor: start; }
        .mm-edge-label-plate { fill: var(--background); }
        .mm-participant { fill: none; stroke: currentColor; stroke-width: 1.2; }
        .mm-lifeline { stroke: var(--faint); stroke-width: 1; stroke-dasharray: 3 3; }
        .mm-activation { fill: var(--code-fill); stroke: currentColor; stroke-width: 1; }
        .mm-actor { stroke: currentColor; fill: none; stroke-width: 1.2; }
        .mm-note { fill: var(--code-fill); stroke: var(--faint); stroke-width: 1; }
        .mm-note-label { fill: currentColor; font-size: \(labelSize - 1)px; }
        figcaption.mermaid-note {
          margin-top: 0.3em;
          color: var(--muted);
          font-size: \(NSFont.smallSystemFontSize)px;
        }
        """
    }
}
