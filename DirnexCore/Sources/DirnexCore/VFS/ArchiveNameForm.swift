import Foundation

/// How an archive spells its members' names: `inner.txt`, or `./inner.txt` (found 2026-10-26 in
/// PLAN.md §M33 Slice 6's live run).
///
/// A rewrite extracts the archive, edits the tree on disk and repacks it, and the tree on disk has
/// no memory of which spelling the names had. Both are common: a zip tool writes `inner.txt`, while a
/// tar packed with `-C dir .` writes `./inner.txt`, as Sparkle's own release tarball does. They are
/// **different names** to anything that looks a member up by name — `unzip -p pair.zip inner.txt`
/// and Python's `zipfile.getinfo("inner.txt")` both fail on a `./inner.txt` — so a rewrite has to
/// put back the spelling it found. Until 2026-10-26 every rewrite wrote `./`, whatever it found.
public enum ArchiveNameForm: Sendable, Equatable {
    /// `inner.txt`, `docs/x.md`: what zip tools, the pack sheet and the encrypted route write.
    case bare
    /// `./inner.txt`, usually behind a `./` entry for the root: what `tar -C dir .` writes.
    case dotSlash

    /// The form an archive's names are in. `.dotSlash` only when **every** name is spelled that
    /// way, so an archive that mixes the two, or holds nothing, is repacked bare: every bare name
    /// then stays exactly as it was, and a prefixed one loses only its `./`.
    public static func inferred(from names: [String]) -> Self {
        guard !names.isEmpty else { return .bare }
        return names.allSatisfy { $0 == "." || $0.hasPrefix("./") } ? .dotSlash : .bare
    }
}
