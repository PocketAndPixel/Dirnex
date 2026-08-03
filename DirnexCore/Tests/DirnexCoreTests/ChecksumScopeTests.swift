import Foundation
import Testing

@testable import DirnexCore

/// The pure decisions behind a checksum run (PLAN.md §M14 Slice 2). Each one reads as obvious and
/// is wrong in a quiet way when reversed, which is why they are pinned here against literals rather
/// than only exercised through `ChecksumRunner`'s temp trees.
@Suite("ChecksumScope")
struct ChecksumScopeTests {
    private func entry(
        _ path: String,
        kind: FileEntry.Kind = .file,
        isHidden: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: .local(path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: isHidden,
            permissions: 0o644,
            inode: 1
        )
    }

    // MARK: - Walking

    @Test("the walk descends into directories and nothing else")
    func descendsOnlyIntoDirectories() {
        #expect(ChecksumScope.shouldDescend(into: entry("/a/dir", kind: .directory)))
        #expect(!ChecksumScope.shouldDescend(into: entry("/a/file.txt")))
        // The rule that costs something: a symlink to a directory is a cycle risk and a
        // duplicate-bytes risk, so a *discovered* link is never followed.
        #expect(!ChecksumScope.shouldDescend(into: entry("/a/link", kind: .symlink)))
    }

    @Test("only regular files are hashable")
    func onlyRegularFilesAreHashable() {
        #expect(ChecksumScope.isHashable(entry("/a/file.txt")))
        #expect(!ChecksumScope.isHashable(entry("/a/dir", kind: .directory)))
        #expect(!ChecksumScope.isHashable(entry("/a/link", kind: .symlink)))
        #expect(!ChecksumScope.isHashable(entry("/a/sock", kind: .other)))
    }

    // MARK: - Where the manifest goes

    @Test("a single file's manifest sits in the file's own directory")
    func manifestDirectoryForOneFile() {
        // Beside the file, not up at some pane root — a nested tree selection lands its manifest
        // where the file is.
        #expect(
            ChecksumScope.manifestDirectory(for: [.local("/Users/me/other/new/DSCF.JPG")])
                == .local("/Users/me/other/new")
        )
    }

    @Test("siblings in one folder put the manifest in that folder")
    func manifestDirectoryForSiblings() {
        let dir = ChecksumScope.manifestDirectory(for: [
            .local("/Users/me/other/new/a.JPG"),
            .local("/Users/me/other/new/b.JPG")
        ])
        // This is the screenshot case: two files marked inside `new/` yield `new` as the folder,
        // so the sheet defaults the name to `new.sha256` and writes bare names beside them.
        #expect(dir == .local("/Users/me/other/new"))
        #expect(dir?.lastComponent == "new")
    }

    @Test("a selection straddling folders lands at their common ancestor")
    func manifestDirectoryAcrossFolders() {
        // A root-level file and a nested one share only `other`, so the manifest lands there and
        // the nested file is spelled `new/b.JPG` — which still resolves.
        #expect(
            ChecksumScope.manifestDirectory(for: [
                .local("/Users/me/other/a.pdf"),
                .local("/Users/me/other/new/b.JPG")
            ]) == .local("/Users/me/other")
        )
    }

    @Test("a folder's manifest sits beside it, not inside it")
    func manifestDirectoryForADirectory() {
        // Selecting the folder `new` writes the manifest in its parent and names its contents
        // `new/…` — the same shape a flat listing has always produced for a folder.
        #expect(
            ChecksumScope.manifestDirectory(for: [.local("/Users/me/other/new")])
                == .local("/Users/me/other")
        )
    }

    @Test("root-level siblings resolve to the backend root")
    func manifestDirectoryAtRoot() {
        #expect(
            ChecksumScope.manifestDirectory(for: [.local("/a.txt"), .local("/b.txt")])
                == .local("/")
        )
    }

    @Test("an empty selection has no manifest directory")
    func manifestDirectoryForNothing() {
        #expect(ChecksumScope.manifestDirectory(for: []) == nil)
    }

    // MARK: - Relative names

    @Test("a file's manifest name is its path relative to the manifest's directory")
    func relativeNames() {
        let root = VFSPath.local("/Users/me/Downloads")
        #expect(
            ChecksumScope.relativeName(of: .local("/Users/me/Downloads/a.txt"), under: root)
                == "a.txt"
        )
        #expect(
            ChecksumScope.relativeName(of: .local("/Users/me/Downloads/sub/b.txt"), under: root)
                == "sub/b.txt"
        )
    }

    @Test("a path outside the manifest's directory has no name")
    func relativeNameRefusesOutsiders() {
        let root = VFSPath.local("/Users/me/Downloads")
        #expect(ChecksumScope.relativeName(of: .local("/Users/me/other.txt"), under: root) == nil)
        // A sibling whose name merely starts with the root's is not inside it.
        #expect(
            ChecksumScope.relativeName(of: .local("/Users/me/Downloads2/a.txt"), under: root) == nil
        )
    }

    @Test("the backend root is a legal manifest directory")
    func relativeNameAtRoot() {
        #expect(ChecksumScope.relativeName(of: .local("/a.txt"), under: .local("/")) == "a.txt")
    }

    // MARK: - Verification pruning

    @Test("a verification descends only into subtrees the manifest mentions")
    func prunesUnmentionedSubtrees() {
        let names: Set<String> = ["a.txt", "sub/b.txt", "deep/one/two.txt"]
        #expect(ChecksumScope.shouldDescend(intoSubdirectory: "sub", manifestNames: names))
        #expect(ChecksumScope.shouldDescend(intoSubdirectory: "deep", manifestNames: names))
        #expect(ChecksumScope.shouldDescend(intoSubdirectory: "deep/one", manifestNames: names))
        // The whole point: a flat manifest must not turn a home directory into a wall of "extra".
        #expect(!ChecksumScope.shouldDescend(intoSubdirectory: "Pictures", manifestNames: names))
    }

    @Test("a directory whose name prefixes a listed one is not descended into")
    func prefixIsNotContainment() {
        // "sub" must not open "subway/" just because the string starts the same way.
        let names: Set<String> = ["subway/b.txt"]
        #expect(!ChecksumScope.shouldDescend(intoSubdirectory: "sub", manifestNames: names))
        #expect(ChecksumScope.shouldDescend(intoSubdirectory: "subway", manifestNames: names))
    }

    // MARK: - Comparable listing

    @Test("the manifest's own file is never reported as extra")
    func manifestExcludesItself() {
        let listing = ChecksumScope.comparableListing(
            walked: [("a.txt", false), ("files.sha256", false)],
            manifestName: "files.sha256",
            manifestNames: ["a.txt"]
        )
        #expect(listing == ["a.txt"])
    }

    @Test("an unlisted hidden file is dropped, and a listed one is kept")
    func hiddenFiles() {
        let listing = ChecksumScope.comparableListing(
            walked: [("a.txt", false), (".DS_Store", true), (".env", true)],
            manifestName: "files.sha256",
            // The manifest deliberately covers `.env`, so it must be verified rather than reported
            // missing; `.DS_Store` is noise on every macOS folder and must not become an "extra".
            manifestNames: ["a.txt", ".env"]
        )
        #expect(listing == ["a.txt", ".env"])
    }

    @Test("an unlisted visible file survives as a candidate extra")
    func extraCandidatesSurvive() {
        let listing = ChecksumScope.comparableListing(
            walked: [("a.txt", false), ("surprise.txt", false)],
            manifestName: "files.sha256",
            manifestNames: ["a.txt"]
        )
        #expect(listing == ["a.txt", "surprise.txt"])
    }
}
