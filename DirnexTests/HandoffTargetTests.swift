import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which rows Open With and Share will act on, and what the app list is built from
/// (PLAN.md §M24 Slice 3).
///
/// The other half of the hand-off, and deliberately a separate suite: `HandoffMaterializeTests` is
/// about what happens to a set once the gesture has one, and everything here happens *before* that
/// — which rows qualify, which surfaces may offer them, and what the menu can say about a file
/// whose bytes are still on a server.
@MainActor
@Suite("Hand-off targets and the app list")
struct HandoffTargetTests {
    // MARK: - Which rows can be handed over at all

    /// A folder that is not on this disk stands for an unknown number of objects in an unknown
    /// number of requests, so it is dropped rather than weighed — copying a tree out is F5's job.
    @Test("a folder that is not here is not a hand-off target")
    func remoteFolderIsRefused() {
        let file = Handoff.remote("/srv/report.pdf")
        let folder = Handoff.remote("/srv/photos", kind: .directory)
        let (pane, host) = hostedPane(showing: [file, folder])
        pane.panel.toggleMark(at: 0)
        pane.panel.toggleMark(at: 1)

        #expect(pane.handoffEntries().map(\.path) == [file.path])
        #expect(host.materializedEntries.isEmpty)
    }

    /// The narrowness control, and the one that stops the rule above from becoming "no folders":
    /// "Open With ▸ Terminal" on a folder on this Mac is an ordinary thing to want, and it worked
    /// before this slice.
    @Test("a folder on this disk is still a hand-off target")
    func localFolderIsKept() {
        let folder = Handoff.local("/tmp/docs", kind: .directory)
        let (pane, host) = hostedPane(showing: [folder])

        #expect(pane.handoffEntries().map(\.path) == [folder.path])
        #expect(host.materializedEntries.isEmpty)
    }

    /// Services fills a pasteboard *synchronously*, so it cannot wait for a download — and asking
    /// the wider question there would advertise the pane to the Services menu for a selection
    /// `writeSelection` then declines to write, leaving items that do nothing.
    @Test("Services stays local while Open With and Share do not")
    func servicesStaysLocal() {
        let (pane, host) = hostedPane(showing: [Handoff.remote("/srv/report.pdf")])

        #expect(pane.canHandOff)
        #expect(!pane.canSendToServices)
        #expect(host.materializedEntries.isEmpty)
    }

    // MARK: - The app list

    /// The menu is built before anything is downloaded, so a row that is not here is typed by its
    /// **name** — and the list has to be the one the same file would get on this disk, or showing it
    /// first buys nothing.
    @Test("a remote row offers the same applications a local file of that type does")
    func remoteRowIsTypedByItsName() throws {
        let onDisk = try Handoff.temporaryFile(named: "note.txt")
        defer { try? FileManager.default.removeItem(at: onDisk.deletingLastPathComponent()) }

        let fromDisk = OpenWithLauncher.candidates(for: [Handoff.local(onDisk.path)])
        let fromName = OpenWithLauncher.candidates(for: [Handoff.remote("/srv/note.txt")])

        // Asserted against the machine rather than a fixed list, like `OpenWithLauncherTests`: which
        // editors are installed is not this test's business, but the two answers must agree.
        #expect(!fromDisk.isEmpty)
        #expect(fromName.defaultApplication == fromDisk.defaultApplication)
        #expect(fromName.others == fromDisk.others)
    }

    /// A remote row with no extension has nothing to be typed by, and the menu says so rather than
    /// guessing — the same reading the core already gives an untypeable local file.
    @Test("a remote row with no extension offers nothing rather than guessing")
    func remoteRowWithNoExtensionOffersNothing() {
        #expect(OpenWithLauncher.candidates(for: [Handoff.remote("/srv/README")]).isEmpty)
    }
}
