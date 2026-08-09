import Foundation

/// The `diskutil` command line behind renaming a vault, and the rules a volume name has to clear —
/// the pure, tested half (PLAN.md §2).
///
/// Sibling of ``DiskImageArguments`` and deliberately separate from it, because the tool is a
/// different one: `hdiutil` owns the *image* (create, attach, detach) while the volume inside it
/// belongs to `diskutil`. Nothing here takes a passphrase either, and for the same reason — renaming
/// happens on a volume that is already unlocked, so there is no secret for this argv to leak.
///
/// ## What a rename actually does, measured
///
/// Probed on macOS 26 against a real encrypted APFS sparsebundle before any of this was written:
/// `diskutil rename <mountPoint> <name>` renames an unlocked vault's volume **unprivileged**, and
/// the mount point moves with it — `/Volumes/Personal` became `/Volumes/Work` synchronously, with a
/// process standing inside the volume, and the new name survived a detach-and-reattach because it
/// lives in the encrypted filesystem. (Nothing readable does: a locked bundle's `Info.plist` carries
/// no volume name at all, which is exactly what ``VaultLocation/volumeName`` is stored for.)
///
/// Three measured consequences the callers depend on:
///
/// - **A collision still succeeds, and moves the goalposts.** Asking for `Work` while something else
///   is already at `/Volumes/Work` renames the volume to `Work` and mounts it at `/Volumes/Work 1`.
///   So a caller must *re-read* where the volume ended up rather than assuming `/Volumes/` plus what
///   the user typed — the same rule the unlock path already follows.
/// - **A `/` is legal in a volume name** and appears in the path as `:` (`a/b` → `/Volumes/a:b`),
///   the usual HFS swap. Nothing needs to refuse it; the path that comes back is a real one.
/// - **A leading `-` is taken as the name, not as a flag.** Probed: renaming to `-force` produced a
///   volume called `-force`. The argument is positional, and Dirnex spawns with an argv rather than
///   through a shell, so there is nothing here to escape.
public enum DiskVolumeArguments {
    /// Renaming the volume mounted at `mountPoint`.
    ///
    /// Takes the mount point rather than the image path, because that is what `diskutil` resolves —
    /// which is also the reason a vault has to be unlocked before it can be renamed at all.
    public static func rename(mountPoint: String, to name: String) -> [String] {
        ["rename", mountPoint, name]
    }
}

/// What a volume may be called.
///
/// The rules are the file system's, read off the real tool rather than guessed — `diskutil` refuses
/// an invalid name outright (exit 1, "does not appear to be a valid volume name for its file
/// system"), so the point of checking first is to say *why* in the user's own language instead of
/// letting a subprocess fail with an English sentence Dirnex would have to scrape.
public enum VolumeName {
    /// The longest a volume name may be, in **UTF-8 bytes — not characters**.
    ///
    /// Measured, and the distinction is the whole reason this is written down: 255 ASCII characters
    /// are accepted and 256 refused, while **127** Cyrillic characters (254 bytes) are accepted and
    /// **128** (256 bytes) refused. Counting characters would let a Russian or Greek name through
    /// that the file system then rejects — the localization trap this project keeps meeting, where
    /// the English case is the one that behaves.
    public static let maximumByteCount = 255

    /// The name as it will actually be used: surrounding whitespace removed.
    ///
    /// Trimmed rather than refused, because trailing space is almost always a paste artifact and
    /// `diskutil` keeps it verbatim — probed, `"  Padded  "` really does mount at `/Volumes/  Padded  `.
    /// The same trim ``DiskImageArguments/vaultPath(inDirectory:named:kind:)`` applies when a vault
    /// is created, so a vault cannot be renamed to something it could not have been called.
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether ``normalized(_:)``'s output can be a volume name.
    ///
    /// Empty, `.` and `..` are the file system's own refusals (probed: all three exit 1). Control
    /// characters are **ours**: `diskutil` accepts a name containing a newline or a tab and mounts
    /// it, which produces a volume whose path cannot be typed, printed in a log, or read back in an
    /// alert — a name nothing else on the Mac will refuse for you.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.utf8.count <= maximumByteCount else { return false }
        return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
