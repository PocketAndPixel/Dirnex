import DirnexCore
import Foundation

/// How a set of transfer sources divides into what the copy queue can take as it stands and what
/// has to come **out of an archive** first (PLAN.md §M23 Slice 5).
///
/// `CopyEngine` takes one backend for both ends, and the archive backend has no `copyFile` — so an
/// archive member handed straight to the queue fails there, long after the gesture, with "This
/// location doesn’t support copying files". F5 has always answered that by extracting to a temp
/// directory first and handing the *real* files over (`PanelViewController+ArchiveExtract`); since
/// M23 the clipboard and a drag reach the same rows, so the routing has to be decided somewhere all
/// three gestures read rather than restated at each of them.
///
/// **The split is per row, not per pane.** A results tab holds hits from an archive beside local
/// files and objects on a server (the M22 shape), and one ⌘C can carry all three — so a paste that
/// asked the *pane* what it was dealing with would answer for none of them.
///
/// Members are grouped by the archive they live in because one extraction is one `bsdtar` (or one
/// libarchive read) over one file, with one passphrase behind it. Two archives are two extractions,
/// in the order the rows arrived, rather than a selection that quietly drops half of itself.
struct ArchiveTransferSources {
    /// One archive's worth of members, and where that archive sits on disk.
    struct Group {
        let archivePath: String
        let members: [FileEntry]
    }

    /// Entries the queue can copy unaided — local files, rows on a connected account, anything whose
    /// backend has a byte-moving verb of its own.
    let direct: [FileEntry]

    /// Archive members, grouped by their archive, each group in the order its rows appeared.
    let groups: [Group]

    init(_ entries: [FileEntry]) {
        var direct: [FileEntry] = []
        var order: [String] = []
        var members: [String: [FileEntry]] = [:]
        for entry in entries {
            // The *row's* backend, which for a browsed archive carries the on-disk archive path. A
            // row that claims to be an archive member and cannot name its archive is not something
            // this can extract, so it goes down the ordinary path and fails where every other
            // unsupported source does — rather than being dropped here, where nothing would say so.
            guard entry.path.backend.isArchive,
                  let archivePath = entry.path.backend.archivePath else {
                direct.append(entry)
                continue
            }
            if members[archivePath] == nil { order.append(archivePath) }
            members[archivePath, default: []].append(entry)
        }
        self.direct = direct
        groups = order.map { Group(archivePath: $0, members: members[$0] ?? []) }
    }

    /// Whether anything here has to be extracted before the queue can see it.
    var needsExtraction: Bool { !groups.isEmpty }
}
