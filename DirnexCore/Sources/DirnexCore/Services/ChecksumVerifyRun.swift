import Foundation

/// The `.verify` half of a checksum job (PLAN.md §M14 Slice 2) — the primary half of the feature.
///
/// Most people never author a checksum file; they download one next to an ISO and want to know
/// whether the bytes survived. So this is the path that has to be tolerant of what other tools
/// wrote (`ChecksumManifest.parse` reads all six shapes the M14 probe captured, where `shasum -c`
/// refuses four of them) and honest about what it could not check.
///
/// The algorithm is never passed in: it comes out of the manifest, by a `MD5 (…)` label or by the
/// digest width, which is distinct for all four. A caller able to override it could verify a
/// SHA-256 file as MD5 and report every single line as a mismatch.
///
/// **Which files it looks at is `ChecksumVerifyScope`'s, not this file's** (M24 Slice 4). Verifying
/// a manifest that is not on this disk is two-phase — nothing can know what to fetch until the
/// manifest has been read — so the gesture works the same set out in order to weigh it, and the two
/// must be one function or a file the gesture failed to predict comes back "not downloaded" while
/// sitting right in front of the user.
struct ChecksumVerifyRun {
    let context: ChecksumRunContext

    func execute(manifest: VFSPath) -> OperationReport {
        let scope: ChecksumVerifyScope
        do {
            scope = try ChecksumVerifyScope.resolve(
                manifestAt: manifest,
                contents: try read(manifest),
                list: { (try? context.backend.listDirectory(at: $0)) ?? [] },
                isCancelled: { context.isCancelled() }
            )
        } catch let error as ChecksumError {
            return context.report(outcome: .failed(error))
        } catch {
            context.recordFailure(manifest, error)
            return context.report(outcome: nil)
        }

        context.measure(files: scope.claimed)
        var computed: [String: ChecksumVerification.Computation] = [:]
        for file in scope.claimed {
            guard !context.checkCancelled() else { return context.report(outcome: nil) }
            computed[file.name] = context
                .digest(of: file.entry, using: scope.manifest.algorithm)
                .computation
        }
        guard !context.checkCancelled() else { return context.report(outcome: nil) }
        return context.report(
            outcome: .verified(
                ChecksumVerification.verify(
                    scope.manifest,
                    listing: scope.listing,
                    computed: computed
                )
            )
        )
    }

    /// The manifest's own bytes, read from the file standing for it.
    ///
    /// For a manifest on this disk that is the manifest; for one in a bucket it is the copy the
    /// gesture brought down before it could know what else to fetch (``MaterializedPaths``). The
    /// job keeps naming the **remote** path throughout, which is what makes `job.root` the remote
    /// directory and every name in the report the server's own spelling.
    ///
    /// ``ChecksumError/needsLocalFile`` when there is no stand-in: the runner already refused that
    /// case before this could be reached, and answering it here rather than force-unwrapping keeps
    /// a dispatch mistake a reported failure instead of a crash.
    private func read(_ manifest: VFSPath) throws -> Data {
        guard let local = context.materialized.localPath(for: manifest) else {
            throw ChecksumError.needsLocalFile
        }
        return try Data(contentsOf: URL(fileURLWithPath: local.path))
    }
}
