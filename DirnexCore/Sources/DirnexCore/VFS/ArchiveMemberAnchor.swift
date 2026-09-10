import Foundation

/// Finding the member a gesture was about again, after the archive's names have been **re-decoded**
/// under a newly declared code page (``ArchiveNameEncoding``).
///
/// Declaring a code page re-spells every non-ASCII name in the archive, so a row's `VFSPath` — the
/// identity `Panel.setListing` re-anchors the cursor by — is a different string afterwards for the
/// very rows the declaration was made for. The cursor therefore falls through to
/// `min(cursor, count - 1)`, which keeps the row *index* while re-sorting has moved a different file
/// there: reported 2026-09-10, answering the chooser left the cursor on `plain.txt` when the file
/// being renamed was `Панорама.txt`, so the obvious next keystroke would have renamed the wrong one.
///
/// What survives the re-decode is everything about the entry that is not its name — a rename of the
/// *label*, not of the file. So the match is on kind and byte size, within the same directory.
///
/// **The modification date is deliberately not compared, and it is the obvious thing to add.** The
/// two listings this spans are read by different engines: before the declaration by `bsdtar -tvf`,
/// whose date column has no seconds field at all (and no year for a recent file), and after it by
/// libarchive, which reports the real `mtime`. So the same member's timestamp differs between them
/// whenever its real seconds are not zero — about fifty-nine times in sixty — and a match that
/// included the date would simply never fire, which is how it was first written and what made its
/// own test reproduce the bug it was meant to fix.
///
/// **It refuses rather than guesses, and that is the whole of its safety.** Two files of the same
/// size and timestamp in one folder are ordinary (a duplicate, a pair of empty files), and no
/// property left after the name is gone can separate them — so an ambiguous set answers `nil` and
/// the caller keeps whatever behaviour it had before. A cursor left where it was is a small
/// annoyance; a rename opened on a confidently-chosen wrong file is not.
public enum ArchiveMemberAnchor {
    /// The entry in `entries` that is `anchor` under its new name, or `nil` when nothing matches or
    /// more than one thing does.
    ///
    /// An exact path match wins outright and costs nothing: a member whose name was already ASCII is
    /// spelled identically before and after, which is most of any real archive.
    public static func match(_ anchor: FileEntry, in entries: [FileEntry]) -> FileEntry? {
        if let exact = entries.first(where: { $0.path == anchor.path }) { return exact }
        let candidates = entries.filter {
            $0.kind == anchor.kind
                && $0.byteSize == anchor.byteSize
                && $0.path.parent == anchor.path.parent
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
