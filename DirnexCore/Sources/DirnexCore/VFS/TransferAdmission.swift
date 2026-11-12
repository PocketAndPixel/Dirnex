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
    /// `/tmp/ab`).
    ///
    /// **One backend crossing is a recursion, and it is the one an archive makes** (PLAN.md §M36).
    /// A browsed archive's contents carry a backend of their own, `archive:<file>`, so the backend
    /// compare above says a local folder can never contain them — while every byte of them lives
    /// in a file on this disk that the folder may well hold. Missing it was not a refusal but a loss:
    /// F6 of `proj` into the pane browsing `proj/backup.zip` added the folder to the archive and then
    /// moved the folder to the Trash, `backup.zip` inside it. So the archive's own file stands in for
    /// its contents, and a source that is that file or holds it recurses, for either kind — adding
    /// an archive to itself is never what anybody meant, and the copy half of it is the half that
    /// silently doubles the archive's size.
    public static func recurses(source: VFSPath, into destination: VFSPath) -> Bool {
        if destination.isSelfOrDescendant(of: source) { return true }
        guard let archiveFile = destination.backend.archivePath else { return false }
        return VFSPath.local(archiveFile).isSelfOrDescendant(of: source)
    }

    // MARK: - One pasted source

    /// Whether one pasted `source` may land in `destination` as `kind` — the filter ⌘V and ⌥⌘V apply
    /// per row.
    ///
    /// Per source rather than per set, unlike a drop: a paste's kind is chosen by the *key*, so
    /// dropping the rows it cannot apply to is what the same-folder rule below has always done,
    /// where a drag has one kind for the whole gesture and refuses it once. The rule was a private
    /// function in the app until M36 gave a second reader — the add into an archive — and that
    /// reader is where it gained its last clause.
    ///
    /// - A **recursion** is refused for either kind (``recurses(source:into:)``).
    /// - A **move** drops an archive member, which has nothing to remove afterwards
    ///   (``allowsMove(from:)``), and a row already living in the destination, since moving a file
    ///   onto itself is nothing.
    /// - A **copy** into the folder it already lives in is kept: that is the duplicate gesture, which
    ///   the queue renames "<name> copy" the way Finder does. **Except into an archive**, whose add
    ///   lands every item under its own name and has no duplicate to make, so the copy would replace
    ///   the member with itself behind a Replace question about nothing.
    ///
    /// Any other kind is not something a paste can be, and admits nothing.
    public static func pasteAdmits(
        _ source: VFSPath,
        into destination: VFSPath,
        kind: FileOperation.Kind
    ) -> Bool {
        if recurses(source: source, into: destination) { return false }
        let landsInPlace = source.parent == destination
        switch kind {
        case .move: return allowsMove(from: [source]) && !landsInPlace
        case .copy: return !(landsInPlace && destination.backend.isArchive)
        default: return false
        }
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
