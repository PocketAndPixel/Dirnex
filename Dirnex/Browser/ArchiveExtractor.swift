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
    ///
    /// Both routes now place the requested members and nothing else, so there is no "this one
    /// happens to hold the whole archive" case for a caller to exploit. It used to carry that flag,
    /// and `ArchivePreviewCache` kept a second cache keyed on it; the member filter retired both.
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
    static func needsPassphrase(
        forArchiveAt archiveOnDiskPath: String,
        nameEncoding: ArchiveNameEncoding? = nil
    ) -> Bool {
        // The encoding is passed through because without it an archive with code-page names throws
        // here, the `try?` reads that as "no passphrase needed", and the extraction goes to `bsdtar`
        // — which cannot place those names at all. A declared archive has to reach the branch below.
        (try? EncryptedArchiveReader.inspect(
            archiveAt: archiveOnDiskPath, nameEncoding: nameEncoding
        ))?.needsPassphrase ?? false
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
    /// **Both routes extract the requested members and nothing else.** The encrypted one used to
    /// extract the whole archive, because libarchive is read sequentially and the reader had no
    /// member filter — so previewing one file inside a 600 MB archive decrypted all 600 MB.
    /// ``DirnexCore/ArchiveMemberFilter`` is that filter, and it agrees with the `bsdtar` route's
    /// member matching (a directory member takes its subtree), which matters because a user cannot
    /// see which engine ran. Measured on a 600 MB AES-256 archive: **1.48 s → 0.001 s** to reach one
    /// small member, since an entry nobody asked for is stepped over rather than decrypted.
    ///
    /// **Both routes end on the same guard, and the encrypted one used not to.** The check that
    /// something actually landed sat only in the `bsdtar` branch, while both callers carried a
    /// comment resting on it — so a member the reader placed *somewhere else* came back as a path
    /// that had never existed, and the caller found out by mounting it. See
    /// ``DirnexCore/ArchiveNamePrivacy/requestsWrapper(_:)`` for the case where that happened.
    static func extract(
        innerPaths: [String],
        fromArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> Extraction {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            try unpack(
                innerPaths: innerPaths,
                fromArchiveAt: archiveOnDiskPath,
                into: directory,
                passphrase: passphrase,
                nameEncoding: nameEncoding
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let extractedPaths = locations(of: innerPaths, in: directory)
        guard extractedPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try? FileManager.default.removeItem(at: directory)
            let name = (archiveOnDiskPath as NSString).lastPathComponent
            throw VFSError.unsupported(.archiveExtractFailed(archive: name))
        }
        return Extraction(directory: directory, extractedPaths: extractedPaths)
    }

    /// Unpack into `directory` by whichever engine the archive's format needs. Leaves the directory
    /// in place; the caller owns it, including cleaning it up when this throws.
    ///
    /// **A declared code page takes the libarchive route whether or not the archive is encrypted**,
    /// for the same reason the listing does: `bsdtar` cannot be told what the names are in, and
    /// under any locale it fails to *create* them — measured, `Can't create '\217\240…':
    /// Illegal byte sequence`, exit 1, because APFS refuses a file name that is not valid UTF-8.
    /// So for these archives the in-process reader is not the faster route, it is the only one.
    private static func unpack(
        innerPaths: [String],
        fromArchiveAt archiveOnDiskPath: String,
        into directory: URL,
        passphrase: ArchivePassphrase?,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws {
        let isEncrypted = needsPassphrase(
            forArchiveAt: archiveOnDiskPath, nameEncoding: nameEncoding
        )
        if isEncrypted || nameEncoding != nil {
            if isEncrypted, passphrase == nil { throw EncryptedArchiveError.passphraseRequired }
            try EncryptedArchiveReader.extract(
                archiveAt: archiveOnDiskPath,
                into: directory.path,
                passphrase: passphrase,
                members: .members(innerPaths),
                nameEncoding: nameEncoding,
                // Asked for the wrapper by name, hand over the wrapper. Unwrapping is right for
                // every other caller and is what makes an encrypted archive extract to the files
                // the user packed; for the one row a hidden-names archive lists, it places the
                // payload and deletes the very file that was requested.
                unwrappingHiddenNames: !ArchiveNamePrivacy.requestsWrapper(innerPaths)
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // Member names go out as arguments and come back as files on disk, so both directions
        // need the locale settled (``ChildProcessLocale``).
        process.environment = ChildProcessLocale.inherited()
        process.arguments = ArchiveExtraction.extractionArguments(
            archiveOnDiskPath: archiveOnDiskPath,
            innerPaths: innerPaths,
            destinationDirectory: directory.path
        )
        // Nothing here reads bsdtar's streams; discarding both avoids a full-pipe stall and keeps
        // a libarchive warning off the console. A real failure shows up as an empty extraction.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        do {
            try process.run()
        } catch {
            throw VFSError.unsupported(.archiveToolUnavailableForExtract)
        }
        awaitExit()
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
