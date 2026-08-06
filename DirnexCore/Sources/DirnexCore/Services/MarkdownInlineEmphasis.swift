import Foundation

/// The second half of the inline pass: pairing `*`, `_` and `~~` runs (PLAN.md §M18 ▸ Slice 1).
///
/// Separate from the scan because emphasis cannot be decided left to right. `*a **b** c*` is the
/// case that settles it: scanning forward from the first `*`, the `**` after `b` is a perfectly
/// legal closer — not preceded by whitespace, the right character — so a greedy match ends the
/// emphasis in the middle of the strong one and the rest of the line comes out as literal asterisks.
/// Collecting the runs first and pairing them from the inside out is what CommonMark does, and it is
/// the difference between a document that renders and one that renders *nearly*.
enum MarkdownInlineEmphasis {
    /// A run of the same delimiter character, and what it is allowed to do.
    struct Delimiter: Equatable {
        let marker: Character
        var length: Int
        var canOpen: Bool
        var canClose: Bool
    }

    /// The scan's output: nodes it finished, and delimiters it left for this pass.
    enum Item: Equatable {
        case node(MarkdownInline)
        case delimiter(Delimiter)
    }

    static func resolve(_ items: [Item]) -> [MarkdownInline] {
        var items = items
        var index = 0
        while index < items.count {
            guard case let .delimiter(closer) = items[index], closer.canClose, closer.length > 0
            else {
                index += 1
                continue
            }
            guard let opener = openerIndex(before: index, matching: closer.marker, in: items) else {
                // No opener for it, so it is not a closer after all. Recorded rather than merely
                // skipped: without this the same run is re-examined on every later pass over it,
                // and it may still legitimately *open* something further along.
                if case var .delimiter(stranded) = items[index] {
                    stranded.canClose = false
                    items[index] = .delimiter(stranded)
                }
                index += 1
                continue
            }
            index = pair(&items, opener: opener, closer: index)
        }
        return flatten(items)
    }

    /// The nearest delimiter before `index` that can open and shares the marker. Nearest, not
    /// first: emphasis nests, and pairing with the outermost candidate would cross the inner pair.
    private static func openerIndex(
        before index: Int,
        matching marker: Character,
        in items: [Item]
    ) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            if case let .delimiter(candidate) = items[cursor],
               candidate.marker == marker, candidate.canOpen, candidate.length > 0 {
                return cursor
            }
            cursor -= 1
        }
        return nil
    }

    /// Wrap what lies between the two runs, consume one or two delimiters from each, and answer
    /// where scanning continues.
    ///
    /// Continuing from the **opener** rather than from past the new node is what lets `***both***`
    /// resolve: the strong pair is taken first, and the single delimiter left on each side is then
    /// found on the very next step. Each pairing removes at least two delimiters, so the walk
    /// terminates whatever the input.
    private static func pair(_ items: inout [Item], opener: Int, closer: Int) -> Int {
        guard case var .delimiter(open) = items[opener],
              case var .delimiter(close) = items[closer]
        else { return closer + 1 }
        let use = min(open.length, close.length) >= 2 ? 2 : 1
        // GFM strikethrough is exactly `~~`. A single tilde is a tilde — it is ordinary punctuation
        // in a file name and in prose about approximation.
        guard open.marker != "~" || use == 2 else {
            close.canClose = false
            items[closer] = .delimiter(close)
            return closer + 1
        }
        let inner = flatten(Array(items[(opener + 1)..<closer]))
        open.length -= use
        close.length -= use
        var replacement: [Item] = []
        if open.length > 0 { replacement.append(.delimiter(open)) }
        replacement.append(.node(node(for: open.marker, use: use, children: inner)))
        if close.length > 0 { replacement.append(.delimiter(close)) }
        items.replaceSubrange(opener...closer, with: replacement)
        return opener
    }

    private static func node(
        for marker: Character,
        use: Int,
        children: [MarkdownInline]
    ) -> MarkdownInline {
        if marker == "~" { return .strikethrough(children) }
        return use == 2 ? .strong(children) : .emphasis(children)
    }

    /// Nodes out, with every unpaired delimiter turned back into the characters it was written as —
    /// which is the guarantee that makes this affordable: a `*` that pairs with nothing is a `*` on
    /// screen, never a swallowed character (PLAN.md §6).
    private static func flatten(_ items: [Item]) -> [MarkdownInline] {
        var nodes: [MarkdownInline] = []
        for item in items {
            switch item {
            case let .node(node): append(node, to: &nodes)
            case let .delimiter(delimiter):
                guard delimiter.length > 0 else { continue }
                append(
                    .text(String(repeating: delimiter.marker, count: delimiter.length)),
                    to: &nodes
                )
            }
        }
        return nodes
    }

    /// Merge adjacent text rather than emitting a node per fragment. The renderer would produce the
    /// same HTML either way; a *test* would not, and an assertion listing six one-character nodes
    /// says nothing about what the parser understood.
    private static func append(_ node: MarkdownInline, to nodes: inout [MarkdownInline]) {
        if case let .text(incoming) = node, case let .text(existing)? = nodes.last {
            nodes[nodes.count - 1] = .text(existing + incoming)
            return
        }
        nodes.append(node)
    }
}
