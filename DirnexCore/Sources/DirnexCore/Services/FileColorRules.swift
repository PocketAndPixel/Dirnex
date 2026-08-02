import Foundation

/// An ordered list of colour rules — Total Commander's signature "define colours by file type"
/// (PLAN.md §M15 Slice 3). A pure value type with no persistence and no AppKit: the app owns the
/// `UserDefaults` store and the editor, this owns the ordering and the matching, so both stay
/// unit-testable headless (matching `UserScripts`, `SavedSearches` and `Workspaces`).
///
/// **Order is meaning, and the list is never silently canonicalized** — the same rule an ACL's entry
/// order follows (NOTES.md ▸ ACLs: "a deny before an allow is a different ACL"). First match wins,
/// so a user puts the specific rule above the general one and that arrangement is the whole content
/// of their intent. Nothing here sorts, dedupes or merges: two rules claiming `*.txt` are two rules,
/// and the second one is simply unreachable — which is a thing a user is allowed to build, and to
/// see, while dragging the first one out of the way.
public struct FileColorRules: Sendable, Equatable, Codable {
    /// The rules in user order — the order the editor presents and `firstMatch` walks.
    public private(set) var rules: [FileColorRule]

    public init(rules: [FileColorRule] = []) {
        // No de-duplication, unlike `UserScripts`/`SavedSearches`: those key on a name that *is*
        // identity, where a duplicate is a store that lost information. Here a repeated pattern is
        // legal and the id is already unique by construction, so the only repair worth making is
        // against a hand-edited store that duplicated an id outright — which would make an editor
        // act on the wrong row.
        var seen = Set<UUID>()
        self.rules = rules.filter { seen.insert($0.id).inserted }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// The first rule that claims a row with this name and kind, or `nil` when none does.
    ///
    /// The order of the two tests is deliberate: the **target** is checked first because it is a
    /// `Bool` comparison, where a pattern is an `fnmatch` call — measured at **263 ns**, and the
    /// dominant cost by far (the `String`→C bridging around it adds ~3 ns, and `Glob`'s case-folding
    /// ~84 ns, so there is no cheap trick inside the matcher; the only lever is calling it less). A
    /// "folders only" rule in a pane of files therefore costs nothing per row.
    ///
    /// The app asks this **once per cell**, which means four times per row — measured rather than
    /// assumed, because the alternative is a memo with an invalidation rule. Over a 60-row screen,
    /// worst case (nothing matches, so every rule runs to the end): an empty list is free, five
    /// rules of two patterns cost **0.46 ms** per full reload and twenty rules of three cost
    /// **2.44 ms**, against 0.10 / 0.53 ms for a per-entry memo. A reload that is already building
    /// 240 views and looking up an icon per row can afford the difference, and an untouched install
    /// — no rules at all — pays nothing whatsoever. Revisit with a memo if a real config ever
    /// measures slow; don't add one on suspicion.
    ///
    /// `isDirectory` is the caller's to decide — see `FileColorTarget.admits(isDirectory:)`.
    public func firstMatch(name: String, isDirectory: Bool) -> FileColorRule? {
        rules.first { $0.target.admits(isDirectory: isDirectory) && $0.matches(name: name) }
    }

    /// The same, for a listing row. Uses `isDirectoryLike`, so a symlink to a folder is coloured as
    /// the folder it opens into — matching what every other pane behaviour does with it.
    public func firstMatch(for entry: FileEntry) -> FileColorRule? {
        firstMatch(name: entry.name, isDirectory: entry.isDirectoryLike)
    }

    // MARK: - Editing

    /// Append a rule at the end — where a new rule is least likely to shadow an existing one, since
    /// first match wins and the general rules a user writes late would otherwise swallow the
    /// specific ones they wrote first.
    public mutating func append(_ rule: FileColorRule) {
        rules.append(rule)
    }

    /// Replace the rule with `rule`'s id, if it is still there. Returns whether one was replaced —
    /// `false` means the editor was holding a rule that has since been deleted, which is the case a
    /// commit-on-focus-loss can genuinely reach.
    @discardableResult
    public mutating func update(_ rule: FileColorRule) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return false }
        rules[index] = rule
        return true
    }

    /// Delete the rule at `index`; out of range is ignored, matching `UserScripts.remove(at:)`.
    public mutating func remove(at index: Int) {
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
    }

    /// Reorder: pull the rule out of `source` and reinsert it so it lands at `destination` in the
    /// *resulting* list (Array semantics, matching the script/server/saved-search reorders).
    public mutating func move(from source: Int, to destination: Int) {
        guard rules.indices.contains(source) else { return }
        let rule = rules.remove(at: source)
        rules.insert(rule, at: min(max(destination, 0), rules.count))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case rules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route through the initializer above so a hand-edited store is repaired on the way in.
        self.init(rules: try container.decode([FileColorRule].self, forKey: .rules))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules, forKey: .rules)
    }
}
