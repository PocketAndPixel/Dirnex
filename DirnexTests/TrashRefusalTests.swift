import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app half of a move-to-Trash the volume cannot perform: which failures stop being failures
/// and become the offer of a permanent delete instead (a mounted SMB share, reported 2026-08-25).
///
/// What is pinned here is the F8 chain end to end. The *classification* moved to the core with
/// ``TrashRefusal`` once three flows came to share it, and is pinned in `DeletePassTests`; the two
/// sibling flows that reach the same offer are in `TrashlessVolumeFlowTests`. The keystroke itself
/// is verified live against a real share.
@MainActor
@Suite("Trash refusal")
struct TrashRefusalTests {
    // MARK: - The offer

    /// A delete pass in which nothing was refused must raise no sheet at all. Without the guard,
    /// every ordinary Trash delete on every volume would end in a permanent-delete confirmation —
    /// which is the one way this fix could be worse than the bug.
    @Test("an empty refusal list raises nothing")
    func emptyRefusalRaisesNothing() async {
        let window = TrashlessProbe.window()
        defer { window.close() }
        let backend = RefusingBackend()
        let pane = TrashlessProbe.pane(with: backend, in: window)

        pane.offerPermanentDelete(forVolumeWithoutTrash: []) { _ in }

        await hold(until: { window.attachedSheet != nil })
        #expect(window.attachedSheet == nil)
        #expect(backend.removedPaths.isEmpty)
    }

    // MARK: - The whole chain

    /// The reported bug end to end: F8 over a volume that keeps no Trash must not report a number.
    /// It asks, and answering **Delete** must actually delete — which is the only thing that can
    /// tell this build from one that merely worded the failure more kindly.
    ///
    /// The assertion is the backend's `removeItem`, for the reason `RemoteFetchPromptTests` rests
    /// on its copy count: nothing about the *decision* was broken before, so only whether the work
    /// was asked for separates the two versions.
    @Test("a refused Trash delete asks, and the answer performs the permanent delete")
    func refusedTrashOffersAndDeletes() async throws {
        let window = TrashlessProbe.window()
        defer { window.close() }
        let backend = RefusingBackend()
        let pane = TrashlessProbe.pane(with: backend, in: window)
        let entry = TrashlessProbe.file("t.txt")

        pane.runDelete([entry.path], permanent: false)

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the offer never appeared")
        // Nothing may have been deleted while the question is still on screen: the refusal happens
        // before any bytes move, so this is a question and not a report of something already done.
        #expect(backend.removedPaths.isEmpty)
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
        await settle { !backend.removedPaths.isEmpty }

        #expect(backend.removedPaths == [entry.path])
        // And the Trash was genuinely attempted first — this is a fallback, not a replacement.
        #expect(backend.trashAttempts == 1)
    }

    /// The narrowness control, and the half that keeps "offer a permanent delete" from becoming
    /// "offer it whenever anything goes wrong". A permission failure is a real failure: it keeps
    /// its own report, and nothing is deleted.
    @Test("a genuine failure is not turned into an offer to delete for good")
    func realFailureIsNotAnOffer() async {
        let window = TrashlessProbe.window()
        defer { window.close() }
        let backend = RefusingBackend(refusal: .permissionDenied)
        let pane = TrashlessProbe.pane(with: backend, in: window)

        pane.runDelete([TrashlessProbe.file("t.txt").path], permanent: false)

        await settle { window.attachedSheet != nil }
        // The failure alert is what appears here; whichever sheet it is, pressing its default
        // button must not delete anything.
        if let sheet = window.attachedSheet, let button = TrashlessProbe.defaultButton(in: sheet) {
            button.performClick(nil)
        }
        await hold(until: { !backend.removedPaths.isEmpty })
        #expect(backend.removedPaths.isEmpty)
    }
}
