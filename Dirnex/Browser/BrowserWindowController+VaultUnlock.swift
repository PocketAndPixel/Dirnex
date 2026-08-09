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
    /// pane. Also what the menu item and the palette entry gate on, so the command is greyed rather
    /// than silently doing nothing.
    var vaultImageUnderCursor: FileEntry? {
        guard focusedPanel.panel.path.backend == .local, !focusedPanel.isVirtualDirectory,
              let entry = focusedPanel.panel.currentEntry else { return nil }
        let suffix = (entry.name as NSString).pathExtension.lowercased()
        guard DiskImageArguments.Kind.allCases.contains(where: { $0.pathExtension == suffix })
        else { return nil }
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
        if let point = DiskImageMount.isMounted(
            imageAtPath: vault.imagePath,
            in: DiskImageRunner.attachedImages()
        ) {
            destination.navigate(to: .local(point))
            destination.focusTable()
            return
        }
        if let passphrase {
            attach(vault, with: passphrase, showingIn: destination, retrying: false)
            return
        }
        // A passphrase filed in the Keychain is tried silently first — that is what "Dirnex saves it
        // so this Mac won't ask again" in the create sheet promises — and a refusal falls through to
        // the prompt rather than to an error, since a stale item is exactly what a re-created vault
        // at the same path leaves behind.
        if let stored = SecretKeychain.passphrase(for: vault) {
            attach(vault, with: stored, showingIn: destination, retrying: false, isStored: true)
            return
        }
        askAndAttach(vault, showingIn: destination, retrying: false)
    }

    private func askAndAttach(
        _ vault: VaultLocation,
        showingIn pane: PanelViewController,
        retrying: Bool
    ) {
        PassphrasePrompt.ask(
            forItemNamed: vault.volumeName,
            retrying: retrying,
            over: window
        ) { [weak self] passphrase in
            guard let self, let passphrase else { return }
            attach(vault, with: passphrase, showingIn: pane, retrying: true)
        }
    }

    /// The attach itself. `isStored` says the passphrase came from the Keychain, which changes only
    /// what a refusal means: the user typed nothing, so they are asked rather than told they were
    /// wrong.
    private func attach(
        _ vault: VaultLocation,
        with passphrase: ArchivePassphrase,
        showingIn pane: PanelViewController,
        retrying: Bool,
        isStored: Bool = false
    ) {
        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        let imagePath = vault.imagePath
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            do {
                let mounted = try await Task.detached(priority: .userInitiated) {
                    try DiskImageRunner.attach(atPath: imagePath, passphrase: passphrase)
                }.value
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
                pane.navigate(to: .local(mounted.mountPoint))
                pane.focusTable()
            } catch VaultError.incorrectPassphrase {
                // A typo, not a dead end. A refused *stored* passphrase asks for the first time.
                self?.askAndAttach(vault, showingIn: pane, retrying: retrying && !isStored)
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
                try await Task.detached(priority: .userInitiated) {
                    try DiskImageRunner.detach(mountPoint: point, name: name)
                }.value
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
