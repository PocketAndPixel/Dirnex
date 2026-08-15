import Foundation

/// The rows a **delimiter-less** `ListObjectsV2` enumeration stands for — everything a walk of the
/// same subtree would have produced, assembled from keys alone (PLAN.md §M22).
///
/// This is the pure half of S3's search shortcut. `ListObjectsV2` with no delimiter returns every
/// key at every depth, so a whole subtree costs one request per 1000 keys where a walk pays one per
/// directory — but what comes back is a flat list of keys, and what a caller renders is a file
/// tree. Turning one into the other is all string work, so it lives here with no transport in sight
/// and is tested against the bytes real buckets sent.
///
/// **Folders have to be synthesized, and that is the whole reason this type exists rather than a
/// `map`.** With no delimiter the server groups nothing into `CommonPrefixes` — the measured fact
/// `S3Backend`'s recursive delete already rests on — so the pages carry `docs/`, `docs/a.txt` and
/// `docs/sub/b.txt` and no folder rows whatsoever. Rendering only the objects would mean a search
/// for `docs` finds nothing called `docs`, and a Kind filter of *Folders* returns an empty result
/// over a bucket full of them: a wrong answer in the quiet direction, since an empty result reads as
/// "there is none" rather than as "this route cannot see them". So every component on the way down
/// to a key names a folder, emitted **once**, exactly as a walk listing each directory in turn would
/// have emitted it.
///
/// **The rows come out shallowest-first**, which matters at exactly the moment the caller's limit
/// bites. S3 returns keys in lexicographic order, so a truncation of the raw order keeps whatever
/// happens to sort early — a deep branch under `a/` ahead of everything under `z/` — where
/// ``SubtreeSearch``'s walk is breadth-first on the stated ground that a person's file is usually
/// near the top. Ordering by depth here is what makes the two routes answer the same way when there
/// are more matches than can be shown, rather than differing on a property of the *store* that
/// nobody chose.
public struct S3SubtreeListing {
    /// The folder being searched — the entries' paths are built under it.
    private let root: VFSPath
    /// `root`'s key plus the delimiter, or the empty string at the bucket root. Every key the pages
    /// carry begins with it, and what is left is the row's position in the tree.
    private let prefix: String
    /// Rows keyed by depth below `root`, in arrival order within each depth.
    private var rows: [Int: [FileEntry]] = [:]
    /// The folders already emitted, as their paths relative to `root` — the dedupe that keeps a
    /// thousand keys under `docs/sub/` from drawing a thousand `sub` rows.
    private var folders: Set<String> = []

    public init(root: VFSPath) {
        self.root = root
        prefix = S3Key.listingPrefix(for: root)
    }

    /// Fold one page of a delimiter-less enumeration in.
    ///
    /// Only `<Contents>` is read. A page asked for with no delimiter carries no `<CommonPrefixes>`,
    /// and reading it if it did would put this reader at odds with `S3Backend`'s recursive delete,
    /// which enumerates the same way and takes its keys from the same element.
    public mutating func add(_ page: S3ListingPage) {
        let decode = S3ListingParser.decoder(for: page)

        for object in page.objects {
            // A key that is not under the prefix is a server ignoring `prefix=` — skipped rather
            // than rendered, since drawing it would put rows from *outside* the searched folder in
            // its results under paths that look like they belong there.
            guard let key = decode(object.key), key.hasPrefix(prefix) else { continue }
            let components = relativeComponents(of: key)
            // Empty means the key *is* the prefix: the root's own directory marker, which is the
            // folder being searched. `SubtreeSearch` never tests the root against the query, and
            // this is the one row that could smuggle it in.
            guard let name = components.last else { continue }

            // A key ending in `/` is a directory marker — the only trace an **empty** folder leaves
            // — so its last component names a folder rather than a file. Everything before the last
            // component names a folder either way.
            let isMarker = key.hasSuffix("/")
            addFolders(components, depth: isMarker ? components.count : components.count - 1)
            guard !isMarker else { continue }

            append(
                S3ListingParser.entry(
                    at: path(of: components),
                    name: name,
                    kind: .file,
                    size: object.size,
                    date: object.lastModified,
                    entityTag: object.entityTag
                ),
                depth: components.count
            )
        }
    }

    /// Every row, shallowest depth first and in arrival order within a depth — see the type's own
    /// note for why the depth ordering is load-bearing rather than tidiness.
    public var entries: [FileEntry] {
        rows.keys.sorted().flatMap { rows[$0] ?? [] }
    }

    /// Emit the folder rows for the first `depth` components of a key, skipping any already seen.
    private mutating func addFolders(_ components: [String], depth: Int) {
        guard depth > 0 else { return }
        for level in 1...depth {
            let relative = components[0..<level].joined(separator: "/")
            guard folders.insert(relative).inserted else { continue }
            append(
                S3ListingParser.entry(
                    at: path(of: Array(components[0..<level])),
                    name: components[level - 1],
                    kind: .directory,
                    size: 0,
                    // A common prefix is not an object and has no `LastModified` of any kind, which
                    // reaches a query as `FileEntry.unknownDate` — the value a date filter refuses
                    // rather than matching vacuously (``SearchPredicate``).
                    date: nil
                ),
                depth: level
            )
        }
    }

    private mutating func append(_ entry: FileEntry, depth: Int) {
        rows[depth, default: []].append(entry)
    }

    /// `key`'s position below `root`, as path components. Empty for the root itself.
    ///
    /// Empty components are dropped, which is `VFSPath`'s own normalization rather than a choice:
    /// S3 permits a key like `docs//a.txt`, and the path built from it could not address the two
    /// slashes anyway.
    private func relativeComponents(of key: String) -> [String] {
        key.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func path(of components: [String]) -> VFSPath {
        VFSPath(backend: root.backend, path: "/\(prefix)\(components.joined(separator: "/"))")
    }
}
