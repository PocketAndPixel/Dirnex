import Foundation

// Spotlight-backed file search (PLAN.md §M4 "Search (Alt+F7 / palette): mdfind-backed
// name+content search with filter chips (kind, size, date, tag)").
//
// This is the pure *query-building* half: a `SpotlightQuery` value describes what the user is
// looking for and renders it into the raw `kMDItem…` metadata predicate `mdfind` understands,
// plus the full argument vector for the `mdfind` CLI. It touches no disk and runs no process
// (so it stays unit-testable without a Spotlight index or a subprocess); the app runs `mdfind`
// with these arguments off the main thread and stats the resulting paths into a virtual panel.
//
// Mirrors `MultiRename`: the tested planning logic lives here; the non-hermetic I/O (spawning
// `mdfind`, statting results) lives in the app layer, like `DirectoryLoader`.

// MARK: - Filter chips

/// The kind-of-file filter chip. Each maps to a Uniform Type Identifier that `mdfind` matches
/// against `kMDItemContentTypeTree`, so a file conforming to that type (a PNG under
/// `public.image`, a folder under `public.folder`) matches.
public enum SearchKind: String, Sendable, Equatable, CaseIterable, Codable {
    case folder
    case image
    case audio
    case movie
    case document
    case archive

    /// The UTI a `kMDItemContentTypeTree` comparison tests conformance to.
    public var contentType: String {
        switch self {
        case .folder: return "public.folder"
        case .image: return "public.image"
        case .audio: return "public.audio"
        case .movie: return "public.movie"
        case .document: return "public.content"
        case .archive: return "public.archive"
        }
    }

    /// The user-facing label for the chip / popup.
    public var title: String {
        switch self {
        case .folder: return "Folders"
        case .image: return "Images"
        case .audio: return "Audio"
        case .movie: return "Movies"
        case .document: return "Documents"
        case .archive: return "Archives"
        }
    }
}

/// The "modified within" date chip — a rolling window ending now, expressed to `mdfind` as a
/// relative offset from `$time.now` so the predicate stays deterministic (no wall-clock literal
/// baked into the query string).
public enum SearchAge: String, Sendable, Equatable, CaseIterable, Codable {
    case today
    case week
    case month
    case year

    /// Seconds in the window — the negative offset applied to `$time.now`. A month is 30 days
    /// and a year 365; the exactness doesn't matter for a "recently changed" filter.
    public var seconds: Int {
        switch self {
        case .today: return 86_400
        case .week: return 604_800
        case .month: return 2_592_000
        case .year: return 31_536_000
        }
    }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Past week"
        case .month: return "Past month"
        case .year: return "Past year"
        }
    }
}

// MARK: - Query

/// A file search described as data. Any combination of the fields narrows the result set (they
/// AND together); an all-empty query is `isEmpty` and produces no predicate, so the search UI
/// disables "Find" until the user asks for something.
public struct SpotlightQuery: Sendable, Equatable, Codable {
    /// Substring matched (case- and diacritic-insensitively) against the file *name*.
    public var nameContains: String
    /// Substring matched against the indexed text *content* of the file.
    public var contentContains: String
    /// Kind chips; an item matches when it conforms to *any* selected kind (they OR together,
    /// then AND with the rest of the query). Empty = any kind.
    public var kinds: Set<SearchKind>
    /// Only items at least this many bytes. `nil` = any size.
    public var minSizeBytes: Int64?
    /// Only items changed within this rolling window. `nil` = any date.
    public var modifiedWithin: SearchAge?
    /// Finder tag chips, matched by name. An item must carry **every** selected tag (they AND
    /// together, unlike the kind chips) — narrowing is what a second chip is for; a user adding
    /// "Urgent" to "Work" is asking for the overlap, not for more results. Empty = any tags.
    ///
    /// Only names are matched, because only names are indexed: Spotlight reports
    /// `kMDItemUserTags = (Red)` with no colour, for a tag written either way. That suits the chip
    /// — tags are identified by name anyway (`FinderTag`), and the colour is the swatch the chip
    /// draws itself with, not part of the question.
    public var tags: Set<String>

    public init(
        nameContains: String = "",
        contentContains: String = "",
        kinds: Set<SearchKind> = [],
        minSizeBytes: Int64? = nil,
        modifiedWithin: SearchAge? = nil,
        tags: Set<String> = []
    ) {
        self.nameContains = nameContains
        self.contentContains = contentContains
        self.kinds = kinds
        self.minSizeBytes = minSizeBytes
        self.modifiedWithin = modifiedWithin
        self.tags = tags
    }

    /// Nothing to search for — every field is at its neutral default. The search UI treats this
    /// as "Find" disabled, and `metadataPredicate()` returns `nil`.
    public var isEmpty: Bool {
        trimmedName.isEmpty && trimmedContent.isEmpty
            && kinds.isEmpty && minSizeBytes == nil && modifiedWithin == nil && trimmedTags.isEmpty
    }

    /// Tag names with the empties and stray whitespace dropped, in a stable order so a predicate
    /// built from a `Set` is deterministic and testable.
    private var trimmedTags: [String] {
        tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var trimmedName: String {
        nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedContent: String {
        contentContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Predicate

    /// The raw `mdfind` metadata query, or `nil` when the query is empty. Clauses are ANDed in a
    /// fixed order so the output is deterministic and testable: name, content, kind, size, date.
    public func metadataPredicate() -> String? {
        var clauses: [String] = []

        let name = trimmedName
        if !name.isEmpty {
            clauses.append(#"kMDItemFSName == "*\#(Self.escape(name))*"cd"#)
        }
        let content = trimmedContent
        if !content.isEmpty {
            clauses.append(#"kMDItemTextContent == "*\#(Self.escape(content))*"cd"#)
        }
        if let kindClause = kindClause() {
            clauses.append(kindClause)
        }
        if let minSizeBytes {
            clauses.append("kMDItemFSSize >= \(minSizeBytes)")
        }
        if let modifiedWithin {
            clauses.append("kMDItemFSContentChangeDate >= $time.now(-\(modifiedWithin.seconds))")
        }
        // One clause per tag rather than one OR group: each must match, and Spotlight compares a
        // multi-valued attribute member-wise, so `kMDItemUserTags == "Work"` is already "carries
        // Work among its tags". Case-insensitive (`c`) to match how the system identifies a tag,
        // but *not* diacritic-insensitive: `Café` and `Cafe` are two different tags to macOS.
        for tag in trimmedTags {
            clauses.append(#"kMDItemUserTags == "\#(Self.escape(tag))"c"#)
        }

        return clauses.isEmpty ? nil : clauses.joined(separator: " && ")
    }

    /// A parenthesized OR over the selected kinds' UTIs (in `SearchKind.allCases` order so it is
    /// deterministic), or `nil` when no kind chip is set.
    private func kindClause() -> String? {
        let selected = SearchKind.allCases.filter { kinds.contains($0) }
        guard !selected.isEmpty else { return nil }
        let terms = selected.map { #"kMDItemContentTypeTree == "\#($0.contentType)"c"# }
        return "(" + terms.joined(separator: " || ") + ")"
    }

    /// The full argument vector for `/usr/bin/mdfind`. `scopePath`, when given, limits the search
    /// to that directory subtree via `-onlyin`; `nil` searches every indexed volume. Returns an
    /// empty array for an empty query (the caller guards on `isEmpty` and never runs it).
    public func mdfindArguments(scopePath: String? = nil) -> [String] {
        guard let predicate = metadataPredicate() else { return [] }
        var arguments: [String] = []
        if let scopePath, !scopePath.isEmpty {
            arguments += ["-onlyin", scopePath]
        }
        arguments.append(predicate)
        return arguments
    }

    // MARK: - Presentation

    /// Which term of a query stands for the whole of it — the *fact* behind the label the panel
    /// title, the path-bar crumb and the "Save Search…" default are all built from.
    ///
    /// Deliberately not a finished string: a label reading "Search results" or a bare `SearchKind
    /// .title` is a sentence this module cannot translate, and it went to the screen in English out
    /// of a fully translated catalog (docs/NOTES.md). The core picks the term, the app picks the
    /// words — the `SyncBadgeStyle` split, applied to a query.
    public enum SummaryTerm: Sendable, Equatable {
        /// The name substring the user typed.
        case name(String)
        /// The content substring the user typed.
        case content(String)
        /// The one kind filter, when it is the only one.
        case kind(SearchKind)
        /// The one tag filter, when it is the only one. Reached by `plainNameTerm` alone.
        case tag(String)
        /// Nothing specific enough to name — a size or date filter on its own.
        case generic
    }

    /// The most specific term the user gave, for the panel title and path-bar crumb.
    public var summaryTerm: SummaryTerm {
        let name = trimmedName
        if !name.isEmpty { return .name(name) }
        let content = trimmedContent
        if !content.isEmpty { return .content(content) }
        if kinds.count == 1, let only = kinds.first { return .kind(only) }
        return .generic
    }

    /// The same precedence, plus a lone tag — the prefill for the "Save Search…" name field, where
    /// a tag is a perfectly good name for the search even though it is a poor crumb.
    public var plainNameTerm: SummaryTerm {
        let term = summaryTerm
        guard case .generic = term else { return term }
        if let onlyTag = trimmedTags.first, trimmedTags.count == 1 { return .tag(onlyTag) }
        return .generic
    }

    // MARK: - Codable

    // Hand-rolled purely so `tags` can arrive absent. A saved search persisted before this field
    // existed has no `tags` key, and the synthesized decoder throws on that — which would not fail
    // loudly, it would make every search the user had already saved disappear from the sidebar on
    // upgrade. New fields on a persisted value are a compatibility question, not a syntax one.
    private enum CodingKeys: String, CodingKey {
        case nameContains, contentContains, kinds, minSizeBytes, modifiedWithin, tags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nameContains = try container.decode(String.self, forKey: .nameContains)
        contentContains = try container.decode(String.self, forKey: .contentContains)
        kinds = try container.decode(Set<SearchKind>.self, forKey: .kinds)
        minSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .minSizeBytes)
        modifiedWithin = try container.decodeIfPresent(SearchAge.self, forKey: .modifiedWithin)
        tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
    }

    /// Escape the characters that are special inside an `mdfind` double-quoted string literal —
    /// a backslash and a double quote — so a search term containing them can't break out of the
    /// literal or corrupt the predicate.
    private static func escape(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
