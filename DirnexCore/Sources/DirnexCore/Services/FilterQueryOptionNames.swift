import Foundation

/// What a ``FilterQuery/Options`` set is **stored** as, so the bar's two toggles can be remembered
/// across surfaces and launches (2026-09-18).
///
/// Names rather than the option set's own `rawValue`, for a reason that is about the core and not
/// about tidiness: those bits are an implementation detail this type has never promised to keep, and
/// writing them into a preferences domain would quietly make the bit layout a compatibility surface
/// — the shape ``VFSPath`` and `PersistedTab` already avoid by storing a raw *string* and reading it
/// back tolerantly. A name also says what it is in a `defaults read`, where `3` does not.
///
/// The read drops a name this build has never heard of, so a domain written by a newer build (or by
/// hand) degrades to the options that do exist rather than trapping. It needs no defensive code of
/// its own above this: `UserDefaults.stringArray(forKey:)` answers `nil` — never a partial value —
/// for a number, a bare string, an array of numbers *and* an array that is only partly strings
/// (measured 2026-09-18), so a half-corrupt value falls back to the default rather than half-applying.
public extension FilterQuery.Options {
    /// Every option this build has.
    ///
    /// Spelled out because an `OptionSet` has no `allCases`. It is what ``storedNames`` and the bar's
    /// menu are both checked against, so an option added here without a name or without a title fails
    /// a test rather than being silently unstorable and unofferable.
    static let all: FilterQuery.Options = [.caseSensitive, .wholeWord, .pattern]

    /// Every option paired with the name it is stored under. The names are API the moment one is
    /// written to disk, so they are never renamed — a new one is added.
    static let named: [(option: FilterQuery.Options, name: String)] = [
        (.caseSensitive, "caseSensitive"),
        (.wholeWord, "wholeWord"),
        (.pattern, "pattern")
    ]

    /// The names of the options that are on, in ``named`` order.
    var storedNames: [String] {
        Self.named.filter { contains($0.option) }.map(\.name)
    }

    /// The options `storedNames` names, ignoring any this build does not know.
    init(storedNames: [String]) {
        self = Self.named.reduce(into: []) { result, entry in
            if storedNames.contains(entry.name) { result.insert(entry.option) }
        }
    }
}
