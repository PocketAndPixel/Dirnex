import DirnexCore
import Foundation

/// Packs files into a new archive by spawning `bsdtar` — the non-hermetic I/O half of TC's Pack
/// (Alt+F5, PLAN.md §M4 "pack via F5-with-archive-target"), mirroring `ArchiveExtractor` and
/// `ArchiveMounter`. The pure argv comes from `DirnexCore.ArchivePacking`; this runs the process
/// off-main and reports whether the archive landed.
///
/// Unlike extraction, packing writes directly to its final destination (the other pane's folder),
/// not to a temp dir — the result *is* a user file, so there's nothing to purge. `bsdtar -c`
/// overwrites any existing file, so the caller resolves a name collision before calling here.
enum ArchivePacker {
    /// Pack `sourceNames` (bare names under `sourceDirectory`) into a new archive at
    /// `archiveOnDiskPath`, whose suffix selects the format. Throws when `bsdtar` can't run,
    /// exits non-zero, or produced no file. Blocks on `bsdtar`, so call it off-main.
    static func pack(
        sourceNames: [String],
        inDirectory sourceDirectory: String,
        toArchiveAt archiveOnDiskPath: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ArchivePacking.packingArguments(
            archiveOnDiskPath: archiveOnDiskPath,
            sourceDirectory: sourceDirectory,
            sourceNames: sourceNames
        )
        // Nothing here reads bsdtar's streams; discarding both avoids a full-pipe stall and keeps
        // a libarchive warning off the console. A real failure shows up as a non-zero exit.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw VFSError.unsupported("Couldn’t run bsdtar to create the archive.")
        }
        process.waitUntilExit()

        // A non-zero exit or a missing output file means nothing usable landed; clean up a partial
        // archive so the destination folder isn't left with a broken file.
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: archiveOnDiskPath) else {
            try? FileManager.default.removeItem(atPath: archiveOnDiskPath)
            let name = (archiveOnDiskPath as NSString).lastPathComponent
            throw VFSError.unsupported("Couldn’t create the archive “\(name)”.")
        }
    }
}
