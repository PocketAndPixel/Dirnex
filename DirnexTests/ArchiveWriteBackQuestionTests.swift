import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What the archive's question offers and says (PLAN.md §M37 Slice 4). Pure, so no sheet is put up
/// in the test host (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("Archive write-back question")
struct ArchiveWriteBackQuestionTests {
    private func pending(_ name: String, at innerDirectory: String = "/") -> PendingArchiveWriteBack {
        PendingArchiveWriteBack(
            edit: EditedFile(
                destination: .archiveMember(
                    archivePath: "/Users/me/pkg.zip",
                    innerDirectory: innerDirectory
                ),
                temporaryURL: URL(fileURLWithPath: "/tmp/edits/\(name)"),
                name: name
            ),
            archivePath: "/Users/me/pkg.zip",
            innerDirectory: innerDirectory
        )
    }

    private func group(_ names: [String]) -> ArchiveWriteBackGroup {
        ArchiveWriteBackGroup(archivePath: "/Users/me/pkg.zip", items: names.map { pending($0) })
    }

    private var readsEnglish: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
    }

    private static let changed = ArchiveMemberVerdict.different(byteSize: 10)

    @Test("Merge… comes first for one changed member, Skip Changed Files for a mixed set")
    func answers() {
        let answers = BrowserWindowController.archivePromptAnswers
        #expect(answers([Self.changed], true) == [.merge, .all, .none])
        #expect(answers([Self.changed], false) == [.all, .none])
        #expect(answers([.unreadable], false) == [.all, .none])
        #expect(answers([.same, Self.changed, .unmoved], false) == [.all, .clean, .none])
        #expect(
            answers([.unreadable, Self.changed], false) == [.all, .none],
            "nothing clean to keep"
        )
        #expect(answers([.unmoved, .noBase, .same], false) == [.all, .none], "the question it was")

        let mixed = answers([.same, Self.changed], false)
        #expect(
            BrowserWindowController.answer(for: .alertSecondButtonReturn, among: mixed) == .clean
        )
        #expect(BrowserWindowController.response(for: .none, in: mixed) == .alertThirdButtonReturn)
    }

    @Test("each button names what it does in the archive")
    func buttonTitles() {
        guard readsEnglish else { return }
        let title = BrowserWindowController.archiveButtonTitle
        #expect(title(.merge) == "Merge…")
        #expect(title(.all) == "Save Back")
        #expect(title(.clean) == "Skip Changed Files")
        #expect(title(.none) == "Keep Editing")
    }

    @Test("with nothing found the body is the one the question always had")
    func unchangedBody() {
        for names in [["notes.txt"], ["a.txt", "b.txt"]] {
            let subject = group(names)
            for undoable in [true, false] {
                let plain = BrowserWindowController.archiveWriteBackBody(subject, undoable: undoable)
                for verdict in [ArchiveMemberVerdict.unmoved, .noBase, .same] {
                    let body = BrowserWindowController.archiveWriteBackBody(
                        subject,
                        verdicts: Array(repeating: verdict, count: names.count),
                        undoable: undoable,
                        offersMerge: false
                    )
                    #expect(body == plain)
                }
            }
        }
    }

    @Test("a changed member is named before the body, and Merge… is explained after it")
    func changedBody() {
        let subject = group(["notes.txt"])
        let plain = BrowserWindowController.archiveWriteBackBody(subject, undoable: true)
        let body = { (verdict: ArchiveMemberVerdict, merge: Bool) in
            BrowserWindowController.archiveWriteBackBody(
                subject, verdicts: [verdict], undoable: true, offersMerge: merge
            )
        }
        let changed = body(Self.changed, false)
        #expect(changed.contains("notes.txt"))
        #expect(changed.hasSuffix(" " + plain))
        let offered = body(Self.changed, true)
        #expect(offered.hasPrefix(changed + " "))
        #expect(offered.contains(BrowserWindowController.mergeButtonTitle))
        let unread = body(.unreadable, false)
        #expect(unread.hasSuffix(" " + plain))
        #expect(unread != changed)
        if readsEnglish {
            #expect(changed.contains("replaces that change"))
            #expect(unread.contains("couldn’t read"))
        }
    }

    @Test("a set says how many changed and names the first few, or that none could be confirmed")
    func setBody() {
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"]
        let subject = group(names)
        let some = BrowserWindowController.archiveWriteBackBody(
            subject,
            verdicts: [Self.changed, .same, .unreadable, Self.changed, Self.changed, .unmoved],
            undoable: false,
            offersMerge: false
        )
        #expect(some.contains("4"))
        #expect(some.contains("a.txt, c.txt, d.txt"))
        #expect(!some.contains("e.txt"))
        #expect(
            some.hasSuffix(BrowserWindowController.archiveWriteBackBody(subject, undoable: false))
        )
        let every = BrowserWindowController.archiveWriteBackBody(
            subject,
            verdicts: Array(repeating: .unreadable, count: names.count),
            undoable: false,
            offersMerge: false
        )
        #expect(every != some)
        #expect(!every.contains("a.txt"))
    }

    @Test("Skip Changed Files writes back the members the check found nothing to say about")
    func uncontested() {
        let subject = group(["a.txt", "b.txt", "c.txt", "d.txt"])
        let clean = ArchiveWriteBackPlan.uncontested(
            subject, verdicts: [.same, Self.changed, .unmoved, .unreadable]
        )
        #expect(clean.archivePath == subject.archivePath)
        #expect(clean.items.map(\.edit.name) == ["a.txt", "c.txt"])
    }

    @Test("a member's inner path is its folder and its name")
    func innerPath() {
        #expect(pending("notes.txt").innerPath == "/notes.txt")
        #expect(pending("notes.txt", at: "/docs/api").innerPath == "/docs/api/notes.txt")
    }

    @Test("Merge… is offered for a changed text member the window reads, and only then")
    func mergeOffer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveMergeOffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let base = try file("base.txt", Data("a\nb\n".utf8))
        let yours = try file("notes.txt", Data("a\nB\n".utf8))
        let binary = try file("binary.txt", Data([0x61, 0x00, 0x62]))
        let offer = BrowserWindowController.archiveMergeBase
        #expect(await offer(base, yours, Self.changed) == base)

        let tooLarge = ArchiveMemberVerdict.different(byteSize: ByteComparator.prescanByteLimit + 1)
        let refused = [
            Refusal("unmoved", base, yours, .unmoved),
            Refusal("same", base, yours, .same),
            Refusal("unreadable", base, yours, .unreadable),
            Refusal("no base", base, yours, .noBase),
            Refusal("no verdict", base, yours, nil),
            Refusal("base gone", nil, yours, Self.changed),
            Refusal("too large", base, yours, tooLarge),
            Refusal("binary copy", base, binary, Self.changed),
            Refusal("binary base", binary, yours, Self.changed)
        ]
        for item in refused {
            #expect(
                await offer(item.base, item.yours, item.verdict) == nil,
                "\(item.reason): no Merge…"
            )
        }
    }

    /// One way Merge… cannot work.
    private struct Refusal {
        let reason: String
        let base: URL?
        let yours: URL
        let verdict: ArchiveMemberVerdict?

        init(_ reason: String, _ base: URL?, _ yours: URL, _ verdict: ArchiveMemberVerdict?) {
            self.reason = reason
            self.base = base
            self.yours = yours
            self.verdict = verdict
        }
    }

    @Test(
        "a merge's first save adopts the archive's version, every save carries, and a close cleans"
    )
    func mergeSaving() async throws {
        let fixture = try ArchiveZipFixture(["notes.txt": "as packed\n"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt")
        defer { edit.cleanup() }
        edit.cache.keepBase(for: edit.pending.edit)
        let first = try #require(edit.base)
        let stamp = try #require(ArchiveIdentity.current(ofFileAt: fixture.path))

        let theirs = ArchiveMemberBase(
            base: try #require(edit.cache.baseStore.keep(edit.copy)), archive: stamp
        )
        var carried: [URL] = []
        let saving = BrowserWindowController.archiveMergeSaving(
            edit.pending.edit, theirs: theirs, cache: edit.cache
        ) { carriedEdit, _ in carried.append(carriedEdit.temporaryURL) }
        await saving.carry?(nil)
        await saving.carry?(nil)
        #expect(carried == [edit.copy, edit.copy])
        #expect(edit.base == theirs)
        #expect(!FileManager.default.fileExists(atPath: first.base.path))
        saving.closed()
        #expect(FileManager.default.fileExists(atPath: theirs.base.path), "the copy's base now")

        // A window closed with no save removes the version it read.
        let unsaved = ArchiveMemberBase(
            base: try #require(edit.cache.baseStore.keep(edit.copy)), archive: stamp
        )
        BrowserWindowController.archiveMergeSaving(
            edit.pending.edit, theirs: unsaved, cache: edit.cache
        ) { _, _ in }.closed()
        #expect(!FileManager.default.fileExists(atPath: unsaved.base.path))
        #expect(edit.base == theirs)
    }
}
