import DirnexCore

/// Which Get Info panel a set of rows deserves (PLAN.md §M24 Slice 7).
///
/// A pure decision, separate from presenting anything, for the reason `AlertKeyCatcher` split its
/// own rule out: the part worth pinning is *which panel*, and a test that presents a real window in
/// the test host destabilizes every suite around it — hosting a live pane makes it do real pane
/// work, which is documented as taking a run from 9/9 green to 7/8 (docs/NOTES.md ▸ Testing).
///
/// The decision is made **per row**, never per pane. A results tab holds hits from anywhere, a tree
/// draws several directories at once, and an expanded bucket in an account pane draws rows on a
/// different backend from the one the pane is on — so "is this pane local" is a different question
/// from the one being asked, and answering it instead is the shape §M24 Slice 6 had already paid
/// for once in the pack sources.
enum AttributesRoute: Equatable {
    /// One row on this Mac: the full editing panel.
    case single
    /// Several rows, all on this Mac: the bulk patch editor.
    case multiple
    /// One row that is not on this Mac: the read-only panel.
    case remote
    /// Several rows, at least one of them not on this Mac.
    ///
    /// Refused rather than served, because the bulk panel is an **editor** and a remote row has
    /// nothing editable yet. Both alternatives fail quietly: opening it over the local subset edits
    /// fewer items than the user marked without saying so — which is exactly what the old
    /// local-only filter did to a mixed selection — and describing the cursor row alone ignores
    /// marks that every other gesture in the app obeys.
    case bulkUnavailable

    /// `targets` is never empty; the caller has already refused that with its own message.
    static func decide(for targets: [FileEntry]) -> AttributesRoute {
        let allLocal = targets.allSatisfy { $0.path.backend == .local }
        if allLocal { return targets.count == 1 ? .single : .multiple }
        return targets.count == 1 ? .remote : .bulkUnavailable
    }
}
