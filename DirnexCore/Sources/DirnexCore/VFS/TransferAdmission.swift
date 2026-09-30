import Foundation

/// The two questions a drop or a paste has to answer before anything is queued: *would this land
/// inside itself*, and *is this a copy or a move* (PLAN.md §M23).
///
/// Both were already being answered, by hand, at two call sites apiece — `PanelViewController
/// +Clipboard.pasteRecurses` and `+Drop.dropPlan` for the first, `+Drop.resolvedKind` for the
/// second — and both got it wrong the moment a transfer could cross backends, which is exactly what
/// M23 makes possible. They are here, pure and tested, because one of them decides whether the
/// user's original file is **deleted**.
public enum TransferAdmission {
    // MARK: - Recursion

    /// Whether placing `source` into `destination` would put it inside its own subtree — dropping a
    /// folder onto itself, or into something it contains.
    ///
    /// Both hand-rolled copies spelled this `destination.path.hasPrefix(source.path + "/")`, a
    /// string test with **no backend in it**. That is right for the one-backend world it was written
    /// in and wrong as soon as two are in play: a local `/tmp` reads as an ancestor of an SFTP
    /// `/tmp/x`, so a perfectly ordinary transfer is refused with no message — the quiet direction,
    /// and impossible to notice without two panes on two backends holding similarly-named folders.
    ///
    /// `VFSPath.isSelfOrDescendant(of:)` has asked the question correctly since M1 (it compares the
    /// backend first, and walks components rather than characters, so `/tmp/abc` is not inside
    /// `/tmp/ab`). This is a name for it, not a new rule.
    public static func recurses(source: VFSPath, into destination: VFSPath) -> Bool {
        destination.isSelfOrDescendant(of: source)
    }

    // MARK: - Volumes

    /// Whether `source` and `destination` sit on the same physical volume — the question Finder's
    /// copy-vs-move default turns on.
    ///
    /// **A backend crossing is never the same volume, and getting that wrong deletes files.**
    /// `CompositeBackend.volumeIdentifier(for:)` answers `nil` for every non-local path, and `nil`
    /// means "one indistinguishable volume" to the queue's scheduler — a correct reading *there*,
    /// where the cost of being wrong is that two jobs are serialized. Read as an answer to *this*
    /// question it inverts: two `nil`s compare equal, so a drag from this Mac onto a server would
    /// have been called a same-volume move and the local original removed. Harmless while every
    /// drop destination was local; the expensive direction the moment one is not.
    ///
    /// So the two facts are separated. Different backends are different volumes, full stop, whatever
    /// the lookup says. Within one backend an **unknown** volume (`nil` on either side) is not a
    /// licence to move either — it is an absence of evidence, and the safe reading of no evidence is
    /// "not the same disk", which costs a copy where a move would have done.
    public static func sharesVolume(
        _ source: VFSPath,
        _ destination: VFSPath,
        volumeIdentifier: (VFSPath) -> String?
    ) -> Bool {
        guard source.backend == destination.backend else { return false }
        guard let sourceVolume = volumeIdentifier(source),
              let destinationVolume = volumeIdentifier(destination) else { return false }
        return sourceVolume == destinationVolume
    }

    // MARK: - What may be moved at all

    /// Whether `sources` may be **moved**, or can only ever be copied.
    ///
    /// An archive member has no move. The container is read-only, so moving one would copy the
    /// bytes out and then have nothing to remove — which is why F6 out of an archive does not exist
    /// (PLAN.md §M4) and `moveToOtherPane` returns rather than queueing one. Since M23 Slice 5 the
    /// clipboard and a drag reach exactly those rows, so ⌥⌘V and a ⌘-forced drag would each have
    /// needed their own copy of that rule — which is the shape the two spellings of `recurses`
    /// above were, and how both came to be wrong.
    ///
    /// **One member answers for the whole set**, deliberately. A drag is one operation with one
    /// kind, and a mixed selection that moved its local rows while copying its archive ones would
    /// be two operations wearing one gesture. Copying everything is the forgiving direction and the
    /// only one that cannot delete something the user still has no second copy of.
    public static func allowsMove(from sources: [VFSPath]) -> Bool {
        !sources.contains { $0.backend.isArchive }
    }

    // MARK: - Copy or move

    /// What the drag source is willing to allow, read off `NSDragOperation` by the caller so this
    /// stays free of AppKit.
    public struct DragOffer: Sendable, Hashable {
        public let allowsCopy: Bool
        public let allowsMove: Bool

        public init(allowsCopy: Bool, allowsMove: Bool) {
            self.allowsCopy = allowsCopy
            self.allowsMove = allowsMove
        }
    }

    /// The keys held as the drop lands: Option forces a copy, Command forces a move — Finder's
    /// convention, and the user's explicit override of everything below.
    public struct DragModifiers: Sendable, Hashable {
        public let forcesCopy: Bool
        public let forcesMove: Bool

        public init(forcesCopy: Bool, forcesMove: Bool) {
            self.forcesCopy = forcesCopy
            self.forcesMove = forcesMove
        }

        public static let none = DragModifiers(forcesCopy: false, forcesMove: false)
    }

    /// Resolve a drop to a copy or a move, or `nil` when the source offers neither.
    ///
    /// Finder's rule: an explicit modifier wins; otherwise move within a volume and copy across one,
    /// so dragging to another disk never silently deletes the original. `sharesVolume` is the
    /// caller's answer from the function above — passing a bare `true` reintroduces the bug that
    /// function exists to prevent.
    ///
    /// A forcing modifier the *offer* does not permit is ignored rather than refusing the drop:
    /// holding Command over a source that only offers copy still copies, which is what Finder does
    /// and is the forgiving direction.
    public static func kind(
        offer: DragOffer,
        modifiers: DragModifiers,
        sharesVolume: Bool
    ) -> FileOperation.Kind? {
        guard offer.allowsCopy || offer.allowsMove else { return nil }
        if modifiers.forcesCopy, offer.allowsCopy { return .copy }
        if modifiers.forcesMove, offer.allowsMove { return .move }
        if offer.allowsMove, sharesVolume { return .move }
        return offer.allowsCopy ? .copy : .move
    }
}
