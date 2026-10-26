import Foundation

/// The bytes an edited copy of a server file started from, kept so a three-way merge has a base
/// when the file changes on the server under the edit (PLAN.md §M34 Slice 4).
///
/// Each kept file is a duplicate in a directory of its own under ``root``, under the copy's own
/// name, so two bases of one name cannot collide. The root sits outside every copy's directory,
/// since the edit watch watches that directory and a file landing in it would wake the watch.
///
/// A duplicate is an APFS clone where the root and the copy share a volume, which takes no time and
/// no space until the copy is edited (docs/NOTES.md ▸ Keeping a file's previous bytes), and a real
/// copy where they do not. Either way it keeps the copy's modification time, so its
/// ``EditedFileRevision`` is the copy's as it was when the duplicate was taken.
public struct EditBaseStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Duplicate the file at `copy` into a directory of its own, and answer where it landed. `nil`
    /// when it could not be, and then nothing is left behind.
    public func keep(_ copy: URL) -> URL? {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let kept = directory.appendingPathComponent(copy.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard ArchiveUndoStore.duplicate(from: copy.path, to: kept.path) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return kept
    }

    /// Remove a file ``keep(_:)`` made, and its directory. A path anywhere but in a directory of its
    /// own directly under ``root`` is left alone, so a caller's mistake cannot reach a user's file.
    public func discard(_ kept: URL) {
        let directory = kept.standardizedFileURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().path == root.standardizedFileURL.path else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
