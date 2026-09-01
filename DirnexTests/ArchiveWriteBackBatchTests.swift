import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Edited archive members written back as **one rewrite per archive** (PLAN.md §4 ▸ *Still open*,
/// taken 2026-09-01).
///
/// The cost this closes is not the same as the remote half's. An upload is per file, so forty of
/// them was forty transfers nobody could see or stop; a **rewrite is per container**, so forty
/// saves was forty full passes over one archive — each extracting and re-compressing everything the
/// previous had just written — with forty sheets in front of them. What these pin is the grouping
/// that turns that into one pass, and the sentences that go with it.
@Suite("Archive save-back batch")
@MainActor
struct ArchiveWriteBackBatchTests {
    private func pending(
        _ name: String,
        in archive: String = "/Users/me/pkg.zip",
        at innerDirectory: String = "/"
    ) -> PendingArchiveWriteBack {
        PendingArchiveWriteBack(
            edit: EditedFile(
                destination: .archiveMember(
                    archivePath: archive, innerDirectory: innerDirectory
                ),
                temporaryURL: URL(fileURLWithPath: "/tmp/edits/\(name)"),
                name: name
            ),
            archivePath: archive,
            innerDirectory: innerDirectory
        )
    }

    private func group(_ items: [PendingArchiveWriteBack]) -> ArchiveWriteBackGroup {
        ArchiveWriteBackGroup(archivePath: items[0].archivePath, items: items)
    }

    // MARK: - Grouping

    @Test("every member of one archive is one group, so one rewrite")
    func oneArchiveIsOneGroup() {
        // The whole change: forty saves into one archive used to be forty extract-and-repack
        // passes over the same container.
        let batch = (1...40).map { pending("f\($0).txt") }
        let groups = ArchiveWriteBackPlan.groups(of: batch)
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 40)
    }

    @Test("two archives are two groups, in the order their first save arrived")
    func twoArchivesKeepFirstSeenOrder() {
        // Order between groups decides the order the sheets arrive in, and a dictionary's own
        // order would differ run to run for the same edits.
        let batch = [
            pending("a.txt", in: "/Users/me/second.zip"),
            pending("b.txt", in: "/Users/me/first.zip"),
            pending("c.txt", in: "/Users/me/second.zip")
        ]
        let groups = ArchiveWriteBackPlan.groups(of: batch)
        #expect(groups.map(\.archivePath) == ["/Users/me/second.zip", "/Users/me/first.zip"])
        #expect(groups[0].items.map(\.edit.name) == ["a.txt", "c.txt"])
        #expect(groups[1].items.map(\.edit.name) == ["b.txt"])
    }

    @Test("members from different folders inside one archive still travel in one pass")
    func differentInnerDirectoriesStayTogether() {
        // The reason `ArchiveWriter.add` grew an `Addition` pair: its single-directory spelling
        // could not express this batch at all, so it would have had to become one rewrite per
        // folder — which for a container-sized cost is barely better than one per file.
        let batch = [
            pending("a.txt", at: "/"),
            pending("b.txt", at: "/docs"),
            pending("c.txt", at: "/docs/api")
        ]
        let groups = ArchiveWriteBackPlan.groups(of: batch)
        #expect(groups.count == 1)
        #expect(groups[0].additions.map(\.innerDirectory) == ["/", "/docs", "/docs/api"])
        #expect(groups[0].additions.map(\.localPath)
            == ["/tmp/edits/a.txt", "/tmp/edits/b.txt", "/tmp/edits/c.txt"])
    }

    @Test("order within a group is the order the saves were gathered")
    func withinAGroupOrderIsPreserved() {
        // `ArchiveWriter.add` replaces as it goes, so for two saves of the same member the last
        // one wins — and "last" has to mean the newest save rather than whatever a grouping
        // happened to produce.
        let batch = [pending("a.txt"), pending("b.txt"), pending("c.txt")]
        #expect(ArchiveWriteBackPlan.groups(of: batch)[0].items.map(\.edit.name)
            == ["a.txt", "b.txt", "c.txt"])
    }

    @Test("an empty batch is no groups rather than one empty one")
    func emptyBatchIsNoGroups() {
        #expect(ArchiveWriteBackPlan.groups(of: []).isEmpty)
    }

    // MARK: - Which ending each save takes

    @Test("a mixed batch is split by destination, each half in the batch's own order")
    func mixedBatchIsSplit() {
        // The one failure here that would be quiet: an archive member handed to the remote ending
        // would try to upload to an `archive:` path, and the sentence the user reads would be about
        // a server they were never on.
        let remotePath = VFSPath(
            backend: .sftp(SFTPLocation(host: "srv", username: "oleg")),
            path: "/home/oleg/r.txt"
        )
        let batch = [
            pending("a.txt").edit,
            EditedFile(
                destination: .remoteFile(remotePath),
                temporaryURL: URL(fileURLWithPath: "/tmp/edits/r.txt"),
                name: "r.txt"
            ),
            pending("b.txt", in: "/Users/me/other.zip").edit
        ]
        let split = BrowserWindowController.split(batch)
        #expect(split.remote.map(\.edit.name) == ["r.txt"])
        #expect(split.members.map(\.edit.name) == ["a.txt", "b.txt"])
        #expect(split.members.map(\.archivePath) == ["/Users/me/pkg.zip", "/Users/me/other.zip"])
    }

    // MARK: - What the user reads

    @Test("one member keeps the sentence it has always had")
    func singleMemberWordingIsUnchanged() {
        let one = group([pending("notes.txt")])
        let title = BrowserWindowController.archiveWriteBackTitle(one)
        #expect(title.contains("notes.txt"))
        #expect(title.contains("pkg.zip"))
        // "a copy", singular — the batch must not make the ordinary single save read like a report
        // about a set.
        #expect(BrowserWindowController.archiveWriteBackBody(one, undoable: true).contains("a copy"))
    }

    @Test("a group says how many, and names the archive rather than the files")
    func batchWordingCountsAndNamesTheArchive() {
        let many = group((1...12).map { pending("f\($0).txt") })
        let title = BrowserWindowController.archiveWriteBackTitle(many)
        #expect(title.contains("12"))
        #expect(title.contains("pkg.zip"))
        // Never the file names: the archive is what is being rewritten, and twelve names in a
        // title is a wall nobody reads.
        #expect(!title.contains("f1.txt"))
    }

    @Test("the body says the rewrite happens once, which is the thing worth telling")
    func batchBodySaysOnce() {
        // The reader is being asked about twelve files and is entitled to know they cost one
        // rewrite rather than twelve.
        let many = group((1...12).map { pending("f\($0).txt") })
        #expect(BrowserWindowController.archiveWriteBackBody(many, undoable: true).contains("once"))
    }

    @Test("undoability changes the sentence, at both sizes")
    func undoabilityIsStated() {
        // Per **archive** rather than per file — it comes from that archive's size against the undo
        // budget, which is why the question is per archive too.
        let one = group([pending("notes.txt")])
        let many = group((1...5).map { pending("f\($0).txt") })
        for subject in [one, many] {
            let undoable = BrowserWindowController.archiveWriteBackBody(subject, undoable: true)
            let permanent = BrowserWindowController.archiveWriteBackBody(subject, undoable: false)
            #expect(undoable != permanent)
            #expect(undoable.contains("Undo"))
            #expect(permanent.contains("can’t be undone"))
        }
    }

    @Test("a failed group names the archive; a failed single member names the file")
    func failureWording() {
        // The rewrite is what failed, and it failed for all of them at once — so naming one of
        // twelve files would say something true about a twelfth of the problem.
        let one = group([pending("notes.txt")])
        #expect(BrowserWindowController.archiveWriteBackFailureTitle(one).contains("notes.txt"))
        let many = group((1...12).map { pending("f\($0).txt") })
        let title = BrowserWindowController.archiveWriteBackFailureTitle(many)
        #expect(title.contains("12"))
        #expect(title.contains("pkg.zip"))
    }
}
