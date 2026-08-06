import Foundation

/// A ```` ```mermaid ```` fence's place in the rendered page (PLAN.md §M18 ▸ Slice 4).
///
/// The rule this file exists to keep: **a fence either draws or shows its source, and it says which
/// it did.** Both outcomes are a `<figure>` with the same shape, and a `<figcaption>` naming
/// anything that did not make it onto the page. Nothing here is silent — that is the whole argument
/// for shipping a *subset*, since a diagram type nobody supports shows up as a user asking for it
/// rather than as a picture that is quietly missing a branch.
///
/// The caption's words come from the caller, never from here. A sentence in `DirnexCore` is a
/// sentence that can never be translated (docs/NOTES.md ▸ Localization), so the core hands over the
/// bare name — `stateDiagram-v2`, `subgraph` — and the app writes the sentence around it.
extension MarkdownHTMLRenderer.Context {
    /// A mermaid fence, drawn or fallen back, or `nil` when the info string never claimed one.
    func diagram(info: String?, code: String) -> String? {
        guard MermaidRenderer.claimsFence(info) else { return nil }
        guard let output = MermaidRenderer.render(code, options: options) else {
            let name = MermaidRenderer.unsupportedType(in: code)
            return figure(fallback(code), notes: name.map { [$0] } ?? [])
        }
        return figure(output.svg, notes: output.undrawn)
    }

    private func figure(_ body: String, notes: [String]) -> String {
        let caption = notes
            .map { MarkdownHTML.escaped(options.describeUndrawnDiagram($0)) }
            .joined(separator: " ")
        let element = caption.isEmpty
            ? ""
            : MarkdownHTML.element("figcaption", caption, attributes: " class=\"mermaid-note\"")
        return MarkdownHTML.element(
            "figure",
            body + element,
            attributes: " class=\"mermaid-figure\""
        )
    }

    /// The fence as it looked before any of this existed: escaped source in a `<pre><code>`.
    ///
    /// Deliberately *not* routed through `SyntaxHighlighter` — no grammar claims mermaid, and
    /// colouring it with a neighbouring language's would be a confident wrong answer where plain
    /// text is a correct one.
    private func fallback(_ code: String) -> String {
        "<pre>" + MarkdownHTML.element(
            "code",
            MarkdownHTML.escaped(code),
            attributes: " class=\"language-mermaid\""
        ) + "</pre>"
    }
}
