/// Where the pane was left in one entry of the trail: the row the cursor was on and the tree
/// folders that were open. A walk back to the entry puts the pane back there, the way walking up
/// already lands on the folder just left, rather than on the first row of an all-collapsed tree.
///
/// Spelled as paths relative to the entry's own folder, which is how a persisted tab spells its
/// cursor and its open folders, so the app puts it back through the same re-anchoring a relaunched
/// tab goes through: by identity, a row deleted since simply not found, and a row inside an open
/// folder anchored once that folder has listed.
///
/// Decodes whatever it can read rather than throwing, like the trail it is stored in: a spot that
/// cannot be read costs only the place inside its folder, never the entry.
public struct NavigationSpot: Sendable, Equatable, Codable {
    /// The row the cursor was on, relative to the folder. `nil` when it was on `..` or the folder
    /// was empty.
    public let cursor: String?
    /// The cursor was on the synthetic `..` row.
    public let cursorOnParent: Bool
    /// The tree folders that were open, relative to the folder. Empty for a flat list.
    public let expanded: [String]

    public init(cursor: String?, cursorOnParent: Bool = false, expanded: [String] = []) {
        self.cursor = cursor
        self.cursorOnParent = cursorOnParent
        self.expanded = expanded
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case cursorOnParent
        case expanded
    }

    public init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        cursor = try? container?.decodeIfPresent(String.self, forKey: .cursor)
        cursorOnParent = (try? container?.decodeIfPresent(Bool.self, forKey: .cursorOnParent)) ?? false
        expanded = (try? container?.decodeIfPresent([String].self, forKey: .expanded)) ?? []
    }

    /// The common case, a flat list with the cursor on a row, is the cursor alone.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        if cursorOnParent { try container.encode(true, forKey: .cursorOnParent) }
        if !expanded.isEmpty { try container.encode(expanded, forKey: .expanded) }
    }
}
