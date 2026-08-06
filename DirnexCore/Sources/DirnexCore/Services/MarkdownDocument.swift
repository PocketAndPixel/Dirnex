import Foundation

/// A rendered Markdown document, ready for the app to wrap and style.
public struct MarkdownRender: Equatable, Sendable {
    /// An HTML **fragment** — the document's body and nothing around it. The `<html>`, the
    /// `<style>` and the appearance they carry are the app's (PLAN.md §M18 ▸ Slice 3).
    public let html: String

    public init(html: String) {
        self.html = html
    }
}

/// The caller's say over the parts of rendering that are not the core's to decide.
///
/// One field today, and it exists because of a *probe*: how a generated document reaches the
/// sibling image a `.md` refers to is a WebKit question with three candidate answers (a file base
/// URL, a scoped file load, or inlining as `data:`), and none of them is the core's business
/// (PLAN.md §M18). The default is identity, so every test in Slice 1 renders the source the file
/// wrote and nothing about the parser depends on how that question is settled.
public struct MarkdownRenderOptions: Sendable {
    /// Maps an image's `src` as written to the one the page should load.
    public var resolveImageSource: @Sendable (String) -> String

    public init(resolveImageSource: @escaping @Sendable (String) -> String = { $0 }) {
        self.resolveImageSource = resolveImageSource
    }
}

/// Markdown, rendered as the document it describes (PLAN.md §M18).
///
/// The public face of the milestone's core half, and deliberately the only one: the block model,
/// the two parsers and the HTML writer are all internal, so the app depends on *what a `.md` looks
/// like rendered* rather than on how it was read. That is the same line `TextPreview` draws — the
/// core turns bytes into something showable, and the app decides which surface shows it.
///
/// Hand-rolled, with no third-party renderer anywhere in it, for the reasons M17 rejected the
/// equivalent shortcut for highlighting: a dependency here is a parser this project cannot test,
/// running over files a user pointed at by accident.
public enum MarkdownDocument {
    public static func render(
        _ text: String,
        options: MarkdownRenderOptions = MarkdownRenderOptions()
    ) -> MarkdownRender {
        MarkdownRender(html: MarkdownHTMLRenderer.render(
            MarkdownBlockParser.scan(text),
            options: options
        ))
    }
}
