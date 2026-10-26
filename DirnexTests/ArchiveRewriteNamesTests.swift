import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A rewrite gives every member back the name it had, in every format `bsdtar` rewrites, against
/// real archives (``ArchiveNameForm``, found 2026-10-26 in PLAN.md §M33 Slice 6's live run).
///
/// Until then the repack packed `.` and wrote every name `./name`, so a zip holding `inner.txt`
/// came back holding `./inner.txt` beside a new `./` entry. Dirnex browsed both the same, which is
/// how it shipped; `unzip -p pair.zip inner.txt` and Python's `zipfile` did not find the member.
/// The names here are read back by `bsdtar -tf`, a reader independent of both of Dirnex's writers.
@Suite("Archive rewrite names")
struct ArchiveRewriteNamesTests {
    /// Every suffix the repack writes: the three containers, each tar compression under both its
    /// spellings, and a zip alias that needs `--format zip`. Not `.tar.zst`: Apple's `bsdtar` runs an
    /// external `zstd` to read or write one, and the test host's `PATH` has none (docs/NOTES.md ▸
    /// bsdtar). The same argv, run from a shell with Homebrew's `zstd`, wrote bare names like the rest.
    static let suffixes = [
        "zip", "jar", "7z", "tar", "tgz", "tar.gz", "tbz2", "tar.bz2", "txz", "tar.xz"
    ]

    @Test("bare names come back bare", arguments: suffixes)
    func bareNamesStayBare(_ suffix: String) throws {
        let fixture = try Fixture(suffix: suffix, form: .bare)
        defer { fixture.cleanup() }
        let before = try fixture.names()
        #expect(before.contains("inner.txt"))

        try ArchiveWriter.delete(
            innerPaths: ["/sibling.txt"], fromArchiveAt: fixture.archive, undo: .none
        )
        #expect(try fixture.names() == before.subtracting(["sibling.txt"]))
        // A symlink's target is what the link says, not a member name, so `./` stays in it.
        #expect(try fixture.extractedLinkTarget() == "./inner.txt")
    }

    @Test("names spelled ./ keep it", arguments: ["zip", "tar.gz", "7z"])
    func dotSlashNamesStayDotSlash(_ suffix: String) throws {
        // The shape `tar -C dir .` writes, and Sparkle's release tarball has.
        let fixture = try Fixture(suffix: suffix, form: .dotSlash)
        defer { fixture.cleanup() }
        let before = try fixture.names()
        #expect(before.contains("./inner.txt"))

        try ArchiveWriter.delete(
            innerPaths: ["/sibling.txt"], fromArchiveAt: fixture.archive, undo: .none
        )
        #expect(try fixture.names() == before.subtracting(["./sibling.txt"]))
    }

    @Test("a hard link's target follows its member's name", arguments: ["tar", "tgz"])
    func hardLinkTargetIsBare(_ suffix: String) throws {
        // Only tar keeps a hard link. Its target is a member name, so it has to be spelled as the
        // members are, or it points at nothing.
        let fixture = try Fixture(suffix: suffix, form: .bare, hardLink: true)
        defer { fixture.cleanup() }

        try ArchiveWriter.delete(
            innerPaths: ["/sibling.txt"], fromArchiveAt: fixture.archive, undo: .none
        )
        let link = try #require(try fixture.verboseListing().first { $0.contains(" link to ") })
        #expect(!link.contains("./"))
        #expect(try fixture.names().isDisjoint(with: ["./", "./inner.txt", "./hard.txt"]))
    }

    @Test("names bsdtar would read as an option or an archive are added under their own names")
    func awkwardNamesAreAdded() throws {
        // Why the repack keeps packing `.` rather than naming the tree's entries: as arguments,
        // `-dash.txt` is an option and `@at.zip` an archive to copy members from, and either one
        // fails the whole pack.
        let fixture = try Fixture(suffix: "zip", form: .bare)
        defer { fixture.cleanup() }
        let added = ["-dash.txt", "@at.zip"].map { name in
            let url = fixture.directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(name.utf8))
            return url.path
        }

        try ArchiveWriter.add(
            localPaths: added, toInnerDirectory: "/", ofArchiveAt: fixture.archive, undo: .none
        )
        let names = try fixture.names()
        #expect(names.isSuperset(of: ["-dash.txt", "@at.zip", "inner.txt", ".hidden"]))
        #expect(!names.contains { $0.hasPrefix("./") })
    }

    @Test("deleting the last member leaves an archive with no entries", arguments: ["zip", "tar.gz"])
    func emptiedArchiveHasNoEntries(_ suffix: String) throws {
        // `.` is also what lets an emptied tree repack at all. Stripped of `./`, the root entry
        // goes too, so nothing is left in the archive.
        let fixture = try Fixture(suffix: suffix, form: .bare, members: ["only.txt"])
        defer { fixture.cleanup() }

        try ArchiveWriter.delete(
            innerPaths: ["/only.txt"], fromArchiveAt: fixture.archive, undo: .none
        )
        #expect(try fixture.names().isEmpty)
    }

    /// An archive packed by `bsdtar` itself, so neither Dirnex writer chose its names: bare names
    /// are passed by name, and the `./` form by packing `.`.
    private struct Fixture {
        let directory: URL
        let archive: String

        static let defaultMembers = ["inner.txt", "sibling.txt", ".hidden", "docs/x.md", "link"]

        init(
            suffix: String,
            form: ArchiveNameForm,
            members: [String] = defaultMembers,
            hardLink: Bool = false
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ArchiveRewriteNames-\(UUID().uuidString)",
                    isDirectory: true
                )
            let source = directory.appendingPathComponent("source", isDirectory: true)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
            var topLevel: [String] = []
            for member in members {
                let url = source.appendingPathComponent(member)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if member == "link" {
                    try fileManager.createSymbolicLink(
                        atPath: url.path,
                        withDestinationPath: "./inner.txt"
                    )
                } else {
                    try Data(member.utf8).write(to: url)
                }
                let first = String(member.split(separator: "/")[0])
                if !topLevel.contains(first) { topLevel.append(first) }
            }
            if hardLink {
                try fileManager.linkItem(
                    at: source.appendingPathComponent("inner.txt"),
                    to: source.appendingPathComponent("hard.txt")
                )
                topLevel.append("hard.txt")
            }

            archive = directory.appendingPathComponent("fixture.\(suffix)").path
            let format = suffix == "jar" ? ["--format", "zip"] : []
            let names = form == .bare ? topLevel : ["."]
            _ = try Self.bsdtar(["-a", "-c"] + format + ["-f", archive, "-C", source.path] + names)
        }

        /// Every entry's name, as `bsdtar -tf` prints it.
        func names() throws -> Set<String> {
            Set(try Self.bsdtar(["-tf", archive]).split(separator: "\n").map(String.init))
        }

        func verboseListing() throws -> [String] {
            try Self.bsdtar(["-tvf", archive]).split(separator: "\n").map(String.init)
        }

        /// Where the archive's `link` points once extracted.
        func extractedLinkTarget() throws -> String {
            let out = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            _ = try Self.bsdtar(["-x", "-f", archive, "-C", out.path])
            return try FileManager.default.destinationOfSymbolicLink(
                atPath: out.appendingPathComponent("link").path
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// Run `bsdtar` to completion and answer its standard output, failing on a non-zero exit.
        private static func bsdtar(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw VFSError.unsupported(
                    .archiveUnreadable(archive: arguments.joined(separator: " "))
                )
            }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
    }
}
