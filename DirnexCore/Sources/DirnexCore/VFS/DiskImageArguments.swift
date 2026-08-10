import Foundation

/// The `hdiutil` command lines behind a Dirnex vault — the pure, tested half.
///
/// The same shape as `FTPProcessArguments` and `ArchivePacking`: this builds argv and touches
/// nothing, while the app runs the process, because non-hermetic subprocess I/O lives in the app
/// (PLAN.md §2). Every flag below was exercised against real `hdiutil` before it was written down.
///
/// ## The passphrase never appears here
///
/// That is the load-bearing property, and it is why a vault is a disk image rather than something
/// hand-rolled. `-stdinpass` makes `hdiutil` read the passphrase from its standard input, so it is
/// in no argv anywhere — verified by scanning the whole process tree mid-run (`hdiutil` itself,
/// `diskimages-helper`, `copy-helper`, `diskimagesiod`) for a known passphrase and finding it in
/// none of them. `ArchivePassphrase` is what the app writes to that pipe.
///
/// There is no function here that takes a passphrase, and that is deliberate: the type system should
/// make "put the secret in the arguments" un-writable, not merely discouraged.
public enum DiskImageArguments {
    /// A vault's on-disk shape.
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        /// A growable bundle. Measured: a 10 GB APFS sparsebundle costs 23 MB the moment it is
        /// created, and grows as it is filled. This is the right default for a vault someone works
        /// in, since the alternative is asking a user to predict how much they will ever store.
        ///
        /// The trade-off is that it is a *directory*, not a file — awkward to email, which is fine:
        /// sending things is what the encrypted-archive half is for.
        case sparseBundle
        /// A fixed-capacity single file. Easier to move around, but its size has to be chosen up
        /// front and is paid for immediately.
        case fixed

        var typeArgument: String {
            switch self {
            case .sparseBundle: return "SPARSEBUNDLE"
            case .fixed: return "UDIF"
            }
        }

        /// The suffix `hdiutil` gives the thing it creates. It appends this itself when the path
        /// lacks it, so Dirnex spells it explicitly and stays in control of the file name.
        public var pathExtension: String {
            switch self {
            case .sparseBundle: return "sparsebundle"
            case .fixed: return "dmg"
            }
        }

        /// Whether `fileName` carries one of the suffixes above — "this file could be a vault
        /// image", in one place.
        ///
        /// Two gestures ask it (the Unlock command's cursor test, and the pane's Enter), which is
        /// exactly the shape docs/NOTES.md keeps finding: one rule, two spellings, and the compiler
        /// checks neither. A `Kind` added later is covered by both for free.
        public static func isImageName(_ fileName: String) -> Bool {
            let suffix = (fileName as NSString).pathExtension.lowercased()
            return allCases.contains { $0.pathExtension == suffix }
        }
    }

    /// Creating a new, empty encrypted vault.
    ///
    /// - Parameters:
    ///   - path: Absolute, including the extension from ``Kind/pathExtension``.
    ///   - volumeName: What the mounted volume is called — what the user sees in `/Volumes` and in
    ///     Dirnex's own sidebar.
    ///   - megabytes: Capacity. For a sparse bundle this is a *ceiling*, not an allocation.
    ///
    /// `-puppetstrings` is what makes a progress bar possible: `hdiutil` then emits machine-readable
    /// `PERCENT:` lines (see ``DiskImageProgress``) instead of drawing its own meter.
    public static func create(
        atPath path: String,
        volumeName: String,
        kind: Kind,
        megabytes: Int
    ) -> [String] {
        [
            "create",
            "-encryption", "AES-256",
            "-stdinpass",
            "-type", kind.typeArgument,
            "-size", "\(megabytes)m",
            "-fs", "APFS",
            "-volname", volumeName,
            "-puppetstrings",
            path
        ]
    }

    /// Unlocking a vault: attach it and mount its volume.
    ///
    /// `-nobrowse` keeps it out of the Finder sidebar, because Dirnex is the one presenting it —
    /// and a vault that silently appears in every other app's open panel is not what "unlock in my
    /// file manager" means. `-plist` makes the result parseable by ``DiskImageMount`` rather than
    /// scraped from prose.
    ///
    /// `showingInFinder` withdraws that flag for one vault (``VaultLocation/showsInFinder``). It is a
    /// parameter with a private default rather than two functions, so a call site that says nothing
    /// gets the private behavior: the failure that matters here is a vault published by omission, and
    /// this is the shape where forgetting cannot cause it.
    public static func attach(atPath path: String, showingInFinder: Bool = false) -> [String] {
        var argv = ["attach", "-stdinpass"]
        if !showingInFinder { argv.append("-nobrowse") }
        argv += ["-plist", path]
        return argv
    }

    /// Locking a vault: unmount and detach it.
    ///
    /// Takes the **mount point**, not the image path, because that is what `hdiutil detach`
    /// resolves. Probed exit codes: `0` the first time, `1` when it is already detached — so a
    /// caller must treat a second lock as success, since the user's intent ("this must not be
    /// mounted") is already satisfied. The same idempotence rule `ExtendedAttributeIO` applies to
    /// `ENOATTR`.
    public static func detach(mountPoint: String) -> [String] {
        ["detach", mountPoint]
    }

    /// Asking which images are attached and where, so Dirnex can show a vault as locked or unlocked
    /// without keeping its own state that could go stale behind a `hdiutil detach` in Terminal.
    public static func info() -> [String] {
        ["info", "-plist"]
    }

    /// The full path for a new vault named `name` in `directory`, with the right extension.
    public static func vaultPath(inDirectory directory: String, named name: String, kind: Kind) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Vault" : trimmed
        let suffix = "." + kind.pathExtension
        let leaf = base.lowercased().hasSuffix(suffix) ? base : base + suffix
        return (directory as NSString).appendingPathComponent(leaf)
    }
}
