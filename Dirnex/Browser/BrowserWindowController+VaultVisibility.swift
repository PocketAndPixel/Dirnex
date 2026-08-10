import AppKit
import DirnexCore

/// Whether one vault's volume is visible to the rest of the Mac while it is unlocked
/// (``VaultLocation/showsInFinder``) — the sidebar's checked menu item, and what it does.
///
/// **Per vault, and off by default.** Dirnex attaches `-nobrowse` because a vault that silently
/// appears in every app's Open panel is not what "unlock it in my file manager" means. But that is
/// the right *default*, not the right rule for everyone's every vault: someone with scans of their
/// documents in one wants to attach them to an email, and the same person wants the other vault to
/// stay where they put it. A single switch in Settings would force one answer onto both, so the
/// answer lives on the vault.
///
/// The setting is stored rather than read back from the mount, because a locked vault has no volume
/// to ask — which is also what lets the menu draw its checkmark whatever state the vault is in.
extension BrowserWindowController {
    func sidebar(
        _ sidebar: SidebarViewController,
        didSet showsInFinder: Bool,
        asShowsInFinderFor vault: VaultLocation
    ) {
        setVaultShowsInFinder(showsInFinder, for: vault)
    }

    /// Save the setting, then make it true of the volume that is mounted right now, if there is one.
    ///
    /// The save comes first and unconditionally: it is the answer the next attach reads, so it must
    /// land whether or not the vault is currently open and whether or not the live remount works.
    /// `VaultStore` posts its change notification, which is what re-checks the menu item — in this
    /// window and in every other.
    func setVaultShowsInFinder(_ showsInFinder: Bool, for vault: VaultLocation) {
        VaultStore.setShowsInFinder(showsInFinder, for: vault)
        guard let point = DiskImageMount.isMounted(
            imageAtPath: vault.imagePath,
            in: DiskImageRunner.attachedImages()
        ) else {
            // Locked. Nothing to remount, and nothing to say: the vault will come up the way it was
            // just asked to the next time it is unlocked.
            return
        }

        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            let change = await Task.detached(priority: .userInitiated) {
                DiskImageRunner.setVisibility(mountPoint: point, showingInFinder: showsInFinder)
            }.value
            guard change == .takesEffectOnNextUnlock else { return }
            self?.presentDeferredVisibility(showsInFinder, name: vault.volumeName)
        }
    }

    /// The volume could not be remounted in place — it is read-only, or `mount` refused for its own
    /// reasons — so say so rather than letting the user watch Finder not change.
    ///
    /// This is the quiet-failure direction the rest of this project keeps finding: the checkmark is
    /// on, the setting really is saved, the vault really will come up that way next time, and
    /// *nothing on screen* would otherwise connect those facts to the sidebar that did not move. The
    /// alert is only raised in this branch; the ordinary case changes Finder within the same second
    /// and needs no confirmation.
    private func presentDeferredVisibility(_ showsInFinder: Bool, name: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = showsInFinder
            ? String(
                localized: "“\(name)” will appear in Finder the next time you unlock it.",
                comment: """
                Title shown when a vault's volume could not be made visible while it is already \
                mounted; %@ is the vault's volume name.
                """
            )
            : String(
                localized: "“\(name)” will be hidden from Finder the next time you unlock it.",
                comment: """
                Title shown when a vault's volume could not be hidden while it is already mounted; \
                %@ is the vault's volume name.
                """
            )
        alert.informativeText = String(
            localized: """
            The setting is saved. This vault’s volume can’t be changed while it is open — locking \
            and unlocking it will apply the change.
            """,
            comment: "Body of the alert explaining that a vault visibility change is deferred."
        )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
