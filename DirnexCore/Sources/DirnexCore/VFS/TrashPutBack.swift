import Foundation

/// Where a trashed item came from: the folder it was deleted out of, and the name it had there.
///
/// The name is carried separately because the two can disagree. A trash that already holds a
/// `alpha.txt` renames the newcomer — probed: it landed as `alpha.txt 13-12-35-977.txt` — while the
/// put-back record still says `alpha.txt`. Restoring under the trash's name would quietly rename
/// the user's file.
public struct TrashOrigin: Sendable, Equatable {
    public let directory: VFSPath
    public let name: String

    public init(directory: VFSPath, name: String) {
        self.directory = directory
        self.name = name
    }

    /// Where the item should land.
    public var destination: VFSPath {
        directory.appending(name)
    }
}

/// Reading Finder's put-back records, so a trashed item can go back where it came from
/// (PLAN.md §M8).
///
/// There is no API for this. Probed 2026-07-21: a trashed file's only xattr is
/// `com.apple.provenance`, `mdls` exposes nothing, and no `URLResourceKey` spelling answers. The
/// origin lives solely in the trash directory's `.DS_Store`, as a pair of string records per item —
/// `ptbL` (the folder) and `ptbN` (the name). `DSStoreReader` gets them out; everything here is the
/// pure interpretation of what they say.
///
/// **The recorded folder is relative to the volume whose trash holds the item**, and it is written
/// two different ways (both probed on the same machine, the same day):
///
/// - from a non-boot volume's `.Trashes/<uid>`, with a leading slash — `/deep/`, or `/` for the
///   volume root;
/// - from `~/.Trash`, with **no** leading slash — `Users/oleg/` — and, when Finder rather than
///   `FileManager` did the trashing, behind the boot volume's data firmlink:
///   `System/Volumes/Data/private/tmp/…` for what is really `/private/tmp/…`.
///
/// Taking either form literally lands a restore in the wrong place (or nowhere), so both are
/// normalized here rather than at any call site.
public enum TrashPutBack {
    /// Finder's property ids for the pair.
    public static let locationKey = "ptbL"
    public static let nameKey = "ptbN"

    /// The boot volume's data firmlink. Paths recorded through it name the same files as the
    /// unprefixed ones.
    private static let dataFirmlink = "System/Volumes/Data/"

    /// The origins recorded in one trash directory's `.DS_Store`, keyed by the filename **as it
    /// appears in that trash** — which is what a listing hands back, and the only thing the two
    /// sides have in common when the item was renamed on the way in.
    ///
    /// Items with no record simply have no entry: Finder leaves records behind long after their
    /// files are gone (the probe machine's `~/.Trash` still listed files deleted weeks earlier), so
    /// the map is a superset of the directory and the caller matches into it, never the reverse.
    public static func origins(
        inDSStore data: Data,
        ofTrashAt trash: VFSPath
    ) throws -> [String: TrashOrigin] {
        let records = try DSStoreReader.stringRecords(in: data)
        let volume = volumeRoot(ofTrashAt: trash)

        var locations: [String: String] = [:]
        var names: [String: String] = [:]
        for record in records {
            switch record.key {
            case locationKey: locations[record.filename] = record.value
            case nameKey: names[record.filename] = record.value
            default: continue
            }
        }

        return locations.reduce(into: [:]) { origins, entry in
            let (filename, location) = entry
            origins[filename] = TrashOrigin(
                directory: directory(recordedAs: location, onVolumeAt: volume),
                // A record with a location but no name is not something the probe produced; falling
                // back to the trash's own name restores *something* rather than dropping the item.
                name: names[filename] ?? filename
            )
        }
    }

    /// The volume a trash directory belongs to — the root its records are relative to.
    ///
    /// `<volume>/.Trashes/<uid>` names its volume outright. Anything else is a home trash
    /// (`~/.Trash`), whose records are relative to the volume the home folder lives on: the boot
    /// volume on any ordinary Mac, which is `/`.
    public static func volumeRoot(ofTrashAt trash: VFSPath) -> VFSPath {
        let components = trash.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(of: Substring(TrashLocations.volumeContainer)) else {
            return VFSPath.local("/")
        }
        return VFSPath.local("/" + components[..<index].joined(separator: "/"))
    }

    /// Turn one recorded folder into a real path on `volume`, absorbing both forms the system
    /// writes: an optional leading slash, and the boot volume's data firmlink.
    public static func directory(recordedAs recorded: String, onVolumeAt volume: VFSPath) -> VFSPath {
        var relative = Substring(recorded)
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.hasPrefix(dataFirmlink) { relative.removeFirst(dataFirmlink.count) }
        return relative
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(volume) { $0.appending(String($1)) }
    }
}
