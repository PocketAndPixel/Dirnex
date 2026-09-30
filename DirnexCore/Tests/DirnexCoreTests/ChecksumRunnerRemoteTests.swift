import Foundation
import Testing

@testable import DirnexCore

/// Hashing rows that are not on this disk (PLAN.md §M24 Slice 4) — the half of the checksum engine
/// that had refused since M14.
///
/// The one claim everything here turns on is the **split**: the bytes come from a temp copy and
/// every name comes from the row, so a manifest written beside a bucket's objects spells `a.bin`
/// and not `A1B2-C3D4/a.bin`. The digests below are `shasum -a 256` over the same bytes — the
/// system tool, never this engine, so a fixture cannot merely agree with the thing it is checking.
@Suite("ChecksumRunner — rows that are not on this disk")
struct ChecksumRunnerRemoteTests {
    private enum Digest {
        static let alpha = "b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060"
        static let beta = "1e6f53bf8c3e3704ca99c5e692d8745b54ed7ec0d83064484a5fb1ce6c7355a8"
    }

    /// The remote side, and beside it the copies a `.materialize` job would have left on this disk.
    private struct Fixture {
        let store: FakeRemoteStore
        let tree: TempTree
        var materialized = MaterializedPaths()

        init(_ remote: [String: String]) throws {
            store = FakeRemoteStore(remote)
            tree = try TempTree()
        }

        /// Stand `remotePath` in with a real local file holding `contents` — what the gesture's
        /// queued transfer produces, written by hand here so the engine is what is under test.
        mutating func materialize(_ remotePath: String, contents: String) throws {
            let name = (remotePath as NSString).lastPathComponent
            let holder = "d\(abs(remotePath.hashValue) % 100000)"
            try tree.makeDir(holder)
            try tree.writeFile("\(holder)/\(name)", contents: contents)
            materialized = materialized.merging(
                MaterializedPaths([store.path(remotePath): tree.path("\(holder)/\(name)")])
            )
        }
    }

    private func createOperation(
        _ fixture: Fixture,
        sources: [String],
        manifest: String
    ) -> FileOperation {
        FileOperation(
            kind: .checksum(.create(manifest: fixture.store.path(manifest), algorithm: .sha256)),
            sources: sources.map { fixture.store.entry($0) },
            destinationDirectory: fixture.store.path(
                (manifest as NSString).deletingLastPathComponent
            ),
            materialized: fixture.materialized
        )
    }

    private func verifyOperation(_ fixture: Fixture, manifest: String) -> FileOperation {
        FileOperation(
            kind: .checksum(.verify(manifest: fixture.store.path(manifest))),
            sources: [],
            destinationDirectory: fixture.store.path(
                (manifest as NSString).deletingLastPathComponent
            ),
            materialized: fixture.materialized
        )
    }

    private func created(_ report: OperationReport) throws -> ChecksumCreationSummary {
        guard case let .created(summary)? = report.checksum else {
            Issue.record("expected a creation summary, got \(String(describing: report.checksum))")
            throw CancellationError()
        }
        return summary
    }

    private func verified(_ report: OperationReport) throws -> ChecksumVerificationReport {
        guard case let .verified(verdict)? = report.checksum else {
            Issue.record("expected a verdict, got \(String(describing: report.checksum))")
            throw CancellationError()
        }
        return verdict
    }

    // MARK: - Create

    /// The whole slice in one assertion: remote names in the file, real digests of the temp bytes,
    /// and the file itself uploaded to where its names resolve from.
    @Test("a manifest of remote rows keeps the remote names and lands beside them")
    func createsRemoteManifest() throws {
        var fixture = try Fixture([
            "/data/a.bin": "alpha\n",
            "/data/b.bin": "beta contents\n"
        ])
        defer { fixture.tree.cleanup() }
        try fixture.materialize("/data/a.bin", contents: "alpha\n")
        try fixture.materialize("/data/b.bin", contents: "beta contents\n")

        let report = ChecksumRunner.run(
            createOperation(
                fixture,
                sources: ["/data/a.bin", "/data/b.bin"],
                manifest: "/data/files.sha256"
            ),
            using: fixture.store
        )

        let summary = try created(report)
        #expect(summary.writtenCount == 2)
        #expect(summary.isComplete)
        #expect(report.succeeded)
        #expect(
            fixture.store.contents["/data/files.sha256"]
                == "\(Digest.alpha)  a.bin\n\(Digest.beta)  b.bin\n"
        )
    }

    /// A row whose transfer failed is **named and omitted**, never quietly dropped: a manifest that
    /// silently covers less than it claims verifies clean forever after. It is the same row an
    /// evicted cloud placeholder produces, which is the same fact about a different provider.
    @Test("a row with no copy on this disk is skipped as not downloaded, not failed")
    func reportsRowsThatNeverArrived() throws {
        var fixture = try Fixture([
            "/data/a.bin": "alpha\n",
            "/data/b.bin": "beta contents\n"
        ])
        defer { fixture.tree.cleanup() }
        try fixture.materialize("/data/a.bin", contents: "alpha\n")

        let report = ChecksumRunner.run(
            createOperation(
                fixture,
                sources: ["/data/a.bin", "/data/b.bin"],
                manifest: "/data/files.sha256"
            ),
            using: fixture.store
        )

        let summary = try created(report)
        #expect(summary.writtenCount == 1)
        #expect(!summary.isComplete)
        #expect(summary.skipped.map(\.name) == ["b.bin"])
        #expect(summary.skipped.map(\.status) == [.notDownloaded])
        #expect(fixture.store.contents["/data/files.sha256"] == "\(Digest.alpha)  a.bin\n")
    }

    /// The sentence a user reads has to be the one the thing that declined actually said. Before
    /// this slice `recordFailure` normalized every error through an errno, which flattens a
    /// backend's own refusal to `.io` — a code nobody can look up, standing in for "the bucket is
    /// read-only".
    @Test("a refused upload reports the backend's own reason")
    func keepsTheBackendsRefusal() throws {
        var fixture = try Fixture(["/data/a.bin": "alpha\n"])
        defer { fixture.tree.cleanup() }
        try fixture.materialize("/data/a.bin", contents: "alpha\n")
        let store = FakeRemoteStore(
            ["/data/a.bin": "alpha\n"],
            refusingUploadsTo: ["/data/files.sha256"]
        )

        let report = ChecksumRunner.run(
            createOperation(fixture, sources: ["/data/a.bin"], manifest: "/data/files.sha256"),
            using: store
        )

        #expect(report.checksum == nil)
        #expect(
            report.failures.map(\.error) == [.permissionDenied(store.path("/data/files.sha256"))]
        )
        #expect(store.contents["/data/files.sha256"] == nil)
    }

    // MARK: - Verify

    /// Two phases in one map: the manifest came down first because nothing could know what else to
    /// fetch, and the files it names came down after.
    @Test("a remote manifest is read from its own copy and verified against the rows' copies")
    func verifiesRemoteManifest() throws {
        let manifest = "\(Digest.alpha)  a.bin\n\(Digest.beta)  b.bin\n"
        var fixture = try Fixture([
            "/data/a.bin": "alpha\n",
            "/data/b.bin": "beta contents\n",
            "/data/files.sha256": manifest
        ])
        defer { fixture.tree.cleanup() }
        try fixture.materialize("/data/files.sha256", contents: manifest)
        try fixture.materialize("/data/a.bin", contents: "alpha\n")
        try fixture.materialize("/data/b.bin", contents: "beta contents\n")

        let verdict = try verified(
            ChecksumRunner.run(
                verifyOperation(fixture, manifest: "/data/files.sha256"),
                using: fixture.store
            )
        )

        #expect(verdict.okCount == 2)
        #expect(verdict.entries.map(\.name) == ["a.bin", "b.bin"])
        #expect(verdict.extraCount == 0)
    }

    /// **A transfer that failed must never read as corruption.** The two verdicts sit in the same
    /// column of the same report, and reporting a download problem as a mismatch is the one wrong
    /// answer this feature can give that a user would act on.
    @Test("a claimed file that never arrived is not downloaded, not a mismatch")
    func missingCopyIsNotAMismatch() throws {
        let manifest = "\(Digest.alpha)  a.bin\n\(Digest.beta)  b.bin\n"
        var fixture = try Fixture([
            "/data/a.bin": "alpha\n",
            "/data/b.bin": "beta contents\n",
            "/data/files.sha256": manifest
        ])
        defer { fixture.tree.cleanup() }
        try fixture.materialize("/data/files.sha256", contents: manifest)
        try fixture.materialize("/data/a.bin", contents: "alpha\n")

        let verdict = try verified(
            ChecksumRunner.run(
                verifyOperation(fixture, manifest: "/data/files.sha256"),
                using: fixture.store
            )
        )

        #expect(verdict.entries.first { $0.name == "a.bin" }?.status == .ok)
        #expect(verdict.entries.first { $0.name == "b.bin" }?.status == .notDownloaded)
        #expect(verdict.mismatchCount == 0)
    }

    /// The dispatch mistake, answered rather than crashed: the gesture always brings the manifest
    /// down first, so reaching here means something skipped it.
    @Test("a verify with no copy of its manifest fails rather than trapping")
    func verifyWithoutTheManifestFails() throws {
        let fixture = try Fixture(["/data/files.sha256": "\(Digest.alpha)  a.bin\n"])
        defer { fixture.tree.cleanup() }

        let report = ChecksumRunner.run(
            verifyOperation(fixture, manifest: "/data/files.sha256"),
            using: fixture.store
        )

        #expect(report.checksum == .failed(.needsLocalFile))
    }
}
