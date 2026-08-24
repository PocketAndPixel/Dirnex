import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The two flows that trashed items behind a `try?` until 2026-08-25, so on a volume that keeps no
/// Trash they did nothing and said nothing: the F6 move into an archive (which silently became a
/// copy) and a directory sync's deletes (which reported a mirror it had not made).
///
/// Both now reach the offer F8 already had, so what each test asserts is the **backend's
/// `removeItem`** — nothing about either flow's decisions was broken before, and a build that
/// merely worded things better would pass any assertion weaker than "the work was asked for"
/// (the reason `RemoteFetchPromptTests` rests on its copy count).
///
/// `.serialized` on the merits — the shared external state is the app's own sheet machinery, and
/// these seven tests are the only ones here that drive it. Measured both ways over the full app
/// suite: without it, `RemoteFetchPromptTests`' bounded wait for its own deferred sheet expired in
/// **1 run of 4**, naming a feature that works; with it, 6 of 6 green. That failure mode is the one
/// docs/NOTES.md ▸ Testing describes — a neighbour's wait expiring reads as a broken feature, so
/// the cheap fix belongs on the suite that costs it rather than on the suite that reports it.
@MainActor
@Suite("Trash-less volume flows", .serialized)
struct TrashlessVolumeFlowTests {
    // MARK: - F6: move into an archive

    /// The reported half: the items are already in the archive, so the move is finished only once
    /// the originals go. Answering **Delete** must actually delete them — with the `try?` in place
    /// this backend is never asked for anything at all.
    @Test("a refused archive-move original asks, and the answer deletes it")
    func archiveMoveOffersAndDeletes() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend()
        let pane = TrashlessProbe.pane(with: backend, in: window)
        let entry = TrashlessProbe.file("photo.raw")

        pane.removeArchiveMoveOriginals([entry])

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the offer never appeared")
        // Nothing may be gone while the question is on screen: a refusal moves nothing, so this is
        // a question and not a report of something already done.
        #expect(backend.removedPaths.isEmpty)
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
        await settle { !backend.removedPaths.isEmpty }

        #expect(backend.removedPaths == [entry.path])
        // The Trash was genuinely attempted first — this is a fallback, not a replacement.
        #expect(backend.trashAttempts == 1)
    }

    /// Declining is a legitimate ending here, unlike F8: the archive holds the items, so what the
    /// user has is a copy. That has to be *said* — the whole defect was a move quietly meaning
    /// something else, and a "no" that reports nothing recreates it one gesture later.
    @Test("declining keeps the originals and says the move became a copy")
    func archiveMoveDeclineReportsTheCopy() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend()
        let pane = TrashlessProbe.pane(with: backend, in: window)

        pane.removeArchiveMoveOriginals([TrashlessProbe.file("photo.raw")])

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the offer never appeared")
        try #require(TrashlessProbe.cancelButton(in: sheet)).performClick(nil)

        await settle { pane.transientStatus != nil }
        #expect(pane.transientStatus != nil, "the move ended as a copy and nothing said so")
        // Declining must leave the files exactly where they are.
        await hold(until: { !backend.removedPaths.isEmpty })
        #expect(backend.removedPaths.isEmpty)
    }

    /// The narrowness control: a permission failure is a real failure. It keeps its own report,
    /// nothing is deleted, and the status line does not claim the move ended as a copy — that
    /// sentence is about a volume with no Trash, not about anything going wrong.
    @Test("an archive move's real failure is not turned into an offer to delete for good")
    func archiveMoveRealFailureIsNotAnOffer() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend(refusal: .permissionDenied)
        let pane = TrashlessProbe.pane(with: backend, in: window)

        pane.removeArchiveMoveOriginals([TrashlessProbe.file("photo.raw")])

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the failure was never reported")
        #expect(TrashlessProbe.isFailureReport(sheet), "a real failure was offered as a delete")
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
        await settle { window.attachedSheet == nil }

        #expect(backend.removedPaths.isEmpty)
        #expect(pane.transientStatus == nil)
    }

    // MARK: - Directory sync

    /// A sync's deletes are what the run promised up front ("…will move N items to the Trash"), so
    /// a refusal leaves the two sides unequal — the one thing the operation exists to fix.
    @Test("a refused sync delete asks, and the answer deletes")
    func syncDeleteOffersAndDeletes() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend()
        let pane = TrashlessProbe.pane(with: backend, in: window)
        let path = TrashlessProbe.file("stale.txt").path

        pane.runSyncDeletes([path])

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the offer never appeared")
        #expect(backend.removedPaths.isEmpty)
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
        await settle { !backend.removedPaths.isEmpty }

        #expect(backend.removedPaths == [path])
    }

    /// The decision the sync flow turns on: a batch may span hundreds of items and the refusal
    /// cannot be known before the run, so it is collected and asked **once** at the end — never per
    /// item, which would be an obstacle rather than a question. One answer covers the whole batch,
    /// and no second sheet follows it (the permanent re-run consults no Trash, so it can refuse
    /// nothing of its own).
    @Test("a whole batch of refusals is one question, and the answer covers all of it")
    func syncBatchAsksOnce() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend()
        let pane = TrashlessProbe.pane(with: backend, in: window)
        let paths = ["a.txt", "b.txt", "c.txt"].map { TrashlessProbe.file($0).path }

        pane.runSyncDeletes(paths)

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the offer never appeared")
        // Every item was attempted before anything was asked — the question is about the run, not
        // about the item that happened to fail first.
        #expect(backend.trashAttempts == paths.count)
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
        await settle { backend.removedPaths.count == paths.count }

        #expect(backend.removedPaths == paths)
        await hold(until: { window.attachedSheet != nil })
        #expect(window.attachedSheet == nil, "the run asked a second time")
    }

    /// The sync's narrowness control, and the one that matters most here: a sync must never
    /// escalate a failure it met into an irreversible delete of a file the user only asked to move
    /// to the Trash.
    @Test("a sync's real failure is not turned into an offer to delete for good")
    func syncRealFailureIsNotAnOffer() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend(refusal: .permissionDenied)
        let pane = TrashlessProbe.pane(with: backend, in: window)

        pane.runSyncDeletes([TrashlessProbe.file("stale.txt").path])

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the failure was never reported")
        #expect(TrashlessProbe.isFailureReport(sheet), "a real failure was offered as a delete")
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
        await settle { window.attachedSheet == nil }

        #expect(backend.removedPaths.isEmpty)
    }

    /// And the control that keeps the fix from being worse than the bug: an ordinary sync on a
    /// volume that *does* trash must end silently, with no permanent-delete confirmation anywhere
    /// near it.
    @Test("a sync that trashes normally asks nothing")
    func syncOnAVolumeWithATrashIsSilent() async {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend(refusal: .trashesNormally)
        let pane = TrashlessProbe.pane(with: backend, in: window)

        pane.runSyncDeletes([TrashlessProbe.file("stale.txt").path])

        await hold(until: { window.attachedSheet != nil })
        #expect(window.attachedSheet == nil)
        #expect(backend.removedPaths.isEmpty)
        #expect(backend.trashAttempts == 1)
    }
}
