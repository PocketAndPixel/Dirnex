import Foundation

/// The `.create` half of a checksum job (PLAN.md §M14 Slice 2): hash what the user marked and write
/// a manifest beside it.
///
/// The manifest goes in the directory its names are relative to — not into the other pane, the way
/// Pack does. That is forced by the formats rather than chosen: every one of them spells names
/// relative to the checksum file's own location, so a manifest written anywhere else describes
/// files that are not there.
struct ChecksumCreateRun {
    let context: ChecksumRunContext

    func execute(
        sources: [FileEntry],
        manifest: VFSPath,
        algorithm: ChecksumAlgorithm
    ) -> OperationReport {
        let files = gather(sources: sources)
        context.measure(files: files)

        var entries: [ChecksumManifestEntry] = []
        var skipped: [ChecksumVerificationEntry] = []
        for file in files {
            guard !context.checkCancelled() else { return context.report(outcome: nil) }
            let outcome = context.digest(of: file.entry, using: algorithm)
            if case let .digest(hex) = outcome {
                entries.append(ChecksumManifestEntry(name: file.name, digest: hex))
            } else if let status = outcome.status {
                skipped.append(ChecksumVerificationEntry(name: file.name, status: status))
            }
        }
        // Checked again after the loop: a cancel that lands on the last file must not still write.
        guard !context.checkCancelled() else { return context.report(outcome: nil) }

        let contents = ChecksumManifest(algorithm: algorithm, entries: entries)
            .serialized(format: algorithm.manifestFormat)
        do {
            try Data(contents.utf8).write(to: URL(fileURLWithPath: manifest.path), options: .atomic)
        } catch {
            context.recordFailure(manifest, error)
            return context.report(outcome: nil)
        }
        return context.report(
            outcome: .created(
                ChecksumCreationSummary(
                    manifest: manifest,
                    algorithm: algorithm,
                    writtenCount: entries.count,
                    skipped: skipped
                )
            )
        )
    }

    /// Every regular file under the sources, named relative to the manifest's directory.
    ///
    /// Directories are expanded depth-first, and the order files come out in is the order they are
    /// hashed *and* written — so re-running over an unchanged tree produces a byte-identical
    /// manifest, which is what makes one diffable against the last.
    ///
    /// The manifest's own path is excluded even when the user's selection includes it: a checksum
    /// file cannot list itself, and a re-run over a folder that already has one otherwise writes a
    /// digest of the file it is in the middle of replacing.
    private func gather(sources: [FileEntry]) -> [ChecksumWalkedFile] {
        let root = context.job.root
        var found: [ChecksumWalkedFile] = []
        var stack: [FileEntry] = sources.reversed()
        while let entry = stack.popLast() {
            if context.isCancelled() { return found }
            if ChecksumScope.shouldDescend(into: entry) {
                let children = (try? context.backend.listDirectory(at: entry.path)) ?? []
                stack.append(contentsOf: children.reversed())
                continue
            }
            guard ChecksumScope.isHashable(entry),
                  entry.path != context.job.manifest,
                  let name = ChecksumScope.relativeName(of: entry.path, under: root) else { continue }
            found.append(ChecksumWalkedFile(name: name, entry: entry))
        }
        return found
    }
}
