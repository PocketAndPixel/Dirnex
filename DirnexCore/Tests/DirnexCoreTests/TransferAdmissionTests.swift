import Testing

@testable import DirnexCore

/// The rules a drop and a paste apply before anything is queued (PLAN.md §M23).
///
/// Both existed as hand-written copies at the call sites and both were wrong across backends, so
/// the cases that matter here are the **cross-backend** ones — they are what the old spellings got
/// wrong, and they are unreachable in a one-backend world, which is why nothing caught them.
@Suite("TransferAdmission")
struct TransferAdmissionTests {
    private let local = VFSBackendID.local
    private let sftp = VFSBackendID("sftp://user@host")
    private let s3 = VFSBackendID("s3://bucket")
    private let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")

    private func path(_ backend: VFSBackendID, _ path: String) -> VFSPath {
        VFSPath(backend: backend, path: path)
    }

    // MARK: - Recursion

    @Test("a folder dropped onto itself, or inside itself, recurses")
    func recursesIntoItsOwnSubtree() {
        let source = VFSPath.local("/Users/oleg/Docs")
        #expect(TransferAdmission.recurses(source: source, into: source))
        #expect(TransferAdmission.recurses(source: source, into: .local("/Users/oleg/Docs/sub")))
        #expect(TransferAdmission.recurses(
            source: source, into: .local("/Users/oleg/Docs/a/b/c")
        ))
    }

    @Test("a sibling, an ancestor and a same-prefix neighbour do not recurse")
    func doesNotRecurseElsewhere() {
        let source = VFSPath.local("/Users/oleg/Docs")
        #expect(!TransferAdmission.recurses(source: source, into: .local("/Users/oleg")))
        #expect(!TransferAdmission.recurses(source: source, into: .local("/Users/oleg/Other")))
        // The character-comparison trap: "Docs2" starts with "Docs" and is not inside it.
        #expect(!TransferAdmission.recurses(source: source, into: .local("/Users/oleg/Docs2")))
    }

    @Test("the same path on two backends is not a recursion — what the string test got wrong")
    func neverRecursesAcrossBackends() {
        // `destination.path.hasPrefix(source.path + "/")` answered *true* for every pair here,
        // silently refusing an ordinary transfer between two panes on two backends.
        #expect(!TransferAdmission.recurses(
            source: path(local, "/tmp"), into: path(sftp, "/tmp/inbox")
        ))
        #expect(!TransferAdmission.recurses(
            source: path(sftp, "/srv"), into: path(s3, "/srv/deep/deeper")
        ))
        // Identical paths, different backends: copying /data to another server is not a recursion.
        #expect(!TransferAdmission.recurses(
            source: path(sftp, "/data"), into: path(s3, "/data")
        ))
        // The control: the *same* backend still recurses, so the guard has not been disabled.
        #expect(TransferAdmission.recurses(
            source: path(sftp, "/srv"), into: path(sftp, "/srv/deep")
        ))
    }

    // MARK: - Volumes

    @Test("a backend crossing is never the same volume, whatever the lookup says")
    func backendCrossingIsNeverOneVolume() {
        // The shipped hazard, reproduced exactly: the composite answers `nil` for every non-local
        // path, so two `nil`s compared equal and the drop defaulted to a move that deleted the
        // local original. Even a lookup insisting both are "disk1" must not make it one volume.
        #expect(!TransferAdmission.sharesVolume(
            .local("/Users/oleg/a.txt"), path(sftp, "/srv"), volumeIdentifier: { _ in nil }
        ))
        #expect(!TransferAdmission.sharesVolume(
            .local("/Users/oleg/a.txt"), path(s3, "/prefix"), volumeIdentifier: { _ in "disk1" }
        ))
    }

    @Test("within one backend, an unknown volume is not a licence to move")
    func unknownVolumeIsNotTheSameVolume() {
        #expect(!TransferAdmission.sharesVolume(
            path(sftp, "/a"), path(sftp, "/b"), volumeIdentifier: { _ in nil }
        ))
        // One side known, the other not — still no evidence.
        #expect(!TransferAdmission.sharesVolume(
            .local("/a"), .local("/Volumes/Ext/b"),
            volumeIdentifier: { $0.path.hasPrefix("/Volumes") ? nil : "boot" }
        ))
    }

    @Test("two paths on one real volume still share it — the local default is unchanged")
    func sameVolumeStillAnswersYes() {
        #expect(TransferAdmission.sharesVolume(
            .local("/Users/oleg/a"), .local("/Users/oleg/b"), volumeIdentifier: { _ in "boot" }
        ))
        #expect(!TransferAdmission.sharesVolume(
            .local("/Users/oleg/a"), .local("/Volumes/Ext/b"),
            volumeIdentifier: { $0.path.hasPrefix("/Volumes/Ext") ? "ext" : "boot" }
        ))
    }

    // MARK: - What may be moved at all

    @Test("an archive member can only ever be copied — there is nothing to remove afterwards")
    func anArchiveMemberIsNeverMoved() {
        let member = path(archive, "/docs/x.md")
        #expect(!TransferAdmission.allowsMove(from: [member]))
        // The control: everything else still moves, or this rule has quietly become "never move".
        #expect(TransferAdmission.allowsMove(from: [.local("/tmp/a.txt")]))
        #expect(TransferAdmission.allowsMove(from: [path(sftp, "/srv/a.txt")]))
        #expect(TransferAdmission.allowsMove(from: []))
    }

    @Test("one member answers for a mixed set — a drag is one operation with one kind")
    func oneMemberMakesTheWholeSetCopyOnly() {
        // The alternative is moving the local row while copying the archive one, which is two
        // operations wearing one gesture; this is the direction that cannot delete anything.
        #expect(!TransferAdmission.allowsMove(from: [
            .local("/tmp/a.txt"), path(archive, "/inside.txt")
        ]))
    }

    @Test("a ⌘-forced move over an archive member copies, because the offer never permitted it")
    func forcedMoveOverAnArchiveMemberStillCopies() {
        // The rule reaches the resolved kind through `DragOffer`, so the existing "a modifier the
        // source does not offer is ignored" behaviour is what refuses it — no second branch.
        let sources = [path(archive, "/docs/x.md")]
        let kind = TransferAdmission.kind(
            offer: TransferAdmission.DragOffer(
                allowsCopy: true,
                allowsMove: TransferAdmission.allowsMove(from: sources)
            ),
            modifiers: TransferAdmission.DragModifiers(forcesCopy: false, forcesMove: true),
            sharesVolume: false
        )
        #expect(kind == .copy)
    }

    // MARK: - Copy or move

    private let both = TransferAdmission.DragOffer(allowsCopy: true, allowsMove: true)
    private let copyOnly = TransferAdmission.DragOffer(allowsCopy: true, allowsMove: false)

    @Test("the unmodified default is move on one volume, copy across — Finder's rule")
    func defaultsFollowTheVolume() {
        #expect(TransferAdmission.kind(offer: both, modifiers: .none, sharesVolume: true) == .move)
        #expect(TransferAdmission.kind(offer: both, modifiers: .none, sharesVolume: false) == .copy)
    }

    @Test("a drag onto another backend copies — the case that would have deleted the original")
    func crossBackendDefaultsToCopy() {
        // `sharesVolume` is false for a backend crossing (above), and this is what that buys: an
        // unmodified drag from this Mac onto a server copies rather than moving.
        let sharesVolume = TransferAdmission.sharesVolume(
            .local("/Users/oleg/report.pdf"), path(s3, "/prefix"), volumeIdentifier: { _ in nil }
        )
        #expect(TransferAdmission.kind(
            offer: both, modifiers: .none, sharesVolume: sharesVolume
        ) == .copy)
    }

    @Test("an explicit modifier overrides the volume in both directions")
    func modifiersWin() {
        let forceCopy = TransferAdmission.DragModifiers(forcesCopy: true, forcesMove: false)
        let forceMove = TransferAdmission.DragModifiers(forcesCopy: false, forcesMove: true)
        #expect(TransferAdmission.kind(
            offer: both, modifiers: forceCopy, sharesVolume: true
        ) == .copy)
        #expect(TransferAdmission.kind(
            offer: both, modifiers: forceMove, sharesVolume: false
        ) == .move)
    }

    @Test("a modifier the source does not offer is ignored, not refused")
    func unofferedModifierIsIgnored() {
        let forceMove = TransferAdmission.DragModifiers(forcesCopy: false, forcesMove: true)
        // An external drag (Finder) offers copy only; Command must still drop, as a copy.
        #expect(TransferAdmission.kind(
            offer: copyOnly, modifiers: forceMove, sharesVolume: true
        ) == .copy)
    }

    @Test("a source offering neither is no drop at all")
    func nothingOfferedIsNoDrop() {
        let neither = TransferAdmission.DragOffer(allowsCopy: false, allowsMove: false)
        #expect(TransferAdmission.kind(
            offer: neither, modifiers: .none, sharesVolume: true
        ) == nil)
    }

    @Test("a move-only source moves even across volumes — there is nothing else it can do")
    func moveOnlySourceMoves() {
        let moveOnly = TransferAdmission.DragOffer(allowsCopy: false, allowsMove: true)
        #expect(TransferAdmission.kind(
            offer: moveOnly, modifiers: .none, sharesVolume: false
        ) == .move)
    }
}
