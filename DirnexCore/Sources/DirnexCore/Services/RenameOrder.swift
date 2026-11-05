import Foundation

/// The order a batch of in-place renames has to be carried out in: **deepest path first**
/// (2026-11-05).
///
/// A tree selection can mark a folder and something inside it, and the multi-rename tool renames
/// each item in its own folder. Renaming the folder first leaves the inner item's path pointing at
/// nothing, so its rename fails; renaming the inner item first does it inside the folder's old name,
/// and the folder then carries it along. Deepest first is the one order that always works, because a
/// rename never changes the path of anything *deeper* than the item renamed. Items at one depth keep
/// the order they came in, which in a flat listing is every item, so a flat batch runs exactly as it
/// always did.
///
/// One rule for both places a batch is carried out, the backend loop a local or remote ⇧F2 runs and
/// the staged moves of an archive rewrite (``ArchiveMutation/renameMoves(for:)``), so the two cannot
/// disagree about which order works. The undo has to run the other way round, and does:
/// ``UndoRecord/multiRename(_:date:)`` records its steps in reverse.
public enum RenameOrder {
    /// `items` ordered deepest `path` first, stable within one depth.
    ///
    /// Depth is the number of path components, so it compares items of one backend correctly
    /// whatever the backend's root looks like: only relative depth matters, and every item in a
    /// batch lives on the pane's one backend.
    public static func deepestFirst<Item>(_ items: [Item], path: (Item) -> String) -> [Item] {
        items.enumerated()
            .map { (offset: $0.offset, element: $0.element, depth: depth(of: path($0.element))) }
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The first of `items` at the shallowest depth, in the order given: where the cursor lands after
    /// a batch.
    ///
    /// The landing has to be an item whose renamed path is still true once the batch is done, and a
    /// deeper item's may not be: `docs/b.txt` is where the file was renamed to, and `docs` was then
    /// renamed too. Nothing renames anything shallower than the shallowest item, so its path holds.
    /// In a flat batch every item is at one depth and this is the first one, where the cursor has
    /// always landed.
    public static func shallowest<Item>(_ items: [Item], path: (Item) -> String) -> Item? {
        let depths = items.map { depth(of: path($0)) }
        guard let least = depths.min(), let index = depths.firstIndex(of: least) else { return nil }
        return items[index]
    }

    /// How many components `path` has: `/a.txt` is 1, `/docs/a.txt` is 2.
    static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }
}
