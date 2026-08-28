import Foundation

/// SFTP's answer to ``VFSBackend/resolvingSymlinkTargets(in:)``: ask the server what its links point
/// at over the same SSH **exec** channel §M22's search walk uses, because the SFTP protocol has no
/// verb that will say (PLAN.md §M25 Slice 4).
///
/// Every path out of here that is not a confident answer leaves the entry exactly as it arrived,
/// still carrying `nil`, so the feature never depends on the exec channel existing — an account that
/// has none goes on refusing to copy a link, which is what it did before this existed.
public extension SFTPBackend {
    func resolvingSymlinkTargets(in entries: [FileEntry]) -> [FileEntry] {
        // Only a link this backend owns whose target is still unknown is worth asking about, and
        // asking about nothing must cost nothing: a directory with no links — the overwhelming
        // majority — never opens a channel at all.
        let unresolved = entries.filter {
            $0.kind == .symlink && $0.symlinkDestination == nil && $0.path.backend == id
        }
        guard !unresolved.isEmpty, !links.isRefused else { return entries }

        var targets: [String: String] = [:]
        for batch in SSHReadLinkCommand.batches(of: unresolved.map(\.path.path)) {
            guard let resolved = readTargets(of: batch) else { return entries }
            targets.merge(resolved) { _, new in new }
        }

        return entries.map { entry in
            guard let target = targets[entry.path.path] else { return entry }
            return entry.withSymlinkDestination(target)
        }
    }

    /// One exec channel's worth of paths, or `nil` when the account answered with something that is
    /// not this command's output — the one outcome that latches, since it is a fact about the
    /// connection rather than about these paths.
    private func readTargets(of paths: [String]) -> [String: String]? {
        guard let command = SSHReadLinkCommand.targets(of: paths) else { return [:] }

        // A transport failure is not propagated, exactly as the subtree walk does not propagate one:
        // anything that goes wrong reaching the exec channel means only that the target is unknown,
        // and the caller has a sentence for that. There is no cancellation to honour here either —
        // this is one short command, and the operation polls its own flag around it.
        let output: String?
        do {
            output = try transport.runCommand(command, isCancelled: { false })
        } catch {
            output = nil
        }

        guard let output, let targets = SSHLinkTargetParser.parse(output, forPaths: paths) else {
            links.recordUnavailable()
            return nil
        }
        return targets
    }
}
