import Foundation
import Testing

@testable import DirnexCore

/// F7 and ⇧F4 inside a browsed archive: which names a new member can take, where it lands in the
/// staged tree, and that making it never replaces anything already there.
///
/// The staging tests run against a real scratch directory on this Mac's APFS, because the claim
/// worth pinning is the filesystem's answer (a case-only twin collides, a symlink is not followed)
/// and a fake would only restate what this file assumes.
@Suite("ArchiveMutation: creating a member")
struct ArchiveMutationCreationTests {
    // MARK: - Where it lands

    @Test("a new member lands in the folder it was made in")
    func createdInnerPathJoinsTheDirectory() {
        #expect(ArchiveMutation.createdInnerPath(named: "new", inInnerDirectory: "/") == "/new")
        #expect(
            ArchiveMutation.createdInnerPath(named: "notes.txt", inInnerDirectory: "/docs")
                == "/docs/notes.txt"
        )
        #expect(
            ArchiveMutation.createdInnerPath(named: "untitled folder", inInnerDirectory: "/a/b/c")
                == "/a/b/c/untitled folder"
        )
        // Inner paths carry a leading slash everywhere in the app; one that arrives without it still
        // lands at the same place rather than at a relative path `workingLocation` would misread.
        #expect(
            ArchiveMutation.createdInnerPath(named: "x", inInnerDirectory: "docs") == "/docs/x"
        )
    }

    /// The same list rename refuses, for the same reason: the name is joined onto a real path in the
    /// staged tree, where `..` climbs out of the folder and `a/b` lands somewhere else in it.
    @Test("a name that is not one member's own name is refused")
    func createdInnerPathRefusesNamesThatAreNotNames() {
        for bad in ["", "/", "a/b", "..", ".", "../escape", "sub/deep.txt"] {
            #expect(
                ArchiveMutation.createdInnerPath(named: bad, inInnerDirectory: "/docs") == nil,
                "\(bad) should not be a member name"
            )
        }
    }

    // MARK: - Staging

    @Test("a folder is made where the member will be")
    func stagesAFolder() throws {
        let tree = try StagedTree()
        try ArchiveMutation.stage(
            .folder,
            at: tree.member("/docs/new folder"),
            inWorkingDirectory: tree.root
        )

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: tree.root + "/docs/new folder",
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)
        #expect(try tree.contents(of: "/docs/new folder").isEmpty)
    }

    @Test("an empty file is made where the member will be")
    func stagesAnEmptyFile() throws {
        let tree = try StagedTree()
        try ArchiveMutation.stage(
            .emptyFile,
            at: tree.member("/notes.txt"),
            inWorkingDirectory: tree.root
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: tree.root + "/notes.txt")
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(attributes[.size] as? Int == 0)
    }

    /// The modes are what the local backend's F7 and ⇧F4 make, so a folder made inside an archive is
    /// stored the way the same folder made on disk and then packed would be.
    @Test("the new member gets the local backend's modes")
    func stagesWithTheLocalModes() throws {
        let tree = try StagedTree()
        try ArchiveMutation.stage(.folder, at: tree.member("/made"), inWorkingDirectory: tree.root)
        try ArchiveMutation.stage(
            .emptyFile,
            at: tree.member("/made.txt"),
            inWorkingDirectory: tree.root
        )

        // Masked by the process umask, exactly as `mkdir(2)` and `open(2)` on disk are.
        let mask = umask(0)
        umask(mask)
        #expect(try tree.permissions(of: "/made") == 0o755 & ~UInt16(mask))
        #expect(try tree.permissions(of: "/made.txt") == 0o644 & ~UInt16(mask))
    }

    /// An archive lists a folder it has no entry for whenever something is in it, and extraction
    /// makes those folders, so only an archive changed since it was listed lacks one. An add makes it
    /// in that case, and a create does the same rather than failing on a folder the user can see.
    @Test("a folder missing from the staged tree is made on the way")
    func stagesIntoAMissingFolder() throws {
        let tree = try StagedTree()
        try ArchiveMutation.stage(
            .emptyFile,
            at: tree.member("/gone/deeper/x.txt"),
            inWorkingDirectory: tree.root
        )

        #expect(FileManager.default.fileExists(atPath: tree.root + "/gone/deeper/x.txt"))
    }

    // MARK: - Nothing already there is touched

    /// Every kind of occupant, each refused with the archive's own path and left exactly as it was.
    /// The bytes are the assertion: a create that truncated `readme.txt` to make an empty file of
    /// the same name would satisfy every check on the error.
    @Test("a name already taken is refused and its occupant is untouched")
    func refusesAnOccupiedName() throws {
        let tree = try StagedTree()
        for creation in [ArchiveMutation.Creation.folder, .emptyFile] {
            for occupied in ["/readme.txt", "/docs", "/docs/api.md"] {
                let member = tree.member(occupied)
                #expect(throws: VFSError.alreadyExists(member)) {
                    try ArchiveMutation.stage(creation, at: member, inWorkingDirectory: tree.root)
                }
            }
        }
        #expect(try tree.text(of: "/readme.txt") == "read me")
        #expect(try tree.text(of: "/docs/api.md") == "api")
        #expect(try tree.contents(of: "/docs") == ["api.md"])
    }

    /// The tree is staged on APFS, which is case-insensitive by default, so `README.txt` and
    /// `readme.txt` are one name on disk whatever the archive itself could hold. A local F7 in the
    /// same folder says the same thing.
    @Test("a name differing only in case collides")
    func refusesACaseOnlyTwin() throws {
        let tree = try StagedTree()
        let member = tree.member("/README.TXT")
        #expect(throws: VFSError.alreadyExists(member)) {
            try ArchiveMutation.stage(.emptyFile, at: member, inWorkingDirectory: tree.root)
        }
        #expect(try tree.text(of: "/readme.txt") == "read me")
    }

    /// A member can be a symlink pointing anywhere, and the staged tree holds it as a real one. A
    /// create of that name must refuse rather than make something at the link's target, which could
    /// be outside the scratch directory altogether.
    @Test("a symlink of that name is refused, not followed")
    func refusesASymlinkWithoutFollowingIt() throws {
        let tree = try StagedTree()
        let outside = tree.root + "-outside"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: tree.root + "/link",
            withDestinationPath: outside
        )

        for creation in [ArchiveMutation.Creation.folder, .emptyFile] {
            let member = tree.member("/link")
            #expect(throws: VFSError.alreadyExists(member)) {
                try ArchiveMutation.stage(creation, at: member, inWorkingDirectory: tree.root)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    /// The narrowness control: a name taken in *another* folder is not taken here, so the refusal
    /// above is about the name in this folder and not about the name anywhere in the archive.
    @Test("the same name in another folder is free")
    func aNameTakenElsewhereIsFree() throws {
        let tree = try StagedTree()
        try ArchiveMutation.stage(
            .emptyFile,
            at: tree.member("/docs/readme.txt"),
            inWorkingDirectory: tree.root
        )
        try ArchiveMutation.stage(.folder, at: tree.member("/api.md"), inWorkingDirectory: tree.root)

        #expect(try tree.contents(of: "/docs") == ["api.md", "readme.txt"])
        #expect(try tree.text(of: "/readme.txt") == "read me")
    }

    // MARK: - Fixture

    /// A scratch tree shaped like an extracted archive: `readme.txt` and `docs/api.md`.
    private final class StagedTree {
        let root: String
        let archive = "/Users/tester/fixture.zip"

        init() throws {
            root = NSTemporaryDirectory() + "dirnex-archive-create-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: root + "/docs",
                withIntermediateDirectories: true
            )
            try "read me".write(toFile: root + "/readme.txt", atomically: false, encoding: .utf8)
            try "api".write(toFile: root + "/docs/api.md", atomically: false, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        func member(_ innerPath: String) -> VFSPath {
            VFSPath(backend: .archive(forArchiveAt: archive), path: innerPath)
        }

        func contents(of innerPath: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root + innerPath).sorted()
        }

        func text(of innerPath: String) throws -> String {
            try String(contentsOfFile: root + innerPath, encoding: .utf8)
        }

        func permissions(of innerPath: String) throws -> UInt16 {
            let attributes = try FileManager.default.attributesOfItem(atPath: root + innerPath)
            return (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        }
    }
}
