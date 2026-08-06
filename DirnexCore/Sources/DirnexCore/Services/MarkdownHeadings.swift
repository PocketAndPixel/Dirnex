import Foundation

/// One heading of a parsed document, with the anchor it will carry (PLAN.md §M18 ▸ Slice 2).
///
/// The list of these is what `[[_TOC_]]` is built from and what every `id` in the page comes from —
/// **one** derivation feeding both, rather than a slugger in the renderer and a second one in the
/// table of contents. Two sluggers would agree right up until they didn't, and the failure is a TOC
/// whose links land nowhere: the page looks perfect and every entry is dead.
public struct MarkdownHeading: Equatable, Sendable {
    /// 1…6.
    public let level: Int
    /// The heading's **text content** — emphasis, code spans and links flattened to what a reader
    /// sees. That is what GitHub slugs, and what a TOC entry draws (a TOC entry cannot redraw the
    /// markup: a heading holding a link would nest an `<a>` inside the entry's own).
    public let text: String
    /// The anchor, unique within the document, or empty for a heading with nothing sluggable in it.
    public let slug: String

    public init(level: Int, text: String, slug: String) {
        self.level = level
        self.text = text
        self.slug = slug
    }
}

/// The pass that finds every heading in a parsed document and numbers its anchor.
///
/// Runs over the **block tree**, not over the lines, which is what keeps a `#` inside a code fence
/// from becoming a heading — the block pass already decided that. It recurses into blockquotes and
/// list items in document order, so a heading anywhere in the file gets an anchor: `> ## Quoted` is
/// unusual and is still a heading somebody may have linked to.
///
/// The order it visits headings in is the order the renderer renders them in, and that
/// correspondence is the one thing here that could silently drift — so `MarkdownAnchorTests` pins it
/// against a document with headings nested inside both container kinds.
enum MarkdownHeadings {
    static func gather(
        from blocks: [MarkdownBlock],
        references: [String: MarkdownLinkReference]
    ) -> [MarkdownHeading] {
        var slugger = MarkdownSlugger()
        var headings: [MarkdownHeading] = []
        collect(blocks, into: &headings, slugger: &slugger, references: references)
        return headings
    }

    private static func collect(
        _ blocks: [MarkdownBlock],
        into headings: inout [MarkdownHeading],
        slugger: inout MarkdownSlugger,
        references: [String: MarkdownLinkReference]
    ) {
        for block in blocks {
            switch block {
            case let .heading(level, source):
                let text = MarkdownInlineParser.plainText(
                    MarkdownInlineParser.parse(source, references: references)
                )
                headings.append(
                    MarkdownHeading(level: level, text: text, slug: slugger.next(for: text))
                )
            case let .blockQuote(inner):
                collect(inner, into: &headings, slugger: &slugger, references: references)
            case let .list(list):
                for item in list.items {
                    collect(item.blocks, into: &headings, slugger: &slugger, references: references)
                }
            // Spelled out rather than left to a `default`, so a block kind that gains children is
            // named here by the compiler instead of quietly holding headings nobody can link to.
            case .paragraph, .thematicBreak, .codeBlock, .table, .frontMatter, .tableOfContents:
                break
            }
        }
    }
}
