import Testing
@testable import DirnexCore

/// A folder in a drag: itself for every app, and a zip of itself for any app the pointer enters with
/// Shift held (2026-11-09). Gmail fails on a folder and VLC takes one, and nothing tells a drag which an
/// app wants, so the user chooses. On entry, because Teams and Chrome drop what they read then: Oleg's
/// six logged drops with ⇧ pressed over the app took the folder (`RemoteDragHandoff`).
@Suite("Remote drag handoff, folders and Shift")
struct RemoteDragHandoffShiftTests {
    private let finder = RemoteDragHandoff.Surface.finder(processID: 10)
    private let teams = RemoteDragHandoff.Surface.otherApp(processID: 20)
    private let slack = RemoteDragHandoff.Surface.otherApp(processID: 30)

    // MARK: - A folder on a server

    /// A handoff for a drag holding a folder on a server, whose pointer has reached `surface`.
    private func enteredWithFolder(
        _ surface: RemoteDragHandoff.Surface,
        shiftHeld: Bool = false
    ) -> RemoteDragHandoff {
        var handoff = RemoteDragHandoff(holdsFolders: true)
        _ = handoff.pointerMoved(over: surface, shiftHeld: shiftHeld)
        return handoff
    }

    /// VLC takes a folder and a zip is no use to it (2026-11-09): without Shift the folder goes as
    /// itself, and a server's folder is staged for it as a file would be fetched.
    @Test("Without Shift another app is offered the folder itself")
    func folderGoesAsItselfWithoutShift() {
        var handoff = RemoteDragHandoff(holdsFolders: true)
        #expect(handoff.pointerMoved(over: teams) == [.writeLazyFileURLs, .startTransfer])
        #expect(handoff.form == .folders)
        _ = handoff.transferLanded()
        #expect(handoff.compression == .notStarted)
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
    }

    /// A server's folder is zipped from its staged tree, so the zip waits for the transfer.
    @Test("With Shift the zip starts once the transfer has landed, and the read waits for both")
    func zipWaitsForTheTransfer() {
        var handoff = RemoteDragHandoff(holdsFolders: true)
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true) == [
            .writeLazyFileURLs, .startTransfer
        ])
        #expect(handoff.form == .zips)
        #expect(handoff.compression == .notStarted)
        #expect(handoff.readFileURL(from: teams) == .wait)
        #expect(handoff.transferLanded() == [.startCompression])
        #expect(handoff.readFileURL(from: teams) == .wait)
        #expect(handoff.compressionLanded().isEmpty)
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
    }

    /// What Oleg's logged drops met: ⇧ pressed over Teams was read and ignored, so the board waits for
    /// the next entry rather than promising what the drop will not take.
    @Test("A Shift change over the app the pointer is in waits for the next entry")
    func shiftCountsOnEntry() {
        var handoff = enteredWithFolder(teams)
        _ = handoff.transferLanded()
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true).isEmpty)
        #expect(handoff.form == .folders)
        #expect(handoff.pointerMoved(over: .neutral, shiftHeld: true).isEmpty)
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true) == [
            .writeLazyFileURLs, .startCompression
        ])
        #expect(handoff.form == .zips)
        _ = handoff.compressionLanded()
        // Letting go over the same app changes nothing either, until the pointer leaves and comes back.
        #expect(handoff.pointerMoved(over: teams).isEmpty)
        #expect(handoff.form == .zips)
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: teams) == [.writeFileURLs])
        #expect(handoff.form == .folders)
        // The zip made once serves every later entry with Shift, with nothing made again.
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true) == [.writeFileURLs])
    }

    /// Oleg, 2026-11-09: "let a user decide". Finder takes a folder fine, so the key is the only
    /// thing that asks for a zip, there as anywhere.
    @Test("Entering Finder with Shift asks for the zip too, and entering without it for the folder")
    func finderZipsWithShift() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        #expect(handoff.pointerMoved(over: finder, shiftHeld: true).isEmpty)
        #expect(handoff.form == .zips)
        #expect(handoff.pointerMoved(over: finder).isEmpty)
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: finder) == [.writeLazyFileURLs])
        #expect(handoff.form == .folders)
    }

    @Test("Finder keeps the promise until it is entered with Shift, which leaves it for the zip")
    func finderLeavesThePromiseOnlyForAZip() {
        var handoff = RemoteDragHandoff(holdsFolders: true)
        #expect(handoff.pointerMoved(over: finder).isEmpty)
        #expect(handoff.pointerMoved(over: finder, shiftHeld: true).isEmpty)
        #expect(handoff.board == .asBegun)
        _ = handoff.pointerMoved(over: .neutral, shiftHeld: true)
        #expect(handoff.pointerMoved(over: finder, shiftHeld: true) == [
            .writeLazyFileURLs, .startTransfer
        ])
        #expect(handoff.form == .zips)
    }

    /// Before Shift, a board rewritten for another app already offers each folder as itself, which is
    /// what Finder takes, so a crossing costs nothing.
    @Test("Without Shift Finder and another app share one board")
    func finderSharesTheFolderBoard() {
        var handoff = enteredWithFolder(teams)
        #expect(handoff.pointerMoved(over: finder).isEmpty)
        #expect(handoff.pointerMoved(over: slack).isEmpty)
    }

    @Test("Shift over Dirnex or the Dock changes nothing")
    func neutralIgnoresShift() {
        var handoff = enteredWithFolder(teams)
        #expect(handoff.pointerMoved(over: .neutral, shiftHeld: true).isEmpty)
        #expect(handoff.form == .folders)
    }

    /// Pinned beside the rest because the key must not leak: a drag of files reads one board
    /// everywhere, exactly as it did before folders could be zipped.
    @Test("Without a folder Shift changes nothing")
    func withoutAFolderShiftIsIgnored() {
        var handoff = RemoteDragHandoff()
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true) == [
            .writeLazyFileURLs, .startTransfer
        ])
        #expect(handoff.form == .folders)
        #expect(handoff.pointerMoved(over: teams).isEmpty)
        #expect(handoff.pointerMoved(over: finder, shiftHeld: true).isEmpty)
    }

    @Test(
        "Finder without Shift gets a board of its own, after another app was told nothing about a zip"
    )
    func finderWaitsOnItsOwnBoard() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        handoff.holdEnded(over: teams)
        #expect(handoff.readFileURL(from: teams) == .nothing)
        #expect(handoff.pointerMoved(over: finder) == [.writeLazyFileURLs])
        #expect(handoff.readFileURL(from: finder) == .wait)
    }

    @Test("A zip that fails is refused, while the folder itself is still offered")
    func failedZipLeavesTheFolder() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        _ = handoff.transferLanded()
        handoff.compressionFailed()
        #expect(handoff.readFileURL(from: teams) == .nothing)
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: teams) == [.writeFileURLs])
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
    }

    /// A server's folder that could not be staged has no tree to zip either.
    @Test("A failed transfer fails the zip too, and starts none")
    func failedTransferFailsTheZip() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        handoff.transferFailed()
        #expect(handoff.progress == .failed)
        #expect(handoff.compression == .notStarted)
        #expect(handoff.readFileURL(from: teams) == .nothing)
    }

    @Test("A zip landing after the hold ran out replaces the board that said nothing")
    func zipLandingReplacesARefusedBoard() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        _ = handoff.transferLanded()
        handoff.holdEnded(over: teams)
        #expect(handoff.compressionLanded() == [.writeFileURLs])
        #expect(handoff.board == .fileURLs)
    }

    // MARK: - Folders on this disk alone

    /// The board the drag began with is the folder's own URL, which every app can read: VLC took it
    /// first time (2026-11-09). So there is nothing to rewrite and nothing to make until Shift.
    private func localFolders() -> RemoteDragHandoff {
        RemoteDragHandoff(holdsFolders: true, beganWithPromises: false)
    }

    @Test("A folder on this disk is left as it began for every app until Shift is held over one")
    func localFolderIsLeftAlone() {
        var handoff = localFolders()
        #expect(handoff.pointerMoved(over: teams).isEmpty)
        #expect(handoff.pointerMoved(over: finder).isEmpty)
        #expect(handoff.pointerMoved(over: .neutral, shiftHeld: true).isEmpty)
        #expect(handoff.board == .asBegun)
        #expect(handoff.transfer == .notStarted)
    }

    @Test("Shift over Finder zips a folder on this disk as well")
    func localFolderZipsForFinder() {
        var handoff = localFolders()
        #expect(handoff.pointerMoved(over: finder, shiftHeld: true) == [
            .writeLazyFileURLs, .startTransfer
        ])
        #expect(handoff.form == .zips)
    }

    @Test(
        "Entering another app with Shift zips a folder on this disk, and entering without offers it again"
    )
    func localFolderZipsWithShift() {
        var handoff = localFolders()
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true) == [
            .writeLazyFileURLs, .startTransfer
        ])
        // Nothing to fetch, so the transfer lands at once and the zip follows.
        #expect(handoff.transferLanded() == [.startCompression])
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: teams) == [.writeFileURLs])
        #expect(handoff.form == .folders)
    }

    /// A drag of rows nothing is handed off for, such as a locked archive's member beside a file on
    /// this disk, keeps the board it began with.
    @Test("A drag with no promise and no folder never leaves its board")
    func plainDragIsLeftAlone() {
        var handoff = RemoteDragHandoff(beganWithPromises: false)
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true).isEmpty)
        #expect(handoff.board == .asBegun)
    }

    // MARK: - After a refusal

    /// A board of real URLs written on an entry is read on that entry, so nobody is told to come back.
    @Test("Only a board that replaced a refusal needs the pointer to leave and come back")
    func reentryOnlyAfterARefusal() {
        var handoff = enteredWithFolder(teams)
        _ = handoff.transferLanded()
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: teams, shiftHeld: true) == [
            .writeLazyFileURLs, .startCompression
        ])
        handoff.holdEnded(over: teams)
        #expect(handoff.compressionLanded() == [.writeFileURLs])
        #expect(handoff.needsReentry)
        _ = handoff.pointerMoved(over: .neutral)
        #expect(handoff.pointerMoved(over: teams) == [.writeFileURLs])
        #expect(!handoff.needsReentry)
    }

    // MARK: - The drag ending

    /// A zip serves nobody after the drag, so it is stopped however small the transfer was.
    @Test("A zip still being made is stopped, even when the transfer may finish")
    func endStopsAZip() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        _ = handoff.transferLanded()
        #expect(handoff.dragEnded(mayFinish: true) == [.stopTransfer])
    }

    @Test("A transfer that lands after the drag ended starts no zip")
    func noZipAfterTheEnd() {
        var handoff = enteredWithFolder(teams, shiftHeld: true)
        #expect(handoff.dragEnded(mayFinish: true).isEmpty)
        #expect(handoff.transferLanded().isEmpty)
        #expect(handoff.compression == .notStarted)
    }
}
