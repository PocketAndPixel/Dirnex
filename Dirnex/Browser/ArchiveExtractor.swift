import DirnexCore
import Foundation

/// Extracts archive members onto disk by spawning `bsdtar` — the non-hermetic I/O half of F5
/// copy-out (PLAN.md §M4 "copy out with F5"), mirroring `ArchiveMounter`. The pure argv comes
/// from `DirnexCore.ArchiveExtraction`; this runs the process off-main and reports where the
/// files landed, so the panel can hand the resulting real files to the normal copy queue.
///
/// Extractions land under one shared temp root (`temporaryRoot`), each in its own UUID
/// subdirectory. The copy queue *copies* those files into the destination (it never consumes
/// them), so they are dead weight once the transfer is submitted; the root is purged at launch
/// (`purgeTemporaries` — race-free, since nothing is extracting yet), and the current session's
/// temps are reclaimed at the next launch or by the OS clearing its temp directory.
enum ArchiveExtractor {
    /// One extraction's result: the temp directory it wrote into and the on-disk location of each
    /// requested inner path, in the same order (a member `bsdtar` couldn't find is simply absent
    /// on disk — the caller stats each and drops the misses).
    struct Extraction {
        let directory: URL
        let extractedPaths: [String]
    }

    /// The shared temp root every extraction writes beneath, under the user's temp directory.
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexExtract", isDirectory: true)
    }

    /// Whether the archive's data is encrypted, and so whether extracting it needs a passphrase.
    ///
    /// Reads headers only — a zip's central directory is never encrypted — so it costs nothing worth
    /// caching: **3–4 ms for a 600 MB, 301-entry archive**, measured, against 0.1 ms for a small
    /// one. That is what lets every extraction ask unconditionally.
    static func needsPassphrase(forArchiveAt archiveOnDiskPath: String) -> Bool {
        (try? EncryptedArchiveReader.inspect(archiveAt: archiveOnDiskPath))?.needsPassphrase ?? false
    }

    /// Extract `innerPaths` of the archive at `archiveOnDiskPath` into a fresh temp directory and
    /// return where each landed. `bsdtar` best-effort extracts what it finds — a missing member
    /// makes it exit non-zero without stopping the rest — so this throws only when *nothing*
    /// landed (a corrupt archive, or every member missing); a partial extract still returns, and
    /// the caller reports whatever it then can't stat. Blocks, so call it off-main.
    ///
    /// **An encrypted archive never reaches `bsdtar`, and that guard is not optional.** Measured
    /// directly: `bsdtar -xf` on an AES-256 zip with stdin closed writes **170 KB of
    /// `Enter passphrase:` in eight seconds** and never exits — closing stdin does not stop it,
    /// because it re-prompts on EOF. So a spawn here would hang a busy process forever with
    /// `waitUntilExit()` never returning and nothing on screen to say why. Such an archive goes
    /// through `EncryptedArchiveReader` instead, which takes the passphrase in memory; without one
    /// it throws ``EncryptedArchiveError/passphraseRequired`` rather than trying.
    ///
    /// The encrypted route extracts the **whole** archive rather than the requested members —
    /// libarchive is read sequentially and the reader has no member filter yet. Correct, and
    /// wasteful for one member of a large archive; a filter (and a per-archive passphrase for the
    /// session, so preview and nested-archive entry can use it too) is its own slice.
    static func extract(
        innerPaths: [String],
        fromArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil
    ) throws -> Extraction {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if needsPassphrase(forArchiveAt: archiveOnDiskPath) {
            guard let passphrase else {
                try? FileManager.default.removeItem(at: directory)
                throw EncryptedArchiveError.passphraseRequired
            }
            do {
                try EncryptedArchiveReader.extract(
                    archiveAt: archiveOnDiskPath,
                    into: directory.path,
                    passphrase: passphrase
                )
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            return Extraction(
                directory: directory,
                extractedPaths: locations(of: innerPaths, in: directory)
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ArchiveExtraction.extractionArguments(
            archiveOnDiskPath: archiveOnDiskPath,
            innerPaths: innerPaths,
            destinationDirectory: directory.path
        )
        // Nothing here reads bsdtar's streams; discarding both avoids a full-pipe stall and keeps
        // a libarchive warning off the console. A real failure shows up as an empty extraction.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw VFSError.unsupported(.archiveToolUnavailableForExtract)
        }
        process.waitUntilExit()

        let extractedPaths = locations(of: innerPaths, in: directory)
        guard extractedPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try? FileManager.default.removeItem(at: directory)
            let name = (archiveOnDiskPath as NSString).lastPathComponent
            throw VFSError.unsupported(.archiveExtractFailed(archive: name))
        }
        return Extraction(directory: directory, extractedPaths: extractedPaths)
    }

    /// Where each requested member landed. Both routes place an entry at its own archive-relative
    /// path under the temp directory, so one mapping covers them — including a name-privacy archive,
    /// whose inner tar the reader has already unwrapped by this point.
    private static func locations(of innerPaths: [String], in directory: URL) -> [String] {
        innerPaths.map {
            ArchiveExtraction.extractedLocation(ofInnerPath: $0, inDirectory: directory.path)
        }
    }

    /// Remove every extraction temp directory. Called once at launch, before anything can be
    /// extracting, so it can safely clear the whole root without racing an in-flight transfer.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}
