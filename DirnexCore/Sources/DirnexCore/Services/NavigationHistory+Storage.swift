import Foundation

/// A tab's back/forward trail as it is written down with the tab and read back at launch, so ⌘[ and
/// the ⌥↓ list still know where a tab has been after a relaunch.
///
/// **It decodes to an empty trail rather than throwing.** It is a field of a persisted tab, and a
/// pane's tabs are one JSON blob, so a trail that refused to decode would take every tab beside it
/// (the trap ``StoredServerEndpoint`` exists for). An empty trail is then simply not restored: the
/// tab comes back with a fresh one, which is what every tab did before trails were kept.
///
/// The forward entries are kept as well as the older ones, so ⌘] still works after a relaunch for a
/// tab that was quit partway back along its trail.
public struct StoredNavigationHistory: Sendable, Equatable, Codable {
    /// The visited places, oldest first.
    public let entries: [VFSPath]
    /// Which of `entries` the tab was showing.
    public let currentIndex: Int
    /// How to reconnect to each server the trail visits, one per server rather than one per entry.
    /// A tab holds a single endpoint for the place it is *in*, so without these a trail that went
    /// from a server to a local folder would come back with ⌘[ pointing at a server nothing could
    /// reconnect. `nil`, and absent from the JSON, for a trail that never left the Mac.
    public let endpoints: [StoredServerEndpoint]?

    public init(entries: [VFSPath], currentIndex: Int, endpoints: [ServerEndpoint] = []) {
        self.entries = entries
        self.currentIndex = currentIndex
        self.endpoints = endpoints.isEmpty ? nil : endpoints.map(StoredServerEndpoint.init)
    }

    /// The endpoints this build can read; one it cannot is left out, and the entries on that
    /// server are then dropped on the way back in.
    public var serverEndpoints: [ServerEndpoint] {
        endpoints?.compactMap(\.endpoint) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case currentIndex
        case endpoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        // All or nothing: dropping one unreadable entry from the middle would shift every index
        // after it, and the trail would come back pointing at the wrong place.
        entries = (try? container?.decode([VFSPath].self, forKey: .entries)) ?? []
        currentIndex = (try? container?.decode(Int.self, forKey: .currentIndex)) ?? 0
        endpoints = try? container?.decodeIfPresent([StoredServerEndpoint].self, forKey: .endpoints)
    }
}

public extension NavigationHistory {
    /// This trail as it should be written down for a tab showing `path`, or `nil` when there is
    /// nothing worth writing: the trail is only `path` itself, or it does not describe a tab at
    /// `path` at all (a results tab, whose listing never enters the trail).
    ///
    /// Written from the entry **on screen** (``landedIndex``), since that is the place the tab is
    /// restored to, and a walk still in flight at quit never arrived.
    ///
    /// What is left out is what could not come back, decided here by the rule that decides it for a
    /// tab (``TabRestorePolicy``) — a search snapshot, a merged Trash listing, a server with no
    /// endpoint — plus whatever `isExcluded` names, which is what only the app knows: a folder inside
    /// an unlocked vault (implicit memory never keeps one, `VaultPrivacy`) and a nested archive's
    /// temp extraction. Neighbours that meet once something between them is gone fold into one.
    /// Nothing is looked at on disk: a folder deleted since is dealt with when ⌘[ reaches it
    /// (``dropUnreachableTarget()``), not by a `stat` per entry at every quit.
    func stored(
        at path: VFSPath,
        endpoint: (VFSBackendID) -> ServerEndpoint?,
        isExcluded: (VFSPath) -> Bool
    ) -> StoredNavigationHistory? {
        guard entries[landedIndex] == path else { return nil }
        var endpoints: [ServerEndpoint] = []
        var requirements: [VFSBackendID: TabRestoreRequirement?] = [:]
        func requirement(for entry: VFSPath) -> TabRestoreRequirement? {
            if let known = requirements[entry.backend] { return known }
            let answer = TabRestorePolicy.requirement(for: entry, endpoint: endpoint(entry.backend))
            requirements[entry.backend] = answer
            if case let .connection(server) = answer { endpoints.append(server) }
            return answer
        }
        guard let trail = Self.compacted(entries, current: landedIndex, keeping: { entry in
            !isExcluded(entry) && requirement(for: entry) != nil
        }), trail.entries.count > 1 else { return nil }
        // Only the servers an entry that was kept stands on; one whose entries were all excluded
        // has nothing to reconnect for.
        let used = Set(trail.entries.map(\.backend))
        return StoredNavigationHistory(
            entries: trail.entries,
            currentIndex: trail.current,
            endpoints: endpoints.filter { $0.backendID.map(used.contains) ?? false }
        )
    }

    /// The trail a tab restored at `path` comes back with: `stored`, less whatever cannot come
    /// back, or a fresh trail at `path` when there is nothing usable — no stored trail, one that
    /// does not end up at `path`, or one that cannot be read.
    ///
    /// The same rule as writing, applied again because the store is JSON in a defaults domain and
    /// this build may not be the one that wrote it: an entry on a server whose endpoint is missing
    /// or unreadable, or on a listing this build will not restore, is dropped. A trail longer than
    /// `capacity` loses its oldest entries first, then its newest, but never the one at `path`.
    init(
        restoring stored: StoredNavigationHistory?,
        at path: VFSPath,
        capacity: Int = NavigationHistory.defaultCapacity
    ) {
        guard let stored, let trail = Self.restorable(stored, at: path, capacity: max(capacity, 1))
        else {
            self.init(initialPath: path, capacity: capacity)
            return
        }
        self.init(entries: trail.entries, currentIndex: trail.current, capacity: capacity)
    }

    private static func restorable(
        _ stored: StoredNavigationHistory,
        at path: VFSPath,
        capacity: Int
    ) -> (entries: [VFSPath], current: Int)? {
        guard stored.entries.indices.contains(stored.currentIndex) else { return nil }
        let servers = Dictionary(
            stored.serverEndpoints.compactMap { server in server.backendID.map { ($0, server) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard var trail = compacted(stored.entries, current: stored.currentIndex, keeping: {
            TabRestorePolicy.requirement(for: $0, endpoint: servers[$0.backend]) != nil
        }), trail.entries[trail.current] == path else { return nil }
        let olderOverflow = min(trail.entries.count - capacity, trail.current)
        if olderOverflow > 0 {
            trail.entries.removeFirst(olderOverflow)
            trail.current -= olderOverflow
        }
        let newerOverflow = trail.entries.count - capacity
        if newerOverflow > 0 { trail.entries.removeLast(newerOverflow) }
        return trail
    }

    /// `entries` with only what `keep` admits, the neighbours that then meet folded into one, and
    /// `current` moved to the same place — or `nil` when `keep` refuses the entry at `current`.
    private static func compacted(
        _ entries: [VFSPath],
        current: Int,
        keeping keep: (VFSPath) -> Bool
    ) -> (entries: [VFSPath], current: Int)? {
        var kept: [VFSPath] = []
        var keptCurrent: Int?
        for (index, entry) in entries.enumerated() where keep(entry) {
            if kept.last != entry { kept.append(entry) }
            if index == current { keptCurrent = kept.count - 1 }
        }
        guard let keptCurrent else { return nil }
        return (kept, keptCurrent)
    }
}
