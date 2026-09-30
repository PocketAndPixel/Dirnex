import Foundation

/// The `.create` half of a checksum job (PLAN.md §M14 Slice 2): hash what the user marked and write
/// a manifest beside it.
///
/// The manifest goes in the directory its names are relative to — not into the other pane, the way
/// Pack does. That is forced by the formats rather than chosen: every one of them spells names
/// relative to the checksum file's own location, so a manifest written anywhere else describes
/// files that are not there.
///
/// **Which is why a checksum of a bucket's objects writes into the bucket** (M24 Slice 4). The
/// invariant above is the whole argument: there is no third option where the names still resolve.
/// So the *names* are the remote ones, computed here from each row's own path before anything is
/// substituted, and the *bytes* come from wherever the gesture put them — a split that lives one
/// layer down, in `ChecksumRunContext.digest`, so this walk never learns about temp directories at
/// all.
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
            try write(contents, to: manifest)
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

    /// Write the manifest where it belongs, whichever backend that is.
    ///
    /// A local manifest is written in place, atomically, exactly as it always was. A manifest on a
    /// server is staged into a temp file and handed to the backend's own transfer — the same verb
    /// F5 uses, and the same one `MaterializeRunner` uses in the other direction. It is a few
    /// kilobytes, so it is reported as no progress at all rather than as a second bar nobody
    /// watches.
    ///
    /// **Whether the destination may already exist is the caller's question, not this one's.** The
    /// gesture `stat`s and asks before it queues anything, and past that point every transport here
    /// replaces: a `PUT` overwrites, `sftp`'s `put` truncates, `STOR` truncates. Deleting first
    /// would turn a refused write into a lost file.
    ///
    /// A backend with no upload — a browsed archive — throws its own refusal, and that is why there
    /// is no pre-flight guard for it: the sentence a user reads should be the one the thing that
    /// declined actually said (`ChecksumRunContext.recordFailure` keeps a `VFSError` intact).
    private func write(_ contents: String, to manifest: VFSPath) throws {
        let data = Data(contents.utf8)
        guard manifest.backend != .local else {
            try data.write(to: URL(fileURLWithPath: manifest.path), options: .atomic)
            return
        }
        let holder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        // Its real name inside a directory of its own, for `MaterializeRunner`'s reason read
        // backwards: a transport told a destination path is free to look at the local file's name,
        // and there is nothing to gain from letting the two disagree.
        let staged = holder.appendingPathComponent(manifest.lastComponent)
        try data.write(to: staged, options: .atomic)
        try context.backend.copyFile(
            at: .local(staged.path),
            to: manifest,
            expectedSize: Int64(data.count),
            progress: { _ in },
            isCancelled: { context.isCancelled() }
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
