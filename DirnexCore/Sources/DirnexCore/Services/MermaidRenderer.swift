import Foundation

/// A ```` ```mermaid ```` fence, all the way to markup (PLAN.md §M18 ▸ Slice 4).
///
/// One function, and it is the only thing outside this family that anything else calls: parse,
/// lay out, emit. The three stages are separately testable and separately pure, which is what lets
/// the layout assertions be exact numbers and the parse assertions be about a model rather than
/// about a string.
///
/// ## Why this returns `nil` rather than an error
///
/// A fence this cannot draw is not a failure — it is a code fence, which is exactly what it was
/// before mermaid existed here. `nil` sends `MarkdownCodeHighlighting` back to that path, and the
/// caller adds the note naming what it did not draw. The renderer never produces "a diagram that
/// went wrong": either a drawing, or the source somebody wrote.
enum MermaidRenderer {
    /// What a fence turned into, and anything about it the page should say out loud.
    struct Output {
        let svg: String
        /// Diagram types and constructs that were not drawn, if any — facts, never sentences. The
        /// words come from the app, which is the only side that can translate them
        /// (`MarkdownRenderOptions.describeUndrawnDiagram`; docs/NOTES.md ▸ Localization: a
        /// presentation decision in the core is a string that can never be translated).
        let undrawn: [String]
    }

    /// The diagram in `source`, or `nil` when the whole fence has to fall back to its text.
    static func render(_ source: String, options: MarkdownRenderOptions) -> Output? {
        switch MermaidParser.parse(source) {
        case let .flowchart(chart):
            let drawing = MermaidFlowchartLayout.lay(out: chart, metric: options.textMetric)
            return Output(svg: MermaidFlowchartSVG.svg(drawing), undrawn: chart.undrawn)
        case let .sequence(diagram):
            let drawing = MermaidSequenceLayout.lay(out: diagram, metric: options.textMetric)
            return Output(svg: MermaidSequenceSVG.svg(drawing), undrawn: diagram.undrawn)
        case .unsupported:
            return nil
        }
    }

    /// The diagram type a fence names, when this subset does not draw it.
    ///
    /// Separate from `render` because the two answers are needed at different times and for
    /// different reasons: one produces a picture, and this one produces the *word* the note is
    /// about. Returning it from a failed render would make the caller unpack a result it does not
    /// otherwise need.
    static func unsupportedType(in source: String) -> String? {
        guard case let .unsupported(name) = MermaidParser.parse(source) else { return nil }
        return name.isEmpty ? nil : name
    }

    /// Whether a fence's info string asks for a diagram.
    ///
    /// Named spellings rather than one, for the reason `.xhtml` taught §M16 — `mmd` is what a file
    /// carrying a diagram is called, and a document that fences it that way means the same thing.
    static func claimsFence(_ info: String?) -> Bool {
        guard let word = info?.split(whereSeparator: \.isWhitespace).first?.lowercased() else {
            return false
        }
        return word == "mermaid" || word == "mmd"
    }
}
