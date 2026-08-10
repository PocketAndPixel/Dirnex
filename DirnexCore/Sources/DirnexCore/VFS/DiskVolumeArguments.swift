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

    /// What to do about ``VaultLocation/showsInFinder`` for a vault that is **already unlocked**.
    public enum Remount: Equatable, Sendable {
        /// The volume is already as the user asked. Nothing to spawn.
        case unnecessary
        /// Run `/sbin/mount` with these arguments.
        case arguments([String])
        /// It cannot be changed in place; it will take effect the next time the vault is unlocked.
        case takesEffectOnNextUnlock
    }

    /// Flip a mounted volume between visible and hidden **without unmounting it**, so toggling the
    /// setting on an open vault does not make the user lock and unlock it.
    ///
    /// ## Measured on macOS 26, against a real encrypted APFS sparsebundle
    ///
    /// `mount -u -o browse <point>` works **unprivileged** on a volume `hdiutil` attached with
    /// `-nobrowse`, and the volume appears in Finder's Locations immediately. `nobrowse` puts it back.
    /// Two results decide the shape of everything below:
    ///
    /// - **A remount keeps only the options it is given.** A bare `-o browse` cleared
    ///   `MNT_IGNORE_OWNERSHIP` along with `MNT_DONTBROWSE` (`0x04B09218` → `0x04809218`), so a vault
    ///   that ignored ownership silently started enforcing it — every file in it owned by a uid from
    ///   whichever Mac wrote it. `MNT_NOSUID` and `MNT_NODEV` survived on their own, but relying on
    ///   that is relying on which flags this version happens to keep. So the whole current flags word
    ///   is re-stated, and the *only* bit this changes is the browse one.
    /// - **A read-only volume cannot be remounted unprivileged at all** — `mount_apfs: volume could
    ///   not be mounted: Permission denied`, exit 66 — and it fails clean: the flags word was
    ///   byte-identical afterwards (`0x04B09219`), with no half-applied state. Hence
    ///   ``Remount/takesEffectOnNextUnlock`` rather than an error: the setting is still saved, and
    ///   `-nobrowse` is decided again at the next attach, where it will be honored.
    public static func remount(
        mountPoint: String,
        flags: MountFlags,
        showingInFinder: Bool
    ) -> Remount {
        guard flags.contains(.doNotBrowse) == showingInFinder else { return .unnecessary }
        guard !flags.contains(.readOnly) else { return .takesEffectOnNextUnlock }
        var wanted = flags
        wanted.remove(.doNotBrowse)
        let options = [showingInFinder ? "browse" : "nobrowse"] + wanted.remountOptions
        return .arguments(["-u", "-o", options.joined(separator: ","), mountPoint])
    }
}

/// The `statfs` `f_flags` bits a remount has to preserve, named.
///
/// Only the ones with a `mount -o` spelling are here — the rest of the word (`MNT_LOCAL`,
/// `MNT_JOURNALED` and friends) describes what the file system *is* rather than how it was asked to
/// be mounted, and re-stating those is neither possible nor wanted.
public struct MountFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `MNT_RDONLY`.
    public static let readOnly = MountFlags(rawValue: 0x0000_0001)
    /// `MNT_NOEXEC`.
    public static let noExecute = MountFlags(rawValue: 0x0000_0004)
    /// `MNT_NOSUID`.
    public static let noSetUID = MountFlags(rawValue: 0x0000_0008)
    /// `MNT_NODEV`.
    public static let noDevices = MountFlags(rawValue: 0x0000_0010)
    /// `MNT_DONTBROWSE` — the one bit this whole file exists to change.
    public static let doNotBrowse = MountFlags(rawValue: 0x0010_0000)
    /// `MNT_IGNORE_OWNERSHIP`, spelled `noowners`. The flag a bare remount was measured to drop.
    public static let ignoreOwnership = MountFlags(rawValue: 0x0020_0000)
    /// `MNT_NOATIME`.
    public static let noAccessTime = MountFlags(rawValue: 0x1000_0000)

    /// The `-o` options that re-state this set, in a fixed order so the argv is testable.
    ///
    /// ``MountFlags/readOnly`` is deliberately absent: a read-only volume never reaches here (its
    /// remount is refused above), and emitting `rdonly` for one that did would be asking for the
    /// privileged operation that fails.
    var remountOptions: [String] {
        let spellings: [(MountFlags, String)] = [
            (.noExecute, "noexec"),
            (.noSetUID, "nosuid"),
            (.noDevices, "nodev"),
            (.ignoreOwnership, "noowners"),
            (.noAccessTime, "noatime")
        ]
        return spellings.filter { contains($0.0) }.map(\.1)
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
