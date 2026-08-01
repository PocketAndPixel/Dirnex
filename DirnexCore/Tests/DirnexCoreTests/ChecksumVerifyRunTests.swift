import Foundation
import Testing

@testable import DirnexCore

/// The verification half of the queued checksum engine (PLAN.md §M14 Slice 2) — the primary half of
/// the feature, and the one whose answers a user acts on.
///
/// Its own suite because `ChecksumRunnerTests` reached SwiftLint's type-body ceiling, and the seam
/// is the feature's own: creating writes a file, verifying reads one.
///
/// Digests come from the system tools over the same bytes, never from this engine.
@Suite("ChecksumRunner — verify")
struct ChecksumVerifyRunTests {
    let backend = LocalBackend()

    private enum Digest {
        static let alpha = "b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060"
        static let beta = "1e6f53bf8c3e3704ca99c5e692d8745b54ed7ec0d83064484a5fb1ce6c7355a8"
    }

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func createOperation(
        _ tree: TempTree,
        sources: [String],
        manifest: String,
        algorithm: ChecksumAlgorithm = .sha256
    ) throws -> FileOperation {
        FileOperation(
            kind: .checksum(.create(manifest: tree.vfsPath(manifest), algorithm: algorithm)),
            sources: try sources.map { try stat(tree, $0) },
            destinationDirectory: tree.vfsPath()
        )
    }

    private func verifyOperation(_ tree: TempTree, manifest: String) -> FileOperation {
        FileOperation(
            kind: .checksum(.verify(manifest: tree.vfsPath(manifest))),
            sources: [],
            destinationDirectory: tree.vfsPath()
        )
    }

    private func verified(_ report: OperationReport) throws -> ChecksumVerificationReport {
        guard case let .verified(verdict)? = report.checksum else {
            Issue.record("expected a verification report")
            throw CancellationError()
        }
        return verdict
    }

    private func status(
        _ verdict: ChecksumVerificationReport,
        _ name: String
    ) -> ChecksumEntryStatus? {
        verdict.entries.first { $0.name == name }?.status
    }

    @Test("a changed byte is reported as a mismatch, with both digests")
    func detectsMismatch() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "files.sha256"),
            using: backend
        )
        try tree.writeFile("a.txt", contents: "beta contents\n") // same name, different bytes

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "files.sha256"), using: backend)
        )
        #expect(!verdict.isVerified)
        #expect(verdict.mismatchCount == 1)
        #expect(status(verdict, "a.txt") == .mismatch(expected: Digest.alpha, actual: Digest.beta))
    }

    @Test("a file the manifest names and the directory no longer has is missing")
    func detectsMissing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "files.sha256"),
            using: backend
        )
        try FileManager.default.removeItem(atPath: tree.path("a.txt"))

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "files.sha256"), using: backend)
        )
        #expect(verdict.missingCount == 1)
        #expect(!verdict.isVerified)
    }

    @Test("a file the manifest says nothing about is reported as extra")
    func detectsExtra() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "files.sha256"),
            using: backend
        )
        try tree.writeFile("b.txt", contents: "beta contents\n")

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "files.sha256"), using: backend)
        )
        // An extra file does not spoil the verdict — a manifest is a claim about what it names —
        // but it is counted so the user can judge.
        #expect(verdict.isVerified)
        #expect(verdict.extraCount == 1)
        #expect(status(verdict, "b.txt") == .extra)
    }

    @Test("an unmentioned subtree is never walked, so it produces no extras")
    func prunesUnmentionedSubtrees() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("elsewhere/deep")
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("elsewhere/deep/c.txt", contents: "nested\n")
        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "files.sha256"),
            using: backend
        )

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "files.sha256"), using: backend)
        )
        // "elsewhere" is a sibling directory the manifest never mentions. Reporting its contents
        // would turn a one-line manifest in a home directory into a listing of the whole disk.
        // The directory itself is not an extra either: a manifest names files, so a *folder* has no
        // row to be — which is what keeps a pruned subtree completely silent rather than half-shown.
        #expect(verdict.extraCount == 0)
        #expect(status(verdict, "elsewhere/deep/c.txt") == nil)
        #expect(status(verdict, "elsewhere") == nil)
        #expect(verdict.isVerified)
    }

    @Test("a .DS_Store is not reported as extra")
    func ignoresUnlistedHiddenFiles() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "files.sha256"),
            using: backend
        )
        try tree.writeFile(".DS_Store", contents: "junk\n")

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "files.sha256"), using: backend)
        )
        #expect(verdict.extraCount == 0)
        #expect(verdict.isVerified)
    }

    @Test("a manifest written by shasum verifies in Dirnex")
    func readsForeignManifest() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        // Exactly what `shasum -a 256 a.txt` prints — two spaces, text mode.
        try tree.writeFile("a.txt.sha256", contents: "\(Digest.alpha)  a.txt\n")

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "a.txt.sha256"), using: backend)
        )
        #expect(verdict.isVerified)
        #expect(verdict.algorithm == .sha256)
    }

    @Test("a bare-digest .crc companion takes its subject from its own file name")
    func readsBareDigestCompanion() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("a.txt.crc", contents: "9f606eec\n") // /usr/bin/crc32 a.txt

        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "a.txt.crc"), using: backend)
        )
        #expect(verdict.algorithm == .crc32)
        #expect(status(verdict, "a.txt") == .ok)
    }

    @Test("a file with no checksum lines fails the job rather than verifying nothing")
    func refusesUnreadableManifest() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("notes.sha256", contents: "just some prose\n")

        let report = ChecksumRunner.run(
            verifyOperation(tree, manifest: "notes.sha256"),
            using: backend
        )
        #expect(report.checksum == .failed(.manifestUnreadable))
    }

    @Test("a manifest mixing digest widths is refused with both algorithms named")
    func refusesMixedManifest() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile(
            "mixed.sha256",
            contents: "\(Digest.alpha)  a.txt\n9f9f90dbe3e5ee1218c86b8839db1995  b.txt\n"
        )

        let report = ChecksumRunner.run(
            verifyOperation(tree, manifest: "mixed.sha256"),
            using: backend
        )
        #expect(report.checksum == .failed(.manifestMixesAlgorithms(first: .sha256, second: .md5)))
    }
}
