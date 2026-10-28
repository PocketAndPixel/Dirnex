import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The bases kept for edits of server files (PLAN.md §M34 Slice 4).
///
/// A base has to be the server's bytes at the revision its copy is checked against, or a merge
/// reads the server's change as one the user made and drops it in silence. So each rule that moves
/// a copy's record is pinned for what it does to the base: the watch starting, an upload landing,
/// a record forgotten, and a merge saved.
@MainActor
@Suite("Write-back bases")
struct RemoteWriteBackBaseTests {
    private func fetch(
        _ entry: FileEntry,
        into cache: RemoteFileCache,
        using backend: CountingBackend
    ) async throws -> URL {
        try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { false })
    }

    private func edit(of entry: FileEntry, at url: URL) -> EditedFile {
        EditedFile(destination: .remoteFile(entry.path), temporaryURL: url, name: entry.name)
    }

    private func read(_ url: URL?) -> String {
        url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "<none>"
    }

    @Test("a server file's watch keeps its copy as downloaded as the base, once")
    func watchKeepsTheDownload() async throws {
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let copy = try await fetch(entry, into: cache, using: CountingBackend())
        defer { cache.forget(copy: copy) }

        cache.keepBase(for: edit(of: entry, at: copy))
        let base = try #require(cache.base(ofCopy: copy))
        #expect(read(base) == CountingBackend.body)
        #expect(base.path.hasPrefix(RemoteFileCache.basesRoot.path))

        // The editor's save leaves it, and a second watch keeps the base it has.
        try Data("edited".utf8).write(to: copy)
        cache.keepBase(for: edit(of: entry, at: copy))
        #expect(cache.base(ofCopy: copy) == base)
        #expect(read(base) == CountingBackend.body)
    }

    @Test("a copy written before its watch starts keeps no base, and nor does an archive member")
    func writtenCopyKeepsNone() async throws {
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let copy = try await fetch(entry, into: cache, using: CountingBackend())
        defer { cache.forget(copy: copy) }

        // Bytes nothing can vouch for are not the server's, so no merge is offered from them.
        try Data("written by the compare window".utf8).write(to: copy)
        #expect(!cache.isUntouched(copy))
        cache.keepBase(for: edit(of: entry, at: copy))
        #expect(cache.base(ofCopy: copy) == nil)

        let other = try await fetch(Fixture.entry("b.txt"), into: cache, using: CountingBackend())
        defer { cache.forget(copy: other) }
        cache.keepBase(for: EditedFile(
            destination: .archiveMember(archivePath: "/tmp/a.zip", innerDirectory: "/"),
            temporaryURL: other,
            name: "b.txt"
        ))
        #expect(cache.base(ofCopy: other) == nil)
    }

    @Test("an upload's duplicate becomes the base, and the base before it goes")
    func uploadReplacesTheBase() async throws {
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let copy = try await fetch(entry, into: cache, using: CountingBackend())
        defer { cache.forget(copy: copy) }
        cache.keepBase(for: edit(of: entry, at: copy))
        let first = try #require(cache.base(ofCopy: copy))

        try Data("uploaded".utf8).write(to: copy)
        let sent = try #require(cache.baseStore.keep(copy))
        // The editor writes again while the upload runs: the base is what was sent, not this.
        try Data("written during the upload".utf8).write(to: copy)
        let uploaded = Fixture.entry("a.txt", byteSize: 8, modified: Date(timeIntervalSince1970: 2))
        cache.rebaseline(entry.path, to: RemoteFileRevision(uploaded), url: copy, sent: sent)

        #expect(cache.base(ofCopy: copy) == sent)
        #expect(read(cache.base(ofCopy: copy)) == "uploaded")
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!cache.isUntouched(copy))

        // An upload with nothing sent leaves nothing that says what the server holds.
        cache.rebaseline(entry.path, to: RemoteFileRevision(uploaded), url: copy)
        #expect(cache.base(ofCopy: copy) == nil)
        #expect(!FileManager.default.fileExists(atPath: sent.path))
    }

    @Test("forgetting a copy's record takes its base with it")
    func forgetDropsTheBase() async throws {
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let copy = try await fetch(entry, into: cache, using: CountingBackend())
        cache.keepBase(for: edit(of: entry, at: copy))
        let base = try #require(cache.base(ofCopy: copy))

        cache.forget(copy: copy)
        #expect(cache.base(ofCopy: copy) == nil)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("a saved merge makes the server's version the base, and the copy stays the edit's")
    func mergeRebasesTheCopy() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let downloaded = Fixture.entry("a.txt")
        let copy = try await fetch(downloaded, into: cache, using: backend)
        defer { cache.forget(copy: copy) }
        cache.keepBase(for: edit(of: downloaded, at: copy))
        let first = try #require(cache.base(ofCopy: copy))

        let changed = Fixture.entry("a.txt", byteSize: 99)
        let theirs = try await fetch(changed, into: cache, using: backend)
        defer { cache.forget(copy: theirs) }
        let kept = try #require(cache.baseStore.keep(theirs))
        cache.adoptBase(ofCopy: copy, from: kept)
        cache.rebase(copy: copy, onto: RemoteFileRevision(changed))

        #expect(cache.base(ofCopy: copy) == kept)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        // The next save is checked against the version merged, so it uploads unasked.
        #expect(cache.revision(ofCopy: copy) == RemoteFileRevision(changed))
        // The copy holds the merge, so a preview of the row is still handed the server's bytes.
        #expect(cache.cachedURL(for: changed) == theirs)
        #expect(!cache.isUntouched(copy))
    }

    @Test("a fetch of the server's version passes over a held copy that was written")
    func editedCopyIsSetAside() async throws {
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let copy = try await fetch(entry, into: cache, using: CountingBackend())
        defer { cache.forget(copy: copy) }

        cache.setAsideEditedCopy(of: entry)
        #expect(cache.cachedURL(for: entry) == copy)

        try Data("edited in a second editor".utf8).write(to: copy)
        cache.setAsideEditedCopy(of: entry)
        #expect(cache.cachedURL(for: entry) == nil)
        // Its own record stays, for the save that editor may make.
        #expect(cache.revision(ofCopy: copy) == RemoteFileRevision(entry))
    }
}

/// Whether the write-back's prompts offer Merge…, and what their buttons mean (PLAN.md §M34
/// Slice 4). The rules are `static` and pure, since presenting a real sheet in the test host
/// destabilizes its neighbours (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("Write-back merge offer")
struct RemoteWriteBackMergeOfferTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-merge-offer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static let recorded = RemoteFileRevision(Fixture.entry("notes.txt"))
    private static let changed = Fixture.entry("notes.txt", byteSize: 40)

    @Test("Merge… is offered when the server's copy changed and the base and the copy are text")
    func offeredWhenItCanWork() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try file("base.txt", Data("a\nb\n".utf8))
        let yours = try file("notes.txt", Data("a\nB\n".utf8))
        let offered = await BrowserWindowController.mergeBase(
            base, yours: yours, recorded: Self.recorded, current: Self.changed
        )
        #expect(offered == base)
    }

    @Test("Merge… is not offered without a change, a base, a size the window reads, or text")
    func notOfferedOtherwise() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try file("base.txt", Data("a\nb\n".utf8))
        let yours = try file("notes.txt", Data("a\nB\n".utf8))
        let binary = try file("binary.txt", Data([0x61, 0x00, 0x62]))
        let tooLarge = Fixture.entry("notes.txt", byteSize: ByteComparator.prescanByteLimit + 1)
        let unknown = Fixture.entry("notes.txt", byteSize: -1)
        let cases = [
            Case("unchanged", base, yours, Self.recorded, Fixture.entry("notes.txt")),
            Case("no record", base, yours, nil, Self.changed),
            Case("not reached", base, yours, Self.recorded, nil),
            Case("no base", nil, yours, Self.recorded, Self.changed),
            Case("too large", base, yours, Self.recorded, tooLarge),
            Case("size unknown", base, yours, Self.recorded, unknown),
            Case("binary copy", base, binary, Self.recorded, Self.changed),
            Case("binary base", binary, yours, Self.recorded, Self.changed)
        ]
        for item in cases {
            let offered = await BrowserWindowController.mergeBase(
                item.base, yours: item.yours, recorded: item.recorded, current: item.current
            )
            #expect(offered == nil, "\(item.reason): no Merge…")
        }
    }

    /// One way Merge… cannot work.
    private struct Case {
        let reason: String
        let base: URL?
        let yours: URL
        let recorded: RemoteFileRevision?
        let current: FileEntry?

        init(
            _ reason: String,
            _ base: URL?,
            _ yours: URL,
            _ recorded: RemoteFileRevision?,
            _ current: FileEntry?
        ) {
            self.reason = reason
            self.base = base
            self.yours = yours
            self.recorded = recorded
            self.current = current
        }
    }

    @Test("with Merge… offered it is the first button, and Keep Editing stays last and ⎋'s")
    func promptButtons() {
        let answers = BrowserWindowController.promptAnswers(offersSkip: false, offersMerge: true)
        #expect(answers == [.merge, .all, .none])
        let answer = { (response: NSApplication.ModalResponse) in
            BrowserWindowController.answer(for: response, offersSkip: false, offersMerge: true)
        }
        #expect(answer(.alertFirstButtonReturn) == .merge)
        #expect(answer(.alertSecondButtonReturn) == .all)
        #expect(answer(.alertThirdButtonReturn) == .none)
        #expect(answer(.cancel) == .none)
        #expect(BrowserWindowController.response(for: .none, in: answers) == .alertThirdButtonReturn)
        // Without it, the prompt is the one it was.
        #expect(BrowserWindowController.promptAnswers(offersSkip: true, offersMerge: false)
            == [.all, .clean, .none])
        #expect(BrowserWindowController.promptAnswers(offersSkip: false, offersMerge: false)
            == [.all, .none])
    }

    @Test("after a refused upload, Merge… is offered for one changed file with a base, first")
    func refusalOffersMerge() {
        let path = VFSPath(backend: Fixture.backendID, path: "/notes.txt")
        func item(base: URL?) -> CheckedWriteBack {
            CheckedWriteBack(
                edit: EditedFile(
                    destination: .remoteFile(path),
                    temporaryURL: URL(fileURLWithPath: "/tmp/edits/notes.txt"),
                    name: "notes.txt"
                ),
                destination: path,
                concern: nil,
                condition: .unconditional,
                byteSize: 10,
                mergeBase: base
            )
        }
        let based = item(base: URL(fileURLWithPath: "/tmp/bases/x/notes.txt"))
        let answers = BrowserWindowController.uploadAnywayAnswers
        #expect(answers([based], .changed) == [.merge, .all, .none])
        // Gone has nothing to merge with, a set is one question, and no base is no merge.
        #expect(answers([based], .gone) == [.all, .none])
        #expect(answers([based, based], .changed) == [.all, .none])
        #expect(answers([item(base: nil)], .changed) == [.all, .none])
    }

    @Test("a prompt about one file uploads it, and a batch's uploads all")
    func uploadButtonNamesTheCount() {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true else { return }
        let title = BrowserWindowController.buttonTitle
        #expect(title(.all, 1) == "Upload")
        #expect(title(.all, 3) == "Upload All")
        #expect(title(.merge, 1) == "Merge…")
        #expect(title(.none, 1) == "Keep Editing")
        #expect(title(.clean, 3) == "Skip Changed Files")
    }

    @Test("Merge… uploads nothing, and an upload sends the duplicate taken for it")
    func mergeUploadsNothing() {
        let path = VFSPath(backend: Fixture.backendID, path: "/notes.txt")
        let copy = URL(fileURLWithPath: "/tmp/edits/notes.txt")
        var item = CheckedWriteBack(
            edit: EditedFile(destination: .remoteFile(path), temporaryURL: copy, name: "notes.txt"),
            destination: path,
            concern: "changed",
            condition: .unconditional,
            byteSize: 10
        )
        #expect(WriteBackBatchPlan.items(for: .merge, from: [item]).isEmpty)
        #expect(WriteBackBatchPlan.job(for: [item]).items.map(\.localPath) == [copy.path])
        item.sent = URL(fileURLWithPath: "/tmp/bases/x/notes.txt")
        #expect(WriteBackBatchPlan.job(for: [item]).items.map(\.localPath)
            == ["/tmp/bases/x/notes.txt"])
    }

    @Test("the three versions are read whole, yours' file taken as it was before it was read")
    func readsTheThree() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try file("base.txt", Data("a\nb\n".utf8))
        let yours = try file("notes.txt", Data("a\nB\n".utf8))
        let theirs = try file("theirs.txt", Data("a\nb\nc\n".utf8))
        let documents = try BrowserWindowController.readMerge(
            base: base, yours: yours, theirs: theirs
        ).get()
        #expect(documents.base.lines.map(\.content) == ["a", "b"])
        #expect(documents.yours.lines.map(\.content) == ["a", "B"])
        #expect(documents.theirs.lines.map(\.content) == ["a", "b", "c"])
        #expect(documents.target == .reading(yours.path))

        let binary = try file("binary.txt", Data([0x61, 0x00, 0x62]))
        let refused = BrowserWindowController.readMerge(base: base, yours: yours, theirs: binary)
        #expect(refused.failure == CompareReadFailure(name: "notes.txt", reason: .binary))
    }

    @Test("the offer keeps the prompt's own sentence and says what Merge… does after it")
    func offerWording() {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true else { return }
        let body = "The file on the server has changed."
        let offered = BrowserWindowController.mergeOfferBody(body)
        #expect(offered.hasPrefix(body + " "))
        #expect(offered.contains("Merge…"))
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(failure) = self else { return nil }
        return failure
    }
}

/// The merge window's save of a server file (PLAN.md §M34 Slice 4): the result goes into the
/// editor's copy, the window counts it saved, and only then is it carried on to the server.
@MainActor
@Suite("Merge window server saves")
struct MergeServerSaveTests {
    /// What the carry saw when it ran.
    @MainActor
    private final class Carried {
        weak var controller: MergeWindowController?
        var path = ""
        var times = 0
        var contents: [String] = []
        var unsaved: [Bool] = []
        var saving: [Bool] = []
        var windows: [NSWindow?] = []
        var closed = 0
        /// Whether a carry is running and held, and whether the test has let it go.
        var isHeld = false
        var released = false
    }

    private static let merged = "a\nY\nc\nd\nE\nf\nG\nh\nI\nK\nj\n"

    private func resolve(_ rig: MergeRig) async throws {
        rig.controller.take(.yours)
        try await rig.landed()
        rig.controller.take(.yoursThenTheirs)
        try await rig.landed()
    }

    @Test("a save writes the copy, counts as saved, then carries it on, once per save")
    func saveThenCarry() async throws {
        let carried = Carried()
        let rig = try MergeRig(carry: { window in
            carried.times += 1
            carried.contents.append(
                (try? String(contentsOfFile: carried.path, encoding: .utf8)) ?? "<none>"
            )
            carried.unsaved.append(carried.controller?.hasUnsavedChoices ?? true)
            carried.saving.append(carried.controller?.isSaving ?? false)
            carried.windows.append(window)
        })
        defer { rig.cleanup() }
        carried.controller = rig.controller
        carried.path = rig.path
        try await resolve(rig)

        #expect(await rig.controller.saveResult())
        #expect(carried.times == 1)
        #expect(carried.contents == [Self.merged], "the result was in the copy before it went on")
        #expect(carried.unsaved == [false], "and the window counted it saved")
        #expect(carried.saving == [true], "while Save stayed held back")
        #expect(carried.windows == [rig.controller.window])

        // A choice changed and saved again is carried again.
        rig.controller.goToConflict(1)
        rig.controller.take(.theirs)
        try await rig.landed()
        #expect(await rig.controller.saveResult())
        #expect(carried.times == 2)
        #expect(carried.contents.last == "a\nY\nc\nd\nE\nf\nG\nh\nK\nj\n")
    }

    @Test("while a save carries the result on, the window does not close; afterwards it does")
    func holdsWhileCarrying() async throws {
        let carried = Carried()
        let rig = try MergeRig(carry: { _ in
            carried.isHeld = true
            while !carried.released {
                try? await Task.sleep(for: .milliseconds(10))
            }
        })
        defer { rig.cleanup() }
        try await resolve(rig)
        let window = try #require(rig.controller.window)

        let saving = Task { await rig.controller.saveResult() }
        try await settleUntil { carried.isHeld }
        #expect(!rig.controller.hasUnsavedChoices)
        #expect(!rig.controller.windowShouldClose(window), "the upload's question may still come")
        carried.released = true
        #expect(await saving.value)
        #expect(rig.controller.windowShouldClose(window))
    }

    @Test("closing the window calls its closed hook once")
    func closedHook() throws {
        let carried = Carried()
        let rig = try MergeRig(closed: { carried.closed += 1 })
        defer { rig.cleanup() }
        rig.controller.close()
        #expect(carried.closed == 1)
    }
}
