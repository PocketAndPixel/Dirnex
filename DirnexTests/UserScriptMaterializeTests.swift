import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Running a user script over rows that are not on this disk (PLAN.md §M24 Slice 5).
///
/// Scripts were the fourth of the seven local-only gestures to stop refusing, and the one with a
/// second half nothing before it needed: a script may **write to** what it is handed. So there are
/// two claims here that pull against each other, and they are pinned together for that reason — the
/// copies must reach the shell, and a save to one of them must not be left in a temp directory
/// nobody will look in again.
///
/// Neither the transfer nor the process is under test. `MaterializeRunner` owns the first and is
/// tested in the core against a real backend; `UserScriptRunnerTests` owns the second. What an app
/// test can see is what the **gesture** did: which rows it queued, which copies it registered for
/// write-back, and what it told the shell about where it is.
@MainActor
@Suite("Running a script over rows that are not here")
struct UserScriptMaterializeTests {
    /// A script that cannot fail, so no run reaches `presentOperationFailure` — which in a
    /// window-less pane is `runModal()` and wedges the whole suite on a dialog nobody can click
    /// (docs/NOTES.md ▸ Testing).
    private let harmless = UserScript(name: "Nothing", command: "true", runMode: .combined)

    // MARK: - Where a script can run

    @Test("a panel on this disk names itself; one that is not names nothing")
    func localPanelDirectoryAnswersPerPanel() {
        let (localPane, localHost) = hostedPane(at: .local("/tmp/here"))
        let (remotePane, remoteHost) = hostedPane(
            at: VFSPath(backend: Handoff.remoteID, path: "/srv")
        )
        #expect(localPane.localPanelDirectory == "/tmp/here")
        #expect(remotePane.localPanelDirectory == nil)
        withExtendedLifetime((localHost, remoteHost)) {}
    }

    /// The one panel where the two spellings of this question disagree, and the reason it goes
    /// through `writeDirectory`: the merged iCloud listing's own path is synthetic while the folder
    /// underneath it is perfectly real, so a fresh `panel.path.backend == .local` would tell a script
    /// there is nowhere here about a directory the user can create files in.
    ///
    /// Skipped rather than failed on a Mac with no iCloud container, where `writeDirectory` itself
    /// answers `nil` and the claim has nothing to be about. Non-vacuous where it was written.
    @Test("the merged iCloud listing names the real folder underneath it")
    func iCloudListingNamesItsRealHome() {
        guard let real = SidebarLocations.iCloudDrive() else { return }
        let (pane, host) = hostedPane(at: VFSPath(backend: .icloud, path: "/iCloud Drive"))
        #expect(pane.localPanelDirectory == real.path)
        withExtendedLifetime(host) {}
    }

    /// The gate is "somewhere to run **or** something to run on", which is what lets a marked set on
    /// a server reach a script at all while a panel with neither goes on refusing.
    @Test("the gate opens for a local panel, for marked remote rows, and for nothing else")
    func gateOpensOnEitherHalf() {
        let (local, localHost) = hostedPane(at: .local("/tmp/here"))
        #expect(local.canRunUserScript)

        let row = Handoff.remote("/srv/report.pdf")
        let (marked, markedHost) = hostedPane(
            showing: [row], at: VFSPath(backend: Handoff.remoteID, path: "/srv")
        )
        marked.panel.moveCursor(to: 0)
        #expect(marked.canRunUserScript)

        let (bare, bareHost) = hostedPane(at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        #expect(!bare.canRunUserScript)
        withExtendedLifetime((localHost, markedHost, bareHost)) {}
    }

    /// A panel that is not a folder on this disk tells the script **nothing** about where the user
    /// is, rather than handing over the temp directory one copy happens to sit in.
    @Test("a panel with no folder omits DIRNEX_CURRENT_DIR entirely")
    func remotePanelOmitsTheCurrentDirectory() throws {
        let (pane, host) = hostedPane(at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        let copy = try Handoff.temporaryFile(named: "report.pdf")

        let environment = pane.scriptContext(selection: [copy]).environment()

        #expect(environment[UserScriptEnvironment.currentDirectory] == nil)
        // The files are what the script acts on, and they are as real as they ever were.
        #expect(environment[UserScriptEnvironment.selectedPaths] == copy.path)
        withExtendedLifetime(host) {}
    }

    @Test("a panel on this disk still names itself to the script")
    func localPanelNamesTheCurrentDirectory() {
        let (pane, host) = hostedPane(at: .local("/tmp/here"))
        let environment = pane.scriptContext(selection: []).environment()
        #expect(environment[UserScriptEnvironment.currentDirectory] == "/tmp/here")
        withExtendedLifetime(host) {}
    }

    // MARK: - What the gesture does with the set

    /// The control that keeps every other claim here from being bought at the price of the common
    /// case: a marked set of plain local files runs with nothing queued and nothing watched.
    @Test("a set already on this disk runs with no job and nothing to write back")
    func localSetRunsWithNoJob() throws {
        let file = try Handoff.temporaryFile(named: "a.txt")
        let row = Handoff.local(file.path)
        let hosted = windowedPane(showing: [row], at: .local(file.deletingLastPathComponent().path))
        hosted.pane.panel.moveCursor(to: 0)

        hosted.pane.runScript(harmless)

        #expect(hosted.host.materializedEntries.isEmpty)
        #expect(!hosted.host.editedFiles.isWatching(file))
    }

    @Test("a remote set is queued, and the copies are what the script is handed")
    func remoteSetIsQueuedAndCopiesAreWatched() throws {
        let row = Handoff.remote("/srv/report.pdf")
        let copy = try Handoff.temporaryFile(named: "report.pdf")
        let hosted = windowedPane(
            showing: [row], at: VFSPath(backend: Handoff.remoteID, path: "/srv")
        )
        hosted.host.materializeReport = Handoff.report(landing: [(row, copy)])
        hosted.pane.panel.moveCursor(to: 0)

        hosted.pane.runScript(harmless)

        #expect(hosted.host.materializedEntries.map { $0.map(\.path) } == [[row.path]])
        // The headline half of the slice: the copy the shell was handed is watched, so a script
        // that rewrites it gets that save offered back up to the server it came from.
        #expect(hosted.host.editedFiles.isWatching(copy))
    }

    // MARK: - Where an edited copy goes back to

    @Test("a row already on this disk has nowhere to go back to")
    func localRowHasNoDestination() {
        let (pane, host) = hostedPane()
        #expect(pane.editDestination(for: Handoff.local("/tmp/a.txt")) == nil)
        withExtendedLifetime(host) {}
    }

    @Test("a remote file goes back to its own path; a remote folder goes nowhere")
    func remoteFileHasADestination() {
        let (pane, host) = hostedPane()
        let file = Handoff.remote("/srv/report.pdf")
        #expect(pane.editDestination(for: file) == .remoteFile(file.path))
        // A directory is not a file somebody can save, and `canEditRemoteFile` says so — the same
        // answer F4 gives it.
        #expect(pane.editDestination(for: Handoff.remote("/srv/docs", kind: .directory)) == nil)
        withExtendedLifetime(host) {}
    }

    @Test("an archive member goes back to the directory it came from inside the archive")
    func archiveMemberCarriesItsInnerDirectory() {
        let (pane, host) = hostedPane()
        let member = Handoff.entry(
            VFSPath(backend: .archive(forArchiveAt: "/tmp/bundle.zip"), path: "/docs/note.txt")
        )
        #expect(
            pane.editDestination(for: member)
                == .archiveMember(archivePath: "/tmp/bundle.zip", innerDirectory: "/docs")
        )
        withExtendedLifetime(host) {}
    }

    /// The pairing is positional, so a set that does not line up is not guessed at: `materialize`
    /// only ever hands back one URL per row, and a mismatch here could only mean somebody changed
    /// that rule.
    @Test("rows and copies that do not line up are not paired")
    func mismatchedPairingWatchesNothing() throws {
        let (pane, host) = hostedPane()
        let copy = try Handoff.temporaryFile(named: "report.pdf")

        pane.watchForWriteBack(
            of: [Handoff.remote("/srv/report.pdf"), Handoff.remote("/srv/other.pdf")],
            at: [copy]
        )

        #expect(!host.editedFiles.isWatching(copy))
    }
}
