import Foundation

/// A heading's anchor, spelled the way GitHub spells it (PLAN.md §M18 ▸ Slice 2).
///
/// There is no specification for this — GitHub's rule is whatever `github-slugger` does — so it was
/// **measured** rather than derived (§"How to work here"). The oracle was 211 real `.md` files on
/// this Mac carrying 2282 hand-written `](#…)` links: a table of contents somebody wrote by copying
/// the anchors GitHub had actually produced. Three candidate rules were scored against it, and the
/// one below resolved every link either of the others did plus **25 more**, with none going the
/// other way.
///
/// Two things the probe settled that reading the rule would have got wrong:
///
/// - **Nothing is trimmed.** `## 🐛 Bugs` really does anchor as `#-bugs` and `## Contributors ✨` as
///   `#contributors-` — the emoji leaves, and the space beside it becomes a hyphen with nothing on
///   the far side of it. Both spellings appear in the corpus as links that resolve, so tidying the
///   leading and trailing hyphens away — which is the obvious improvement — breaks real documents.
/// - **The rule is an allow-list.** `github-slugger`'s published regex is a *block-list* of
///   punctuation, which leaves emoji in the slug; keeping only letters, digits, spaces, hyphens and
///   underscores is what accounts for all 25. It also keeps non-Latin headings working, since every
///   Cyrillic or CJK character is a letter.
enum MarkdownSlug {
    /// The anchor for a heading's **text content** — inline markup already flattened away, which is
    /// what `MarkdownInlineParser.plainText` produces.
    ///
    /// Whitespace other than a space becomes a hyphen too. A setext heading may genuinely span two
    /// lines, so its text can carry a newline, and dropping it would run two words together.
    static func slug(for text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                result.append(character)
            } else if character.isWhitespace {
                result.append("-")
            }
        }
        return result
    }
}

/// One document's worth of anchors, with duplicates resolved (PLAN.md §M18 ▸ Slice 2).
///
/// A value type carried through one traversal of the block tree, so every heading in a file is
/// numbered against the same table. The suffix rule is GitHub's and is not "append the count": a
/// second `## Usage` becomes `usage-1`, and if the author *also* wrote a heading that already slugs
/// to `usage-1` the counter keeps going until the result is free. That loop is not defensive
/// programming — the probe found real files linking to `#all`, `#all-1` **and** `#all-2`, which is
/// exactly the shape it produces.
struct MarkdownSlugger {
    /// Every slug handed out so far, mapped to how many suffixed variants of it have been used.
    private var occurrences: [String: Int] = [:]

    mutating func next(for text: String) -> String {
        let base = MarkdownSlug.slug(for: text)
        // A heading with nothing sluggable in it — `## !!!`, or one that is a single emoji — gets no
        // anchor and takes no place in the numbering. There is nothing to link to, and an `id=""` is
        // a broken attribute rather than a usable one.
        guard !base.isEmpty else { return "" }
        var result = base
        while occurrences[result] != nil {
            let count = (occurrences[base] ?? 0) + 1
            occurrences[base] = count
            result = "\(base)-\(count)"
        }
        occurrences[result] = 0
        return result
    }
}
