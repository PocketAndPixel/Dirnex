import Foundation

/// One row of a sync and what the sync was told to do with it: what keeping reads to know which
/// files the sync copied (PLAN.md §M38 Slice 8).
public struct SyncDecision: Sendable, Equatable {
    /// The row as the comparison listed it, just before the sync ran.
    public let entry: SyncEntry
    public let action: SyncAction

    public init(entry: SyncEntry, action: SyncAction) {
        self.entry = entry
        self.action = action
    }
}

/// Keeping on a pair with a server side (PLAN.md §M38 Slice 8).
///
/// A local pair's versions are proved against both sides' bytes, and a server's bytes would have to
/// be downloaded for that, every text file on every sync. So a server pair keeps **only what its
/// sync copied**, where the bytes just crossed and both ends are known without reading either again:
/// the version is a clone of the local file, and the server's row, as a listing gives it once the
/// copy has landed, goes beside it as the stamp a later listing is compared with. A file both sides
/// already held is not kept, and a pair whose sync copied nothing has nothing to merge over.
///
/// **What proves a copy landed is the two rows, before and after.** The source still reads as the
/// comparison listed it, so what crossed is what was listed. The destination has moved from what it
/// held, so the copy wrote it. And the two sides are one size. A copy that failed leaves the
/// destination as it was, since the queue swaps a finished copy into place. A file inside a folder
/// the sync copied whole had no row of its own before, so for it the sizes are the whole proof.
///
/// **The server's stamps come from the walk the comparison takes**, through ``DirectorySync``'s own
/// survey, so a stamp is kept by the route a later look reads it by. SFTP's listing and its exec
/// channel's `find` print dates their own ways, and a stamp kept from one and read from the other
/// would read as a change on every file. That walk is one comparison's worth of listing, and one
/// request where the server has a subtree shortcut (``VFSBackend/subtreeListing(at:isCancelled:)``).
/// A sync that copied nothing walks nothing.
public extension SyncRecordStore {
    /// Keep what the sync described by `decisions` copied, once its copies and deletes have finished.
    /// A local pair is walked as ``keep(for:using:vaultMountPoints:date:isCancelled:)`` walks it,
    /// so a caller has one call for either. Does nothing for a pair the user has not asked to
    /// remember. Blocking; call it off the main thread.
    ///
    /// Throws what the walk throws, in which case nothing has changed, and what writing the record
    /// throws, which removes this pass's files and leaves the old record standing. A stop keeps what
    /// was finished.
    func keep(
        after decisions: [SyncDecision],
        for pair: SyncRecordPair,
        using backend: some VFSBackend,
        vaultMountPoints: [String] = [],
        date: Date = Date(),
        isCancelled: () -> Bool = { false }
    ) throws -> SyncKeepReport {
        guard let server = pair.serverFolder else {
            return try keep(
                for: pair,
                using: backend,
                vaultMountPoints: vaultMountPoints,
                date: date,
                isCancelled: isCancelled
            )
        }
        guard let before = record(for: pair) else { return SyncKeepReport() }
        let copies = ServerCopy.copies(in: decisions)
        guard !copies.isEmpty else { return SyncKeepReport() }
        let rows = try DirectorySync.survey(
            left: .local(pair.first),
            right: server,
            leftBackend: backend,
            rightBackend: backend,
            isCancelled: isCancelled
        )
        var report = SyncKeepReport()
        let candidates = Self.candidates(
            in: rows,
            copies: copies,
            vaultMountPoints: vaultMountPoints,
            report: &report
        )
        try run(
            candidates,
            from: before,
            rows: rows,
            date: date,
            report: &report,
            isCancelled: isCancelled
        )
        return report
    }

    /// Keep a version of the one file at `relativePath`, which a merge has just saved into `local`
    /// and uploaded to the server, where a listing or a `stat` now gives `server`. No other file is
    /// looked at and no server byte is read. Blocking; call it off the main thread.
    ///
    /// Does nothing for a pair the user has not asked to remember, or one with no server side, and
    /// throws what writing the record throws.
    func keep(
        relativePath: String,
        local: URL,
        server: FileEntry,
        for pair: SyncRecordPair,
        vaultMountPoints: [String] = [],
        date: Date = Date()
    ) throws -> SyncKeepReport {
        guard pair.serverFolder != nil, let before = record(for: pair) else { return SyncKeepReport() }
        var report = SyncKeepReport()
        guard server.kind == .file,
              let revision = EditedFileRevision.current(ofFileAt: local.path),
              revision.byteSize == server.byteSize
        else {
            report.notEqual = 1
            return report
        }
        guard Self.isKeepable(local: .local(local.path), vaultMountPoints: vaultMountPoints) else {
            report.notKeepable = 1
            return report
        }
        let candidate = Candidate(
            relativePath: relativePath,
            file: local,
            proof: .server(RemoteFileRevision(server), local: revision),
            byteSize: revision.byteSize
        )
        try run(
            [candidate],
            from: before,
            rows: nil,
            date: date,
            report: &report,
            isCancelled: { false }
        )
        return report
    }
}

extension SyncRecordStore {
    /// The files worth keeping among `rows`, a walk of the pair after its sync with the local side on
    /// the left: those the sync copied, whose copy is shown to have landed.
    ///
    /// A row the sync did not copy is not counted, since nothing was asked of it.
    fileprivate static func candidates(
        in rows: [SyncEntry],
        copies: [String: ServerCopy],
        vaultMountPoints: [String],
        report: inout SyncKeepReport
    ) -> [Candidate] {
        rows.compactMap { row in
            guard let copy = ServerCopy.covering(row.relativePath, in: copies) else { return nil }
            guard let local = row.left, let server = row.right,
                  local.kind == .file, server.kind == .file,
                  local.byteSize == server.byteSize,
                  copy.isWholeFolder || copy.landed(local: local, server: server)
            else {
                if (row.left ?? row.right)?.kind == .file { report.notEqual += 1 }
                return nil
            }
            guard isKeepable(local: local.path, vaultMountPoints: vaultMountPoints) else {
                report.notKeepable += 1
                return nil
            }
            // Read now, for the clone to be checked against: a write since the walk is a file that
            // no longer holds what the server was found holding.
            guard let revision = EditedFileRevision.current(ofFileAt: local.path.path),
                  revision.byteSize == local.byteSize
            else {
                report.notEqual += 1
                return nil
            }
            return Candidate(
                relativePath: row.relativePath,
                file: URL(fileURLWithPath: local.path.path),
                proof: .server(RemoteFileRevision(server), local: revision),
                byteSize: local.byteSize
            )
        }
    }
}

/// One item a sync copied between this disk and the server, as the comparison listed it before.
struct ServerCopy {
    /// Whether the bytes went up to the server rather than down from it.
    let toServer: Bool
    /// The two sides before the sync, `nil` where a side had nothing.
    let localBefore: FileEntry?
    let serverBefore: FileEntry?
    /// A folder the sync copied whole: every file under it is one it copied.
    let isWholeFolder: Bool

    /// The copies among `decisions`, by relative path. A link or a special file is no concern of a
    /// merge and is left out.
    static func copies(in decisions: [SyncDecision]) -> [String: ServerCopy] {
        var copies: [String: ServerCopy] = [:]
        for decision in decisions {
            let entry = decision.entry
            let (source, destination): (FileEntry?, FileEntry?)
            switch decision.action {
            case .copyToRight: (source, destination) = (entry.left, entry.right)
            case .copyToLeft: (source, destination) = (entry.right, entry.left)
            case .none, .deleteLeft, .deleteRight, .conflict: continue
            }
            guard let source, source.kind == .file || source.kind == .directory else { continue }
            let toServer = source.path.backend == .local
            copies[entry.relativePath] = ServerCopy(
                toServer: toServer,
                localBefore: toServer ? source : destination,
                serverBefore: toServer ? destination : source,
                isWholeFolder: source.kind == .directory
            )
        }
        return copies
    }

    /// The copy that wrote the file at `relativePath`: its own row's, or a folder's above it that the
    /// sync copied whole.
    static func covering(_ relativePath: String, in copies: [String: ServerCopy]) -> ServerCopy? {
        if let copy = copies[relativePath] { return copy.isWholeFolder ? nil : copy }
        var rest = Substring(relativePath)
        while let slash = rest.lastIndex(of: "/") {
            rest = rest[..<slash]
            if let copy = copies[String(rest)] { return copy.isWholeFolder ? copy : nil }
        }
        return nil
    }

    /// Whether the two sides, as the walk after the sync lists them, show this copy landed: the
    /// source still as it was listed, and the destination moved from what it held.
    func landed(local: FileEntry, server: FileEntry) -> Bool {
        func sameLocal(_ one: FileEntry, _ other: FileEntry) -> Bool {
            one.byteSize == other.byteSize && one.modificationDate == other.modificationDate
        }
        let serverNow = RemoteFileRevision(server)
        if toServer {
            guard let localBefore, sameLocal(localBefore, local) else { return false }
            return serverBefore.map { RemoteFileRevision($0).isSuperseded(by: serverNow) } ?? true
        }
        guard let serverBefore, !RemoteFileRevision(serverBefore).isSuperseded(by: serverNow) else {
            return false
        }
        return localBefore.map { !sameLocal($0, local) } ?? true
    }
}
