import Foundation

/// What kind of row a colour rule is allowed to claim (PLAN.md §M15 Slice 3).
///
/// A name glob cannot express "every folder" — a folder is ordinarily named like anything else, so
/// `*` would take every file with it. This is the one thing the pattern genuinely cannot say, which
/// is why it is a field rather than a convention, and colouring folders apart from files is one of
/// the first things a Total Commander user reaches for.
///
/// Raw `String` rather than an `Int`, and read back tolerantly (see `FileColorRule.init(from:)`):
/// the whole rule list is one JSON value, so a `Codable` enum throwing on a case a newer build wrote
/// would take *every* rule down with it — the trap PLAN.md §M15 Slice 1 already recorded for
/// `PersistedTab.viewMode`.
public enum FileColorTarget: String, Sendable, Hashable, CaseIterable, Codable {
    /// Files and folders alike — the default, and what a plain `*.jpg` rule means.
    case any
    case filesOnly
    case foldersOnly

    /// Whether a row of this kind is eligible for a rule carrying this target.
    ///
    /// `isDirectory` is the *caller's* judgement, not a re-derivation: the app hands over
    /// `FileEntry.isDirectoryLike`, so a symlink pointing at a folder is coloured as the folder it
    /// opens into — which is what the pane does with it everywhere else.
    public func admits(isDirectory: Bool) -> Bool {
        switch self {
        case .any: return true
        case .filesOnly: return !isDirectory
        case .foldersOnly: return isDirectory
        }
    }
}

/// One colour rule: some globs, and the colour a row matching any of them draws in.
///
/// **The colour rides as user data (`#RRGGBB`), not as a decision this module authored** — the
/// `FinderTag` split, where the core carries the colour and the app maps it to pixels. Nothing here
/// resolves a colour or produces a display string, so nothing here is a presentation choice that
/// could never be translated (NOTES.md ▸ Localization).
///
/// Identity is a `UUID`, unlike `SavedSearch`/`UserScript`, whose identity is their name. Those are
/// looked up by name; a colour rule never is, and neither its name nor its patterns are unique by
/// nature — two rules legitimately claim `*.txt` with different targets, and a user is free to leave
/// both unnamed. So a stable id is what lets an editor reorder and delete without acting on the
/// wrong row.
public struct FileColorRule: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID

    /// What the user calls this rule ("Images", "Archives"), or empty to let a list fall back to
    /// showing the patterns themselves. Never translated — it is the user's own text.
    public var name: String

    /// The globs, in the `Glob` dialect `+`/`-` pattern select already uses — `*`, `?` and `[…]`,
    /// matched case-insensitively against the **name alone**, never the path.
    ///
    /// A list rather than one string so "Images" is one rule with one colour. Any pattern matching
    /// is enough; an empty list never matches, which is what a rule being typed into an editor looks
    /// like and is the harmless direction for it to fail in.
    public var patterns: [String]

    /// `#RRGGBB`. Kept as the string the user's defaults hold, not parsed here: this module has no
    /// colour type, and a value it cannot make sense of is the app's to degrade (it draws no colour
    /// at all), exactly as a hand-edited palette hex already does.
    public var colorHex: String

    public var target: FileColorTarget

    public init(
        id: UUID = UUID(),
        name: String = "",
        patterns: [String] = [],
        colorHex: String = "",
        target: FileColorTarget = .any
    ) {
        self.id = id
        self.name = name
        // Trimmed and de-emptied on the way in, the way `UserScripts` sanitizes its store: a
        // trailing separator in the editor's field ("*.jpg;") would otherwise leave an empty
        // pattern, and `fnmatch("", …)` is a rule that matches nothing but costs a call per row.
        self.patterns = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.colorHex = colorHex
        self.target = target
    }

    /// Whether `name` matches any of this rule's patterns, ignoring the target.
    ///
    /// Case-insensitive, through the very same `Glob` that `+`/`-` pattern select uses — deliberately
    /// the same primitive rather than a faster private one, so a pattern a user has already learned
    /// in the select prompt means the identical thing here.
    ///
    /// **A malformed pattern matches nothing rather than everything.** Probed: `fnmatch` answers its
    /// error code (2), not `FNM_NOMATCH`, for `[`, `[a-` and a lone `\`, and `Glob` tests for `== 0`
    /// — so a half-typed `[` in a live editor quietly colours nothing while the user keeps typing,
    /// instead of flooding the pane. Worth stating because the failure is silent either way, and only
    /// one of the two directions is survivable.
    public func matches(name: String) -> Bool {
        patterns.contains { Glob.matches($0, name) }
    }
}

// MARK: - Tolerant decoding
//
// In a same-file extension so SwiftLint's `type_body_length` doesn't count it against the type.

extension FileColorRule {
    private enum CodingKeys: String, CodingKey {
        case id, name, patterns, colorHex, target
    }

    /// Every field degrades rather than throws, because **the whole rule list is one JSON value**:
    /// a single throw anywhere in it takes every rule the user ever wrote, not just the odd one.
    /// That is the same failure PLAN.md §M15 Slice 1 designed around for `PersistedTab.viewMode`,
    /// one level up — there a bad tab dropped out of the session, here a bad *anything* would empty
    /// the list.
    ///
    /// An unrecognised `target` becomes `.any` rather than dropping the rule: a rule that colours
    /// more than it should is visible and one popup away from being fixed, where a rule that
    /// silently vanished leaves nothing to fix. Same call `AppPreferences` makes reading
    /// `rowDensity`, and the reason a missing `id` is replaced rather than fatal — a hand-edited
    /// store is a supported thing to have (PLAN.md §2, "boring and debuggable").
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? container.decode(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? container.decode(String.self, forKey: .name)) ?? "",
            patterns: (try? container.decode([String].self, forKey: .patterns)) ?? [],
            colorHex: (try? container.decode(String.self, forKey: .colorHex)) ?? "",
            target: (try? container.decode(String.self, forKey: .target))
                .flatMap(FileColorTarget.init(rawValue:)) ?? .any
        )
    }
}
