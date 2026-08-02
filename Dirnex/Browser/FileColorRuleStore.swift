import DirnexCore
import Foundation

/// App-wide persistence for the file-type colour rules (PLAN.md §M15 Slice 3) — the ordered
/// glob → colour list Settings ▸ Panels edits and every pane draws through. One shared list across
/// every window, stored as boring JSON in `UserDefaults` beside the user scripts
/// (`UserScriptStore`), the saved searches and the workspaces (PLAN.md §2 "JSON/plist for config").
///
/// **Unlike those, this one is read from a render loop**, so it keeps the decoded value in memory:
/// `tableView(_:viewFor:row:)` asks for the rules once per cell, and decoding JSON there would cost
/// more than the matching it exists to feed. The cache is the whole reason this is not a verbatim
/// copy of `UserScriptStore`, and it is what makes `@MainActor` isolation necessary — a mutable
/// static needs it under Swift 6 strict concurrency, and every reader (the render pass, the Settings
/// editor) is already on the main actor.
@MainActor
enum FileColorRuleStore {
    private static let key = "Dirnex.fileColorRules"

    /// Posted after any `save`, so open panes repaint. The pane observer is the twin of the palette's
    /// (`PanelViewController+FileColors`), since the response is the same: nothing moved, so restyle
    /// the rows in place.
    static let didChangeNotification = Notification.Name("Dirnex.fileColorRulesDidChange")

    /// `nil` until first read — decoded once, then held. Not an empty list as the initial value, or
    /// "never loaded" and "loaded, and the user has no rules" would be the same state and the store
    /// would re-read the defaults domain on every cell of every render.
    private static var cached: FileColorRules?

    /// The current rules. Cheap enough to call per cell: after the first read it is a stored-property
    /// load.
    static var rules: FileColorRules {
        if let cached { return cached }
        let loaded = decode()
        cached = loaded
        return loaded
    }

    static func save(_ rules: FileColorRules) {
        cached = rules
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Drop the in-memory copy so the next read comes off `UserDefaults` again — for tests, which
    /// write the defaults domain directly and would otherwise be served a value from a previous case.
    static func invalidateCache() {
        cached = nil
    }

    /// A store that cannot be decoded at all reads as "no rules" rather than throwing: the rules are
    /// decoration, and losing them must never keep a pane from drawing. `FileColorRule` already
    /// degrades field by field on the way in, so reaching this line means the JSON itself is not a
    /// rule list.
    private static func decode() -> FileColorRules {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode(FileColorRules.self, from: data) else {
            return FileColorRules()
        }
        return rules
    }
}
