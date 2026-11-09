import Foundation

/// How one pass of keeping went.
public struct SyncKeepReport: Sendable, Equatable {
    /// Versions written or confirmed: both sides hold exactly these bytes.
    public internal(set) var kept = 0
    /// Files on both sides that differ, so whatever version was kept stands.
    public internal(set) var notEqual = 0
    /// Files of no use to a merge, or that could not be read: binary, past 64 MiB, a placeholder.
    public internal(set) var notKeepable = 0
    /// Files that did not fit the budget.
    public internal(set) var overBudget = 0

    public init() {}
}

/// Keeping what a sync left equal (PLAN.md §M37 Slice 7).
///
/// Run after the sync, over the two folders as they now stand, so a copy that failed or a row the
/// user unticked simply is not equal, and the version kept before it stands. That version is the last
/// one both sides held, which is what a later merge needs.
///
/// **A version is what both sides were found holding, byte for byte, never what a comparison
/// assumed.** Size and date say two files are probably the same, and a base that was only probably
/// the file's is how a merge loses an edit. The side is cloned first and the clone is what gets
/// compared, so a write to either side during the comparison leaves a clone that does not match and
/// a file that is not kept, rather than a version neither side ever held.
///
/// It costs a read of both sides of every text file, within the budget. This repository with its
/// build products and worktrees (71 945 text files, 1.7 GiB) took 6 s to clone and 14 s to compare.
public extension SyncRecordStore {
    /// Walk the pair's two folders and keep a version of each text file of up to 64 MiB that both
    /// hold. Does nothing for a pair the user has not asked to remember. Blocking; call it off the
    /// main thread.
    ///
    /// Throws what the walk throws, in which case nothing has changed, and what writing the record
    /// throws, which removes this pass's files and leaves the old record standing. A stop keeps what
    /// was finished.
    func keep(
        for pair: SyncRecordPair,
        using backend: some VFSBackend,
        vaultMountPoints: [String] = [],
        date: Date = Date(),
        isCancelled: () -> Bool = { false }
    ) throws -> SyncKeepReport {
        guard let before = record(for: pair) else { return SyncKeepReport() }
        let rows = try DirectorySync.survey(
            left: .local(pair.first),
            right: .local(pair.second),
            leftBackend: backend,
            rightBackend: backend,
            isCancelled: isCancelled
        )
        var report = SyncKeepReport()
        let candidates = Self.candidates(
            in: rows,
            vaultMountPoints: vaultMountPoints,
            report: &report
        )
        let admitted = zip(candidates, budget.admitted(candidates.map(\.byteSize))).compactMap { $1 ? $0 : nil }
        report.overBudget = candidates.count - admitted.count
        try makeRoom(for: admitted, in: before)

        // Read again: making room may have taken some of this pair's own.
        guard let record = record(for: pair) else { return report }
        var pass = Pass(record: record, date: date)
        for candidate in admitted where !isCancelled() {
            pass.keep(candidate, report: &report, isCancelled: isCancelled)
        }
        pass.forgetVanished(given: rows)
        do {
            try write(Manifest(pair: pair, versions: pass.versions), to: directory(of: pair))
        } catch {
            pass.removeWritten()
            throw error
        }
        pass.removeReplaced()
        return report
    }
}

extension SyncRecordStore {
    /// A file both sides hold, worth trying to keep.
    struct Candidate {
        let relativePath: String
        let left: URL
        let right: URL
        let byteSize: Int64
    }

    /// The rows worth keeping, by what can be told without reading them whole.
    ///
    /// Anything but a file on both sides is no concern of a merge and is not counted.
    private static func candidates(
        in rows: [SyncEntry],
        vaultMountPoints: [String],
        report: inout SyncKeepReport
    ) -> [Candidate] {
        rows.compactMap { row in
            guard let left = row.left, let right = row.right, left.kind == .file, right.kind == .file else {
                return nil
            }
            guard left.byteSize == right.byteSize else {
                report.notEqual += 1
                return nil
            }
            guard isKeepable(left.path, right.path, vaultMountPoints: vaultMountPoints) else {
                report.notKeepable += 1
                return nil
            }
            return Candidate(
                relativePath: row.relativePath,
                left: URL(fileURLWithPath: left.path.path),
                right: URL(fileURLWithPath: right.path.path),
                byteSize: left.byteSize
            )
        }
    }

    /// Whether a same-sized pair could be a kept version.
    ///
    /// The placeholder is asked about first, since sniffing the file for text is a read and a read
    /// of an evicted file downloads it. One side's text is enough: a version is kept only if the two
    /// are then found equal.
    private static func isKeepable(_ left: VFSPath, _ right: VFSPath, vaultMountPoints: [String]) -> Bool {
        guard !VaultPrivacy.isInside(left, mountPoints: vaultMountPoints),
              !VaultPrivacy.isInside(right, mountPoints: vaultMountPoints),
              let leftSubject = try? ByteComparator.subject(left),
              let rightSubject = try? ByteComparator.subject(right),
              mayRead(leftSubject, rightSubject)
        else { return false }
        return (try? ComparedText.precheck(
            contentsOf: URL(fileURLWithPath: left.path),
            byteLimit: ByteComparator.prescanByteLimit
        )) != nil
    }

    /// Whether both sides are regular files whose bytes are on this disk.
    static func mayRead(_ left: ComparisonSubject, _ right: ComparisonSubject) -> Bool {
        left.isRegularFile && right.isRegularFile && !left.isDataless && !right.isDataless
    }

    /// Drop the oldest versions, across every record, until this pass's fit.
    ///
    /// The versions this pass replaces are not counted, since they go when it ends. If one of those
    /// files then turns out not to be equal, its old version stays and the store runs over by that
    /// much until the next pass.
    private func makeRoom(for admitted: [Candidate], in record: SyncRecord) throws {
        let replacing = Set(admitted.compactMap { record.versions[$0.relativePath]?.file })
        let held = allManifests()
            .flatMap(\.manifest.versions.values)
            .filter { !replacing.contains($0.file) }
            .map { SyncRecordBudget.Held(file: $0.file, byteSize: $0.byteSize, keptAt: $0.keptAt) }
        let evicted = Set(
            budget.evictions(held: held, incoming: admitted.reduce(0) { $0 + $1.byteSize })
        )
        guard !evicted.isEmpty else { return }
        for (directory, manifest) in allManifests() {
            let staying = manifest.versions.filter { !evicted.contains($0.value.file) }
            guard staying.count != manifest.versions.count else { continue }
            try write(Manifest(pair: manifest.pair, versions: staying), to: directory)
            for version in manifest.versions.values where evicted.contains(version.file) {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(version.file.uuidString)
                )
            }
        }
    }

    /// One pass over one record: what it will say, and which files come and go with it.
    private struct Pass {
        let record: SyncRecord
        let date: Date
        var versions: [String: SyncRecord.Version]
        private var written: [URL] = []
        private var replaced: [URL] = []

        init(record: SyncRecord, date: Date) {
            self.record = record
            self.date = date
            versions = record.versions
        }

        mutating func keep(
            _ candidate: Candidate,
            report: inout SyncKeepReport,
            isCancelled: () -> Bool
        ) {
            func same(_ one: URL, _ other: URL) throws -> Bool {
                try ByteComparator.localFilesEqual(
                    .local(one.path),
                    .local(other.path),
                    isCancelled: isCancelled
                )
            }
            do {
                let old = record.versions[candidate.relativePath]
                // A version already kept that still holds both sides' bytes saves a copy on every
                // sync where the store is on another volume from the files.
                if let old, let kept = record.keptFile(for: candidate.relativePath),
                   try same(kept, candidate.left), try same(kept, candidate.right) {
                    versions[candidate.relativePath] = .init(
                        file: old.file,
                        byteSize: old.byteSize,
                        keptAt: date
                    )
                    report.kept += 1
                    return
                }
                guard let version = try clone(candidate, comparingWith: same) else {
                    report.notEqual += 1
                    return
                }
                versions[candidate.relativePath] = version
                if let old { replaced.append(record.url(of: old)) }
                report.kept += 1
            } catch {
                if !(error is CancellationError) { report.notKeepable += 1 }
            }
        }

        /// Clone the left side and compare the clone with the right, answering `nil` when they
        /// differ. A failure removes the clone before it is thrown.
        private mutating func clone(
            _ candidate: Candidate,
            comparingWith same: (URL, URL) throws -> Bool
        ) throws -> SyncRecord.Version? {
            let name = UUID()
            let file = record.directory.appendingPathComponent(name.uuidString)
            guard ArchiveUndoStore.duplicate(from: candidate.left.path, to: file.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // A clone keeps a locked file's flag, and then neither eviction nor Forget can remove
            // it. It keeps the mode too, which may not let it be read again.
            lchflags(file.path, 0)
            chmod(file.path, 0o600)
            do {
                guard try same(file, candidate.right),
                      let landed = EditedFileRevision.current(ofFileAt: file.path)
                else {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
                written.append(file)
                return .init(file: name, byteSize: landed.byteSize, keptAt: date)
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }

        /// Forget the versions of files gone from both sides.
        ///
        /// A folder on only one side is one row for its whole subtree, so a file under such a row
        /// is still there, and its version stays.
        mutating func forgetVanished(given rows: [SyncEntry]) {
            let named = Set(rows.map(\.relativePath))
            for (path, version) in versions where !Self.isNamed(path, in: named) {
                versions[path] = nil
                replaced.append(record.url(of: version))
            }
        }

        private static func isNamed(_ path: String, in named: Set<String>) -> Bool {
            var rest = Substring(path)
            while !named.contains(String(rest)) {
                guard let slash = rest.lastIndex(of: "/") else { return false }
                rest = rest[..<slash]
            }
            return true
        }

        func removeWritten() {
            for file in written { try? FileManager.default.removeItem(at: file) }
        }

        func removeReplaced() {
            for file in replaced { try? FileManager.default.removeItem(at: file) }
        }
    }
}
