import Foundation

/// One tracked directory in the frecency index (PLAN.md §M3 "Frecency jump …
/// zoxide-style scoring"): where it is, how often it has been visited (`rank`), and when
/// it was last visited (`lastAccess`). The two together produce the *frecency* score —
/// frequency weighted by recency — so a folder you opened ten times last month ranks below
/// one you opened twice this morning.
public struct FrecencyEntry: Sendable, Hashable, Codable {
    /// The visited directory — and the entry's identity: a path is tracked at most once.
    public let path: VFSPath
    /// Accumulated visit weight. Bumped by one on each visit and decayed by aging; an
    /// entry that ages below 1 is dropped, so the index stays bounded.
    public var rank: Double
    /// When the directory was last visited, driving the recency multiplier in `score`.
    public var lastAccess: Date

    public init(path: VFSPath, rank: Double, lastAccess: Date) {
        self.path = path
        self.rank = rank
        self.lastAccess = lastAccess
    }
}

/// A zoxide-style frecency index over the directories the user has visited — the model
/// behind the path bar's fuzzy jump (PLAN.md §M3 "path bar accepts fuzzy fragments
/// ('dl' → ~/Downloads)").
///
/// A pure value type with no persistence or AppKit: the app owns the store (JSON in
/// `UserDefaults`, like `TabPersistence`/`FavoritesStore`; the plan pencils in SQLite for
/// when undo shares the DB) and the path-bar UI, this owns the scoring and matching rules
/// so they stay unit-testable headless (matching `Panel`, `Favorites`, `NavigationHistory`).
///
/// Scoring follows zoxide: each visit adds one to a directory's `rank`, and the score a
/// query ranks by is that rank scaled by a recency multiplier (visited within the hour
/// counts far more than a month ago). Aging keeps the total rank bounded so the index
/// can't grow without limit no matter how long the app runs.
public struct Frecency: Sendable, Equatable, Codable {
    /// The tracked directories, de-duplicated by path. Order is not significant — queries
    /// sort by score — so this is stored as a flat list for simple `Codable` round-tripping.
    public private(set) var entries: [FrecencyEntry]
    /// The rank budget: once the summed rank of every entry exceeds this, aging scales them
    /// all down (and drops those that fall below 1), so a long-lived index stays small.
    /// zoxide's default of 10,000 caps the index at roughly that many entries in the worst
    /// case and far fewer in practice.
    public let maxAge: Double

    public init(entries: [FrecencyEntry] = [], maxAge: Double = 10_000) {
        // Collapse duplicate paths on the way in (a hand-edited or legacy store), keeping the
        // first occurrence so a path maps to a single entry.
        var seen = Set<VFSPath>()
        self.entries = entries.filter { seen.insert($0.path).inserted }
        self.maxAge = max(maxAge, 1)
    }

    // MARK: - Recording

    /// Record a visit to `path`: bump its rank (or start it at 1 if new) and stamp
    /// `lastAccess`, then age the index if the rank budget is spent. Every successful
    /// navigation calls this, so the index learns from crumb clicks, the sidebar, favorites
    /// jumps, and back/forward alike — a visit is a visit.
    public mutating func visit(_ path: VFSPath, now: Date = Date()) {
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index].rank += 1
            entries[index].lastAccess = now
        } else {
            entries.append(FrecencyEntry(path: path, rank: 1, lastAccess: now))
        }
        age()
    }

    // MARK: - Scoring

    /// The frecency score for `entry` at time `now` — its rank scaled by how recently it was
    /// visited. The recency buckets match zoxide: within the last hour weighs 4×, the last
    /// day 2×, the last week ½×, and anything older ¼×. A negative interval (a clock moved
    /// backwards, or an entry stamped in the future) falls into the most-recent bucket.
    public func score(for entry: FrecencyEntry, now: Date = Date()) -> Double {
        let elapsed = now.timeIntervalSince(entry.lastAccess)
        let multiplier: Double
        switch elapsed {
        case ..<3600: multiplier = 4 // within the hour
        case ..<86_400: multiplier = 2 // within the day
        case ..<604_800: multiplier = 0.5 // within the week
        default: multiplier = 0.25 // older
        }
        return entry.rank * multiplier
    }

    // MARK: - Matching

    /// The tracked directories whose final path component fuzzily matches `query`, best
    /// first. `query` is a slash-free fragment (the path bar routes real paths straight to
    /// the filesystem and only falls back here for a bare word), matched as a
    /// case-insensitive subsequence of the folder name — so "dl" finds "Downloads". Ranking
    /// is by frecency score, then most-recent, then path for a stable order.
    public func matches(for query: String, now: Date = Date()) -> [FrecencyEntry] {
        let needle = Array(query.trimmingCharacters(in: .whitespaces).lowercased())
        guard !needle.isEmpty else { return [] }
        return entries
            .filter { Frecency.isSubsequence(needle, of: Array($0.path.lastComponent.lowercased())) }
            .sorted { lhs, rhs in
                let lhsScore = score(for: lhs, now: now)
                let rhsScore = score(for: rhs, now: now)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.lastAccess != rhs.lastAccess { return lhs.lastAccess > rhs.lastAccess }
                return lhs.path.path < rhs.path.path
            }
    }

    /// Whether `needle` appears in `haystack` as a left-to-right subsequence (each character
    /// in order, gaps allowed). Both are expected pre-lowercased.
    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        var index = 0
        for character in haystack where index < needle.count {
            if character == needle[index] { index += 1 }
        }
        return index == needle.count
    }

    // MARK: - Aging

    /// Keep the index bounded (zoxide's aging): once the summed rank exceeds `maxAge`, scale
    /// every rank down by `0.9 · maxAge / total` and drop entries that fall below 1. This
    /// both caps growth and lets stale directories decay out of the index over time.
    private mutating func age() {
        let total = entries.reduce(0.0) { $0 + $1.rank }
        guard total > maxAge else { return }
        let factor = 0.9 * maxAge / total
        for index in entries.indices {
            entries[index].rank *= factor
        }
        entries.removeAll { $0.rank < 1 }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case entries
        case maxAge
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the de-duplicating initializer so a legacy/corrupt store is
        // sanitized on the way back in; a store written before `maxAge` existed uses the default.
        let entries = try container.decode([FrecencyEntry].self, forKey: .entries)
        let maxAge = try container.decodeIfPresent(Double.self, forKey: .maxAge) ?? 10_000
        self.init(entries: entries, maxAge: maxAge)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(maxAge, forKey: .maxAge)
    }
}
