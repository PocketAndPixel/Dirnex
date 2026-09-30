import Foundation

/// Whether an encrypted archive also hides what it contains.
///
/// Encryption in a zip covers entry *data* and nothing else — the central directory is plaintext in
/// every zip ever written, so an "encrypted" archive still hands over every file name, every size and
/// every modification date to whoever holds it. For a folder called `Divorce` or `Layoffs Q3`, the
/// names are most of the secret.
///
/// The fix is the one every archiver uses: put the whole selection into a single inner archive, and
/// let that one entry be the thing that gets encrypted. The outer archive then lists exactly one
/// name, and nothing about the real contents is readable without the passphrase.
///
/// ## Why it is off by default
///
/// The recipient sees one file called `Contents.tar` and has to unpack twice. Dirnex undoes it
/// transparently on its own side, but 7-Zip on Windows will not, and someone who was sent a
/// straightforward archive and got a Russian doll has been surprised for a reason they did not ask
/// for. It is offered where the user can see it and choose it, which is the same call
/// `ArchiveEncryption` makes about naming the cipher rather than saying "Encrypted".
public enum ArchiveNamePrivacy: String, CaseIterable, Sendable, Hashable {
    /// The archive lists its entries the way any zip does.
    case visible

    /// The selection is wrapped in a single inner entry, so the outer archive lists only that.
    case hidden

    /// The label the pack dialog shows beside the checkbox.
    public var displayName: String {
        switch self {
        case .visible: return "Show file names"
        case .hidden: return "Hide file names"
        }
    }

    /// The single entry an outer archive carries when names are hidden.
    ///
    /// A `.tar` rather than a second `.zip`, for two reasons that both matter. Tar stores bytes
    /// verbatim, so the outer zip's deflate is the *only* compression pass — nesting a zip inside a
    /// zip would compress everything twice, which costs time and produces a larger file, since
    /// already-compressed data does not compress. And tar carries POSIX permissions and symlinks
    /// losslessly, which is what makes the unwrapped result identical to the un-hidden one.
    ///
    /// The name is deliberately plain and English: it is the one string a recipient using some other
    /// archiver will see, and it should read as an instruction rather than as a Dirnex artifact. It
    /// is **not** localized for exactly that reason — the person opening it may not share the
    /// sender's language, and a `.tar` suffix is understood everywhere.
    public static let wrappedEntryName = "Contents.tar"

    /// Whether an inspected archive looks like one of ours with names hidden — a single entry, named
    /// as above.
    ///
    /// Recognized by shape rather than by any marker written into the file. A marker would be a
    /// second thing to keep in sync, and worse, it would sit in the *plaintext* central directory
    /// announcing that this archive is worth attacking. The shape check costs nothing and says
    /// nothing.
    public static func looksWrapped(_ entryNames: [String]) -> Bool {
        entryNames == [wrappedEntryName]
    }

    /// Whether `innerPaths` — VFS inner paths like `/Contents.tar` — name the wrapper itself.
    ///
    /// The reader undoes the wrap transparently, which is right for everything that wants the files
    /// and wrong for the one caller that wants the **container**: a pane browsing such an archive
    /// lists exactly one row, `Contents.tar`, and every gesture aimed at that row asks for it by
    /// name. Unwrapped out from under them, the file they were promised is never placed at all — so
    /// entering it mounted a path that did not exist and reported the archive as unreadable.
    public static func requestsWrapper(_ innerPaths: [String]) -> Bool {
        looksWrapped(innerPaths.map { path in String(path.drop { $0 == "/" }) })
    }
}
