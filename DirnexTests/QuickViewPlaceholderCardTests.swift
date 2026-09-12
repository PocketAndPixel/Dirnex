import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The placeholder card's two buttons, which are the whole of what a user can *do* about a remote
/// file the preview declined to fetch (PLAN.md §M21 Slice 10).
///
/// The surface swallows the mouse everywhere else on purpose — a click under a preview would move
/// the covered pane's cursor invisibly — so these controls exist only insofar as `hitTest` exempts
/// them. That exemption is a list of views, and a view being *on the list* is not the same as it
/// being the one the mouse reaches: everything the surface holds is pinned into one container, so
/// whichever was added last is on top. Nothing else in the suite can see that, because every other
/// backend is the only visible thing in the container when it is asked about.
@Suite("Quick View placeholder card")
@MainActor
struct QuickViewPlaceholderCardTests {
    /// The click the card is for.
    ///
    /// **The order the surface builds its subviews in decides this**, which is why the card is shown
    /// on a surface that has never displayed anything else — the state a pane is in when Quick View
    /// is switched on with the cursor already sitting on a remote file, i.e. exactly how the mode is
    /// reached. Shipped, that put the (item-less, transparent, and therefore invisible)
    /// `QLPreviewView` on top of the card: it answers `hitTest` and then declines the event, so the
    /// surface swallowed every press and the Download button was dead for the whole session.
    /// Reported by a user 2026-08-14.
    @Test("Download is clickable on a surface whose first content is the card")
    func downloadTakesTheMouse() throws {
        let preview = Self.surface()
        var asked = false
        preview.placeholderActions = RemotePreviewActions(
            download: { asked = true }, stop: {}, progress: { nil }, downloadShortcut: nil
        )
        preview.show(
            nil,
            style: .default,
            placeholder: Self.placeholder(.awaitingRequest(.tooLarge))
        )
        let card = try #require(preview.placeholderCard)
        preview.superview?.layoutSubtreeIfNeeded()

        let hit = try #require(preview.hitTest(Self.center(of: card.downloadButton, in: preview)))
        #expect(hit.isDescendant(of: card.downloadButton))
        // The hit is what the mouse reaches; that it *runs* the action is the other half, and the
        // one that says the button is wired to the pane rather than merely reachable.
        (hit as? NSButton ?? card.downloadButton).performClick(nil)
        #expect(asked)
    }

    /// Stop is the same exemption on the other state, and it is the one that can never be reached
    /// by a surface that has shown something first — a download only ever starts from this card.
    @Test("Stop is clickable while a download is running")
    func stopTakesTheMouse() throws {
        let preview = Self.surface()
        var stopped = false
        preview.placeholderActions = RemotePreviewActions(
            download: {}, stop: { stopped = true }, progress: { nil }, downloadShortcut: nil
        )
        preview.show(nil, style: .default, placeholder: Self.placeholder(.downloading))
        let card = try #require(preview.placeholderCard)
        preview.superview?.layoutSubtreeIfNeeded()

        let hit = try #require(preview.hitTest(Self.center(of: card.stopButton, in: preview)))
        #expect(hit.isDescendant(of: card.stopButton))
        (hit as? NSButton ?? card.stopButton).performClick(nil)
        #expect(stopped)
    }

    /// The other half of the invariant, and the reason the exemption is the two *buttons* rather
    /// than the card: a press on the card's own body must still be swallowed, or a click beside the
    /// button moves the covered pane's cursor to whatever row is under it.
    @Test("the card's body still swallows the mouse")
    func cardBodyIsStillSwallowed() throws {
        let preview = Self.surface()
        preview.placeholderActions = RemotePreviewActions(
            download: {}, stop: {}, progress: { nil }, downloadShortcut: nil
        )
        preview.show(
            nil,
            style: .default,
            placeholder: Self.placeholder(.awaitingRequest(.tooLarge))
        )
        let card = try #require(preview.placeholderCard)
        preview.superview?.layoutSubtreeIfNeeded()

        // The card fills the surface, so its top-left corner is card body and nothing else.
        let corner = try #require(preview.superview).convert(NSPoint(x: 6, y: 6), from: card)
        #expect(preview.hitTest(corner) === preview)
    }

    /// The card's bar carries the same staleness the queue bar's does, and for the same reason: it
    /// is hidden between downloads rather than emptied, so whatever the last transfer left on it is
    /// what the next one reveals. Reported together with the queue bar's on 2026-08-19 — "started
    /// from 100 % before loading the image".
    ///
    /// **The model is the only thing a headless test can see, and it is enough — but only if it is
    /// read at the right moment.** Zeroing the value on the way *in* (which `startPolling` has
    /// always done) leaves the model reading 0 the whole time the next download runs, while the
    /// *presentation* layer goes on showing the old fill for a frame; sampling it in the running app
    /// caught 0.96 at the reveal, empty 11 ms later. So the claim to pin is the one about the
    /// **exit**: when the card stops drawing a download, the bar is already empty.
    ///
    /// Both exits are covered because the ordinary one is not the obvious one: the bytes landing
    /// hides the card outright (no state is re-applied), which is exactly why the first version of
    /// this fix — keyed on a non-downloading state — never ran.
    @Test(
        "a finished download leaves the card's bar empty, however the card leaves",
        arguments: [true, false]
    )
    func aFinishedDownloadEmptiesTheBar(showingAFile: Bool) async throws {
        let preview = Self.surface()
        let moved = ByteCounter()
        moved.value = 29_000_000
        preview.placeholderActions = RemotePreviewActions(
            download: {}, stop: {}, progress: { moved.value }, downloadShortcut: nil
        )
        preview.show(nil, style: .default, placeholder: Self.placeholder(.downloading))
        let card = try #require(preview.placeholderCard)

        // The poll is a task, so wait for it rather than spinning the run loop (docs/NOTES.md ▸
        // Testing) — a run-loop spin drives layout but never lands an awaited result.
        let deadline = Date().addingTimeInterval(2)
        while card.progressFraction == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(card.progressFraction == 1, "the download filled the bar: \(card.progressFraction)")

        if showingAFile {
            // What actually happens: the bytes arrive and the preview shows the file, which stands
            // the card down without applying any state to it.
            preview.show(Self.imageFile, style: .default, placeholder: nil)
        } else {
            // The other exit: the transfer stopped or failed, so the card stays up saying so.
            preview.show(nil, style: .default, placeholder: Self.placeholder(.stopped))
        }
        #expect(card.progressFraction == 0, "the next download would open on the last one's fill")
    }

    // MARK: - Helpers

    /// A surface in a window with a real frame, and — deliberately — nothing shown in it yet.
    private static func surface() -> QuickViewPreviewView {
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        guard let content = window.contentView else { return preview }
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return preview
    }

    private static func placeholder(
        _ state: RemotePreviewPlaceholder.State
    ) -> RemotePreviewPlaceholder {
        RemotePreviewPlaceholder(
            name: "DSC_0002.NEF", size: "29 MB", byteSize: 29_000_000, state: state
        )
    }

    /// Any real file the image backend will take, so the card is stood down the way the bytes
    /// landing stands it down. Its content is irrelevant — what is under test is the card.
    private static let imageFile = Bundle(for: QuickViewPreviewView.self).bundleURL
        .appendingPathComponent("Contents/Resources/AppIcon.icns")

    /// `hitTest` takes a point in the *superview's* space, which is where a real click arrives.
    private static func center(of view: NSView, in preview: QuickViewPreviewView) -> NSPoint {
        let middle = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        return preview.superview?.convert(middle, from: view) ?? middle
    }
}
