import Foundation

/// One file a checksum run looks at, with the relative name a manifest spells it by.
///
/// The two halves are deliberately independent, and M24 Slice 4 is what makes that visible: the
/// **name** is a fact about where the file sits relative to the manifest — on a server, that is the
/// server's own spelling and must survive into the written file — while the **entry** is only ever
/// used to find bytes, which for a remote row live in a temp directory nobody should ever be told
/// about. Collapsing them would put `A1B2-C3D4/report.pdf` in a manifest sitting beside a bucket's
/// objects.
public struct ChecksumWalkedFile: Sendable, Equatable {
    /// The manifest-relative, `/`-separated name — the spelling every checksum format uses.
    public let name: String
    /// The row whose bytes are hashed, on whatever backend it lives.
    public let entry: FileEntry

    public init(name: String, entry: FileEntry) {
        self.name = name
        self.entry = entry
    }
}

/// What a verification is going to look at, worked out before a single byte is read (PLAN.md §M14
/// Slice 2, made shareable at §M24 Slice 4).
///
/// This used to be private to `ChecksumVerifyRun`, and it could be while the answer was only ever
/// needed by the loop about to run. Verifying a manifest that is **not on this disk** is two-phase —
/// nothing can know what else to fetch until the manifest itself has been read — so the gesture has
/// to work out the same set the run will hash, in order to weigh it and confirm it. Two spellings of
/// "which files does this manifest claim" is precisely the drift this project keeps paying for
/// (docs/NOTES.md ▸ Design lessons), and here it would fail in the quiet direction: every file the
/// gesture failed to predict comes back as ``ChecksumEntryStatus/notDownloaded`` for a file sitting
/// right in front of the user.
///
/// So the walk is one function, called twice — once to plan and once to run — and it takes its
/// listing as a closure, which is what keeps it free of I/O policy and testable against literals.
public struct ChecksumVerifyScope: Sendable {
    /// The manifest as parsed, including the algorithm it named itself.
    public let manifest: ChecksumManifest
    /// The names the verdict compares against — everything the walk found that is worth reporting,
    /// including the siblings that make an ``ChecksumEntryStatus/extra`` verdict mean something.
    public let listing: [String]
    /// The files that will actually be hashed: those the manifest claims *and* the walk found.
    ///
    /// This is the set a remote verification has to bring down, and the reason this type is public.
    public let claimed: [ChecksumWalkedFile]

    public init(manifest: ChecksumManifest, listing: [String], claimed: [ChecksumWalkedFile]) {
        self.manifest = manifest
        self.listing = listing
        self.claimed = claimed
    }

    /// Parse `contents` as the manifest at `path` and walk the directory it sits in.
    ///
    /// `list` is the one seam that touches the world, and it answers with **whatever backend the
    /// manifest is on** — a verification of a manifest in a bucket walks the bucket. That costs
    /// listings and no transfers, which is what makes the two-phase gesture affordable: the
    /// expensive half is the files, and by the time anything is fetched the set is known exactly.
    ///
    /// Throws ``ChecksumError`` when the manifest cannot be read as one — the job's own failure,
    /// distinct from any path's, and the reason a gesture can report it without queueing anything.
    public static func resolve(
        manifestAt path: VFSPath,
        contents: Data,
        list: (VFSPath) -> [FileEntry],
        isCancelled: () -> Bool = { false }
    ) throws -> ChecksumVerifyScope {
        let manifestName = path.lastComponent
        let parsed = try ChecksumManifest.parse(
            contents,
            implicitName: ChecksumManifest.impliedName(forManifestFileName: manifestName)
        )
        let names = Set(parsed.entries.map(\.name))
        let root = path.parent ?? path
        let walked = walk(root: root, manifestNames: names, list: list, isCancelled: isCancelled)
        let listing = ChecksumScope.comparableListing(
            walked: walked.map { ($0.name, $0.entry.isHidden) },
            manifestName: manifestName,
            manifestNames: names
        )
        let comparable = Set(listing)
        return ChecksumVerifyScope(
            manifest: parsed,
            listing: listing,
            // Only files the manifest actually claims are hashed. The rest of the listing exists to
            // answer "extra", which costs a `stat` the walk already did and not one byte of reading.
            claimed: walked.filter { names.contains($0.name) && comparable.contains($0.name) }
        )
    }

    /// Every regular file the manifest could be talking about, plus the siblings that make an
    /// `extra` verdict meaningful — pruned by `ChecksumScope` so a subtree the manifest never
    /// mentions is not walked at all.
    ///
    /// Sorted by name so a re-run's report diffs cleanly against the previous one; the walk's own
    /// order is directory-entry order, which is not stable across filesystems.
    private static func walk(
        root: VFSPath,
        manifestNames: Set<String>,
        list: (VFSPath) -> [FileEntry],
        isCancelled: () -> Bool
    ) -> [ChecksumWalkedFile] {
        var found: [ChecksumWalkedFile] = []
        var stack: [VFSPath] = [root]
        while let directory = stack.popLast() {
            if isCancelled() { return found }
            for entry in list(directory) {
                guard let name = ChecksumScope.relativeName(of: entry.path, under: root) else {
                    continue
                }
                if ChecksumScope.shouldDescend(into: entry) {
                    if ChecksumScope.shouldDescend(
                        intoSubdirectory: name,
                        manifestNames: manifestNames
                    ) {
                        stack.append(entry.path)
                    }
                    continue
                }
                guard ChecksumScope.isHashable(entry) else { continue }
                found.append(ChecksumWalkedFile(name: name, entry: entry))
            }
        }
        return found.sorted { $0.name < $1.name }
    }
}
