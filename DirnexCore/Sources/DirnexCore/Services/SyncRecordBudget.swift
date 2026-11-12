import Foundation

/// How much text the sync records may keep, and what goes first to stay inside it (PLAN.md §M37).
///
/// One budget across every folder pair, counted in logical bytes. On the store's own volume a kept
/// version is a clone and costs nothing until the file changes, and from then on it holds the old
/// blocks (docs/NOTES.md ▸ Keeping a file's previous bytes). On another volume it is a real copy. So
/// the sum of sizes is the most it can cost, which is the number worth bounding.
///
/// Pure: it decides, and ``SyncRecordStore`` carries the decision out.
public struct SyncRecordBudget: Sendable, Equatable {
    /// 5 GiB, the same as an archive rewrite's undo. Every text file of up to 64 MiB in this
    /// repository, with its build products and worktrees, came to 1.7 GiB (measured 2026-11-09).
    public static let `default` = SyncRecordBudget(bytes: 5 << 30)

    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = max(0, bytes)
    }

    /// One version the records hold.
    public struct Held: Sendable, Equatable {
        public let file: UUID
        public let byteSize: Int64
        public let keptAt: Date

        public init(file: UUID, byteSize: Int64, keptAt: Date) {
            self.file = file
            self.byteSize = byteSize
            self.keptAt = keptAt
        }
    }

    /// Which of one sync's files to keep, in the order given. A file that does not fit is passed
    /// over and the smaller ones after it are still taken, so a sync larger than the whole budget
    /// keeps as many files as it can.
    public func admitted(_ incoming: [Int64]) -> [Bool] {
        var room = bytes
        return incoming.map { size in
            guard size <= room else { return false }
            room -= size
            return true
        }
    }

    /// Which held versions to drop so that the rest and `incoming` bytes fit, oldest first.
    ///
    /// A sync stamps all its versions with one date, so the order among them comes from the file's
    /// identifier. `sorted(by:)` is not stable, and a key with ties makes it answer differently from
    /// run to run (docs/NOTES.md ▸ Keeping a file's previous bytes).
    public func evictions(held: [Held], incoming: Int64) -> [UUID] {
        var total = held.reduce(Int64(0)) { $0 + $1.byteSize }
        var evicted: [UUID] = []
        let oldestFirst = held.sorted {
            ($0.keptAt, $0.file.uuidString) < ($1.keptAt, $1.file.uuidString)
        }
        for version in oldestFirst where total + incoming > bytes {
            evicted.append(version.file)
            total -= version.byteSize
        }
        return evicted
    }
}
