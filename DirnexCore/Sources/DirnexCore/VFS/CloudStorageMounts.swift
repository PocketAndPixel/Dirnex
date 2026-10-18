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
    /// mounts one unlabeled folder.
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
    public var symbolName: String { Self.symbolName }

    /// The same glyph, for a surface that knows a location is inside *some* mount without holding
    /// the mount: a tab chip names the kind of source, which this one symbol already is.
    public static let symbolName = "cloud"
}

/// Finds the cloud provider mounts on this Mac by reading `~/Library/CloudStorage`.
///
/// Every File Provider-based sync client macOS 12+ hosts puts its folder here under a
/// `<Provider>-<account>` name, so one scan covers Google Drive and everything alongside it.
/// The scan is deliberately provider-agnostic: recognizing only `GoogleDrive-*` would be the
/// same code with a narrower answer, and would need rewriting the first time Dropbox is
/// installed.
///
/// Not every directory there is a mount, though: a sync client that sets its domain up again can
/// leave the old folder behind, renamed and no longer synced (▸ ``domainMarkerAttribute``).
public enum CloudStorageMounts {
    /// `~/Library/CloudStorage`, the parent of every provider mount.
    ///
    /// Unlike `~/Library/Mobile Documents`, this directory lists **without** Full Disk Access
    /// (probed 2026-07-21) — it is not TCC-gated, so the Cloud section fills in on a Mac that has
    /// never seen the onboarding sheet.
    public static func cloudStorage(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home).appending("Library").appending("CloudStorage")
    }

    /// Whether `path` is `~/Library/CloudStorage` or anything inside it — a pure string test, no
    /// I/O, so it is free to ask on an error path.
    ///
    /// **This is the "is a macOS grant even relevant here" question**, which is why it names the
    /// directory rather than a mount: a refusal on `CloudStorage` itself is as far outside TCC's
    /// reach as one three levels into somebody's Drive. Full Disk Access does not gate this tree
    /// (probed 2026-07-21, ▸ ``cloudStorage(home:)``), so a permission failure here is the sync
    /// client's answer about the account's own sharing and **not** something System Settings can
    /// change — the same "a sentence naming a remedy on *this machine* is making a claim about
    /// where the failure happened" rule that already splits the remote case (PLAN.md §M26 Slice 3).
    ///
    /// Deliberately **not** ``TrashLanding/providerRoots``, which lists this directory alongside
    /// `~/Library/Mobile Documents` because both refuse `FileManager.trashItem`. They are opposites
    /// for *this* question: `Mobile Documents` is TCC-gated, so Full Disk Access is exactly the
    /// right advice for an iCloud path and exactly the wrong advice for a `CloudStorage` one. One
    /// pair of roots, two questions, and only a name keeps them from being merged.
    public static func isInsideCloudStorage(
        _ path: VFSPath,
        home: String = NSHomeDirectory()
    ) -> Bool {
        path.backend == .local && path.isSelfOrDescendant(of: cloudStorage(home: home))
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
    /// reach the network, and the path bar rebuilds on every navigation) — plus one `getxattr` per
    /// directory there, 9–16 µs each (▸ ``carriesDomainMarker(atPath:)``).
    ///
    /// A folder a sync client left behind is not a mount, so a path inside one answers `nil` and the
    /// path bar draws its real crumbs rather than a provider name it no longer has.
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
    ///
    /// Leftover folders are dropped here, ahead of the naming, so every caller gets the same answer:
    /// no sidebar row, no provider name in the path bar, no trash merged into the Trash, and no
    /// second account for the disambiguation to count (▸ ``domainRoots(_:in:_:)``). `domainMarker`
    /// is the seam a test uses for the read that fails, which a real directory cannot produce on
    /// demand.
    static func named(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        domainMarker: (String) -> Bool? = carriesDomainMarker(atPath:)
    ) -> [CloudStorageMount] {
        let parent = cloudStorage(home: home)
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else {
            return []
        }

        // Two passes, because a mount's *name* cannot be decided from the mount alone: the
        // account is shown only when a second mount of the same provider makes it load-bearing.
        let directoryNames = domainRoots(
            names.filter { !$0.hasPrefix(".") && isDirectory(parent.appending($0).path, fileManager) },
            in: parent,
            domainMarker
        )

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

    /// The attribute macOS writes on the root directory of every File Provider domain under
    /// `~/Library/CloudStorage`. Its value is `<extension bundle id>/<domain id>`, e.g.
    /// `com.getdropbox.dropbox.fileprovider/358400b9-…`.
    ///
    /// **A folder without it is one a sync client left behind**, and Finder does not show it.
    /// Found 2026-10-18: Dropbox set its domain up again as `Dropbox` and left
    /// `Dropbox-Home (18.10.2026 00:09)` beside it, renamed and no longer synced, which the scan
    /// listed as a second account and named "Home (18.10.2026 00:09) — Dropbox". The leftover still
    /// carries Dropbox's own `com.dropbox.*` attributes, so only this one tells them apart. Measured
    /// on macOS 26 against all six directories on this Mac: Box, Dropbox, OneDrive and both Google
    /// Drive accounts (one streaming, one mirror) carry it, the leftover does not, and
    /// `fileproviderctl dump` registers exactly one Dropbox domain.
    static let domainMarkerAttribute = "com.apple.file-provider-domain-id"

    /// Whether the directory at `path` is a File Provider domain's root: `true` when it carries
    /// ``domainMarkerAttribute``, `false` when the read says it does not (`ENOATTR`), `nil` when the
    /// read itself failed.
    ///
    /// Cheap and ungated, which is what lets ``named(home:fileManager:domainMarker:)`` ask it of
    /// every directory on every path bar rebuild. Probed 2026-10-18 from an ad-hoc-signed app
    /// launched through LaunchServices, with no Full Disk Access (`~/Library/Mail` refused it
    /// `EPERM`): no prompt, and a median of 9–16 µs per directory against the 650–1000 µs a resource
    /// read inside a domain costs (docs/NOTES.md ▸ Google Drive). Only the size is asked for. The
    /// value is not needed, and the attribute is on the directory itself, so no provider is asked
    /// anything. `XATTR_NOFOLLOW`, as everywhere else (docs/NOTES.md ▸ Extended attributes): a
    /// symlink placed in `CloudStorage` is not a domain root, whatever it points at.
    static func carriesDomainMarker(atPath path: String) -> Bool? {
        if getxattr(path, domainMarkerAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
        return errno == ENOATTR ? false : nil
    }

    /// `directoryNames` without the folders a sync client left behind, in the same order.
    ///
    /// Two guards keep it from hiding a real account. Erring the other way is cheap: a stale row
    /// costs a confusing name, while a missing account leaves the user no way to their files from
    /// the sidebar.
    ///
    /// - **Nothing is dropped unless some directory carries the marker.** The package targets
    ///   macOS 14, and the marker is measured only on 26. On a system that does not write it, every
    ///   directory reads `false`, and without this guard the whole section would go empty. With it,
    ///   such a Mac keeps the listing it had before the filter existed.
    /// - **Only a definite `false` drops a directory.** A read that failed (`nil`) is not evidence
    ///   that the folder is no domain, so it stays.
    static func domainRoots(
        _ directoryNames: [String],
        in parent: VFSPath,
        _ domainMarker: (String) -> Bool?
    ) -> [String] {
        let markers = directoryNames.map { domainMarker(parent.appending($0).path) }
        guard markers.contains(true) else { return directoryNames }
        return zip(directoryNames, markers).compactMap { name, marker in marker == false ? nil : name }
    }

    /// Splits `GoogleDrive-someone@gmail.com` into its provider and its account.
    ///
    /// The fallback split is at the **first** hyphen, which matters: a Google account label is an
    /// email address and those routinely contain hyphens (`some-one@gmail.com`), so splitting at
    /// the last one would hand back a truncated address and a provider that is not one.
    ///
    /// That rule alone assumes no provider's own name contains a hyphen, and OneDrive breaks it:
    /// it mounts a SharePoint document library as `OneDrive-SharedLibraries-<tenant>`, where the
    /// first hyphen falls *inside* the provider's name. Taking it there yields the account
    /// `SharedLibraries-Contoso`, which reaches the sidebar two ways and is wrong both times — as a
    /// bare "OneDrive" when it is the only OneDrive-family mount (it is not the user's own drive),
    /// and otherwise as an internal English token in a sidebar that ships in fourteen languages.
    ///
    /// So a known provider id wins over the hyphen, longest first — `OneDrive-SharedLibraries`
    /// before `OneDrive`, which is the whole reason the order matters. Everything not in the table
    /// falls back to the hyphen exactly as before.
    static func split(directoryName: String) -> (providerID: String, accountLabel: String?) {
        for providerID in knownProviderIDs where directoryName.hasPrefix("\(providerID)-") {
            let account = String(directoryName.dropFirst(providerID.count + 1))
            return (providerID, account.isEmpty ? nil : account)
        }
        guard let hyphen = directoryName.firstIndex(of: "-") else { return (directoryName, nil) }
        let account = String(directoryName[directoryName.index(after: hyphen)...])
        return (String(directoryName[..<hyphen]), account.isEmpty ? nil : account)
    }

    /// The provider ids that must be matched whole rather than cut at the first hyphen, longest
    /// first so a prefix never shadows the longer id it is a prefix *of*.
    private static let knownProviderIDs = providerNames.keys.sorted { $0.count > $1.count }

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
    /// Deliberately short: `Dropbox`, `OneDrive` and `Box` all name their folder exactly as they
    /// name themselves, so falling back to the raw prefix is *correct* for them, not a degradation.
    /// Two are not. Google's folder is `GoogleDrive` and the product is "Google Drive"; and
    /// `OneDrive-SharedLibraries-<tenant>` is not OneDrive at all but a SharePoint document
    /// library, which is a different product the user reaches for by a different name.
    ///
    /// These are brand names and are never translated, which is what makes the table the right
    /// home for them rather than the string catalog — the same rule the section already follows by
    /// leaving "Dropbox" and "Box" untranslated.
    ///
    /// The table doubles as ``knownProviderIDs``, so an entry added here also stops being cut at
    /// its first hyphen. That is why `OneDrive` itself is absent: its folder name already reads
    /// correctly, and adding it would only shadow the longer id.
    private static let providerNames = [
        "GoogleDrive": "Google Drive",
        "OneDrive-SharedLibraries": "SharePoint"
    ]

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
