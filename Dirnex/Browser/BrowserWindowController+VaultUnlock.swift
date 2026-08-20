import AppKit
import DirnexCore

/// Unlocking and locking a vault (PLAN.md §M19 Slice 2) — the sidebar's two gestures, and the two
/// commands that do the same thing from the keyboard.
///
/// **A vault introduces no new backend.** Unlocked it is a mounted volume, which `LocalBackend`
/// already browses, so everything below is about *reaching* a directory rather than about a new kind
/// of place — which is what keeps it clear of the trap docs/NOTES.md records for backends that are
/// places ("a new backend has to be named at every site that lists the old ones, and the compiler
/// checks none of them").
extension BrowserWindowController {
    // MARK: - Sidebar

    func sidebar(_ sidebar: SidebarViewController, didActivateVault vault: VaultLocation) {
        openVault(vault)
    }

    func sidebar(_ sidebar: SidebarViewController, didRequestLockOf vault: VaultLocation) {
        lock(vault)
    }

    // MARK: - Panes

    func panelRequestsVaultOpen(_ vault: VaultLocation, showingIn pane: PanelViewController) {
        openVault(vault, showingIn: pane)
    }

    // MARK: - Commands

    /// Unlock the vault image under the cursor — how an image that is not in the sidebar yet gets
    /// opened, and how it gets *into* the sidebar.
    @objc func unlockVault(_ sender: Any?) {
        guard let entry = vaultImageUnderCursor else { return }
        openVault(
            VaultLocation(
                imagePath: entry.path.path,
                // Nothing can be asked of a locked image — the volume name lives inside the
                // encrypted filesystem — so the file's own name stands in until an attach reports
                // the real mount, which is where `openVault` corrects it.
                volumeName: (entry.name as NSString).deletingPathExtension
            )
        )
    }

    /// Lock the vault the focused pane is standing in. The gesture for "I'm done here", which is why
    /// it takes no target: the vault you are looking at is the one you mean.
    @objc func lockVault(_ sender: Any?) {
        guard let vault = vaultContainingFocusedPane else { return }
        lock(vault)
    }

    /// The image under the cursor, if it is one — a `.sparsebundle` or a `.dmg` in a real local
    /// pane. Also what the menu item and the palette entry gate on, so the command is grayed rather
    /// than silently doing nothing.
    var vaultImageUnderCursor: FileEntry? {
        guard focusedPanel.panel.path.backend == .local, !focusedPanel.isVirtualDirectory,
              let entry = focusedPanel.panel.currentEntry,
              DiskImageArguments.Kind.isImageName(entry.name) else { return nil }
        return entry
    }

    /// The saved vault whose volume the focused pane is inside, if any.
    ///
    /// Two free conditions come first, and they are load-bearing rather than tidy: this is what the
    /// Lock menu item validates on, so it runs for **every menu open**, and the real answer costs a
    /// `hdiutil` spawn (measured at 12–14 ms). A vault is attached without `-mountpoint`, so its
    /// volume is always under `/Volumes`; a pane anywhere else, or a user with no vaults at all,
    /// is answered without spawning anything.
    var vaultContainingFocusedPane: VaultLocation? {
        guard focusedPanel.panel.path.backend == .local else { return nil }
        let here = focusedPanel.panel.path.path
        guard here.hasPrefix("/Volumes/"), !VaultStore.load().vaults.isEmpty else { return nil }
        let attached = DiskImageRunner.attachedImages()
        return VaultStore.load().vaults.first { vault in
            guard let point = DiskImageMount.isMounted(
                imageAtPath: vault.imagePath,
                in: attached
            ) else { return false }
            return isPath(here, inside: point)
        }
    }

    // MARK: - Unlock

    /// Open `vault` in `pane`, unlocking it first if it is locked.
    ///
    /// One entry point for the sidebar click, the command and the just-created vault, because the
    /// user's intent is identical in all three — *show me what is in there* — and the lock state is
    /// a fact to look up rather than a mode the caller should have to know.
    func openVault(
        _ vault: VaultLocation,
        with passphrase: ArchivePassphrase? = nil,
        showingIn pane: PanelViewController? = nil
    ) {
        let destination = pane ?? focusedPanel
        withUnlockedVault(vault, using: passphrase) { [weak destination] point in
            destination?.navigate(to: .local(point))
            destination?.focusTable()
        }
    }

    /// Make sure `vault` is unlocked, then hand `body` the mount point it landed on.
    ///
    /// The unlock funnel itself, with the navigation lifted out of it — because Rename needs a vault
    /// open without the pane going anywhere. The user asked to rename it, not to browse it, and a
    /// pane that jumped into the vault would be the gesture answering a question nobody asked.
    ///
    /// `body` runs only on success: a cancelled passphrase prompt, or a failure that has already
    /// raised its own alert, simply ends here.
    func withUnlockedVault(
        _ requested: VaultLocation,
        using passphrase: ArchivePassphrase? = nil,
        then body: @escaping @MainActor (String) -> Void
    ) {
        // Resolve against the store before anything else. Two entry points *construct* a
        // `VaultLocation` from a file under the cursor — the Unlock command and the pane's Enter —
        // and such a value carries the defaults for everything that is not addressing: today
        // `showsInFinder`, tomorrow whatever else a vault remembers. Since a successful attach ends
        // in `VaultStore.remember`, which replaces the saved entry wholesale, unlocking a vault from
        // the pane rather than from the sidebar would silently reset its settings. One line here
        // covers every caller; correcting it inside `remember` would instead make the setting
        // impossible to turn back off.
        let vault = VaultStore.load().vault(atPath: requested.imagePath) ?? requested
        if let point = DiskImageMount.isMounted(
            imageAtPath: vault.imagePath,
            in: DiskImageRunner.attachedImages()
        ) {
            body(point)
            return
        }
        if let passphrase {
            attach(vault, with: passphrase, retrying: false, then: body)
            return
        }
        // A passphrase filed in the Keychain is tried silently first — that is what "Dirnex saves it
        // so this Mac won't ask again" in the create sheet promises — and a refusal falls through to
        // the prompt rather than to an error, since a stale item is exactly what a re-created vault
        // at the same path leaves behind.
        if let stored = SecretKeychain.passphrase(for: vault) {
            attach(vault, with: stored, retrying: false, isStored: true, then: body)
            return
        }
        askAndAttach(vault, retrying: false, then: body)
    }

    private func askAndAttach(
        _ vault: VaultLocation,
        retrying: Bool,
        then body: @escaping @MainActor (String) -> Void
    ) {
        PassphrasePrompt.ask(
            forItemNamed: vault.volumeName,
            retrying: retrying,
            over: window
        ) { [weak self] passphrase in
            guard let self, let passphrase else { return }
            attach(vault, with: passphrase, retrying: true, then: body)
        }
    }

    /// The attach itself. `isStored` says the passphrase came from the Keychain, which changes only
    /// what a refusal means: the user typed nothing, so they are asked rather than told they were
    /// wrong.
    private func attach(
        _ vault: VaultLocation,
        with passphrase: ArchivePassphrase,
        retrying: Bool,
        isStored: Bool = false,
        then body: @escaping @MainActor (String) -> Void
    ) {
        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        let imagePath = vault.imagePath
        let showsInFinder = vault.showsInFinder
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            do {
                let mounted = try await BlockingWork.run {
                    Result {
                        try DiskImageRunner.attach(
                            atPath: imagePath,
                            passphrase: passphrase,
                            showingInFinder: showsInFinder
                        )
                    }
                }.get()
                guard let self else { return }
                // The volume's real name is only knowable once it is mounted, so this is where a
                // vault opened from the pane (named after its file) gets the name it will keep.
                var opened = vault
                opened.volumeName = (mounted.mountPoint as NSString).lastPathComponent
                // Before the navigation below, not after: `navigate` records a frecency visit, and
                // the whole point of `VaultPrivacy` is that this one must not be recorded. Waiting
                // for the mount notification would lose the race with our own next line.
                VaultMounts.shared.note(mountPoint: mounted.mountPoint)
                VaultStore.remember(opened)
                SecretKeychain.store(passphrase: passphrase, for: opened)
                body(mounted.mountPoint)
            } catch VaultError.incorrectPassphrase {
                // A typo, not a dead end. A refused *stored* passphrase asks for the first time.
                self?.askAndAttach(vault, retrying: retrying && !isStored, then: body)
            } catch {
                self?.presentVaultError((error as? VaultError) ?? .couldNotUnlock)
            }
        }
    }

    // MARK: - Lock

    /// Unmount `vault`, moving any pane standing inside it out first.
    ///
    /// The move has to happen **before** the detach, in every tab of both panes: a pane left pointing
    /// into a volume that no longer exists lists nothing, and the user's way back — the `..` row —
    /// leads through a directory that is gone. They go to the folder holding the vault file, which is
    /// where the vault appears from their point of view.
    private func lock(_ vault: VaultLocation) {
        guard let point = DiskImageMount.isMounted(
            imageAtPath: vault.imagePath,
            in: DiskImageRunner.attachedImages()
        ) else {
            // Already locked. Nothing to say — the row redraws shut, which is the whole answer.
            sidebar.rebuild()
            return
        }
        let home = (vault.imagePath as NSString).deletingLastPathComponent
        for pane in [leftPanel, rightPanel] where isPath(pane.panel.path.path, inside: point) {
            pane.navigate(to: .local(home), focus: .local(vault.imagePath))
        }

        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        let name = vault.volumeName
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            do {
                try await BlockingWork.run {
                    Result {
                        try DiskImageRunner.detach(mountPoint: point, name: name)
                    }
                }.get()
                self?.forgetVaultContents(under: point)
                self?.sidebar.rebuild()
            } catch {
                self?.presentVaultError((error as? VaultError) ?? .couldNotLock)
            }
        }
    }

    /// A vault has just locked: nothing Dirnex keeps implicitly may still name what was in it
    /// (PLAN.md §M19 / ``VaultPrivacy``).
    ///
    /// Both stores are guarded on the way *in* as well, so on the ordinary path there is nothing
    /// here to remove and both calls are no-ops. This is the second wall, for the case the guard
    /// cannot cover: an image unlocked outside Dirnex, browsed in the window between the mount and
    /// the notification that reports it. Re-persisting the panes is what rewrites a tab list saved
    /// while the vault was open — they have already been navigated out, above.
    private func forgetVaultContents(under mountPoint: String) {
        VaultMounts.shared.forget(mountPoint: mountPoint)
        FrecencyStore.shared.forget(pathsUnder: mountPoint)
        leftPanel.persistState()
        rightPanel.persistState()
    }

    /// Whether `path` is `mountPoint` or somewhere under it — ``VaultPrivacy/isInside(_:mountPoints:)``
    /// under this file's own name, so the pane-eviction rule and the privacy rule cannot drift into
    /// two different answers to one question (the trap docs/NOTES.md keeps finding: one rule, two
    /// spellings, and the compiler checks neither).
    private func isPath(_ path: String, inside mountPoint: String) -> Bool {
        VaultPrivacy.isInside(path, mountPoints: [mountPoint])
    }
}
