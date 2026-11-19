import Foundation

// The tags this account's Finder offers, which are the names it writes (PLAN.md §M40 Slice 6).
//
// Measured 2026-11-19 by tagging files through Finder's own context menu and reading
// `_kMDItemUserTags` back, on a clone of the CI VM (macOS 26.6.2) and on this Mac:
//
// - **Finder writes the names in the account's favorites, not an English constant and not the UI's
//   language.** The VM's US-English account wrote `Red\n6` and `Gray\n1`; this Mac's lists `Grey`;
//   a list made under German wrote `Rot\n6` and `Grau\n1`.
// - **That list is made once, when the account first runs Finder, and is kept.** The VM switched
//   to German, with a German menu bar, still wrote `Red` and `Gray` and showed them in the sidebar.
//   Only a list made afresh under German read Rot, Orange, Gelb, Grün, Blau, Lila, Grau.
// - **The context menu's dots are `com.apple.finder` ▸ `FavoriteTagNames`.** Replacing one name
//   with a new one turned its dot hollow, and that dot wrote the new name, uncolored.
// - **The system's own lookup colors a name from the same list.** `NSURLTagNamesKey` on the German
//   list gave `Rot` 6 and `Red`, `Gray` and `Grey` all 0.
//
// So a hard-coded Red … Grey was a second, colorless tag beside Finder's on a German account, and
// its `Grey` split from Finder's `Gray` on a fresh US-English one.

/// The tags Finder's menus offer on this account, in Finder's order, each in the color the system
/// knows it by. They are what the ⌃T menu and the sidebar's Tags section offer before anything has
/// been scanned, and the names whose color `FinderTagIndex` never takes from a file.
public struct FinderStockTags: Sendable, Equatable {
    public let tags: [FinderTag]

    /// `tags` as given, a repeated name dropped (first wins, by `FinderTag`'s case-folded identity).
    public init(tags: [FinderTag]) {
        var seen = Set<FinderTag>()
        self.tags = tags.filter { seen.insert($0).inserted }
    }

    /// Finder's favorites, each colored by what the system's lookup answered for it.
    ///
    /// `favoriteNames` is the preference as stored, whose first entry is an empty string; an empty
    /// name is no tag and is skipped. A name the lookup did not answer for is colorless, which is
    /// what Finder draws for a favorite its list has no color for.
    public init(favoriteNames: [String], coloredAs resolved: [FinderTag]) {
        let colors = Dictionary(
            resolved.map { ($0, $0.color) },
            uniquingKeysWith: { first, _ in first }
        )
        self.init(tags: favoriteNames.filter { !$0.isEmpty }.map { name in
            let tag = FinderTag(name: name)
            return FinderTag(name: name, color: colors[tag] ?? .none)
        })
    }

    /// The seven English names (`FinderTagColor.systemTagName`), for when Finder's favorites can't
    /// be read: under the tests, and on an account that has never run Finder.
    public static let fallback = FinderStockTags(tags: FinderTagColor.displayOrder.compactMap { color in
        color.systemTagName.map { FinderTag(name: $0, color: color) }
    })

    /// Whether `tag` is one of these, by name and case-insensitively.
    public func contains(_ tag: FinderTag) -> Bool {
        tags.contains(tag)
    }

    // MARK: - This process's set

    /// The set this process uses, `fallback` until the app adopts the account's at launch
    /// (`FinderStockTagLookup.forThisAccount()`). A test never sets it: tests run in parallel, and a
    /// test that needs another set builds its own and hands it to `FinderTagIndex(stock:)`.
    public static var current: FinderStockTags {
        get { store.value }
        set { store.value = newValue }
    }

    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = FinderStockTags.fallback

        var value: FinderStockTags {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }
    }
}

/// Reading this account's stock tags: Finder's favorites, colored through the system's lookup.
///
/// It reads another app's preferences and writes a scratch file, so it is I/O, and the app runs it
/// once at launch. Measured on this Mac in a cold process: 2–4 ms for the preference and 4–7 ms for
/// the lookup.
public enum FinderStockTagLookup {
    static let finderDomain = "com.apple.finder"
    static let favoritesKey = "FavoriteTagNames"

    /// Finder's favorites as its preference holds them, the leading empty string included, or `nil`
    /// when there is no such preference.
    public static func favoriteNames() -> [String]? {
        CFPreferencesCopyAppValue(favoritesKey as CFString, finderDomain as CFString) as? [String]
    }

    /// What the system colors each of `names`, asked the one way it answers: one scratch file in
    /// `directory`, tagged through `NSURLTagNamesKey` with the bare names, its attribute read back,
    /// and the file removed.
    ///
    /// `NSURL`'s setter rather than `URLResourceValues.tagNames`, whose setter is macOS 26 and later
    /// (`FinderTagStorage`). The lookup knows only the names in the account's own list, so a name it
    /// does not know comes back colorless, and the write registers nothing (`FinderTagStorage`).
    public static func colors(of names: [String], in directory: URL) throws -> [FinderTag] {
        let names = names.filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        let file = directory.appendingPathComponent("dirnex-tag-lookup-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try (file as NSURL).setResourceValue(names, forKey: .tagNamesKey)
        return try FinderTagStorage.tags(at: .local(file.path))
    }

    /// This account's stock tags: Finder's favorites in the colors the system gives them. `fallback`
    /// when there is no favorites preference, or the lookup cannot run; an empty preference is an
    /// empty set, as Finder's menu then offers none.
    public static func forThisAccount(
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) -> FinderStockTags {
        guard let names = favoriteNames() else { return .fallback }
        guard let colored = try? colors(of: names, in: scratchDirectory) else { return .fallback }
        return FinderStockTags(favoriteNames: names, coloredAs: colored)
    }
}
