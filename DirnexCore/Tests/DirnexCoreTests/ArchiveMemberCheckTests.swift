import Foundation
import Testing

@testable import DirnexCore

/// An extractor over a made-up archive: what each inner path holds, and what it was asked.
private final class FakeArchive: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var state = State()

    struct State {
        var members: [String: String] = [:]
        var requests: [[String]] = []
        var failure: (any Error)?
        /// Run inside the extraction, as another writer touching the archive would.
        var during: (@Sendable () -> Void)?
    }

    init(root: URL, members: [String: String]) {
        self.root = root
        state.members = members
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var requests: [[String]] { withState { $0.requests } }

    func set(_ innerPath: String, _ contents: String?) {
        withState { $0.members[innerPath] = contents }
    }

    func fail(with error: any Error) {
        withState { $0.failure = error }
    }

    func during(_ work: @escaping @Sendable () -> Void) {
        withState { $0.during = work }
    }

    var extract: ArchiveMemberCheck.Extract {
        { [self] innerPaths in
            let (members, failure, during) = withState { state in
                state.requests.append(innerPaths)
                return (state.members, state.failure, state.during)
            }
            during?()
            if let failure { throw failure }
            let directory = root.appendingPathComponent(
                "extract-\(UUID().uuidString)", isDirectory: true
            )
            let files = try innerPaths.map { innerPath in
                let file = directory.appendingPathComponent(String(innerPath.dropFirst()))
                if let contents = members[innerPath] {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try Data(contents.utf8).write(to: file)
                }
                return file
            }
            return ArchiveMemberCheck.Placed(directory: directory, files: files)
        }
    }
}

/// Reading an edited member again from its archive (PLAN.md §M37 Slice 4).
///
/// A plain file stands for the archive, since what the check asks of the archive is its identity,
/// and a fake extractor places members holding whatever the test says the archive holds now. Every
/// test counts the extractions too, because the check's other promise is that an archive that has
/// not moved costs no read at all, and one that has costs one read for every member asked about.
@Suite("Archive member check")
struct ArchiveMemberCheckTests {
    private struct Rig {
        let tree: TempTree
        let archive: FakeArchive
        let archivePath: String

        init(_ members: [String: String]) throws {
            tree = try TempTree()
            archivePath = try tree.writeFile("pkg.zip", contents: "the archive")
            archive = FakeArchive(root: tree.root, members: members)
        }

        var check: ArchiveMemberCheck {
            ArchiveMemberCheck(archivePath: archivePath, extract: archive.extract)
        }

        /// A base holding `contents`, stamped with the archive as it is now.
        func base(_ name: String, _ contents: String) throws -> ArchiveMemberBase {
            let url = URL(fileURLWithPath: try tree.writeFile("base-\(name)", contents: contents))
            let stamp = try #require(ArchiveIdentity.current(ofFileAt: archivePath))
            return ArchiveMemberBase(base: url, archive: stamp)
        }

        /// Another writer rewrites the archive: a new file under the same name.
        func moveArchive() throws {
            try Self.moveArchive(at: archivePath)
        }

        static func moveArchive(at archivePath: String) throws {
            let replacement = archivePath + ".new"
            try Data("the archive, rewritten".utf8).write(to: URL(fileURLWithPath: replacement))
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: archivePath),
                withItemAt: URL(fileURLWithPath: replacement)
            )
        }

        /// No extraction directory is left in the tree.
        var leftNothing: Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: tree.root.path)) ?? []
            return !names.contains { $0.hasPrefix("extract-") }
        }
    }

    // MARK: - Nothing to read

    @Test("a member with no base is noBase, and nothing is extracted")
    func noBaseReadsNothing() throws {
        let rig = try Rig(["/a.txt": "a"])
        defer { rig.tree.cleanup() }
        try rig.moveArchive()
        let verdicts = rig.check.verdicts(for: [.init(innerPath: "/a.txt", base: nil)])
        #expect(verdicts == [.noBase])
        #expect(rig.archive.requests.isEmpty)
    }

    @Test("an archive still the one the base was read from is unmoved, and nothing is extracted")
    func unmovedReadsNothing() throws {
        let rig = try Rig(["/a.txt": "changed, but nobody wrote the archive"])
        defer { rig.tree.cleanup() }
        let base = try rig.base("a", "a")
        #expect(rig.check.verdicts(for: [.init(innerPath: "/a.txt", base: base)]) == [.unmoved])
        #expect(rig.archive.requests.isEmpty)
    }

    // MARK: - Reading again

    @Test("a moved archive whose member holds the base's bytes is same, and the extraction goes")
    func movedButSame() throws {
        let rig = try Rig(["/docs/a.txt": "as extracted\n"])
        defer { rig.tree.cleanup() }
        let base = try rig.base("a", "as extracted\n")
        try rig.moveArchive()
        let verdicts = rig.check.verdicts(for: [.init(innerPath: "/docs/a.txt", base: base)])
        #expect(verdicts == [.same])
        #expect(rig.archive.requests == [["/docs/a.txt"]])
        #expect(rig.leftNothing)
    }

    @Test("a member changed inside a moved archive is different, with its size as it is now")
    func movedAndDifferent() throws {
        let rig = try Rig(["/a.txt": "as extracted\n"])
        defer { rig.tree.cleanup() }
        let base = try rig.base("a", "as extracted\n")
        // The same size, so only the bytes can tell.
        rig.archive.set("/a.txt", "AS EXTRACTED\n")
        try rig.moveArchive()
        let verdicts = rig.check.verdicts(for: [.init(innerPath: "/a.txt", base: base)])
        #expect(verdicts == [.different(byteSize: 13)])
        #expect(verdicts[0].isConcern)
        #expect(rig.leftNothing)
    }

    @Test("every moved member is read in one extraction, in the order given, and no other")
    func oneExtractionForTheMoved() throws {
        let rig = try Rig([
            "/a.txt": "a", "/b.txt": "b, changed", "/c.txt": "c", "/d.txt": "d"
        ])
        defer { rig.tree.cleanup() }
        let old = try rig.base("a", "a")
        let changed = try rig.base("b", "b")
        let gone = try rig.base("c", "c")
        try rig.moveArchive()
        // Opened after the move, so its base is stamped with the archive as it is now.
        let fresh = try rig.base("d", "d")
        rig.archive.set("/c.txt", nil)

        let verdicts = rig.check.verdicts(for: [
            .init(innerPath: "/a.txt", base: old),
            .init(innerPath: "/b.txt", base: changed),
            .init(innerPath: "/x.txt", base: nil),
            .init(innerPath: "/c.txt", base: gone),
            .init(innerPath: "/d.txt", base: fresh)
        ])
        #expect(verdicts == [.same, .different(byteSize: 10), .noBase, .unreadable, .unmoved])
        #expect(rig.archive.requests == [["/a.txt", "/b.txt", "/c.txt"]])
        #expect(rig.leftNothing)
    }

    @Test("an extraction that fails and an archive that is gone are unreadable")
    func unreadable() throws {
        let rig = try Rig(["/a.txt": "a"])
        defer { rig.tree.cleanup() }
        let base = try rig.base("a", "a")
        try rig.moveArchive()
        rig.archive.fail(with: EncryptedArchiveError.passphraseRequired)
        #expect(rig.check.verdicts(for: [.init(innerPath: "/a.txt", base: base)]) == [.unreadable])
        #expect(rig.archive.requests.count == 1)

        // Gone: no identity at all is a move, never "unchanged".
        try FileManager.default.removeItem(atPath: rig.archivePath)
        #expect(rig.check.verdicts(for: [.init(innerPath: "/a.txt", base: base)]) == [.unreadable])
        #expect(ArchiveMemberVerdict.unreadable.isConcern)
    }

    @Test("only a change or an unread member is a concern")
    func concerns() {
        #expect(!ArchiveMemberVerdict.unmoved.isConcern)
        #expect(!ArchiveMemberVerdict.noBase.isConcern)
        #expect(!ArchiveMemberVerdict.same.isConcern)
        #expect(ArchiveMemberVerdict.different(byteSize: 0).isConcern)
        #expect(ArchiveMemberVerdict.unreadable.isConcern)
    }

    // MARK: - Keeping the archive's version

    @Test("keep stamps the archive before extracting, keeps the member, and removes the extraction")
    func keepStampsFirst() throws {
        let rig = try Rig(["/docs/a.txt": "the archive's version\n"])
        defer { rig.tree.cleanup() }
        let store = EditBaseStore(root: URL(fileURLWithPath: try rig.tree.makeDir("bases")))
        let before = try #require(ArchiveIdentity.current(ofFileAt: rig.archivePath))
        // Another writer, during the read: the stamp must be the archive the read started from,
        // so the next check reads the member again rather than trusting this one.
        let archivePath = rig.archivePath
        rig.archive.during { try? Rig.moveArchive(at: archivePath) }

        let kept = try rig.check.keep("/docs/a.txt", in: store)
        #expect(kept.archive == before)
        #expect(!kept.archive.stillDescribesFile(at: rig.archivePath))
        #expect(try String(contentsOf: kept.base, encoding: .utf8) == "the archive's version\n")
        #expect(kept.base.lastPathComponent == "a.txt")
        #expect(kept.base.deletingLastPathComponent().deletingLastPathComponent().path
            == store.root.path)
        #expect(rig.archive.requests == [["/docs/a.txt"]])
        #expect(rig.leftNothing)
    }

    @Test("keep throws for a member that did not land or an archive that is gone, keeping nothing")
    func keepRefuses() throws {
        let rig = try Rig([:])
        defer { rig.tree.cleanup() }
        let root = URL(fileURLWithPath: try rig.tree.makeDir("bases"))
        let store = EditBaseStore(root: root)
        #expect(throws: VFSError.self) { try rig.check.keep("/a.txt", in: store) }
        #expect(rig.leftNothing)

        try FileManager.default.removeItem(atPath: rig.archivePath)
        #expect(throws: VFSError.notFound(.local(rig.archivePath))) {
            try rig.check.keep("/a.txt", in: store)
        }
        #expect(rig.archive.requests.count == 1, "no read of an archive that is not there")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
