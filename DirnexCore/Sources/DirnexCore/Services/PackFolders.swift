import Foundation

/// The folders a pack's typed path names, made before the write and taken back if it lands no
/// archive (2026-11-18).
///
/// ⌥F5's name field takes a path as F7's does (``ArchivePacking/archiveName(typed:format:)``), so
/// `backups/2026/photos` puts the archive below folders the destination may not have. Both writers
/// need them before they start: `bsdtar` and `EncryptedArchiveWriter` write beside the target on
/// this Mac, and an archive bound for a server is delivered into them. So both runners make them
/// first, through the same walk F7 uses (``NestedCreation/makeFolders(above:below:using:)``).
///
/// **A stopped or failed pack takes them back**, innermost first and each only while empty, which
/// keeps the promise both runners already made: a pack that does not finish leaves nothing at the
/// destination. A folder that was already there is never in the list.
///
/// They are derived from the operation's `destinationDirectory`, which is the folder the other pane
/// shows and the one the archive's path was built from, so a job carries nothing new.
struct PackFolders {
    /// The folders made, outermost first.
    let made: [VFSPath]

    init(for archive: VFSPath, in destination: VFSPath, using backend: any VFSBackend) throws {
        made = try NestedCreation.makeFolders(above: archive, below: destination, using: backend)
    }

    /// `report` as it stands, after taking the folders back when it created no archive.
    func settle(after report: OperationReport, using backend: any VFSBackend) -> OperationReport {
        if case .created = report.pack { return report }
        NestedCreation.takeBack(made, using: backend)
        return report
    }

    /// A refusal on the way, as the job's failure: the backend's own `VFSError`, which names the file
    /// standing where a folder would go, so the app can say which name is wrong.
    static func failure(_ error: any Error, archive: VFSPath) -> VFSError {
        (error as? VFSError) ?? .unsupported(.archiveCreateFailed(archive: archive.lastComponent))
    }
}
