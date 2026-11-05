import Foundation

/// One rename the app carried out: an item that kept its folder and took a new name, from the path
/// that was true when the rename ran (2026-11-05).
///
/// Two places need to say that, and it is the same fact in both. A search snapshot cannot re-list,
/// so it is told which renames happened (``SearchSnapshot/renaming(_:after:)``, where this is
/// ``SearchSnapshot/Renamed``). And an archive rewrite's undo is a swap of whole containers that
/// says nothing about what changed inside, so the step that swaps them carries the renames as well
/// (``UndoStep/restoreArchive(archive:snapshot:expected:restored:renames:)``). Codable for that
/// second use, since the journal is persisted.
public struct PathRename: Sendable, Equatable, Codable {
    /// Where the item was when the rename ran.
    public let from: VFSPath
    /// Where it is now.
    public let to: VFSPath

    public init(from: VFSPath, to: VFSPath) {
        self.from = from
        self.to = to
    }

    /// The renames that undo `renames`: the same ones the other way round, last first. Each pair's
    /// paths were true when that rename ran, so the last rename has to come back first, as
    /// ``UndoRecord/multiRename(_:date:)`` orders its steps.
    public static func reversal(of renames: [PathRename]) -> [PathRename] {
        renames.reversed().map { PathRename(from: $0.to, to: $0.from) }
    }
}
