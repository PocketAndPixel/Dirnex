import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The four files git makes, a service whose windows a test can reach, and what it answered.
@MainActor
final class GitMergeRig {
    let folder: URL
    var answers: [GitMergeAnswer] = []
    var refusals: [(title: String, detail: String)] = []
    private(set) var windows: [MergeWindowController] = []
    private(set) lazy var service = GitMergeService(
        openWindow: { [unowned self] input, saving in
            let controller = MergeWindowController(input: input, saving: saving)
            windows.append(controller)
            Self.retained.append(controller)
            return controller
        },
        refuse: { [unowned self] title, detail in refusals.append((title, detail)) }
    )

    /// Kept for the life of the test host, as `MergeRig` keeps its windows.
    private static var retained: [MergeWindowController] = []

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-gitmerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
    }

    func path(_ name: String) -> String {
        folder.appendingPathComponent(name).path
    }

    func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    var request: GitMergeRequest {
        GitMergeRequest(
            local: path("a_LOCAL_1.txt"),
            base: path("a_BASE_1.txt"),
            remote: path("a_REMOTE_1.txt"),
            merged: path("a.txt")
        )
    }

    /// The four files of one conflict, with git's markers in the working-tree file.
    func writeConflict(base: String = "1\n2\n3\n") throws {
        try write("a_LOCAL_1.txt", "1\nY\n3\n")
        try write("a_BASE_1.txt", base)
        try write("a_REMOTE_1.txt", "1\nT\n3\n")
        try write("a.txt", "1\n<<<<<<< HEAD\nY\n=======\nT\n>>>>>>> o\n3\n")
    }

    /// Ask for the merge and wait for its window, with the merge computed and on screen.
    func open() async throws -> MergeWindowController {
        await service.open(request) { [unowned self] in answers.append($0) }
        let controller = try #require(windows.last)
        let merge = TextMerge(
            base: controller.input.base.document,
            yours: controller.input.yours.document,
            theirs: controller.input.theirs.document
        )
        controller.load(
            merge,
            prepared: MergePrepared.prepare(
                merge,
                language: nil,
                coloringLimit: CompareTextStyle.syntaxColoringLimit
            )
        )
        return controller
    }

    var contentsOfFolder: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
}
