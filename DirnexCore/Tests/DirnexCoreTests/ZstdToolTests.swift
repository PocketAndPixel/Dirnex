import Foundation
import Testing

@testable import DirnexCore

@Suite("ZstdTool")
struct ZstdToolTests {
    private let home = "/Users/someone"

    /// A throwaway directory holding whatever `make` puts in it.
    private func scratchDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "dirnex-zstd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - The search

    @Test("the inherited PATH is searched first, then Homebrew, /etc/paths.d and MacPorts")
    func searchOrder() {
        let directories = ZstdTool.searchDirectories(
            inheritedPath: "/Users/someone/bin:/usr/bin:/bin",
            systemDirectories: ["/usr/local/share/dotnet"],
            home: home
        )
        #expect(directories == [
            "/Users/someone/bin", "/usr/bin", "/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            "/usr/sbin", "/sbin",
            "/usr/local/share/dotnet", "/opt/local/bin"
        ])
    }

    @Test(
        "a relative or tilde entry in the inherited PATH is skipped or expanded, and a repeat dropped"
    )
    func searchSkipsRelativeEntries() {
        let directories = ZstdTool.searchDirectories(
            inheritedPath: "bin:./tools:~/bin:/opt/homebrew/bin:/opt/homebrew/bin",
            systemDirectories: [],
            home: home
        )
        #expect(directories.first == "/Users/someone/bin")
        #expect(!directories.contains("bin") && !directories.contains("./tools"))
        #expect(directories.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test("the first directory holding an executable zstd wins")
    func locateTakesTheFirstMatch() {
        let found = ZstdTool.locate(in: ["/a", "/b", "/c"]) { $0 == "/b/zstd" || $0 == "/c/zstd" }
        #expect(found == "/b/zstd")
        #expect(ZstdTool.locate(in: ["/a"]) { _ in false } == nil)
    }

    @Test("locate finds an executable file, and not a directory or a plain file called zstd")
    func locateChecksTheFile() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = root + "/folder", plain = root + "/plain", tool = root + "/tool"
        try FileManager.default.createDirectory(
            atPath: folder + "/zstd", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plain + "/zstd", contents: Data("x".utf8))
        try FileManager.default.createDirectory(atPath: tool, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: tool + "/zstd", contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )

        let found = ZstdTool.$searchDirectoriesOverride.withValue([folder, plain, tool]) {
            ZstdTool.locate()
        }
        #expect(found == tool + "/zstd")
        #expect(ZstdTool.$searchDirectoriesOverride.withValue([]) { ZstdTool.locate() } == nil)
    }

    // MARK: - A child's PATH

    @Test("zstd's directory is appended to a child's PATH when it is missing")
    func childPathAppends() {
        #expect(ZstdTool.childPath("/usr/bin:/bin", zstd: "/opt/homebrew/bin/zstd")
            == "/usr/bin:/bin:/opt/homebrew/bin")
    }

    @Test("a PATH that already has zstd's directory is left as it is")
    func childPathKeepsAPathThatHasIt() {
        let path = "/opt/homebrew/bin:/usr/bin:/bin"
        #expect(ZstdTool.childPath(path, zstd: "/opt/homebrew/bin/zstd") == path)
    }

    @Test("no zstd leaves PATH alone, and no PATH keeps posix_spawnp's default in front")
    func childPathEdges() {
        #expect(ZstdTool.childPath("/usr/bin:/bin", zstd: nil) == "/usr/bin:/bin")
        #expect(ZstdTool.childPath(nil, zstd: nil) == nil)
        #expect(
            ZstdTool.childPath(nil, zstd: "/opt/local/bin/zstd") == "/usr/bin:/bin:/opt/local/bin"
        )
    }

    @Test("a bsdtar child gets the pinned locale and zstd's directory, and nothing else changes")
    func bsdtarEnvironment() {
        let base = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": home]
        let child = BsdtarEnvironment.make(from: base, zstd: "/opt/homebrew/bin/zstd")
        #expect(child == [
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_CTYPE": "UTF-8", "LC_TIME": "C",
            "HOME": home
        ])
        #expect(BsdtarEnvironment.make(from: base, zstd: nil)["PATH"] == "/usr/bin:/bin")
    }

    // MARK: - The reader's command

    @Test("the read command quotes the path and runs bsdtar's own read flags")
    func readCommand() {
        #expect(ZstdTool.readCommand(zstd: "/opt/homebrew/bin/zstd")
            == #""/opt/homebrew/bin/zstd" -d -qq"#)
        #expect(ZstdTool.readCommand(zstd: "/Users/me/my tools/zstd")
            == #""/Users/me/my tools/zstd" -d -qq"#)
        #expect(ZstdTool.readCommand(zstd: #"/odd/a"b\c/zstd"#)
            == #""/odd/a\"b\\c/zstd" -d -qq"#)
    }

    // MARK: - Recognizing a Zstandard stream

    @Test("a frame and all sixteen skippable frames start a Zstandard stream")
    func recognizesZstandard() {
        #expect(ZstdTool.isZstandard([0x28, 0xB5, 0x2F, 0xFD, 0x00]))
        #expect(ZstdTool.isZstandard([0x50, 0x2A, 0x4D, 0x18]))
        #expect(ZstdTool.isZstandard([0x5F, 0x2A, 0x4D, 0x18]))
    }

    @Test("gzip, a near miss and a short file are not Zstandard")
    func rejectsOtherStreams() {
        #expect(!ZstdTool.isZstandard([0x1F, 0x8B, 0x08, 0x00]))
        #expect(!ZstdTool.isZstandard([0x60, 0x2A, 0x4D, 0x18]))
        #expect(!ZstdTool.isZstandard([0x28, 0xB5, 0x2F, 0xFC]))
        #expect(!ZstdTool.isZstandard([0x28, 0xB5, 0x2F]))
    }

    // MARK: - The refusal

    @Test("a Zstandard archive with no zstd is refused by name")
    func refusesWithoutZstd() throws {
        let archive = try ZstdFixture.archive("plain-bsdtar")
        #expect(ZstdTool.refusal(forArchiveAt: archive, zstd: nil)
            == .archiveNeedsZstd(archive: "plain-bsdtar.tar.zst"))
        #expect(ZstdTool.refusal(forArchiveAt: try ZstdFixture.archive("plain-pzstd"), zstd: nil)
            == .archiveNeedsZstd(archive: "plain-pzstd.tar.zst"))
    }

    @Test("with zstd, or for another kind of file, there is no refusal to make")
    func noRefusalOtherwise() throws {
        let archive = try ZstdFixture.archive("plain-bsdtar")
        #expect(ZstdTool.refusal(forArchiveAt: archive, zstd: "/opt/homebrew/bin/zstd") == nil)
        let zip = try EncryptedArchiveFixture.archive("plain-bsdtar")
        #expect(ZstdTool.refusal(forArchiveAt: zip, zstd: nil) == nil)
        #expect(ZstdTool.refusal(forArchiveAt: "/nonexistent/x.tar.zst", zstd: nil) == nil)
    }

    @Test("the refusal names the archive and how to get zstd")
    func refusalSentence() {
        let sentence = VFSUnsupportedReason.archiveNeedsZstd(archive: "backup.tar.zst").sentence
        #expect(sentence.contains("“backup.tar.zst”"))
        #expect(sentence.contains("brew install zstd"))
    }
}

/// The two `.tar.zst` fixtures, each holding `alpha.txt` (6 bytes), `docs/` and `docs/beta.txt`
/// (5 bytes), owned by root:wheel. Made on 2026-10-26 with Homebrew's zstd 1.5.7:
///
///     bsdtar -c -a --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel \
///            -f plain-bsdtar.tar.zst alpha.txt docs
///     pzstd -q plain.tar -o plain-pzstd.tar.zst
///
/// The first starts with a Zstandard frame (`28 b5 2f fd`), the second with the skippable frame
/// `pzstd` writes before its first (`50 2a 4d 18`).
enum ZstdFixture {
    static func archive(_ name: String) throws -> String {
        try #require(
            Bundle.module.url(forResource: name, withExtension: "tar.zst", subdirectory: "Fixtures"),
            "missing fixture \(name).tar.zst"
        ).path
    }
}
