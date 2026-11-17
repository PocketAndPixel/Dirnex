import Foundation

/// `[[name]]`, a link to another note by its name (PLAN.md §M39 ▸ Slice 7).
///
/// Obsidian's spelling, which Foam and MediaWiki share: `[[name]]`, `[[name|text]]` drawn as
/// `text`, and `[[name#Heading]]` or `[[#Heading]]` naming a heading by its text. `.md` is added
/// when the name has none, so `[[dirnex-project-goal]]` is `dirnex-project-goal.md`. GitHub's wikis
/// put the text first (`[[text|name]]`); that order is not read.
///
/// ## A link only when what it names is there
///
/// The real wiki links on this Mac are Claude's memory notes, each naming a sibling `.md`. The same
/// brackets turn up as prose more often: JavaScript READMEs write `[[Prototype]]` and `[[Get]]s` for
/// the spec's internal slots, and this repository's HISTORY.md writes
/// `[[swift-testing-expect-optional-arithmetic]]-adjacent`, naming a note that is not in it. GitHub
/// draws all of them as the text they are. So `[[name]]` is a link only when its file exists beside
/// the document, and `[[#Heading]]` only when the document has that heading; anything else stays
/// its own text, as a footnote's reference with no definition does (Oleg's call, 2026-11-14). Which
/// files exist is the app's to say (`MarkdownRenderOptions.locateFile`), since the render does no
/// I/O and only the app knows whether the document is on this disk or on a server it holds a
/// listing of. The app answers with the name as the file spells it, so `[[Note]]` on a disk that
/// ignores case links to `note.md` and the click lands on that row.
///
/// ## Where the name is looked for
///
/// In the document's own folder, or along the path written in the name, relative to the document:
/// the `href` written into the page is that relative path, so a click goes through
/// `DocumentLink.resolve(_:from:)` and the pane moves as it does for any link. Obsidian searches a
/// whole vault for the name; that walk is not made (Oleg's call, 2026-11-14), and a name written
/// with a leading `/`, a path from the vault's root, is text.
///
/// Two neighbours win over a wiki link, as on GitHub: a link whose text is in brackets
/// (`[[0.1.0]](#010)`, `[[#4995]](https://…)`, both common in changelogs), and anything inside a
/// code span. A heading's anchor is made from the heading's text as written, brackets and all, so a
/// heading holding a wiki link anchors as GitHub would anchor it.
enum MarkdownWikiLink {
    /// What one `[[…]]` says, before anything is asked about what exists.
    struct Reference: Equatable {
        /// The name as written, trimmed; empty for `[[#Heading]]`, which is the document itself.
        let name: String
        /// The heading after the last `#`, as written: its text, not its anchor. Obsidian nests
        /// headings as `[[name#Part#Section]]`, and the last is the one to land on.
        let heading: String?
        /// The text after `|`, drawn in place of the name.
        let label: String?
        /// What is drawn when there is no label: the name and heading as written.
        let written: String
    }

    /// What a wiki link is checked against: the files beside the document and its own anchors.
    ///
    /// A class so its answers are kept for the whole render: a note that names the same file fifty
    /// times asks about it once, and over a server the question is a lookup in a listing anyway.
    final class Lookup {
        private let locateFile: (String) -> String?
        let anchors: Set<String>
        private var answers: [String: String?] = [:]

        init(locateFile: @escaping (String) -> String?, anchors: Set<String>) {
            self.locateFile = locateFile
            self.anchors = anchors
        }

        /// The file `path` names, spelled as it is, or `nil` when there is none.
        func locate(_ path: String) -> String? {
            if let answer = answers[path] { return answer }
            let answer = locateFile(path)
            answers[path] = answer
            return answer
        }
    }

    /// The link the `[[…]]` at `start` draws, and the index after its `]]`, when what it names is
    /// there.
    static func take(
        in characters: [Character],
        at start: Int,
        lookup: Lookup
    ) -> (MarkdownInline, Int)? {
        guard let (reference, end) = reference(in: characters, at: start) else { return nil }
        let anchor = reference.heading.map(MarkdownSlug.slug(for:)).flatMap { $0.isEmpty ? nil : $0 }
        let destination: String
        if reference.name.isEmpty {
            guard let anchor, lookup.anchors.contains(anchor) else { return nil }
            destination = "#" + encoded(anchor, keeping: unreserved)
        } else {
            guard let path = candidates(for: reference.name).lazy.compactMap(lookup.locate).first
            else { return nil }
            destination = encoded(path, keeping: pathCharacters)
                + (anchor.map { "#" + encoded($0, keeping: unreserved) } ?? "")
        }
        let text = reference.label ?? reference.written
        return (.link(destination: destination, title: nil, children: [.text(text)]), end)
    }

    /// The `[[…]]` at `start`, read but not resolved, and the index after its `]]`.
    ///
    /// Bounded by the line, and holding no bracket: `[[a] b]]` is two brackets of prose, and a
    /// wiki link never wraps.
    static func reference(in characters: [Character], at start: Int) -> (Reference, Int)? {
        guard start + 1 < characters.count, characters[start] == "[", characters[start + 1] == "["
        else { return nil }
        var close = start + 2
        while close < characters.count, characters[close] != "]" {
            guard characters[close] != "[", characters[close] != "\n" else { return nil }
            close += 1
        }
        guard close + 1 < characters.count, characters[close + 1] == "]" else { return nil }
        let end = close + 2
        // `[[0.1.0]](#010)` is a link whose text is `[0.1.0]`, as on GitHub.
        if end < characters.count, characters[end] == "(" || characters[end] == "[" { return nil }
        return parse(String(characters[(start + 2)..<close])).map { ($0, end) }
    }

    /// The parts of what is between the brackets, or `nil` when it names nothing.
    static func parse(_ inner: String) -> Reference? {
        let (target, label) = split(inner, at: "|")
        let written = target.trimmingCharacters(in: .whitespaces)
        let (name, rest) = split(written, at: "#")
        let heading = rest?.split(separator: "#", omittingEmptySubsequences: false).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.hasPrefix("/") else { return nil }
        guard !trimmedName.isEmpty || heading?.isEmpty == false else { return nil }
        return Reference(
            name: trimmedName,
            heading: heading?.isEmpty == true ? nil : heading,
            label: label.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
            written: written
        )
    }

    /// The paths `name` may be, in the order they are tried: a note first, as Obsidian tries it, then
    /// the name as written, which is how `[[diagram.png]]` or `[[LICENSE]]` names a file.
    static func candidates(for name: String) -> [String] {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".md") || lowered.hasSuffix(".markdown") { return [name] }
        return [name + ".md", name]
    }

    private static func split(_ text: String, at separator: Character) -> (String, String?) {
        guard let index = text.firstIndex(of: separator) else { return (text, nil) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    private static func encoded(_ text: String, keeping allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// RFC 3986's `pchar` and `/`, less `:`: a name like `Notes: May` would otherwise open the
    /// `href` with a scheme.
    private static let pathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=@/"
    )

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}
