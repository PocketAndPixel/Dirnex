import Foundation

/// Where a trashed item came from: the folder it was deleted out of, and the name it had there.
///
/// The name is carried separately because the two can disagree. A trash that already holds a
/// `alpha.txt` renames the newcomer — probed: it landed as `alpha.txt 13-12-35-977.txt` — while the
/// put-back record still says `alpha.txt`. Restoring under the trash's name would quietly rename
/// the user's file.
///
/// `Codable` because ``TrashOriginRecords`` persists it: the records Dirnex writes for its own
/// deletes have to survive relaunch, since Put Back is the gesture for an item sitting in the Trash
/// a week later.
public struct TrashOrigin: Sendable, Equatable, Codable {
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

    /// The per-directory sidecar the pair lives in. One spelling, because both a reader and a
    /// writer now name it.
    public static let storeName = ".DS_Store"

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

    /// Write the `ptbL`/`ptbN` pair for an item that has just landed in `trash`, into the records
    /// that trash's `.DS_Store` already holds (PLAN.md §M26 Slice 5).
    ///
    /// Needed because `FileManager.trashItem` writes the pair itself and cannot be used on an item
    /// inside a File Provider domain, so ``ProviderAwareTrashPerformer`` performs that move with a
    /// rename — and a rename records nothing. Without this, a Dropbox file deleted in Dirnex offers
    /// no **Put Back** in Finder while the same file deleted in Finder does (reported 2026-08-31).
    ///
    /// `name` is the name the item has *in the trash*, which a collision may have stamped; the
    /// origin's own name is what `ptbN` carries, and the difference is the whole reason there are
    /// two records rather than one.
    ///
    /// - Returns: the merged records, or `nil` when the origin cannot be expressed relative to the
    ///   trash's own volume — a record Finder could not read, and one no reader here would either.
    public static func recording(
        _ origin: TrashOrigin,
        forItemNamed name: String,
        inTrashAt trash: VFSPath,
        into entries: [DSStoreEntry]
    ) -> [DSStoreEntry]? {
        guard let location = location(of: origin.directory, forTrashAt: trash) else { return nil }
        // Replace rather than append: a name reused after an earlier item left the Trash would
        // otherwise carry two locations, and which one a reader takes is undefined.
        var merged = entries.filter { !(
            $0.filename == name && ($0.key == locationKey || $0.key == nameKey)
        ) }
        merged.append(.string(filename: name, key: locationKey, value: location))
        merged.append(.string(filename: name, key: nameKey, value: origin.name))
        return merged
    }

    /// The string a `ptbL` record carries for `directory` — the inverse of
    /// ``directory(recordedAs:onVolumeAt:)``, and written in the same shape the system does.
    ///
    /// Relative to the trash's own volume, with a trailing slash, and with a **leading** slash only
    /// for a volume trash (`<volume>/.Trashes/<uid>`), which is the form probed on a real one. A
    /// home or File Provider trash records against `/` and writes no leading slash — the form
    /// `FileManager.trashItem` leaves in `~/.Trash`, and the one Finder read back correctly when it
    /// was written here by hand (probed 2026-08-31, in `~/.Trash` and in Google Drive's
    /// `<mount>/.Trash`).
    ///
    /// The volume's own root is a bare `/` in both forms.
    ///
    /// - Returns: `nil` for a directory that is not on the trash's volume at all, which cannot be
    ///   recorded and must not be guessed at.
    public static func location(of directory: VFSPath, forTrashAt trash: VFSPath) -> String? {
        guard directory.backend == .local, trash.backend == .local else { return nil }
        let volume = volumeRoot(ofTrashAt: trash)
        let volumeComponents = components(of: volume)
        let directoryComponents = components(of: directory)
        guard directoryComponents.count >= volumeComponents.count,
              Array(directoryComponents.prefix(volumeComponents.count)) == volumeComponents
        else {
            return nil
        }
        let relative = directoryComponents.dropFirst(volumeComponents.count).joined(separator: "/")
        // The volume's own root is recorded as a bare "/" — not as the empty relative path with a
        // slash on each side. Caught by comparing this against the strings macOS wrote in the
        // fixture, which is the only reason it is right.
        guard !relative.isEmpty else { return "/" }
        return (volumeComponents.isEmpty ? "" : "/") + relative + "/"
    }

    private static func components(of path: VFSPath) -> [String] {
        path.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
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
