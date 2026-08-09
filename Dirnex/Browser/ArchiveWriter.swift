import DirnexCore
import Foundation

/// Rewrites an archive to delete members from it *or* add new items into it, by spawning `bsdtar` —
/// the non-hermetic I/O half of TC's write-inside-an-archive gestures (F8 delete, paste/F5/F6 add;
/// PLAN.md §M4 "Archive writes: add/delete inside zip — rewrite strategy, journal-safe temp file"),
/// mirroring `ArchiveExtractor`/`ArchivePacker`. The pure argv comes from `DirnexCore.ArchiveMutation`;
/// this runs the processes off-main and performs the atomic swap.
///
/// Both gestures share one rewrite shape: extract the whole archive into a scratch directory, edit
/// the tree there by real filesystem paths (delete → `removeItem` a member; add → `copyItem` new
/// items in — exact, see `ArchiveMutation` for why an in-place `bsdtar --exclude`/append can't do
/// this safely), repack the result into a hidden sibling of the original, then atomically replace the
/// original with it (`FileManager.replaceItemAt`, a same-volume swap). The original is never touched
/// until the repack has fully succeeded, so a failure or crash mid-rewrite leaves it intact — the
/// "journal-safe temp file" the plan calls for.
///
/// **An encrypted archive takes the same shape through libarchive instead of `bsdtar`** (PLAN.md
/// §M19), for the reason the whole `CArchiveShim` exception exists: `bsdtar` has nowhere safe to put
/// a passphrase. Measured on a real AES-256 zip, `bsdtar -x` over the whole archive does not prompt
/// and does not hang — it exits 1 having written nothing — so before this route existed, F8 delete
/// and F5/paste add inside an encrypted archive failed outright. They failed *safely* (the rewrite
/// throws before the original is touched), which is why it read as "not supported yet" rather than
/// as damage. `ArchiveRewriteFormat` decides which route runs, off one header read.
enum ArchiveWriter {
    /// The shared scratch root every rewrite extracts beneath, under the user's temp directory.
    /// Purged at launch like the extractor's, since a rewrite fully finishes (or fails) before
    /// returning — nothing lingers that a later session needs.
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexArchiveWrite", isDirectory: true)
    }

    /// Delete `innerPaths` (VFS inner paths like `/docs/api/x.md`, a directory removing its whole
    /// subtree) from the archive at `archiveOnDiskPath`, rewriting it in place. Throws — leaving the
    /// original untouched — when the archive can't be read, the repack fails, or the swap fails.
    /// Blocks, so call it off-main.
    ///
    /// `passphrase` is required for an encrypted archive and ignored otherwise, so a caller holding
    /// one may pass it speculatively.
    static func delete(
        innerPaths: [String],
        fromArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil
    ) throws {
        try rewrite(archiveOnDiskPath: archiveOnDiskPath, passphrase: passphrase) { workingDirectory in
            // Remove each target by its exact extracted path. A member that isn't there (already
            // gone, or a stale selection) is not a failure — the rewrite still drops it.
            for innerPath in innerPaths {
                let location = ArchiveMutation.workingLocation(
                    ofInnerPath: innerPath,
                    inWorkingDirectory: workingDirectory
                )
                try? FileManager.default.removeItem(atPath: location)
            }
        }
    }

    /// Add the on-disk items at `localPaths` into the archive's inner directory `innerDirectory`
    /// (`/` = the archive root), rewriting the archive at `archiveOnDiskPath` in place. Each item is
    /// copied under its own last path component; a same-named member already there is replaced (the
    /// app confirms that overwrite first). Throws — leaving the original untouched — when the archive
    /// can't be read, a copy fails, the repack fails, or the swap fails. Blocks and does file copies,
    /// so call it off-main.
    ///
    /// `passphrase` is required for an encrypted archive and ignored otherwise. This is also the
    /// primitive behind editing a member in place: writing one edited file back is an add of that
    /// file into the directory it came from, replacing the member of the same name.
    static func add(
        localPaths: [String],
        toInnerDirectory innerDirectory: String,
        ofArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil
    ) throws {
        let name = (archiveOnDiskPath as NSString).lastPathComponent
        try rewrite(archiveOnDiskPath: archiveOnDiskPath, passphrase: passphrase) { workingDirectory in
            // The destination directory exists already when adding into a browsed folder, but make
            // sure — the archive could have been emptied, or the add could target a fresh path.
            let destinationDirectory = ArchiveMutation.additionDirectory(
                forInnerDirectory: innerDirectory,
                inWorkingDirectory: workingDirectory
            )
            try FileManager.default.createDirectory(
                atPath: destinationDirectory,
                withIntermediateDirectories: true
            )
            for localPath in localPaths {
                let sourceURL = URL(fileURLWithPath: localPath)
                let destinationURL = URL(fileURLWithPath: destinationDirectory)
                    .appendingPathComponent(sourceURL.lastPathComponent)
                // Replace a same-named member (the overwrite was confirmed) — `copyItem` would
                // otherwise fail if the destination already exists.
                try? FileManager.default.removeItem(at: destinationURL)
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    throw VFSError.unsupported(
                        .archiveAddFailed(item: sourceURL.lastPathComponent, archive: name)
                    )
                }
            }
        }
    }

    /// The shared rewrite: make a scratch directory, extract the whole archive into it, let `edit`
    /// mutate the extracted tree by real filesystem paths, then repack + atomically swap. Both
    /// `delete` and `add` are just different `edit` closures over this one flow (see the type doc).
    private static func rewrite(
        archiveOnDiskPath: String,
        passphrase: ArchivePassphrase?,
        edit: (_ workingDirectory: String) throws -> Void
    ) throws {
        let archiveURL = URL(fileURLWithPath: archiveOnDiskPath)
        let name = archiveURL.lastPathComponent

        // Headers only — no passphrase needed to learn whether one is needed, which is what lets the
        // caller be asked before any work starts rather than after the extract has failed.
        let format = ArchiveRewriteFormat.inferred(
            from: try EncryptedArchiveReader.inspect(archiveAt: archiveOnDiskPath)
        )
        if format.needsPassphrase, passphrase == nil || passphrase?.isEmpty == true {
            throw EncryptedArchiveError.passphraseRequired
        }

        let workingDirectory = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        try extractAll(
            archiveOnDiskPath: archiveOnDiskPath,
            into: workingDirectory.path,
            format: format,
            passphrase: passphrase,
            name: name
        )

        try edit(workingDirectory.path)

        // Repack into a hidden sibling in the archive's own directory (same volume → the swap below
        // is atomic), then replace the original. Clean up the sibling on any failure so a broken
        // rewrite never litters the folder.
        let rewrittenURL = archiveURL.deletingLastPathComponent().appendingPathComponent(
            ArchiveMutation.temporaryArchiveName(forArchiveNamed: name, token: UUID().uuidString)
        )
        do {
            try repackAll(
                from: workingDirectory.path,
                into: rewrittenURL.path,
                format: format,
                passphrase: passphrase,
                name: name
            )
            guard FileManager.default.fileExists(atPath: rewrittenURL.path) else {
                throw VFSError.unsupported(.archiveRewriteFailed(archive: name))
            }
            _ = try FileManager.default.replaceItemAt(archiveURL, withItemAt: rewrittenURL)
        } catch {
            try? FileManager.default.removeItem(at: rewrittenURL)
            throw error is VFSError || error is EncryptedArchiveError
                ? error
                : VFSError.unsupported(.archiveUpdateFailed(archive: name))
        }
    }

    /// Unpack the whole archive into the scratch directory, by whichever engine its format needs.
    ///
    /// A hidden-names archive unwraps here transparently — `EncryptedArchiveReader` undoes the
    /// wrapper — so `edit` always sees the real tree, and `repackAll` puts the wrapper back. That
    /// symmetry is what keeps every caller ignorant of name privacy.
    private static func extractAll(
        archiveOnDiskPath: String,
        into workingDirectory: String,
        format: ArchiveRewriteFormat,
        passphrase: ArchivePassphrase?,
        name: String
    ) throws {
        guard format.needsPassphrase else {
            try run(
                ArchiveMutation.extractAllArguments(
                    archiveOnDiskPath: archiveOnDiskPath,
                    into: workingDirectory
                ),
                failure: .archiveUnreadable(archive: name)
            )
            return
        }
        _ = try EncryptedArchiveReader.extract(
            archiveAt: archiveOnDiskPath,
            into: workingDirectory,
            passphrase: passphrase
        )
    }

    /// Pack the edited tree back into a new archive, re-stating what the original was.
    ///
    /// The unencrypted route packs `.` through `bsdtar`, which is what preserves the container
    /// format from the new archive's suffix. The encrypted route enumerates the working directory's
    /// top level instead — **including dot-files**, since a rewrite that quietly dropped a
    /// `.gitignore` somebody packed would be a data loss nobody would notice until much later.
    private static func repackAll(
        from workingDirectory: String,
        into newArchiveOnDiskPath: String,
        format: ArchiveRewriteFormat,
        passphrase: ArchivePassphrase?,
        name: String
    ) throws {
        guard format.needsPassphrase else {
            try run(
                ArchiveMutation.repackAllArguments(
                    newArchiveOnDiskPath: newArchiveOnDiskPath,
                    from: workingDirectory
                ),
                failure: .archiveRewriteFailed(archive: name)
            )
            return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: workingDirectory)
        guard !names.isEmpty else {
            // `EncryptedArchiveWriter` refuses an empty item list by design (`nothingToArchive`),
            // and deleting the last member of an archive is a legitimate thing to have just done.
            throw VFSError.unsupported(.archiveRewriteFailed(archive: name))
        }
        try EncryptedArchiveWriter.write(
            items: try ArchiveSourceEnumerator.items(
                inDirectory: workingDirectory,
                names: names,
                // The bytes are already on local disk in our own scratch directory: nothing here can
                // be an un-materialized cloud placeholder, so the guard has nothing to protect.
                allowDataless: true
            ),
            toArchiveAt: newArchiveOnDiskPath,
            encryption: format.encryption,
            passphrase: passphrase,
            namePrivacy: format.namePrivacy
        )
    }

    /// Remove every rewrite scratch directory. Called once at launch, before anything can be
    /// rewriting, so it can clear the whole root without racing an in-flight operation.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    // MARK: - Process

    /// Run one `bsdtar` invocation to completion, throwing `failure` on a spawn error or non-zero
    /// exit. Both streams are discarded — nothing here reads them, and doing so avoids a full-pipe
    /// stall and keeps libarchive warnings off the console (a real problem shows as a non-zero exit).
    private static func run(_ arguments: [String], failure reason: VFSUnsupportedReason) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw VFSError.unsupported(reason)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VFSError.unsupported(reason) }
    }
}
