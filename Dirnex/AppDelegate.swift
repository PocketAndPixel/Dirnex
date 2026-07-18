import AppKit

/// Application lifecycle owner.
///
/// Brings up the dual-pane browser window (M1) and installs the registry-driven main menu
/// (M3) so the app behaves like a real macOS citizen. The Cmd+K command palette is owned
/// here too, since it floats over whichever window is key and dispatches through the
/// responder chain.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserWindowController: BrowserWindowController?
    private let commandPalette = CommandPaletteController()

    /// The browser window an AppleScript verb acts on: the key window's controller when it is a
    /// browser, otherwise the one built at launch. The scripting command handlers
    /// (`ScriptingCommands.swift`) reach the active panel through here rather than the palette's
    /// responder chain, since an Apple event arrives with no key window guaranteed.
    var activeBrowserWindowController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? browserWindowController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenuBuilder.build()

        // Tell the Services system what a pane can hand a Service (PLAN.md §M6): file URLs, and
        // nothing coming back. Without this the Services menu is built without ever asking the
        // responder chain, so it would list nothing our selection could feed — the registration is
        // what makes AppKit ask `PanelViewController.validRequestor` at all.
        NSApp.registerServicesMenuSendTypes([.fileURL], returnTypes: [])

        // Clear any archive copy-out temp files and rewrite scratch dirs left by a previous session
        // (PLAN.md §M4 F5 copy-out / F8 delete). Safe here — nothing is extracting or rewriting yet,
        // so there's no in-flight operation to race.
        ArchiveExtractor.purgeTemporaries()
        ArchiveWriter.purgeTemporaries()

        // Rebuild the registry-driven menu whenever the user rebinds a shortcut, so the new
        // key equivalents take effect immediately (PLAN.md §M3 "rebindable shortcuts").
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMainMenu),
            name: KeyBindingStore.didChange,
            object: nil
        )

        let controller = BrowserWindowController()
        controller.showWindow(nil)
        browserWindowController = controller

        NSApp.activate(ignoringOtherApps: true)

        // First-run onboarding, in order (PLAN.md §M7): a fresh install gets the palette-centric
        // tour, and only then the Full Disk Access prompt — the presenter chains the two so the
        // welcome comes before the permission wall. On later launches the tour is skipped and the
        // FDA check runs directly; both are one-shots the user can re-open from the app menu/palette.
        FirstRunTourPresenter.presentIfNeeded(over: controller.window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Unmount only the SMB shares *we* mounted, leaving any Finder-mounted share as the user had it
    /// (PLAN.md §M5 "unmount only what we mounted on disconnect/quit"), and hang up the terminal
    /// drawer's shell (PLAN.md §M6) rather than leave it reparented to launchd.
    func applicationWillTerminate(_ notification: Notification) {
        SMBMounter.shared.unmountOwnedMounts()
        browserWindowController?.terminateTerminalShell()
    }

    @objc private func rebuildMainMenu() {
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    // MARK: - Command palette

    /// ⌘K (and View ▸ Command Palette…) — open the fuzzy command palette over the key window,
    /// or close it if it is already showing. Reached through the responder chain: the app
    /// delegate is its final link, so a menu item with a nil target lands here.
    @objc func showCommandPalette(_ sender: Any?) {
        commandPalette.toggle(over: NSApp.keyWindow ?? browserWindowController?.window)
    }

    // MARK: - Settings

    /// ⌘, (and the palette's "Settings…") — open the SwiftUI settings window. Reached through
    /// the responder chain, with the app delegate as its final link.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    // MARK: - Full Disk Access

    /// App menu ▸ "Full Disk Access…" (and the palette command) — re-open the onboarding prompt on
    /// demand (PLAN.md §M7), whatever the current grant state. Reached through the responder chain,
    /// with the app delegate as its final link.
    @objc func showFullDiskAccess(_ sender: Any?) {
        FullDiskAccessOnboarding.present(over: NSApp.keyWindow ?? browserWindowController?.window)
    }

    // MARK: - First-run tour

    /// App menu ▸ "Welcome to Dirnex…" (and the palette command) — re-open the first-run tour on
    /// demand (PLAN.md §M7), whatever the launch latch says. Reached through the responder chain,
    /// with the app delegate as its final link.
    @objc func showFirstRunTour(_ sender: Any?) {
        FirstRunTourPresenter.present(over: NSApp.keyWindow ?? browserWindowController?.window)
    }
}
