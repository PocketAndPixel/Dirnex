import AppKit
import DirnexCore

/// Whether an unlocked vault's volume is visible to the rest of the Mac — Finder's sidebar, the
/// desktop, every other app's Open panel — and what has to happen when that answer changes while
/// vaults are open.
///
/// **One app-wide preference, on by default** (`AppPreferences.showVaultsInFinder`, edited in
/// Settings ▸ General). It was a per-vault flag on a sidebar context menu until 2026-09-02; the
/// argument for that is written down where the preference now lives, along with what it cost.
///
/// The whole mechanism is `hdiutil`'s `-nobrowse`, decided at attach time — so the preference alone
/// would take effect at the *next* unlock, and flipping it with a vault open would look like it did
/// nothing. That is the quiet-failure direction this project keeps finding, and it is why this type
/// exists: `mount -u -o browse` changes a mounted volume unprivileged, measured, so the vaults that
/// are open right now are remounted to match.
@MainActor
final class VaultVisibility: NSObject {
    static let shared = VaultVisibility()

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferenceChanged),
            name: AppPreferences.showVaultsInFinderDidChange,
            object: nil
        )
    }

    /// Touch the singleton at launch so it is observing before the Settings window can be opened.
    /// Nothing else builds it, so a lazy `shared` would simply never hear the first change.
    static func start() { _ = shared }

    @objc private func preferenceChanged() {
        apply(AppPreferences.shared.showVaultsInFinder)
    }

    /// Remount every vault that is unlocked right now, so Finder agrees with the setting the user
    /// just changed.
    ///
    /// The preference is already saved by the time this runs — it is what the next attach reads —
    /// so nothing here decides anything the user could lose. A vault that cannot be remounted in
    /// place is reported rather than retried: `hdiutil` has no verb for a volume already open, and
    /// the honest sentence is that the next unlock will honor it.
    func apply(_ showsInFinder: Bool) {
        let vaults = VaultStore.load()
        Task {
            let attached = await BlockingWork.run { DiskImageRunner.attachedImages() }
            let open = vaults.vaults.compactMap { vault in
                DiskImageMount.isMounted(imageAtPath: vault.imagePath, in: attached)
                    .map { (identity: vault.resolvedImagePath, mountPoint: $0) }
            }
            guard !open.isEmpty else { return }

            for vault in open { SidebarRowActivity.shared.begin(vault.identity) }
            defer { for vault in open { SidebarRowActivity.shared.end(vault.identity) } }

            let points = open.map(\.mountPoint)
            let changes = await BlockingWork.run {
                points.map {
                    DiskImageRunner.setVisibility(mountPoint: $0, showingInFinder: showsInFinder)
                }
            }
            guard changes.contains(.takesEffectOnNextUnlock) else { return }
            presentDeferredVisibility()
        }
    }

    /// At least one open volume could not be remounted — it is read-only, or `mount` refused for its
    /// own reasons — so say so rather than letting the user watch Finder not change.
    ///
    /// This is the quiet-failure direction the rest of this project keeps finding: the switch is on,
    /// the setting really is saved, those vaults really will come up that way next time, and
    /// *nothing on screen* would otherwise connect those facts to the Finder window that did not
    /// move. Raised only in this branch; the ordinary case changes Finder within the same second and
    /// needs no confirmation.
    ///
    /// It names no vault. Under a per-vault menu item the sentence could — there was exactly one
    /// vault in question — and under one app-wide switch there are as many as are open, so a name
    /// here would either be a plural nobody can translate cleanly or a list nobody asked for. The
    /// user changed one setting; they get one answer about it.
    private func presentDeferredVisibility() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "The change will apply the next time you unlock.",
            comment: """
            Title shown when a vault that is already unlocked could not be shown in or hidden from \
            Finder without being locked first.
            """
        )
        alert.informativeText = String(
            localized: """
            The setting is saved. A vault that is already open can’t always be changed while it is \
            mounted — locking and unlocking it applies the change.
            """,
            comment: "Body of the alert explaining that a vault visibility change is deferred."
        )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        // A user flipped a switch and is waiting to see it happen, so this keeps the `runModal`
        // fallback the "who is waiting?" rule reserves for that kind (docs/NOTES.md ▸ Testing).
        if let host = NSAlert.sheetHost(over: NSApp.keyWindow ?? NSApp.mainWindow) {
            alert.beginSheetModal(for: host)
        } else {
            alert.runModal()
        }
    }
}
