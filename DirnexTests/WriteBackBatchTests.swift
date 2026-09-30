import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Save-backs gathered into one queued job (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// The core suites pin what the job does to a server. What only this target can ask is the part
/// that was the gap: whether anybody is interrupted, which items a given answer uploads, and what
/// the user reads afterwards — all of it decided by pure `static` rules, because presenting a real
/// sheet in the test host destabilizes its neighbours (docs/NOTES.md ▸ Testing).
@Suite("Save-back batch")
@MainActor
struct WriteBackBatchTests {
    private let backendID = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))

    private func checked(_ name: String, concern: String? = nil) -> CheckedWriteBack {
        let path = VFSPath(backend: backendID, path: "/home/oleg/\(name)")
        return CheckedWriteBack(
            edit: EditedFile(
                destination: .remoteFile(path),
                temporaryURL: URL(fileURLWithPath: "/tmp/edits/\(name)"),
                name: name
            ),
            destination: path,
            concern: concern,
            condition: .unconditional,
            byteSize: 10
        )
    }

    // MARK: - Who gets interrupted

    @Test("a batch the checks found nothing wrong with asks nothing")
    func cleanBatchIsSilent() {
        // The rule the single save has followed since 2026-08-23, applied to a set — and the common
        // case here by construction, since the copies were downloaded minutes ago by the same
        // gesture that rewrote them.
        let batch = (1...40).map { checked("f\($0).txt") }
        #expect(!WriteBackBatchPlan.needsConfirmation(batch))
    }

    @Test("one contested file in forty is enough to ask, once")
    func oneConcernAsksOnce() {
        var batch = (1...40).map { checked("f\($0).txt") }
        batch[7] = checked("f8.txt", concern: "changed")
        #expect(WriteBackBatchPlan.needsConfirmation(batch))
    }

    // MARK: - What each answer uploads

    @Test("skipping the changed files uploads the rest, in order")
    func skipUploadsTheCleanRemainder() {
        // The answer the whole sheet exists for: thirty-seven edits must not be abandoned to
        // protect three, and three files nobody has looked at must not be overwritten to save
        // thirty-seven.
        let batch = [
            checked("a.txt"),
            checked("b.txt", concern: "changed"),
            checked("c.txt")
        ]
        let clean = WriteBackBatchPlan.items(for: .clean, from: batch)
        #expect(clean.map(\.edit.name) == ["a.txt", "c.txt"])
        #expect(WriteBackBatchPlan.items(for: .all, from: batch).map(\.edit.name)
            == ["a.txt", "b.txt", "c.txt"])
        #expect(WriteBackBatchPlan.items(for: .none, from: batch).isEmpty)
    }

    @Test("the job carries each item's own precondition")
    func jobCarriesPerItemConditions() {
        // Per item, never per job: a batch is independent files with their own entity tags, and one
        // condition shared across them could only ever be `.unconditional`.
        let bucket = S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let path = VFSPath(backend: .s3(bucket), path: "/a.txt")
        let guarded = CheckedWriteBack(
            edit: EditedFile(
                destination: .remoteFile(path),
                temporaryURL: URL(fileURLWithPath: "/tmp/edits/a.txt"),
                name: "a.txt"
            ),
            destination: path,
            concern: nil,
            condition: .ifMatches(entityTag: "\"aaa\""),
            byteSize: 5
        )
        let job = WriteBackBatchPlan.job(for: [guarded, checked("b.txt")])
        #expect(job.items.map(\.condition) == [.ifMatches(entityTag: "\"aaa\""), .unconditional])
        #expect(job.items.map(\.localPath) == ["/tmp/edits/a.txt", "/tmp/edits/b.txt"])
        #expect(job.totalBytes == 15)
    }

    // MARK: - Which button means what

    @Test("the answer a response means depends on how many buttons there were")
    func responseMapping() {
        // The off-by-one this exists to prevent: with no clean remainder there is no Skip button,
        // so the *second* response is Keep Editing rather than Skip — and a mapping that ignored
        // that would silently upload nothing when the user asked to upload everything but the
        // contested ones, or worse, the other way about.
        #expect(
            BrowserWindowController.answer(for: .alertFirstButtonReturn, offersSkip: true) == .all
        )
        #expect(
            BrowserWindowController.answer(for: .alertSecondButtonReturn, offersSkip: true) == .clean
        )
        #expect(
            BrowserWindowController.answer(for: .alertThirdButtonReturn, offersSkip: true) == .none
        )

        #expect(
            BrowserWindowController.answer(for: .alertFirstButtonReturn, offersSkip: false) == .all
        )
        #expect(
            BrowserWindowController.answer(for: .alertSecondButtonReturn, offersSkip: false) == .none
        )
        // Escape, and anything else, upload nothing.
        #expect(BrowserWindowController.answer(for: .cancel, offersSkip: true) == .none)
    }

    // MARK: - What the user reads

    @Test("one file keeps the sentence it has always had")
    func singleFileWordingIsUnchanged() {
        // The batch must not make the ordinary save read like a report about a set.
        let one = [checked("notes.txt", concern: "somebody else edited it")]
        #expect(BrowserWindowController.writeBackPromptTitle(contested: one, total: 1)
            .contains("notes.txt"))
        #expect(BrowserWindowController.writeBackPromptBody(contested: one, total: 1)
            == "somebody else edited it")
    }

    @Test("a batch says how many of how many, and names a few")
    func batchWordingCountsAndNames() {
        let contested = [checked("a.txt", concern: "x"), checked("b.txt", concern: "x")]
        let body = BrowserWindowController.writeBackPromptBody(contested: contested, total: 40)
        #expect(body.contains("2"))
        #expect(body.contains("a.txt"))
        // "The rest are as you left them" is what makes Skip a comprehensible button; without it
        // the reader cannot tell whether skipping leaves anything to upload.
        #expect(body.contains("rest"))
    }

    @Test("a batch where everything is contested says so rather than counting")
    func allContestedWordingDiffers() {
        let all = [checked("a.txt", concern: "x"), checked("b.txt", concern: "x")]
        let body = BrowserWindowController.writeBackPromptBody(contested: all, total: 2)
        // Naming a clean remainder that does not exist would be false, and would describe a Skip
        // button the sheet does not offer.
        #expect(!body.contains("rest"))
    }

    @Test("the status line names one file and counts many")
    func statusLineWording() {
        #expect(BrowserWindowController.uploadedStatus([checked("notes.txt")], wasCancelled: false)
            .contains("notes.txt"))
        let many = (1...12).map { checked("f\($0).txt") }
        let status = BrowserWindowController.uploadedStatus(many, wasCancelled: false)
        // A count rather than twelve names: the status line truncates its tail in silence and an
        // interpolated name is unbounded (docs/NOTES.md ▸ Localization).
        #expect(status.contains("12"))
        #expect(!status.contains("f1.txt"))
    }

    @Test("a stopped batch says what had already gone up")
    func stoppedBatchSaysSo() {
        // Some items really did land, and a sentence claiming the whole batch landed would be wrong
        // in the direction that matters — the user pressed Stop and is entitled to know it was not
        // free, because an upload cannot be taken back.
        let landed = [checked("a.txt"), checked("b.txt")]
        let status = BrowserWindowController.uploadedStatus(landed, wasCancelled: true)
        #expect(status.contains("2"))
        #expect(status != BrowserWindowController.uploadedStatus(landed, wasCancelled: false))
    }

    // MARK: - The route back from the queue

    @Test("a save-back and a materialize report to the gesture that queued them; nothing else does")
    func reportRouting() {
        // The seam whose **absence** nothing else can see: a kind that never reaches its deliverer
        // leaves the gesture waiting on a report that will not come — and because the gather is
        // serialized, a save-back that never finishes means no further save-back for the life of
        // the window. It compiles, it lints, and every other assertion here stays green.
        #expect(BrowserWindowController.reportsToItsGesture(.writeBack(WriteBackJob(items: []))))
        // Retroactive: `.materialize` has had the same untested route since M24 Slice 2.
        #expect(BrowserWindowController.reportsToItsGesture(.materialize))

        // The narrowness half — a rule that answered for everything would take every copy and move
        // out of the pane refresh and the failure alert they report through.
        #expect(!BrowserWindowController.reportsToItsGesture(.copy))
        #expect(!BrowserWindowController.reportsToItsGesture(.move))
        #expect(!BrowserWindowController.reportsToItsGesture(.plainPack(
            PlainPackJob(sources: [], archive: .local("/tmp/a.zip"), format: .zip)
        )))
    }

    // MARK: - The second question

    @Test("a set of refusals that agree keeps its own sentence; a mixed set takes the safe one")
    func conflictWording() {
        let first = checked("a.txt")
        let second = checked("b.txt")
        #expect(BrowserWindowController.conflictKind(of: [(first, .gone)]) == .gone)
        #expect(BrowserWindowController.conflictKind(of: [(first, .gone), (second, .gone)]) == .gone)
        // "This file isn't there any more" said about a set of which one is missing would be false
        // about the others; the changed wording warns about destroying a newer version, which is
        // the outcome worth warning about.
        #expect(
            BrowserWindowController.conflictKind(of: [(first, .gone), (second, .changed)]) == .changed
        )
    }
}
