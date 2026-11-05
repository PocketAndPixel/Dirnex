import Foundation

/// Renaming several members of a browsed archive in **one** rewrite: ⇧F2's batch (taken 2026-11-05),
/// and F2's single rename as the batch of one.
///
/// A rewrite is extract → edit the staged tree → repack → swap, so what it costs is the container
/// and not how many names changed. The multi-rename tool used to rename each target with the
/// backend's `moveItem`, which an archive refuses, so it was gray inside one. This is the plan that
/// lets the whole batch ride a single pass instead.
///
/// **The order is the plan's job, and deepest-first is the order that always works.** In a tree the
/// marked set can hold a folder and a file inside it. Moving the folder first would leave the file's
/// path pointing at nothing; moving the file first renames it inside the folder, and the folder then
/// carries it along. The order is ``RenameOrder``'s, which the backend loop a local or remote ⇧F2
/// runs shares.
///
/// **A batch that only works in one particular order is refused, not ordered.** A swap (`a` → `b`,
/// `b` → `a`) or a chain (`a` → `b`, `b` → `c`) lands a member on a name another member still holds.
/// The multi-rename planner already reports those as collisions (``MultiRename``), so they never
/// reach here from the tool; refusing them again here keeps the writer safe whoever calls it, rather
/// than safe because one caller happened to check.
extension ArchiveMutation {
    /// One member and the name it is to take in the folder it is already in.
    public struct Rename: Sendable, Equatable {
        /// The member's inner path, `/docs/a.txt`.
        public let innerPath: String
        /// Its new last component, `b.txt`.
        public let newName: String

        public init(innerPath: String, newName: String) {
            self.innerPath = innerPath
            self.newName = newName
        }
    }

    /// One move inside the staged tree, by inner path.
    public struct Move: Sendable, Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// The moves that carry out `renames` in one staged tree, deepest member first, or `nil` when
    /// the batch cannot be carried out as one:
    ///
    /// - a new name no member can have (``renamedInnerPath(ofInnerPath:to:)``),
    /// - the same member named twice,
    /// - two members landing on one name in one folder, or
    /// - a member landing on a name another member of the batch holds now (a swap or a chain).
    ///
    /// Names compare case-insensitively, as on the APFS the tree is staged on, except that a member
    /// may take its *own* name in another case: that is a rename like any other. A name held by a
    /// member **outside** the batch is not checked here; the staged move refuses it
    /// (``stage(_:ofArchiveAt:inWorkingDirectory:)``).
    public static func renameMoves(for renames: [Rename]) -> [Move]? {
        var moves: [Move] = []
        for rename in renames {
            guard let destination = renamedInnerPath(
                ofInnerPath: rename.innerPath, to: rename.newName
            ) else { return nil }
            moves.append(Move(from: rename.innerPath, to: destination))
        }

        let sources = moves.map { $0.from.lowercased() }
        guard Set(sources).count == sources.count else { return nil }
        var destinations: Set<String> = []
        for (index, move) in moves.enumerated() {
            let destination = move.to.lowercased()
            guard destinations.insert(destination).inserted else { return nil }
            let heldByAnother = sources.enumerated().contains { other, source in
                other != index && source == destination
            }
            guard !heldByAnother else { return nil }
        }

        // Deepest first, the order every batch of renames runs in (``RenameOrder``).
        return RenameOrder.deepestFirst(moves, path: \.from)
    }

    /// Carry out `moves` in the staged tree at `workingDirectory`, in the order given.
    ///
    /// **The move is its own collision guard**, as it is for F2 (measured 2026-09-10):
    /// `FileManager.moveItem` refuses an occupied destination and leaves its bytes alone, and still
    /// performs a case-only change on case-insensitive APFS. A refusal throws
    /// ``VFSError/alreadyExists(_:)`` naming the member's path in the archive at `archivePath`, so the
    /// sentence the app renders is about what the user is looking at. Moves before the refused one
    /// have already happened in the staged tree, which is harmless: a refusal means the tree is never
    /// repacked, and the archive is untouched.
    public static func stage(
        _ moves: [Move],
        ofArchiveAt archivePath: String,
        inWorkingDirectory workingDirectory: String
    ) throws {
        for move in moves {
            let source = workingLocation(
                ofInnerPath: move.from,
                inWorkingDirectory: workingDirectory
            )
            let destination = workingLocation(
                ofInnerPath: move.to,
                inWorkingDirectory: workingDirectory
            )
            do {
                try FileManager.default.moveItem(atPath: source, toPath: destination)
            } catch let error as NSError where error.code == NSFileWriteFileExistsError {
                throw VFSError.alreadyExists(
                    VFSPath(backend: .archive(forArchiveAt: archivePath), path: move.to)
                )
            }
        }
    }
}
