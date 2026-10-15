import Foundation

/// Where a search runs, in the terms the Find Files dialog asks it: a real folder, and whether the
/// search covers that folder or everything there is.
///
/// Two directions, one definition. **Forward**, ⌥F7 turns the folder it was pressed in and the
/// dialog's "Search in" choice into the scope a search actually runs with (``scope``) — `nil` for
/// Spotlight's everywhere, the connection's own root on a walk. **Backward**, editing the search
/// behind a results tab turns what that tab stored back into the folder and the choice the dialog
/// opens on (``init(scope:origin:home:)``). Held in one type because the backward half is only right
/// for as long as it is the exact inverse of the forward one.
///
/// The backward half carries the trap that makes this worth a type rather than three lines in the
/// pane: **a results tab is not a place to search.** Its path is the synthetic `search:/…`, which
/// ``SearchFields/answerable(by:)`` answers with the listing set — so a dialog built from the tab's
/// own path hides Content and Tags, and re-running from it drops those terms without a word. A
/// search for text inside files would come back as a name search under the same label. Everything
/// here is asked of ``folder``, which is always the real place the search ran in.
public struct SearchPlace: Sendable, Equatable {
    /// The real folder the search runs in: what the dialog's "This Folder" option names, and what
    /// decides the route and the fields — never a results listing.
    public var folder: VFSPath
    /// Whether the search covers everything — every indexed volume on the Spotlight route, the
    /// connection's or archive's own root on a walk — rather than ``folder`` and what is under it.
    public var everything: Bool

    public init(folder: VFSPath, everything: Bool) {
        self.folder = folder
        self.everything = everything
    }

    /// Recover the place a results tab's search ran in from what the tab stored.
    ///
    /// - Parameters:
    ///   - scope: the scope the search ran with — `nil` is Spotlight's everywhere.
    ///   - origin: the folder ⌥F7 was pressed in, when the tab knows it. Only an *everything* scope
    ///     needs it, since that scope no longer names the folder; a saved search or a tag's search
    ///     has none.
    ///   - home: where an everywhere search with no origin points "This Folder" — the same fallback
    ///     ⌥F7 itself uses on a pane with no folder of its own.
    public init(scope: VFSPath?, origin: VFSPath?, home: VFSPath) {
        guard let scope else {
            // Only a local folder can have run an everywhere search, so an origin on any other
            // backend is not one this search could have come from.
            let local = origin.flatMap { SearchRoute.forBackend($0.backend) == .spotlight ? $0 : nil }
            self.init(folder: local ?? home, everything: true)
            return
        }
        // On a walk, "everything" *is* a scope: the connection's root. A search stored there covers
        // the whole connection whichever option produced it — at the root, both options search the
        // same thing — so it opens on the option that says so.
        if SearchRoute.forBackend(scope.backend) == .walk, scope.isRoot {
            let sameConnection = origin.flatMap { $0.backend == scope.backend ? $0 : nil }
            self.init(folder: sameConnection ?? scope, everything: true)
            return
        }
        self.init(folder: scope, everything: false)
    }

    /// How a search over this place runs.
    public var route: SearchRoute {
        SearchRoute.forBackend(folder.backend)
    }

    /// The fields a search over this place can answer — what the dialog draws.
    public var fields: SearchFields {
        SearchFields.answerable(by: folder.backend)
    }

    /// The scope a search over this place runs with, and what its results tab stores.
    ///
    /// `nil` is Spotlight's everywhere, which is the absence of a place rather than a place; nothing
    /// else has one, because a walk needs a root to start at. An unsearchable folder answers itself:
    /// it never runs, and inventing an everywhere for it would be the widening ``SearchRoute`` exists
    /// to refuse.
    public var scope: VFSPath? {
        guard everything else { return folder }
        switch route {
        case .spotlight:
            return nil
        case .walk:
            return VFSPath(backend: folder.backend, path: "/")
        case .unavailable:
            return folder
        }
    }
}
