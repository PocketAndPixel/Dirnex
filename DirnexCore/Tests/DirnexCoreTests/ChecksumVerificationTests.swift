import Foundation
import Testing

@testable import DirnexCore

@Suite("ChecksumVerification")
struct ChecksumVerificationTests {
    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)

    private static func manifest(
        _ entries: [(String, String)],
        algorithm: ChecksumAlgorithm = .sha256
    ) -> ChecksumManifest {
        ChecksumManifest(
            algorithm: algorithm,
            entries: entries.map { ChecksumManifestEntry(name: $0.0, digest: $0.1) }
        )
    }

    @Test("a matching digest passes")
    func matching() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA)]),
            listing: ["a.txt"],
            computed: ["a.txt": .digest(Self.digestA)]
        )
        #expect(report.entries.map(\.status) == [.ok])
        #expect(report.isVerified)
        #expect(report.algorithm == .sha256)
    }

    @Test("a differing digest reports both sides")
    func mismatch() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA)]),
            listing: ["a.txt"],
            computed: ["a.txt": .digest(Self.digestB)]
        )
        #expect(report.entries.map(\.status)
            == [.mismatch(expected: Self.digestA, actual: Self.digestB)])
        #expect(report.mismatchCount == 1)
        #expect(!report.isVerified)
    }

    @Test("a name the directory doesn't have is missing")
    func missing() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA)]),
            listing: [],
            computed: [:]
        )
        #expect(report.entries.map(\.status) == [.missing])
        #expect(report.missingCount == 1)
        #expect(!report.isVerified)
    }

    /// A file that is present but was not hashed is neither a pass nor a failure: nothing was
    /// compared, so nothing may be asserted — and a report that called it "ok" would be lying in
    /// the one direction that matters.
    @Test("a present but unhashed file is unreadable, and spoils the verdict")
    func unreadable() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA)]),
            listing: ["a.txt"],
            computed: ["a.txt": .unreadable]
        )
        #expect(report.entries.map(\.status) == [.unreadable])
        #expect(!report.isVerified)
    }

    @Test("a present file with no computation at all is also unreadable")
    func computationMissing() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA)]),
            listing: ["a.txt"],
            computed: [:]
        )
        #expect(report.entries.map(\.status) == [.unreadable])
    }

    /// "A manifest that omits a file is a different answer from one that fails it" — so an extra
    /// file is a row, not silence, and not a failure either.
    @Test("a file the manifest doesn't mention is extra, and does not fail the run")
    func extra() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA)]),
            listing: ["a.txt", "b.txt"],
            computed: ["a.txt": .digest(Self.digestA)]
        )
        #expect(report.entries.map(\.name) == ["a.txt", "b.txt"])
        #expect(report.entries.map(\.status) == [.ok, .extra])
        #expect(report.extraCount == 1)
        #expect(report.isVerified)
    }

    @Test("manifest rows come first, in manifest order; extras follow in listing order")
    func ordering() {
        let report = ChecksumVerification.verify(
            Self.manifest([("z.txt", Self.digestA), ("a.txt", Self.digestA)]),
            listing: ["a.txt", "m.txt", "z.txt", "b.txt"],
            computed: [
                "a.txt": .digest(Self.digestA),
                "z.txt": .digest(Self.digestA)
            ]
        )
        #expect(report.entries.map(\.name) == ["z.txt", "a.txt", "m.txt", "b.txt"])
    }

    /// `openssl` and Windows `.sfv` tools both emit uppercase; the comparison must not care.
    @Test("digest comparison ignores case and surrounding whitespace")
    func caseInsensitive() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA.uppercased())]),
            listing: ["a.txt"],
            computed: ["a.txt": .digest("  \(Self.digestA) ")]
        )
        #expect(report.entries.map(\.status) == [.ok])
    }

    @Test("names are relative paths, so a manifest can describe a subtree")
    func subdirectoryNames() {
        let report = ChecksumVerification.verify(
            Self.manifest([("sub/dir/a.txt", Self.digestA)]),
            listing: ["sub/dir/a.txt"],
            computed: ["sub/dir/a.txt": .digest(Self.digestA)]
        )
        #expect(report.entries.map(\.status) == [.ok])
    }

    @Test("a name listed twice is verified twice")
    func duplicateEntries() {
        let report = ChecksumVerification.verify(
            Self.manifest([("a.txt", Self.digestA), ("a.txt", Self.digestB)]),
            listing: ["a.txt"],
            computed: ["a.txt": .digest(Self.digestA)]
        )
        #expect(report.entries.count == 2)
        #expect(report.okCount == 1)
        #expect(report.mismatchCount == 1)
    }

    @Test("the counts add up over a mixed run")
    func mixedCounts() {
        let report = ChecksumVerification.verify(
            Self.manifest([
                ("ok.txt", Self.digestA),
                ("bad.txt", Self.digestA),
                ("gone.txt", Self.digestA),
                ("locked.txt", Self.digestA)
            ]),
            listing: ["ok.txt", "bad.txt", "locked.txt", "surprise.txt"],
            computed: [
                "ok.txt": .digest(Self.digestA),
                "bad.txt": .digest(Self.digestB),
                "locked.txt": .unreadable
            ]
        )
        #expect(report.okCount == 1)
        #expect(report.mismatchCount == 1)
        #expect(report.missingCount == 1)
        #expect(report.unreadableCount == 1)
        #expect(report.extraCount == 1)
        #expect(report.entries.count == 5)
        #expect(!report.isVerified)
    }

    @Test("an empty listing against an empty manifest verifies vacuously")
    func empty() {
        let report = ChecksumVerification.verify(
            Self.manifest([]),
            listing: [],
            computed: [:]
        )
        #expect(report.entries.isEmpty)
        #expect(report.isVerified)
    }

    /// End to end over real bytes: hash two files, verify them against a manifest Dirnex itself
    /// serialized and re-parsed, then corrupt one and watch it fail.
    @Test("a manifest written, re-read and verified against real files")
    func endToEnd() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello checksum world\n")
        try tree.writeFile("b.txt", contents: "two words here\n")

        let names = ["a.txt", "b.txt"]
        var computed: [String: ChecksumVerification.Computation] = [:]
        var entries: [ChecksumManifestEntry] = []
        for name in names {
            let digests = try ChecksumEngine.digests(of: tree.vfsPath(name), using: [.sha256])
            let digest = try #require(digests[.sha256])
            entries.append(ChecksumManifestEntry(name: name, digest: digest))
            computed[name] = .digest(digest)
        }

        let text = ChecksumManifest(algorithm: .sha256, entries: entries).serialized()
        let reparsed = try ChecksumManifest.parse(text)
        let report = ChecksumVerification.verify(reparsed, listing: names, computed: computed)
        #expect(report.isVerified)

        try tree.writeFile("b.txt", contents: "two words here!\n")
        let after = try ChecksumEngine.digests(of: tree.vfsPath("b.txt"), using: [.sha256])
        computed["b.txt"] = .digest(try #require(after[.sha256]))
        let failed = ChecksumVerification.verify(reparsed, listing: names, computed: computed)
        #expect(!failed.isVerified)
        #expect(failed.mismatchCount == 1)
    }
}
