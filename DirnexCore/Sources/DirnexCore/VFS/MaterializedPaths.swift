import Foundation

/// Which file on this disk stands for each row of a set that was not all on it (PLAN.md §M24
/// Slice 4).
///
/// M24's one structural rule is that the **gesture** materializes and the engine never does, which
/// leaves exactly one thing to carry across that boundary: the map from the row somebody marked to
/// the copy that arrived. `MaterializeRunner` produces those as ``MaterializedFile`` values and this
/// is the shape an engine reads them back in — so a checksum manifest can name `report.pdf` while
/// the bytes it hashed came out of a temp directory, and neither half has to know about the other.
///
/// Keyed by the **source** path rather than by name, because a set can hold two objects called
/// `report.pdf` from two different prefixes — the same fact that makes `MaterializeRunner` give each
/// copy its own directory.
///
/// **A local path stands for itself, and that includes a cloud placeholder.** A dataless file's
/// bytes land at the path it already names, so there is no copy anywhere for this to be holding and
/// asking would invite a wrong answer — the gesture asks the file provider and the same path is the
/// answer before and after. That is what lets an ordinary local run reach the identical code with
/// an empty map and no branch anybody has to remember.
///
/// **A row with no stand-in answers `nil`, and `nil` is an ordinary outcome rather than an error.**
/// It is a transfer that failed, or a row nothing was ever asked to fetch, and the checksum report
/// already has the row for exactly that: ``ChecksumEntryStatus/notDownloaded``, which is what an
/// evicted placeholder produces too. Modelling it as a throw is what would let a caller `try?` a
/// file out of a manifest that then verifies clean while covering less than it claims — the same
/// false comfort ``ChecksumEntryStatus/extra`` exists to prevent, one step earlier.
public struct MaterializedPaths: Sendable, Equatable {
    /// Where each non-local source's bytes are, as an absolute local path.
    private let localPaths: [VFSPath: String]

    /// Nothing was materialized: every row stands for itself. The ordinary local run, and the
    /// default every existing caller keeps.
    public init() {
        localPaths = [:]
    }

    /// An explicit map — for a caller assembling one from somewhere other than a job's report.
    ///
    /// The app is that caller and has to be: a row the plan classified as already `cached` is never
    /// asked for, so it produces no ``MaterializedFile`` and yet is exactly as readable as the ones
    /// that were. A map built only from the report would report those as not downloaded.
    public init(_ localPaths: [VFSPath: String]) {
        self.localPaths = localPaths
    }

    /// The copies a `.materialize` job brought down.
    ///
    /// A repeated source keeps the **last** copy: a second fetch of the same row supersedes the
    /// first, and the first is the one whose directory may already have been swept away.
    public init(_ files: [MaterializedFile]) {
        self.init(Dictionary(files.map { ($0.source, $0.localPath) }) { _, latest in latest })
    }

    /// Nothing has been substituted, so every row is expected to stand for itself.
    public var isEmpty: Bool { localPaths.isEmpty }

    /// This map plus `other`'s, with `other` winning any collision.
    ///
    /// Written for the two-phase gesture verification is: the manifest comes down first, because
    /// nothing can know what else to fetch until it has been read, and the files it names come down
    /// after. One map reaches the engine, and it holds both.
    public func merging(_ other: MaterializedPaths) -> MaterializedPaths {
        MaterializedPaths(localPaths.merging(other.localPaths) { _, latest in latest })
    }

    /// The file to read in place of `path`, or `nil` when its bytes are not on this disk.
    public func localPath(for path: VFSPath) -> VFSPath? {
        if path.backend == .local { return path }
        guard let local = localPaths[path] else { return nil }
        return .local(local)
    }
}
