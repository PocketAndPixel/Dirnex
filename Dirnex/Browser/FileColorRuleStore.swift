import DirnexCore
import Foundation

/// App-wide persistence for the file-type color rules (PLAN.md §M15 Slice 3) — the ordered
/// glob → color list Settings ▸ Panels edits and every pane draws through. One shared list across
/// every window, stored as boring JSON in `UserDefaults` beside the user scripts
/// (`UserScriptStore`), the saved searches and the workspaces (PLAN.md §2 "JSON/plist for config").
///
/// **Unlike those, this one is read from a render loop**, so it keeps the decoded value in memory:
/// `tableView(_:viewFor:row:)` asks for the rules once per cell, and decoding JSON there would cost
/// more than the matching it exists to feed. The cache is the whole reason this is not a verbatim
/// copy of `UserScriptStore`, and it is what makes `@MainActor` isolation necessary — a mutable
/// cache needs it under Swift 6 strict concurrency, and every reader (the render pass, the Settings
/// editor) is already on the main actor.
@MainActor
final class FileColorRuleStore {
    static let shared = FileColorRuleStore(defaults: .standard)

    private let defaults: UserDefaults
    private let key = "Dirnex.fileColorRules"

    /// Required so a test cannot write to the user's domain through a default argument.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Posted after any `save`, so open panes repaint. The pane observer is the twin of the palette's
    /// (`PanelViewController+FileColors`), since the response is the same: nothing moved, so restyle
    /// the rows in place. The object is this store, so scratch stores do not notify live panes.
    static let didChangeNotification = Notification.Name("Dirnex.fileColorRulesDidChange")

    /// `nil` until first read — decoded once, then held. Not an empty list as the initial value, or
    /// "never loaded" and "loaded, and the user has no rules" would be the same state and the store
    /// would re-read the defaults domain on every cell of every render.
    private var cached: FileColorRules?

    /// The current rules. Cheap enough to call per cell: after the first read it is a stored-property
    /// load.
    var rules: FileColorRules {
        if let cached { return cached }
        let loaded = decode()
        cached = loaded
        return loaded
    }

    func save(_ rules: FileColorRules) {
        cached = rules
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// A store that cannot be decoded at all reads as "no rules" rather than throwing: the rules are
    /// decoration, and losing them must never keep a pane from drawing. `FileColorRule` already
    /// degrades field by field on the way in, so reaching this line means the JSON itself is not a
    /// rule list.
    private func decode() -> FileColorRules {
        guard let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode(FileColorRules.self, from: data) else {
            return FileColorRules()
        }
        return rules
    }
}
