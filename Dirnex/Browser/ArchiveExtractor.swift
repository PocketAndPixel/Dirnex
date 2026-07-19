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

    /// Extract `innerPaths` of the archive at `archiveOnDiskPath` into a fresh temp directory and
    /// return where each landed. `bsdtar` best-effort extracts what it finds — a missing member
    /// makes it exit non-zero without stopping the rest — so this throws only when *nothing*
    /// landed (a corrupt archive, or every member missing); a partial extract still returns, and
    /// the caller reports whatever it then can't stat. Blocks on `bsdtar`, so call it off-main.
    static func extract(
        innerPaths: [String],
        fromArchiveAt archiveOnDiskPath: String
    ) throws -> Extraction {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
            throw VFSError.unsupported("Couldn’t run bsdtar to extract from the archive.")
        }
        process.waitUntilExit()

        let extractedPaths = innerPaths.map {
            ArchiveExtraction.extractedLocation(ofInnerPath: $0, inDirectory: directory.path)
        }
        guard extractedPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try? FileManager.default.removeItem(at: directory)
            let name = (archiveOnDiskPath as NSString).lastPathComponent
            throw VFSError.unsupported("Couldn’t extract from the archive “\(name)”.")
        }
        return Extraction(directory: directory, extractedPaths: extractedPaths)
    }

    /// Remove every extraction temp directory. Called once at launch, before anything can be
    /// extracting, so it can safely clear the whole root without racing an in-flight transfer.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}
