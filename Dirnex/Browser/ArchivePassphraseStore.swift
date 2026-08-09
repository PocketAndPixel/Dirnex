import DirnexCore
import Foundation

/// The passphrases the user has given for encrypted archives this session, keyed by the archive's
/// on-disk path (PLAN.md §M19).
///
/// A zip's central directory is never encrypted, so an encrypted archive *browses* without anyone
/// typing anything and the passphrase is wanted only at the moment bytes are — previewing a member,
/// opening one, entering a nested archive, copying out with F5. Each of those would otherwise ask
/// again, and the preview, which follows the cursor, would ask on every arrow key.
///
/// **Memory only, and never persisted.** Nothing here reaches `UserDefaults`, the Keychain or the
/// undo journal: a vault's passphrase is filed because the user asked for a vault, and an archive's
/// is answered because they wanted to look at one file. `ArchivePassphrase` keeps it out of every
/// string-shaped surface — see its doc comment for exactly how far that goes, and where it stops —
/// and this keeps it out of every store.
///
/// One per window, beside `ArchivePreviewCache` and `NestedArchiveRegistry`.
@MainActor
final class ArchivePassphraseStore {
    private var byArchivePath: [String: ArchivePassphrase] = [:]

    /// The passphrase already given for this archive, or `nil` if none has been. The passive preview
    /// paths read this and nothing else — an unlocked archive keeps previewing as the cursor moves,
    /// and a locked one stays quiet rather than raising a sheet nobody asked for.
    func passphrase(forArchiveAt archivePath: String) -> ArchivePassphrase? {
        byArchivePath[archivePath]
    }

    /// File a passphrase that has actually opened the archive. Called only after a successful read,
    /// so a typo is never remembered and the next gesture never inherits one.
    func remember(_ passphrase: ArchivePassphrase, forArchiveAt archivePath: String) {
        byArchivePath[archivePath] = passphrase
    }
}
