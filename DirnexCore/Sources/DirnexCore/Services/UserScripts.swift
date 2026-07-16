import Foundation

/// An ordered, name-de-duplicated collection of user scripts — the model behind the palette's
/// script entries and their management UI (PLAN.md §M6). A pure value type with no persistence or
/// AppKit: the app owns the `UserDefaults` store and any editor, this owns the ordering and naming
/// rules so they stay unit-testable headless (matching `ServerConnections`, `SavedSearches`, and
/// `Workspaces`).
public struct UserScripts: Sendable, Equatable, Codable {
    /// The saved scripts in user order — the order the palette and any list present.
    public private(set) var scripts: [UserScript]

    public init(scripts: [UserScript] = []) {
        // Collapse duplicate names on the way in (a hand-edited or legacy store), keeping the
        // first occurrence so a name maps to a single script — the same invariant `save` upholds.
        var seen = Set<String>()
        self.scripts = scripts.filter { seen.insert($0.name).inserted }
    }

    /// Whether a script named `name` exists — drives an editor's replace confirmation.
    public func contains(name: String) -> Bool {
        scripts.contains { $0.name == name }
    }

    /// The script named `name`, or `nil`. The palette resolves a pick by name so a mid-open store
    /// change can't act on the wrong (index-shifted) script.
    public func script(named name: String) -> UserScript? {
        scripts.first { $0.name == name }
    }

    /// The palette `Command`s for every script, in order — what the app merges into the catalog so
    /// scripts rank and render alongside the built-in actions.
    public var paletteCommands: [Command] {
        scripts.map(\.paletteCommand)
    }

    /// Save `script`: overwrite an existing one with the same name *in place* (keeping its
    /// position), else append. Returns whether it replaced an existing script.
    @discardableResult
    public mutating func save(_ script: UserScript) -> Bool {
        if let index = scripts.firstIndex(where: { $0.name == script.name }) {
            scripts[index] = script
            return true
        }
        scripts.append(script)
        return false
    }

    /// Delete the script named `name`, if present. Returns whether one was removed.
    @discardableResult
    public mutating func remove(name: String) -> Bool {
        guard let index = scripts.firstIndex(where: { $0.name == name }) else { return false }
        scripts.remove(at: index)
        return true
    }

    /// Delete the script at `index`; out-of-range is ignored.
    public mutating func remove(at index: Int) {
        guard scripts.indices.contains(index) else { return }
        scripts.remove(at: index)
    }

    /// Rename the script named `name` to `newName`. Rejected (returns `false`, leaving the list
    /// unchanged) when `newName` is empty or already names a *different* script, so a rename can
    /// never collapse two entries into one. Renaming to the same name is a no-op success.
    @discardableResult
    public mutating func rename(name: String, to newName: String) -> Bool {
        guard let index = scripts.firstIndex(where: { $0.name == name }) else { return false }
        guard !newName.isEmpty else { return false }
        guard !scripts.contains(where: { $0.name == newName }) || newName == name else {
            return false
        }
        scripts[index].name = newName
        return true
    }

    /// Reorder: pull the script out of `source` and reinsert it so it lands at `destination` in the
    /// *resulting* list (Array semantics, matching the server/saved-search reorder).
    public mutating func move(from source: Int, to destination: Int) {
        guard scripts.indices.contains(source) else { return }
        let script = scripts.remove(at: source)
        scripts.insert(script, at: min(max(destination, 0), scripts.count))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case scripts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the de-duplicating initializer so a legacy/corrupt store is
        // sanitized on the way back in.
        self.init(scripts: try container.decode([UserScript].self, forKey: .scripts))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scripts, forKey: .scripts)
    }
}
