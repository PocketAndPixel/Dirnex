import Foundation

/// Following a vault's image file when the user moves or renames it in a pane (PLAN.md §M19).
///
/// A saved vault is addressed by its image's **path**, in two places: the sidebar's list and the
/// Keychain account holding its passphrase (``VaultLocation/keychainAccount``). So an ordinary F2 on
/// the `.sparsebundle`, or an F6 that moves it — or a move of any folder above it — leaves the row
/// pointing at a file that is not there, and the passphrase filed under a path nothing will ever ask
/// about again. Nothing logs, and the row looks perfectly normal until it is clicked.
///
/// ## Why the candidates are symmetric
///
/// This reads an `UndoRecord`, which is the one funnel every rename, move, multi-rename and sync
/// already reports through — so a single hook covers gestures that have nothing else in common. Each
/// ``UndoStep/restore(from:to:)`` names both ends of a move, and this returns a vault paired with
/// the **other** end *in both directions*: a vault at `to` may have moved to `from`, and a vault at
/// `from` may have moved to `to`.
///
/// That symmetry is what makes undo and redo need no special case, and no bookkeeping about which
/// way time is running: the caller picks between the two by asking the file system which one is
/// actually there. A half-applied undo — some steps reverted, some refused — comes out right for the
/// same reason, since each vault is judged on where its own image ended up rather than on what the
/// operation was supposed to do.
///
/// ## What is deliberately not followed
///
/// **A trashed vault stays where it was.** `moveToTrash` produces the same `restore` steps as a
/// move, and following one would re-point the row into `~/.Trash` — where the vault would still
/// unlock, which is not what throwing something away means. Leaving the path alone is also what
/// makes Put Back work: the image returns to exactly the path the row still names, and the row comes
/// back to life on its own.
///
/// A copy is not a move and never appears here — it journals `remove` steps rather than `restore`,
/// so the original vault keeps its row and its passphrase, which is correct.
public enum VaultImageMove {
    /// A saved vault, and where the record suggests its image may now be.
    public struct Candidate: Sendable, Equatable {
        public let vault: VaultLocation
        /// The other end of the move. Only a candidate — the caller confirms against the disk.
        public let destination: String

        public init(vault: VaultLocation, destination: String) {
            self.vault = vault
            self.destination = destination
        }
    }

    /// Every saved vault `record` could have moved, each paired with where it might have landed.
    ///
    /// Containment is ``VaultPrivacy/rebase(_:from:to:)`` — the same component-boundary rule the
    /// vault machinery uses everywhere else — so a vault *inside* a moved folder is followed exactly
    /// like one that was renamed itself, and a sibling whose path merely shares a prefix is not.
    public static func candidates(in record: UndoRecord, vaults: SavedVaults) -> [Candidate] {
        guard record.label != .moveToTrash else { return [] }
        var found: [Candidate] = []
        for step in record.steps {
            guard case let .restore(from, to) = step,
                  from.backend == .local, to.backend == .local
            else { continue }
            for vault in vaults.vaults {
                for (one, other) in [(from.path, to.path), (to.path, from.path)] {
                    guard let moved = VaultPrivacy.rebase(
                        vault.resolvedImagePath, from: one, to: other
                    ) else { continue }
                    let candidate = Candidate(vault: vault, destination: moved)
                    guard !found.contains(candidate) else { continue }
                    found.append(candidate)
                }
            }
        }
        return found
    }
}
