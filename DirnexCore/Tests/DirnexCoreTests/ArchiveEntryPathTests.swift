import Foundation
import Testing

@testable import DirnexCore

/// The traversal defense, at both levels: the pure rule, and a real hostile archive driven end to
/// end through the extractor.
///
/// The two attack fixtures were produced by **`bsdtar`**, which is the fact worth keeping. This is
/// not a theoretical shape assembled by hand to make a test go red — a stock tool shipped with macOS
/// writes both of them without complaint:
///
///     bsdtar -c -f attack-traversal-bsdtar.zip --format zip \
///            -s '|payload.txt|../../escaped.txt|' payload.txt
///
///     bsdtar -c -f attack-symlink-bsdtar.zip --format zip \
///            -s '|^innocent.txt$|escape/dirnex-symlink-escape.txt|' escape innocent.txt
///
/// The second is the one that survives a naive fix: every *name* in it is innocent. `escape` is a
/// symlink to `/tmp`, and `escape/dirnex-symlink-escape.txt` is an ordinary relative path that any
/// path check waves through — it is the link created one entry earlier that makes it land outside.
@Suite("ArchiveEntryPath")
struct ArchiveEntryPathTests {
    // MARK: - The rule

    @Test("an ordinary relative name is allowed and normalized")
    func ordinaryNames() {
        #expect(ArchiveEntryPath.sanitized("notes/hello.txt") == .allowed("notes/hello.txt"))
        #expect(ArchiveEntryPath.sanitized("./notes/hello.txt") == .allowed("notes/hello.txt"))
        #expect(ArchiveEntryPath.sanitized("notes//hello.txt") == .allowed("notes/hello.txt"))
        #expect(ArchiveEntryPath.sanitized("a/./b/./c") == .allowed("a/b/c"))
    }

    @Test("a parent-traversal component is refused wherever it appears")
    func parentTraversalIsRefused() {
        #expect(ArchiveEntryPath.sanitized("../escaped.txt") == .refused(.parentTraversal))
        #expect(ArchiveEntryPath.sanitized("../../escaped.txt") == .refused(.parentTraversal))
        #expect(ArchiveEntryPath.sanitized("notes/../../escaped.txt") == .refused(.parentTraversal))
        // Refused rather than resolved even though this one happens to stay inside. Canceling
        // `a/../b` into `b` is one edit away from canceling `a/../../b` into `../b`, and no
        // legitimate archive needs it.
        #expect(ArchiveEntryPath.sanitized("a/../b") == .refused(.parentTraversal))
    }

    @Test("an absolute name is refused")
    func absoluteIsRefused() {
        #expect(ArchiveEntryPath.sanitized("/etc/passwd") == .refused(.absolutePath))
        #expect(ArchiveEntryPath.sanitized("/") == .refused(.absolutePath))
    }

    @Test("a name that would truncate at a syscall is refused")
    func nulByteIsRefused() {
        // The danger is specific: the checked string and the created name would differ, so the file
        // lands somewhere the check never looked at.
        #expect(ArchiveEntryPath.sanitized("safe\0/../../evil") == .refused(.containsNulByte))
    }

    @Test("a name with nothing left in it is refused")
    func emptyIsRefused() {
        #expect(ArchiveEntryPath.sanitized("") == .refused(.emptyName))
        #expect(ArchiveEntryPath.sanitized(".") == .refused(.emptyName))
        #expect(ArchiveEntryPath.sanitized("./././") == .refused(.emptyName))
    }

    @Test("a backslash stays a literal character rather than becoming a separator")
    func backslashIsNotASeparator() {
        // The zip specification says `/`, and `\` is a legal character in a POSIX filename.
        // Translating it would silently rename the user's file; the visible cost of not translating
        // it is one oddly-named file from a non-conforming Windows tool.
        #expect(ArchiveEntryPath.sanitized(#"notes\hello.txt"#) == .allowed(#"notes\hello.txt"#))
        #expect(ArchiveEntryPath.sanitized(#"..\..\escaped.txt"#) == .allowed(#"..\..\escaped.txt"#))
    }

    // MARK: - Symlink targets

    @Test("a symlink may point within the extraction root, including sideways")
    func ordinarySymlinkTargets() {
        #expect(ArchiveEntryPath.isSafeSymlinkTarget("hello.txt", forLinkAt: "link.txt"))
        #expect(ArchiveEntryPath.isSafeSymlinkTarget("notes/hello.txt", forLinkAt: "link.txt"))
        // `../` is fine when the link's own depth pays for it: this one sits in `a/b/` and points
        // at `a/c`. Refusing every `..` in a target would break ordinary archives.
        #expect(ArchiveEntryPath.isSafeSymlinkTarget("../c", forLinkAt: "a/b/link"))
    }

    @Test("a symlink that would escape the extraction root is refused")
    func escapingSymlinkTargets() {
        #expect(!ArchiveEntryPath.isSafeSymlinkTarget("/tmp", forLinkAt: "escape"))
        #expect(!ArchiveEntryPath.isSafeSymlinkTarget("/", forLinkAt: "escape"))
        #expect(!ArchiveEntryPath.isSafeSymlinkTarget("..", forLinkAt: "link"))
        #expect(!ArchiveEntryPath.isSafeSymlinkTarget("../../elsewhere", forLinkAt: "a/link"))
    }

    @Test("a target cannot climb out and back in to pay for itself")
    func escapeThenReturnIsRefused() {
        // Checked at every component rather than on the net total: `../../a/b` ends up one level
        // *inside* the root by arithmetic, but it passes through the outside on the way, and a
        // symlink is followed step by step.
        #expect(!ArchiveEntryPath.isSafeSymlinkTarget("../../a/b", forLinkAt: "link"))
    }

    // MARK: - End to end, against archives bsdtar wrote

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"),
            "missing fixture \(name).zip"
        )
        return url.path
    }

    private func scratchDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "dirnex-attack-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("a ../.. member is refused, reported, and never written")
    func traversalArchiveIsContained() throws {
        let destination = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: destination) }

        // Where the entry would have landed had it been joined naively: two levels above the
        // destination. Asserting on the actual escape target, not merely on the report.
        let escapeTarget = ((destination as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent + "/escaped.txt"
        #expect(
            !FileManager.default.fileExists(atPath: escapeTarget),
            "stale file from an earlier run"
        )

        let report = try EncryptedArchiveReader.extract(
            archiveAt: fixture("attack-traversal-bsdtar"), into: destination, passphrase: nil
        )

        #expect(report.extractedPaths.isEmpty)
        #expect(report.refused.map(\.name) == ["../../escaped.txt"])
        #expect(report.refused.map(\.reason) == [.parentTraversal])
        #expect(!FileManager.default.fileExists(atPath: escapeTarget))
    }

    @Test("a symlink out of the root is dropped, so the member aimed through it lands nowhere")
    func symlinkEscapeIsContained() throws {
        let destination = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: destination) }

        // The archive's link points at `/tmp`, so this is the literal path the attack is reaching
        // for. Cleaned first so a previous failing run cannot make this one pass.
        let escapeTarget = "/tmp/dirnex-symlink-escape.txt"
        try? FileManager.default.removeItem(atPath: escapeTarget)

        try EncryptedArchiveReader.extract(
            archiveAt: fixture("attack-symlink-bsdtar"), into: destination, passphrase: nil
        )

        #expect(
            !FileManager.default.fileExists(atPath: escapeTarget),
            "the archive wrote outside its destination"
        )

        // The link itself must not exist either — dropping it is what makes the following member
        // land inside the destination (as a real file) rather than through the link.
        var linkStatus = stat()
        let linkExists = lstat(destination + "/escape", &linkStatus) == 0
        if linkExists {
            #expect((linkStatus.st_mode & S_IFMT) != S_IFLNK, "the escaping symlink was created")
        }
    }
}
