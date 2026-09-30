import Foundation
import Testing

@testable import DirnexCore

/// The same table asked about a **set** rather than about the one row under a cursor (PLAN.md §M24
/// Slice 1).
///
/// Its sibling suite pins the per-file rows; nothing here re-states them. What is new is that a
/// gesture now names N files, which brings a second quantity the byte rule is structurally blind to
/// — the number of round trips — and a second way for a total to be unknown, a directory whose
/// subtree nothing here can size. Each rule below is tested where it is the *only* thing that can
/// fire, and each with the control that stops it from having become "always confirm".
@Suite("Remote fetch policy over a set")
struct RemoteFetchSetPolicyTests {
    private static let limits: [Int64] = [
        0,
        RemoteFetchPolicy.defaultPreviewLimit,
        300 * 1_000_000,
        RemoteFetchPolicy.previewLimitRange.upperBound
    ]

    /// Written out rather than read from `isAutomatic`: borrowing it would prove the two agree, not
    /// that either is right.
    private func expectedRefusal(for purpose: RemoteFetchPurpose) -> RemoteFetchDecision {
        purpose == .cursorPreview ? .decline : .confirm
    }

    private func entry(
        _ path: VFSPath,
        kind: FileEntry.Kind = .file,
        size: Int64
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    private func remotes(_ count: Int, each size: Int64) -> [FileEntry] {
        (0..<count).map {
            entry(VFSPath(backend: VFSBackendID("s3://bucket"), path: "/p/o\($0)"), size: size)
        }
    }

    private func plan(_ entries: [FileEntry], cached: Set<VFSPath> = []) -> MaterializationPlan {
        MaterializationPlan.plan(for: entries) { cached.contains($0.path) }
    }

    private func decision(
        _ plan: MaterializationPlan,
        _ purpose: RemoteFetchPurpose,
        _ limit: Int64
    ) -> RemoteFetchDecision {
        RemoteFetchPolicy.decision(for: plan, purpose: purpose, previewLimit: limit)
    }

    // MARK: - The case that must never ask

    /// The ordinary use of every gesture M24 touches: a marked set of plain local files, which must
    /// reach the engine with no dialog at **any** limit — zero included, since "never download a
    /// preview I did not ask for" must not turn Open With on this disk into a question.
    @Test("a set already on this disk starts without asking, at every limit and purpose")
    func localSetNeverAsks() {
        let local = (0..<500).map { entry(.local("/Users/oleg/f\($0)"), size: 900_000_000) }
        let result = plan(local)

        for limit in Self.limits {
            for purpose in RemoteFetchPurpose.allCases {
                #expect(decision(result, purpose, limit) == .fetch)
            }
        }
    }

    // MARK: - The rule the byte total cannot see

    /// `unaskedRequestLimit`'s whole justification, as an assertion. Ten thousand objects of 500
    /// bytes is **5 MB** — under every row of the table — and at the measured 0.512–0.519 s to first
    /// byte it is about 83 minutes. A policy expressed in bytes alone says `fetch` and does not come
    /// back.
    @Test("many tiny objects are confirmed although their bytes are trivial")
    func manyTinyObjectsAreConfirmed() {
        let swarm = plan(remotes(10_000, each: 500))

        #expect(swarm.byteTotal == 5_000_000)
        for limit in Self.limits {
            #expect(decision(swarm, .checksum, limit) == .confirm)
        }
    }

    /// The control that stops the rule above from having become "any remote set confirms": the same
    /// bytes in few enough requests start without a word.
    @Test("the same bytes in a handful of requests start without asking")
    func fewRequestsOfTheSameBytesFetch() {
        let few = plan(remotes(5, each: 1_000_000))

        #expect(few.byteTotal == 5_000_000)
        #expect(decision(few, .checksum, RemoteFetchPolicy.defaultPreviewLimit) == .fetch)
    }

    /// The boundary is a boundary and not a fence: at the limit it runs, one past it asks. A cap
    /// would have been the wrong shape — over it the user is told the count, not refused.
    @Test("the request rule admits its own limit and refuses one more")
    func requestLimitBoundary() {
        let limit = RemoteFetchPolicy.unaskedRequestLimit
        let at = plan(remotes(limit, each: 16))
        let past = plan(remotes(limit + 1, each: 16))

        #expect(decision(at, .userScript, RemoteFetchPolicy.defaultPreviewLimit) == .fetch)
        #expect(decision(past, .userScript, RemoteFetchPolicy.defaultPreviewLimit) == .confirm)
    }

    /// Running a gesture twice must not ask twice: copies already pulled down are neither requests
    /// nor bytes, so the second ⌥F3 over the same pair is free.
    @Test("cached rows bring a set back under both rules")
    func cachedRowsAdmitASetThatWouldOtherwiseAsk() {
        let all = remotes(RemoteFetchPolicy.unaskedRequestLimit + 5, each: 8_000_000)
        let cold = plan(all)
        let warm = plan(all, cached: Set(all.dropLast().map(\.path)))

        #expect(decision(cold, .compare, RemoteFetchPolicy.defaultPreviewLimit) == .confirm)
        #expect(decision(warm, .compare, RemoteFetchPolicy.defaultPreviewLimit) == .fetch)
    }

    // MARK: - The rule the request count cannot see

    /// The mirror of the swarm: one object, one round trip, and far too many bytes. Neither rule
    /// subsumes the other, which is why both are here.
    @Test("one enormous object is confirmed although it is a single request")
    func oneEnormousObjectIsConfirmed() {
        let whole = plan(remotes(1, each: 900_000_000))

        #expect(whole.requestCount == 1)
        #expect(decision(whole, .browseArchive, RemoteFetchPolicy.defaultPreviewLimit) == .confirm)
    }

    // MARK: - Totals that are floors

    /// A folder on a server stands for an unknown number of bytes in an unknown number of requests,
    /// so its 4 KB of directory entry must not be read as the answer — the unknown-size row arriving
    /// over a set. Both directions in one test: the same set sized for real starts immediately.
    @Test("a remote folder is confirmed where the same set of files is not")
    func inexactTotalsAreConfirmed() {
        let folder = entry(
            VFSPath(backend: VFSBackendID("sftp://user@host"), path: "/srv/data"),
            kind: .directory,
            size: 4096
        )
        let unknown = plan([folder])
        let known = plan(remotes(1, each: 4096))

        for limit in Self.limits {
            #expect(decision(unknown, .pack, limit) == .confirm)
        }
        #expect(decision(known, .pack, RemoteFetchPolicy.defaultPreviewLimit) == .fetch)
    }

    // MARK: - Asking versus declining

    /// `isAutomatic` decides what a refusal *is* here exactly as it does per file — the set form
    /// must not have quietly acquired the right to raise a dialog on a keystroke.
    @Test("an automatic gesture declines a set where an explicit one confirms")
    func automaticDeclinesASet() {
        let swarm = plan(remotes(10_000, each: 500))

        for limit in Self.limits {
            #expect(decision(swarm, .cursorPreview, limit) == .decline)
            #expect(decision(swarm, .preview, limit) == .confirm)
        }
    }

    /// Every purpose refuses the same set, and each in its own voice. Catches a case added later
    /// that reaches a threshold by inheriting one — the thing the exhaustive switch exists to make
    /// impossible.
    @Test("every purpose refuses an over-sized set in the shape its gesture allows")
    func everyPurposeRefusesConsistently() {
        let swarm = plan(remotes(10_000, each: 500))

        for purpose in RemoteFetchPurpose.allCases {
            #expect(decision(swarm, purpose, 0) == expectedRefusal(for: purpose))
        }
    }
}
