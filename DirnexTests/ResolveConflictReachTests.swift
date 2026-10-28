import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Resolve Conflict… in the running app's terms (PLAN.md §M34 Slice 5): what a save leaves in the
/// repository, and where the command is offered.
@Suite("Resolve Conflict in the app")
@MainActor
struct ResolveConflictReachTests {
    private static func text(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// `readConflict` on a thread of its own, as the app runs it.
    private static func read(_ target: ConflictTarget) async -> Result<
        ConflictDocuments,
        ConflictReadFailure
    > {
        await BlockingWork.run { PanelViewController.readConflict(target) }
    }

    private func bothModified() async throws -> ConflictRepository {
        try await ConflictRepository.make(
            base: ["f.txt": Self.text("a\nb\nc\n")],
            ours: ["f.txt": Self.text("a\nours\nc\n")],
            theirs: ["f.txt": Self.text("a\ntheirs\nc\n")]
        )
    }

    // MARK: - Saving

    /// Every window a test built, kept for the life of the test host (docs/NOTES.md ▸ Testing).
    private static var retained: [MergeWindowController] = []

    @Test("Save writes the working-tree file only, so git still lists the conflict until git add")
    func saveLeavesTheIndex() async throws {
        let repository = try await ConflictRepository.make(
            base: ["f.txt": Self.text("a\nb\nc\nd\ne\nf\ng\n")],
            ours: ["f.txt": Self.text("a\nours\nc\nd\ne\nf\nG\n")],
            theirs: ["f.txt": Self.text("a\ntheirs\nc\nd\nE\nf\ng\n")]
        )
        defer { repository.cleanup() }
        let target = try repository.target("f.txt")
        let documents = try await Self.read(target).get()
        let input = PanelViewController.mergeInput(for: target, documents)
        let controller = MergeWindowController(input: input, saving: .none)
        Self.retained.append(controller)
        let merge = TextMerge(
            base: input.base.document,
            yours: input.yours.document,
            theirs: input.theirs.document
        )
        controller.load(
            merge,
            prepared: MergePrepared.prepare(
                merge,
                language: nil,
                coloringLimit: CompareTextStyle.syntaxColoringLimit
            )
        )
        #expect(repository.contents("f.txt").contains("<<<<<<<"))
        let before = try repository.gitDirectoryState()

        controller.take(.theirsThenYours)
        try await settleUntil { controller.shownChoices == controller.choicesMade }
        #expect(await controller.saveResult())

        // Theirs' E and yours' G merged on their own; the conflict took theirs, then yours.
        #expect(repository.contents("f.txt") == "a\ntheirs\nours\nc\nd\nE\nf\nG\n")
        #expect(try repository.gitDirectoryState() == before)
        #expect(try repository.status() == "UU f.txt\n")
    }

    // MARK: - Where it is offered

    @Test(
        "a conflicted file's right-click menu leads with Resolve Conflict…, and the command validates on it"
    )
    func offered() async throws {
        let repository = try await bothModified()
        defer { repository.cleanup() }
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local(repository.path),
            restorationKey: nil
        )
        let conflicted = try LocalBackend().stat(at: .local(repository.file("f.txt")))
        let listing = DirectoryListing(path: .local(repository.path), entries: [conflicted])
        pane.panel.setModel(DirectoryModel(listing: listing))
        pane.panel.moveCursor(to: 0)
        let item = NSMenuItem(
            title: "",
            action: #selector(PanelViewController.resolveConflict(_:)),
            keyEquivalent: ""
        )
        #expect(CommandBinding.selector(for: "file.resolveConflict") == item.action)
        #expect(!pane.validateMenuItem(item), "no snapshot yet: no badge to act on")
        #expect(
            pane.contextMenu(onEntry: true, onParentRow: false).items.first?.action != item.action
        )

        pane.gitSnapshot = GitStatusSnapshot(
            repositoryRoot: .local(repository.path),
            branch: GitBranch(name: "main"),
            entries: [GitStatusEntry(relativePath: "f.txt", indexStatus: "U", worktreeStatus: "U")]
        )
        #expect(pane.validateMenuItem(item))
        let menu = pane.contextMenu(onEntry: true, onParentRow: false)
        #expect(menu.items.first?.action == item.action)
        #expect(menu.items.first?.title == "Resolve Conflict…")
        #expect(menu.items.dropFirst().first?.isSeparatorItem == true)
    }
}
