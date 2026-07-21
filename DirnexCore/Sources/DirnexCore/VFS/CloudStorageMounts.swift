import Foundation

/// One cloud provider's synced folder under `~/Library/CloudStorage` — the File Provider mount
/// Google Drive, Dropbox, OneDrive and Box all stream into (PLAN.md §M10 Phase 1
/// "the Desktop mount").
///
/// The row is a *real* directory browsed by the ordinary `LocalBackend`, which is the whole point
/// of doing Google Drive this way first: no backend, no OAuth, no API. Everything that already
/// works on a folder — copy, rename, Quick Look, the recursive sizer — works here unchanged.
///
/// Note that a mount is present whether or not it holds anything. Probed 2026-07-21: a Drive
/// account whose roots have not been provisioned on this Mac mounts and lists as an empty
/// directory (macOS's own `fileproviderctl dump` reports `child:3`, all of them hidden), so
/// "the folder is empty" is a legitimate state of a working mount, not a failed scan.
public struct CloudStorageMount: Sendable, Hashable, Identifiable {
    /// The directory's real name under `~/Library/CloudStorage`, e.g.
    /// `GoogleDrive-someone@gmail.com`. Kept because it is the only stable identity a mount has —
    /// `name` is a display string that changes when a second account for the same provider
    /// appears.
    public let directoryName: String
    /// The provider's own spelling of itself, taken from the part before the first hyphen:
    /// `GoogleDrive`, `Dropbox`, `OneDrive`, `Box`.
    public let providerID: String
    /// Which account this mount belongs to — the part after the first hyphen, an email address
    /// for Google Drive and a tenant or plan name for the others. `nil` for a provider that
    /// mounts one unlabelled folder.
    public let accountLabel: String?
    /// What the sidebar row is called, already disambiguated against the other mounts.
    public let name: String
    public let path: VFSPath
    /// Where clicking the row actually lands — see `CloudStorageMounts.entryDirectory(of:_:)`.
    /// Defaults to the mount itself, which is also what it stays for a provider whose content sits
    /// directly at the mount root.
    public let entryDirectory: VFSPath

    public init(
        directoryName: String,
        providerID: String,
        accountLabel: String?,
        name: String,
        path: VFSPath,
        entryDirectory: VFSPath? = nil
    ) {
        self.directoryName = directoryName
        self.providerID = providerID
        self.accountLabel = accountLabel
        self.name = name
        self.path = path
        self.entryDirectory = entryDirectory ?? path
    }

    /// A copy of this mount pointing at `entryDirectory` — how the scan fills the field in once it
    /// has looked at what the mount holds.
    func entering(_ entryDirectory: VFSPath) -> CloudStorageMount {
        CloudStorageMount(
            directoryName: directoryName,
            providerID: providerID,
            accountLabel: accountLabel,
            name: name,
            path: path,
            entryDirectory: entryDirectory
        )
    }

    public var id: VFSPath { path }

    /// The SF Symbol standing in for the mount. Deliberately the one generic cloud glyph for
    /// every provider: none of them has an SF Symbol, and picking a differently-shaped stand-in
    /// per brand would read as a meaningful distinction where there is none. iCloud Drive keeps
    /// its own `icloud` symbol because Apple ships one.
    public var symbolName: String { "cloud" }
}

/// Finds the cloud provider mounts on this Mac by reading `~/Library/CloudStorage`.
///
/// Every File Provider-based sync client macOS 12+ hosts puts its folder here under a
/// `<Provider>-<account>` name, so one scan covers Google Drive and everything alongside it.
/// The scan is deliberately provider-agnostic: recognising only `GoogleDrive-*` would be the
/// same code with a narrower answer, and would need rewriting the first time Dropbox is
/// installed.
public enum CloudStorageMounts {
    /// `~/Library/CloudStorage`, the parent of every provider mount.
    ///
    /// Unlike `~/Library/Mobile Documents`, this directory lists **without** Full Disk Access
    /// (probed 2026-07-21) — it is not TCC-gated, so the Cloud section fills in on a Mac that has
    /// never seen the onboarding sheet.
    public static func cloudStorage(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home).appending("Library").appending("CloudStorage")
    }

    /// Every provider mount that exists right now, ordered by display name, each pointing at the
    /// directory a click should open (`entryDirectory`).
    ///
    /// Follows the same "only what exists" rule as `SidebarLocations.favorites()` and
    /// `iCloudDrive()`: a Mac with no sync client installed has no `CloudStorage` directory at
    /// all and gets no rows, rather than a dead one.
    public static func mounts(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> [CloudStorageMount] {
        named(home: home, fileManager: fileManager).map {
            $0.entering(entryDirectory(of: $0.path, fileManager))
        }
    }

    /// The mount `path` lives in, or `nil` for anywhere else — what the path bar needs to render a
    /// location inside a mount under the provider's name instead of the raw
    /// `…/Library/CloudStorage/GoogleDrive-someone@gmail.com/…`.
    ///
    /// Cheap on the overwhelmingly common miss: a pure string test rejects any path outside
    /// `~/Library/CloudStorage` before touching the disk, so an ordinary navigation pays nothing.
    /// A hit costs one small local `readdir` — of `CloudStorage` itself, never of the mounts, which
    /// is why this uses `named` rather than `mounts` (a File Provider mount's own `readdir` can
    /// reach the network, and the path bar rebuilds on every navigation).
    public static func mount(
        containing path: VFSPath,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> CloudStorageMount? {
        guard path.backend == .local, path.isSelfOrDescendant(of: cloudStorage(home: home))
        else { return nil }
        return named(home: home, fileManager: fileManager)
            .first { path.isSelfOrDescendant(of: $0.path) }
    }

    /// Where clicking a mount's row should land: its **single visible child** when it has exactly
    /// one, otherwise the mount itself.
    ///
    /// Google Drive mounts as a folder holding nothing but `My Drive` (plus dot-directories), so
    /// opening the mount root shows the user one row they must then step through every time. The
    /// rule is deliberately "exactly one" rather than "a child named `My Drive`", because that is
    /// the condition under which descending hides nothing: an account that also has *Shared drives*
    /// has two visible children and opens at the root where both are reachable, and a provider like
    /// Dropbox that puts content directly at the mount root has many and stays put. It descends one
    /// level only — recursing would tunnel arbitrarily deep into a thin tree.
    ///
    /// Note that `My Drive` is a **symlink** when Drive is in mirror mode (probed 2026-07-21: it
    /// points out to `~/My Drive`), which is why this tests for a directory through
    /// `fileExists` — that follows symlinks — rather than reading the file type.
    static func entryDirectory(of mount: VFSPath, _ fileManager: FileManager) -> VFSPath {
        guard let names = try? fileManager.contentsOfDirectory(atPath: mount.path) else {
            return mount
        }
        let visible = names.filter { !$0.hasPrefix(".") }
        guard visible.count == 1, let only = visible.first else { return mount }
        let child = mount.appending(only)
        return isDirectory(child.path, fileManager) ? child : mount
    }

    /// The mounts with their names resolved, but without looking inside any of them.
    ///
    /// Internal rather than private because `SidebarLocations.trashDirectories` needs the mount list
    /// to construct each one's `.Trash`, and wants exactly this cheap form: a File Provider mount's
    /// own `readdir` can reach the network, so the trash enumeration must not use `mounts()`, which
    /// looks inside each one to find its entry directory.
    static func named(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> [CloudStorageMount] {
        let parent = cloudStorage(home: home)
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else {
            return []
        }

        // Two passes, because a mount's *name* cannot be decided from the mount alone: the
        // account is shown only when a second mount of the same provider makes it load-bearing.
        let directoryNames = names.filter {
            !$0.hasPrefix(".") && isDirectory(parent.appending($0).path, fileManager)
        }

        var countByProvider: [String: Int] = [:]
        for name in directoryNames {
            countByProvider[split(directoryName: name).providerID, default: 0] += 1
        }

        let mounts = directoryNames.map { directoryName in
            let (providerID, accountLabel) = split(directoryName: directoryName)
            return CloudStorageMount(
                directoryName: directoryName,
                providerID: providerID,
                accountLabel: accountLabel,
                name: displayName(
                    providerID: providerID,
                    accountLabel: accountLabel,
                    isAmbiguous: countByProvider[providerID, default: 0] > 1
                ),
                path: parent.appending(directoryName)
            )
        }
        // By provider first, then by label — not by label alone. Once a second account puts the
        // account at the *front* of the label, sorting on the label would file a Google row under
        // its email address and split one provider's accounts across the section.
        return mounts.sorted { lhs, rhs in
            let providers = providerName(lhs.providerID)
                .localizedStandardCompare(providerName(rhs.providerID))
            if providers != .orderedSame { return providers == .orderedAscending }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Splits `GoogleDrive-someone@gmail.com` into its provider and its account.
    ///
    /// The split is at the **first** hyphen, which matters: a Google account label is an email
    /// address and those routinely contain hyphens (`some-one@gmail.com`), so splitting at the
    /// last one would hand back a truncated address and a provider that is not one. The
    /// assumption this does rest on is that no provider's own name contains a hyphen — true of
    /// every client that ships one of these folders today.
    static func split(directoryName: String) -> (providerID: String, accountLabel: String?) {
        guard let hyphen = directoryName.firstIndex(of: "-") else { return (directoryName, nil) }
        let account = String(directoryName[directoryName.index(after: hyphen)...])
        return (String(directoryName[..<hyphen]), account.isEmpty ? nil : account)
    }

    /// The row's label: the provider's name, or — when a second account of the same provider
    /// would otherwise make two rows identical — the **account first**, then the provider.
    ///
    /// Showing the account unconditionally would put an email address in the sidebar of the
    /// overwhelmingly common one-account setup, where it distinguishes nothing.
    ///
    /// The order is the part that was got wrong first and only a screenshot caught: the obvious
    /// spelling, `Google Drive (someone@gmail.com)`, renders in a sidebar narrow enough to tail-
    /// truncate, so two accounts both came out as the *same* string — "Google Drive (ol…". The
    /// disambiguator has to sit where truncation cannot eat it. Google's own aliases in the home
    /// folder are named this way too (`someone@gmail.com - Google Drive`), so the shape is theirs
    /// rather than invented.
    static func displayName(
        providerID: String,
        accountLabel: String?,
        isAmbiguous: Bool
    ) -> String {
        let provider = providerName(providerID)
        guard isAmbiguous, let accountLabel else { return provider }
        return "\(accountLabel) — \(provider)"
    }

    /// How the provider writes its own name, given the spelling it uses for its folder.
    static func providerName(_ providerID: String) -> String {
        providerNames[providerID] ?? providerID
    }

    /// Providers whose directory name is not how the product is written.
    ///
    /// Only one entry, and that is the point rather than an omission: `Dropbox`, `OneDrive` and
    /// `Box` all name their folder exactly as they name themselves, so falling back to the raw
    /// prefix is *correct* for them, not a degradation. Google is the exception — its folder is
    /// `GoogleDrive`, and the product is "Google Drive".
    private static let providerNames = ["GoogleDrive": "Google Drive"]

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
