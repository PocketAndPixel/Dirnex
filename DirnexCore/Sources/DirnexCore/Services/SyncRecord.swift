import CryptoKit
import Foundation

/// The two folders a sync's record belongs to (PLAN.md §M37 Slice 7, §M38 Slice 8).
///
/// The initializer is the one definition of which pairs can have a record, and it answers `nil` for
/// the rest:
///
/// - **Two servers, or a side that is not a folder a file can land in.** A version is the local
///   side's bytes, so a pair needs one, and a merge saves into both sides, so the other has to take
///   an upload (``VFSBackendID/acceptsUploads``): SFTP, FTP, S3 and WebDAV, not the Photos library,
///   an archive or a virtual listing.
/// - **A server side, unless the caller allows one.** Such a pair is kept from what its sync copied
///   rather than from a walk (``SyncRecordStore/keep(after:for:using:vaultMountPoints:date:isCancelled:)``),
///   and its stamps are read rather than its bytes, so a caller says it knows that.
/// - **A side inside a vault.** A record is plain text under Application Support, and a vault's whole
///   promise is that locking it puts its contents out of reach (``VaultPrivacy``).
///
/// The pair has no direction. A record holds nothing that belongs to one side, so swapping the panes
/// finds the same one.
public struct SyncRecordPair: Sendable, Hashable, Codable {
    /// The two folders in one order, each in ``VaultLocation/normalizedPath(_:)``'s one spelling. For
    /// a pair with a server side, `first` is the local folder and `second` is the server's
    /// (``serverFolder``).
    ///
    /// **A server side is spelled into `second`**, as its account's id and its path joined by a NUL
    /// that neither can hold, rather than given a field of its own. A build that predates server pairs
    /// then decodes the record and finds its folder named for it, as ``key`` is the same hash of the
    /// same two strings. A field of its own would decode to a pair whose key names another folder, and
    /// that build's launch purge removes such a folder (``SyncRecordStore/purge()``). The release in
    /// `/Applications` shares Application Support with a Debug build.
    public let first: String
    public let second: String

    public init?(
        left: VFSPath,
        right: VFSPath,
        vaultMountPoints: [String],
        allowingServerSide: Bool = false
    ) {
        switch (left.backend == .local, right.backend == .local) {
        case (true, true):
            let one = VaultLocation.normalizedPath(left.path)
            let other = VaultLocation.normalizedPath(right.path)
            guard one != other,
                  !VaultPrivacy.isInside(one, mountPoints: vaultMountPoints),
                  !VaultPrivacy.isInside(other, mountPoints: vaultMountPoints)
            else { return nil }
            first = min(one, other)
            second = max(one, other)
        case (true, false), (false, true):
            let (local, server) = left.backend == .local ? (left, right) : (right, left)
            let path = VaultLocation.normalizedPath(local.path)
            guard allowingServerSide, server.backend.acceptsUploads,
                  !VaultPrivacy.isInside(path, mountPoints: vaultMountPoints)
            else { return nil }
            first = path
            second = server.backend.rawValue + String(Self.serverSeparator) + server.path
        case (false, false):
            return nil
        }
    }

    /// Between a server side's account and its path in ``second``.
    private static let serverSeparator: Character = "\0"

    /// The server folder of a pair with a server side, or `nil` for two local folders.
    public var serverFolder: VFSPath? {
        guard let separator = second.firstIndex(of: Self.serverSeparator) else { return nil }
        return VFSPath(
            backend: VFSBackendID(String(second[..<separator])),
            path: String(second[second.index(after: separator)...])
        )
    }

    /// The name of the record's folder: stable across launches, which `Hasher` is not, and free of
    /// anything a path can hold. A local path has no NUL, so a server pair's key never names a local
    /// pair's folder.
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

    /// The version a merge would start from, for a file that moved on differently on both sides.
    public var mergeBase: URL? {
        if case let .changedOnBoth(base) = self { return base }
        return nil
    }
}

public extension DirectorySync {
    /// ``defaultAction(for:direction:)``, told what the record knows about the file.
    ///
    /// Both Directions lets the newer file win because it has nothing better to go on, and that
    /// overwrites the older file's edit. A file known to have changed on both sides is a conflict
    /// instead, left for a merge or a choice made by hand. A mirror keeps its copy, since replacing
    /// the other side is what a mirror was asked to do.
    static func defaultAction(
        for status: SyncStatus,
        direction: SyncDirection,
        change: SyncChange?
    ) -> SyncAction {
        if direction == .bidirectional, change?.mergeBase != nil { return .conflict }
        return defaultAction(for: status, direction: direction)
    }
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
        /// For a pair with a server side, the server's file as it was listed once it held these bytes:
        /// its size, date and tag. What a later listing is compared with, since the server's bytes are
        /// never read to say whether it changed (``SyncRecord/change(of:left:right:isCancelled:)``).
        /// `nil` on a local pair, and on a server pair's version rewritten by a build that predates
        /// the field, which then reads as no version.
        public let serverRevision: RemoteFileRevision?

        public init(
            file: UUID,
            byteSize: Int64,
            keptAt: Date,
            serverRevision: RemoteFileRevision? = nil
        ) {
            self.file = file
            self.byteSize = byteSize
            self.keptAt = keptAt
            self.serverRevision = serverRevision
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

    /// What changed in each of `rows` holding a file on both sides that has a kept version, by
    /// relative path. Rows with nothing to compare have no answer. Blocking; call it off the main
    /// thread. Throws only `CancellationError`.
    ///
    /// On a pair with a server side, the server's half is read from the row's stamp and the local
    /// half from its bytes (``change(of:left:right:isCancelled:)``), so nothing is downloaded.
    public func changes(
        of rows: [SyncEntry],
        isCancelled: () -> Bool = { false }
    ) throws -> [String: SyncChange] {
        var answers: [String: SyncChange] = [:]
        for row in rows {
            guard versions[row.relativePath] != nil, let left = row.left, let right = row.right,
                  left.kind == .file, right.kind == .file else { continue }
            guard pair.serverFolder == nil else {
                answers[row.relativePath] = try change(
                    of: row.relativePath,
                    left: left,
                    right: right,
                    isCancelled: isCancelled
                )
                continue
            }
            answers[row.relativePath] = try change(
                of: row.relativePath,
                left: URL(fileURLWithPath: left.path.path),
                right: URL(fileURLWithPath: right.path.path),
                isCancelled: isCancelled
            )
        }
        return answers
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
