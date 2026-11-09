import CryptoKit
import Foundation

/// The two folders a sync's record belongs to (PLAN.md §M37 Slice 7).
///
/// The initializer is the one definition of which pairs can have a record, and it answers `nil` for
/// the rest:
///
/// - **A side that is not on this Mac's file system.** Every kept version is proved against both
///   sides' bytes, which on a server means downloading every text file on every sync, and a server's
///   listing has no clock good enough to say what changed (decided with Oleg 2026-11-09).
/// - **A side inside a vault.** A record is plain text under Application Support, and a vault's whole
///   promise is that locking it puts its contents out of reach (``VaultPrivacy``).
///
/// The pair has no direction. A record holds nothing that belongs to one side, so swapping the panes
/// finds the same one.
public struct SyncRecordPair: Sendable, Hashable, Codable {
    /// The two folders in one order, each in ``VaultLocation/normalizedPath(_:)``'s one spelling.
    public let first: String
    public let second: String

    public init?(left: VFSPath, right: VFSPath, vaultMountPoints: [String]) {
        guard left.backend == .local, right.backend == .local else { return nil }
        let one = VaultLocation.normalizedPath(left.path)
        let other = VaultLocation.normalizedPath(right.path)
        guard one != other,
              !VaultPrivacy.isInside(one, mountPoints: vaultMountPoints),
              !VaultPrivacy.isInside(other, mountPoints: vaultMountPoints)
        else { return nil }
        first = min(one, other)
        second = max(one, other)
    }

    /// The name of the record's folder: stable across launches, which `Hasher` is not, and free of
    /// anything a path can hold.
    var key: String {
        SHA256.hash(data: Data((first + "\0" + second).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Where one file stands against the version the last sync left on both sides.
///
/// Answered by bytes alone. A modification time says when something wrote the file, and a `touch` or
/// a restore moves it without changing what the file says, so no clock is consulted.
public enum SyncChange: Sendable, Equatable {
    /// No version is kept for this file, so there is nothing to compare with and no merge to offer.
    case noVersion
    /// Both sides still hold the kept bytes.
    case unchanged
    case changedOnLeft
    case changedOnRight
    /// Both sides moved on from the kept version and arrived at the same bytes.
    case changedAlike
    /// Both sides moved on differently: what a merge is for, over `base`.
    case changedOnBoth(base: URL)
    /// A side could not be read, or is a placeholder whose bytes are not on this disk, so nothing
    /// is claimed about it.
    case unreadable
}

/// What is remembered about one folder pair: for each file, the bytes both sides last held.
public struct SyncRecord: Sendable, Equatable {
    /// One kept version.
    public struct Version: Sendable, Equatable, Codable {
        /// The kept file's name in the record's folder. A UUID rather than a string, so a damaged
        /// record cannot name a file anywhere else for an eviction to remove.
        public let file: UUID
        public let byteSize: Int64
        /// The last sync that found both sides holding these bytes.
        public let keptAt: Date

        public init(file: UUID, byteSize: Int64, keptAt: Date) {
            self.file = file
            self.byteSize = byteSize
            self.keptAt = keptAt
        }
    }

    public let pair: SyncRecordPair
    public let directory: URL
    /// By path relative to the two folders.
    public let versions: [String: Version]

    public init(pair: SyncRecordPair, directory: URL, versions: [String: Version]) {
        self.pair = pair
        self.directory = directory
        self.versions = versions
    }

    func url(of version: Version) -> URL {
        directory.appendingPathComponent(version.file.uuidString)
    }

    /// The kept version of the file at `relativePath`, or `nil` when none is, or when what is on
    /// disk is no longer what was kept. A merge is offered only over a base that really was the
    /// file's, so a damaged one counts as none.
    public func keptFile(for relativePath: String) -> URL? {
        guard let version = versions[relativePath] else { return nil }
        let file = url(of: version)
        guard EditedFileRevision.current(ofFileAt: file.path)?.byteSize == version.byteSize else {
            return nil
        }
        return file
    }

    /// Which side of the file at `relativePath` changed since the last sync, given the two sides'
    /// files on this disk. Reads only as far as it has to, and nothing when the sizes differ.
    /// Blocking; call it off the main thread.
    ///
    /// Throws only `CancellationError`. An evicted placeholder is reported rather than read:
    /// looking over a tree is not a reason to download it (docs/NOTES.md ▸ Google Drive).
    public func change(
        of relativePath: String,
        left: URL,
        right: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> SyncChange {
        guard let kept = keptFile(for: relativePath) else { return .noVersion }
        func same(_ one: URL, _ other: URL) throws -> Bool {
            try ByteComparator.localFilesEqual(
                .local(one.path),
                .local(other.path),
                isCancelled: isCancelled
            )
        }
        do {
            switch try (same(left, kept), same(right, kept)) {
            case (true, true): return .unchanged
            case (false, true): return .changedOnLeft
            case (true, false): return .changedOnRight
            case (false, false):
                return try same(left, right) ? .changedAlike : .changedOnBoth(base: kept)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
    }
}
