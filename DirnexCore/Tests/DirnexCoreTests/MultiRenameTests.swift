import Foundation
import Testing

@testable import DirnexCore

@Suite("MultiRename")
struct MultiRenameTests {
    // MARK: - Fixtures

    private func entry(
        _ name: String,
        in directory: String = "/dir",
        modified: Date = Date(timeIntervalSince1970: 0)
    ) -> FileEntry {
        FileEntry(
            path: .local("\(directory)/\(name)"),
            name: name,
            kind: .file,
            byteSize: 0,
            modificationDate: modified,
            creationDate: modified,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A fixed timestamp whose local-calendar components are known, for date-token tests.
    private func date(_ components: DateComponents) -> Date {
        Calendar.current.date(from: components)!
    }

    // MARK: - Identity

    @Test("the default spec reproduces every name unchanged")
    func identityIsUnchanged() {
        let items = [entry("photo.jpg"), entry("notes"), entry(".hidden")]
        let plan = MultiRename.plan(
            for: items,
            spec: .identity,
            existingNames: Set(items.map(\.name))
        )
        #expect(plan.map(\.newName) == ["photo.jpg", "notes", ".hidden"])
        let allUnchanged = plan.allSatisfy { $0.status == .unchanged }
        #expect(allUnchanged)
    }

    @Test("an extension-less file gets no trailing dot")
    func noTrailingDotWithoutExtension() {
        let plan = MultiRename.plan(
            for: [entry("README")],
            spec: RenameSpec(nameTemplate: "doc"),
            existingNames: ["README"]
        )
        #expect(plan[0].newName == "doc")
    }

    // MARK: - Counter

    @Test("the counter advances one step per item, padded to width")
    func counterAdvancesAndPads() {
        let items = (1...3).map { entry("file\($0).txt") }
        let spec = RenameSpec(
            nameTemplate: "img[C]",
            counter: RenameCounter(start: 1, step: 1, padding: 3)
        )
        let plan = MultiRename.plan(for: items, spec: spec, existingNames: Set(items.map(\.name)))
        #expect(plan.map(\.newName) == ["img001.txt", "img002.txt", "img003.txt"])
    }

    @Test("counter honours start and step")
    func counterStartAndStep() {
        let items = (0..<3).map { entry("f\($0)") }
        let spec = RenameSpec(
            nameTemplate: "[C]",
            counter: RenameCounter(start: 10, step: 5, padding: 1)
        )
        let plan = MultiRename.plan(for: items, spec: spec, existingNames: Set(items.map(\.name)))
        #expect(plan.map(\.newName) == ["10", "15", "20"])
    }

    @Test("a negative counter pads the digits, not the sign")
    func counterNegativePadding() {
        let items = [entry("a"), entry("b")]
        let spec = RenameSpec(
            nameTemplate: "[C]",
            counter: RenameCounter(start: -5, step: 1, padding: 3)
        )
        let plan = MultiRename.plan(for: items, spec: spec, existingNames: ["a", "b"])
        #expect(plan.map(\.newName) == ["-005", "-004"])
    }

    // MARK: - Tokens

    @Test("name and extension tokens combine and can be swapped")
    func nameAndExtensionTokens() {
        let plan = MultiRename.plan(
            for: [entry("report.pdf")],
            spec: RenameSpec(nameTemplate: "[N]-final", extensionTemplate: "[E]"),
            existingNames: ["report.pdf"]
        )
        #expect(plan[0].newName == "report-final.pdf")
    }

    @Test("a literal token inside a filename is not re-substituted")
    func literalTokenInNameIsSafe() {
        // The name contains "[C]"; substituting [N] must not then expand that "[C]".
        let plan = MultiRename.plan(
            for: [entry("draft[C].txt")],
            spec: RenameSpec(nameTemplate: "[N]", counter: RenameCounter(start: 7)),
            existingNames: ["draft[C].txt"]
        )
        #expect(plan[0].newName == "draft[C].txt")
    }

    @Test("unknown or malformed brackets pass through literally")
    func unknownBracketsPassThrough() {
        let plan = MultiRename.plan(
            for: [entry("x.txt")],
            spec: RenameSpec(nameTemplate: "[Z][N", extensionTemplate: "[E]"),
            existingNames: ["x.txt"]
        )
        #expect(plan[0].newName == "[Z][N.txt")
    }

    @Test("date tokens read the modification date in the local calendar")
    func dateTokens() {
        let stamp = date(DateComponents(year: 2021, month: 3, day: 7, hour: 9, minute: 5, second: 8))
        let plan = MultiRename.plan(
            for: [entry("clip.mov", modified: stamp)],
            spec: RenameSpec(nameTemplate: "[Y]-[M]-[D]_[h][n][s]"),
            existingNames: ["clip.mov"]
        )
        #expect(plan[0].newName == "2021-03-07_090508.mov")
    }

    // MARK: - Find / replace

    @Test("literal find/replace rewrites the combined name")
    func literalFindReplace() {
        let items = [entry("IMG_001.jpg"), entry("IMG_002.jpg")]
        let spec = RenameSpec(find: "IMG", replace: "Photo")
        let plan = MultiRename.plan(for: items, spec: spec, existingNames: Set(items.map(\.name)))
        #expect(plan.map(\.newName) == ["Photo_001.jpg", "Photo_002.jpg"])
    }

    @Test("regex find/replace supports capture references")
    func regexFindReplace() {
        let plan = MultiRename.plan(
            for: [entry("track09.mp3")],
            spec: RenameSpec(find: #"track(\d+)"#, replace: "song-$1", useRegex: true),
            existingNames: ["track09.mp3"]
        )
        #expect(plan[0].newName == "song-09.mp3")
    }

    @Test("an invalid regex leaves names untouched and is reported")
    func invalidRegexIsInert() {
        let spec = RenameSpec(find: "(unclosed", replace: "x", useRegex: true)
        #expect(!spec.regexIsValid)
        let plan = MultiRename.plan(
            for: [entry("keep.txt")],
            spec: spec,
            existingNames: ["keep.txt"]
        )
        #expect(plan[0].newName == "keep.txt")
        #expect(plan[0].status == .unchanged)
    }

    // MARK: - Case

    @Test("case transforms fold the whole resulting name")
    func caseTransforms() {
        let name = "MixedCase.TXT"
        func newName(_ transform: RenameCase) -> String {
            MultiRename.plan(
                for: [entry(name)],
                spec: RenameSpec(caseTransform: transform),
                existingNames: [name]
            )[0].newName
        }
        #expect(newName(.lower) == "mixedcase.txt")
        #expect(newName(.upper) == "MIXEDCASE.TXT")
        #expect(newName(.asIs) == "MixedCase.TXT")
    }

    // MARK: - Validity & collisions

    @Test("an empty rendered name is flagged, not applied")
    func emptyNameIsFlagged() {
        let plan = MultiRename.plan(
            for: [entry("gone.txt")],
            spec: RenameSpec(nameTemplate: "", extensionTemplate: ""),
            existingNames: ["gone.txt"]
        )
        #expect(plan[0].status == .emptyName)
        #expect(!plan[0].willRename)
    }

    @Test("a slash in the new name is an invalid character")
    func slashIsInvalid() {
        let plan = MultiRename.plan(
            for: [entry("a.txt")],
            spec: RenameSpec(nameTemplate: "sub/name"),
            existingNames: ["a.txt"]
        )
        #expect(plan[0].status == .invalidCharacter)
    }

    @Test("two items resolving to the same name are both duplicates")
    func duplicateTargets() {
        let items = [entry("a.txt"), entry("b.txt")]
        // Both collapse to "same.txt".
        let spec = RenameSpec(nameTemplate: "same")
        let plan = MultiRename.plan(for: items, spec: spec, existingNames: Set(items.map(\.name)))
        let allDuplicates = plan.allSatisfy { $0.status == .duplicate }
        let noneApply = plan.allSatisfy { !$0.willRename }
        #expect(allDuplicates)
        #expect(noneApply)
    }

    @Test("renaming onto a bystander that isn't in the batch is a collision")
    func collisionWithBystander() {
        // Only "a.txt" is in the batch; "taken.txt" already exists in the directory.
        let plan = MultiRename.plan(
            for: [entry("a.txt")],
            spec: RenameSpec(nameTemplate: "taken"),
            existingNames: ["a.txt", "taken.txt"]
        )
        #expect(plan[0].status == .collision)
    }

    @Test("a case-only change is a real, applyable rename")
    func caseOnlyChangeApplies() {
        // "Photo.JPG" → "photo.jpg": the target equals the item's own name case-insensitively,
        // so it isn't a self-collision — it's a genuine rename on a case-insensitive volume.
        let plan = MultiRename.plan(
            for: [entry("Photo.JPG")],
            spec: RenameSpec(caseTransform: .lower),
            existingNames: ["Photo.JPG"]
        )
        #expect(plan[0].newName == "photo.jpg")
        #expect(plan[0].status == .rename)
    }

    @Test("a straightforward prefix rename is applyable")
    func straightforwardRename() {
        let items = [entry("a.txt"), entry("b.txt")]
        let plan = MultiRename.plan(
            for: items,
            spec: RenameSpec(nameTemplate: "doc_[N]"),
            existingNames: Set(items.map(\.name))
        )
        #expect(plan.map(\.newName) == ["doc_a.txt", "doc_b.txt"])
        let allApply = plan.allSatisfy(\.willRename)
        #expect(allApply)
    }

    // MARK: - Undo record

    @Test("a batch rename becomes one undo record of restore steps")
    func undoRecordRestoresEachItem() {
        let record = UndoRecord.multiRename([
            (original: .local("/dir/a.txt"), renamed: .local("/dir/doc_a.txt")),
            (original: .local("/dir/b.txt"), renamed: .local("/dir/doc_b.txt"))
        ])
        #expect(record?.label == .rename)
        #expect(record?.steps == [
            .restore(from: .local("/dir/doc_a.txt"), to: .local("/dir/a.txt")),
            .restore(from: .local("/dir/doc_b.txt"), to: .local("/dir/b.txt"))
        ])
    }

    @Test("an empty batch yields no undo record")
    func undoRecordEmptyIsNil() {
        #expect(UndoRecord.multiRename([]) == nil)
    }
}
