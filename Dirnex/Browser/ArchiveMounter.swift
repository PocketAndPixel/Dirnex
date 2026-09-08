import DirnexCore
import Foundation

/// Reads an archive's table of contents by spawning `bsdtar -tvf` and handing the verbose
/// listing to the pure `ArchiveTOC` parser. The non-hermetic subprocess I/O lives here in the
/// app layer, mirroring `SpotlightSearchRunner`; all parsing stays tested in `DirnexCore`.
enum ArchiveMounter {
    /// - Parameter nameEncoding: The code page the entry names are stored in, when the user has
    ///   declared one. `nil` — every archive whose names are UTF-8, which is nearly all of them —
    ///   takes the `bsdtar` route this has always taken.
    static func readTableOfContents(
        ofArchiveAt archivePath: String,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> ArchiveTOC {
        if let nameEncoding {
            return try readThroughLibarchive(archivePath, nameEncoding: nameEncoding)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // The names the pane draws come out of this listing, and `bsdtar` renders them through
        // `vis(3)`: with no locale set every non-ASCII byte arrives octal-escaped, so the row
        // reads `\320\237…` and every verb built from it addresses a member that is not there
        // (``ChildProcessLocale``).
        process.environment = ChildProcessLocale.inherited()
        process.arguments = ["-tvf", archivePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr so a libarchive warning neither pollutes the listing nor risks a
        // second-pipe deadlock; a real failure shows up as a non-zero exit below.
        process.standardError = FileHandle.nullDevice

        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        do {
            try process.run()
        } catch {
            throw VFSError.unsupported(.archiveToolUnavailableForRead)
        }
        // Read to EOF before waiting so a large table of contents can't deadlock a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        awaitExit()

        // Decoded **leniently**: one member whose name is not valid UTF-8 — a zip written by a
        // Windows tool with code-page names — used to make this whole guard fail, so the archive
        // reported `archiveUnreadable` rather than listing the ninety-nine members that are fine
        // (``SubprocessText``).
        let text = SubprocessText.lossyUTF8(data)
        guard process.terminationStatus == 0 else {
            let name = (archivePath as NSString).lastPathComponent
            throw VFSError.unsupported(.archiveUnreadable(archive: name))
        }
        return ArchiveTOC(verboseListing: text)
    }

    /// Read the table of contents in-process, so the declared code page can be applied.
    ///
    /// This exists because **Apple's `bsdtar` has no `--hdrcharset`** — measured, it answers
    /// `Option --hdrcharset=CP866 is not supported` and exits 1 — so the subprocess route above
    /// cannot be told what the names are in, whatever environment it is handed. libarchive can, and
    /// Dirnex already links it for encrypted archives; this is the same reader with one option set.
    ///
    /// It costs headers rather than a spawn, so it is not the slower path — but it is only ever
    /// taken for an archive somebody has declared, which keeps every ordinary listing on the engine
    /// whose behaviour the whole `ArchiveTOC` corpus was captured from.
    private static func readThroughLibarchive(
        _ archivePath: String,
        nameEncoding: ArchiveNameEncoding
    ) throws -> ArchiveTOC {
        let name = (archivePath as NSString).lastPathComponent
        do {
            let inspection = try EncryptedArchiveReader.inspect(
                archiveAt: archivePath,
                nameEncoding: nameEncoding
            )
            return ArchiveTOC(entries: inspection.entries)
        } catch {
            // Including the case the declaration was *wrong* in: a code page with an unmapped byte
            // makes libarchive answer NULL for the name, which surfaces as `entryNameNotUTF8`. The
            // archive is not damaged and the user can pick again, so it reports as unreadable rather
            // than as anything more alarming.
            throw VFSError.unsupported(.archiveUnreadable(archive: name))
        }
    }
}
