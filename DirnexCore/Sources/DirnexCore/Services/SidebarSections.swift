import Foundation

/// The sidebar's sections, in the order they are rendered (PLAN.md §M8 "Collapsible sections").
///
/// A section is an *identity*, not a title string. The app used to locate the Favorites section by
/// comparing header text, which made a user-visible string load-bearing; a case is what the drag
/// code, the collapse state and the persisted file all key off instead.
///
/// `allCases` is the display order, which is why the cases are declared in it rather than
/// alphabetically.
public enum SidebarSection: String, CaseIterable, Sendable, Hashable {
    case searches
    case favorites
    case volumes
    case servers
    case tags

    /// The section header's label.
    public var title: String {
        switch self {
        case .searches: "Searches"
        case .favorites: "Favorites"
        case .volumes: "Volumes"
        case .servers: "Servers"
        case .tags: "Tags"
        }
    }
}

/// Which sidebar sections the user has collapsed (PLAN.md §M8 "Disclosure triangles, per-section
/// state persisted"). Everything starts expanded: a sidebar that opens folded shut on a fresh
/// install would hide the feature that put the rows there.
///
/// **Collapsed sections are stored as raw strings, not as `SidebarSection` values.** Decoding a
/// `Set<SidebarSection>` throws on the first name it doesn't recognise, and a throwing decode
/// resets *every* section's state — so one unknown name would silently unfold the whole sidebar.
/// Since M8 still has iCloud, Trash and Recents rows to add, and betas do get rolled back, the
/// version that doesn't know a name has to carry it through untouched rather than lose it.
public struct SidebarSectionCollapse: Equatable, Sendable, Codable {
    /// Raw section identifiers, including any this build doesn't know about.
    private var collapsed: Set<String>

    public init(collapsed: Set<SidebarSection> = []) {
        self.collapsed = Set(collapsed.map(\.rawValue))
    }

    public func isCollapsed(_ section: SidebarSection) -> Bool {
        collapsed.contains(section.rawValue)
    }

    /// Flip a section, returning its **new** collapsed state — what a caller needs to update a
    /// disclosure triangle without re-reading.
    @discardableResult
    public mutating func toggle(_ section: SidebarSection) -> Bool {
        let nowCollapsed = !isCollapsed(section)
        setCollapsed(nowCollapsed, for: section)
        return nowCollapsed
    }

    /// Set a section's state, returning whether that **changed** anything — so a caller can skip a
    /// needless write and rebuild. Used by the drop path, where a folder dragged onto a collapsed
    /// Favorites header has to unfold it or the pin lands somewhere the user cannot see.
    @discardableResult
    public mutating func setCollapsed(_ isCollapsed: Bool, for section: SidebarSection) -> Bool {
        let before = collapsed
        if isCollapsed {
            collapsed.insert(section.rawValue)
        } else {
            collapsed.remove(section.rawValue)
        }
        return collapsed != before
    }

    /// The collapsed sections this build understands. Names it doesn't are preserved by the
    /// storage but are deliberately not reported here — there is nothing to render for them.
    public var sections: Set<SidebarSection> {
        Set(collapsed.compactMap(SidebarSection.init(rawValue:)))
    }

    // MARK: - Codable

    // Encoded as a bare, sorted array of names rather than a keyed object: it is one set, the file
    // is meant to be readable (PLAN.md §2 "boring and debuggable"), and sorting keeps a no-op save
    // from rewriting bytes in a different order every launch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        collapsed = Set(try container.decode([String].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(collapsed.sorted())
    }
}
