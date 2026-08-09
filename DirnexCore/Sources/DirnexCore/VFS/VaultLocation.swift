import Foundation

/// A saved encrypted vault: where the image lives, and how to find its passphrase in the Keychain.
///
/// A vault deliberately introduces **no new `VFSBackend`**. Once unlocked it is a mounted volume,
/// which `LocalBackend` already browses — so nothing downstream has to learn about it, and Dirnex
/// avoids the trap docs/NOTES.md records for backends that are *places*: "a new backend has to be
/// named at every site that lists the old ones, and the compiler checks none of them" (five wrong
/// sites the last time). A vault is a folder that happens to require a passphrase to appear.
///
/// What it does need is identity — a stable key for the Keychain and for the sidebar's saved list —
/// which is what this is. Like the three remote locations it holds only the *addressing*: nothing
/// here touches Security.framework or sees a passphrase.
public struct VaultLocation: Sendable, Hashable, Codable {
    /// Absolute path to the `.sparsebundle` or `.dmg`.
    public var imagePath: String

    /// The volume name given at creation — what the mounted volume is called, and what Dirnex shows
    /// in the sidebar whether the vault is locked or unlocked.
    ///
    /// Stored rather than read from the image, because a locked vault cannot be asked: the volume
    /// name lives inside the encrypted filesystem. Without this a locked vault could only be listed
    /// by its file name, which is the one thing a user may deliberately have made unrevealing.
    public var volumeName: String

    public init(imagePath: String, volumeName: String) {
        self.imagePath = imagePath
        self.volumeName = volumeName
    }

    /// The vault's file name, for a display that wants to say where it is rather than what it is
    /// called.
    public var fileName: String { (imagePath as NSString).lastPathComponent }

    /// The path in its canonical spelling — what any comparison against `hdiutil`'s output must use
    /// (see ``DiskImageMount/isMounted(imageAtPath:in:)``), and what the Keychain is keyed by.
    public var resolvedImagePath: String { Self.normalizedPath(imagePath) }

    /// One spelling for a path that macOS writes two ways, **independent of whether it exists**.
    ///
    /// `hdiutil` reports an image's path resolved (`/private/tmp/v.sparsebundle`) while the user, and
    /// Dirnex's own path bar, say `/tmp/v.sparsebundle`. Foundation looks like it settles this and
    /// does not: probed on macOS 26, `URL.resolvingSymlinksInPath()` and `NSString.standardizingPath`
    /// both strip the `/private` prefix **only for a path that currently exists** —
    ///
    ///     /private/tmp/rslv-exists.txt  (exists)  ->  /tmp/rslv-exists.txt
    ///     /private/tmp/rslv-absent.txt  (absent)  ->  /private/tmp/rslv-absent.txt
    ///
    /// — so it is not a normalizer at all, it is a filesystem query wearing one's clothes. That
    /// matters here twice over. A Keychain account keyed through it would change the moment the vault
    /// is moved or deleted, which is exactly when its stored passphrase needs finding in order to be
    /// cleaned up; and a vault that has *just* been created would key differently from the same vault
    /// a moment before it existed.
    ///
    /// So the three `/private` firmlink prefixes are folded by hand. They are a fixed property of
    /// macOS's layout rather than something to discover, and doing it in string space makes the
    /// answer the same on every call whatever is on disk.
    public static func normalizedPath(_ path: String) -> String {
        let collapsed = (path as NSString).standardizingPath
        for prefix in ["/private/tmp", "/private/var", "/private/etc"] where collapsed.hasPrefix(
            prefix
        ) {
            return String(collapsed.dropFirst("/private".count))
        }
        return collapsed
    }
}

/// The vaults the user has, in the order the sidebar lists them.
///
/// A value type with the identity rule in it, rather than an array the app manages: **one vault is
/// one resolved path**, so a vault reached as `/tmp/v.sparsebundle` and again as
/// `/private/tmp/v.sparsebundle` must not become two rows filing two Keychain items — the same
/// comparison ``VaultLocation/keychainAccount`` is keyed on, and for the same reason.
public struct SavedVaults: Sendable, Equatable, Codable {
    public private(set) var vaults: [VaultLocation]

    public init(vaults: [VaultLocation] = []) {
        self.vaults = []
        for vault in vaults { add(vault) }
    }

    /// Add a vault, or update the one already filed under that path. Returns whether anything
    /// changed, so a caller can skip a needless write and sidebar rebuild.
    ///
    /// An existing entry is *replaced* rather than skipped: the volume name is the part that can
    /// legitimately differ (a vault re-created at the same path with a new name), and keeping the
    /// stale one would caption the row with a volume that no longer exists.
    @discardableResult
    public mutating func add(_ vault: VaultLocation) -> Bool {
        if let index = index(ofPath: vault.imagePath) {
            guard vaults[index] != vault else { return false }
            vaults[index] = vault
            return true
        }
        vaults.append(vault)
        return true
    }

    /// Re-point the vault at `imagePath` to `newPath`, **keeping its place in the list**.
    ///
    /// A remove-then-add would send the row to the bottom of the Vaults section, so renaming a
    /// vault's image file would silently reorder the sidebar — a change nobody asked for, made by a
    /// gesture that was about a file name. Returns whether there was a vault to move.
    @discardableResult
    public mutating func move(imagePath: String, to newPath: String) -> Bool {
        guard let index = index(ofPath: imagePath) else { return false }
        vaults[index].imagePath = newPath
        return true
    }

    /// Remove the vault at `imagePath`, whichever spelling it is given in. Returns whether it was
    /// there.
    @discardableResult
    public mutating func remove(imagePath: String) -> Bool {
        guard let index = index(ofPath: imagePath) else { return false }
        vaults.remove(at: index)
        return true
    }

    public func vault(atPath imagePath: String) -> VaultLocation? {
        index(ofPath: imagePath).map { vaults[$0] }
    }

    private func index(ofPath imagePath: String) -> Int? {
        let wanted = VaultLocation.normalizedPath(imagePath)
        return vaults.firstIndex { $0.resolvedImagePath == wanted }
    }
}

extension VaultLocation: KeychainAddressable {
    /// One service for every vault, matching the one-per-protocol scheme the remote locations use.
    public static var keychainService: String { "com.dirnex.Dirnex.vault" }

    /// Keyed by the **resolved** image path.
    ///
    /// Resolved for the same reason the mount comparison is: `/tmp/x.sparsebundle` and
    /// `/private/tmp/x.sparsebundle` are one vault, and keying on the raw string would file two
    /// Keychain items for it — so a vault saved through one spelling would prompt for a passphrase
    /// again when reached through the other, with the stored one sitting right there.
    ///
    /// The path is also what makes the key stable across launches, which is what
    /// `KeychainAddressable` asks for. Moving the image is therefore a rename in Keychain terms and
    /// the saved passphrase is orphaned — correct rather than unfortunate: a passphrase filed under
    /// a path that no longer holds that vault would be offered for whatever *does*.
    public var keychainAccount: String { resolvedImagePath }
}
