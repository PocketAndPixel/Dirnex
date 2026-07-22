import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// The AppKit half of F4 "Edit" (PLAN.md §M11): supplies `ExternalTextEditor` with real
/// LaunchServices answers and opens the file in whatever comes back. The *rule* — which editor,
/// in what order, and what "Automatic" means — is the pure, tested core type; this is the thin
/// shell over it, the same split as `ExternalDiffLauncher` and `OpenWithLauncher`.
///
/// Resolution is cheap enough to run live on every menu validation: measured warm, the plain-text
/// handler costs ~20 µs and a bundle-identifier lookup ~2 µs, so nothing here is cached and the
/// menu can name the editor it would actually open without a staleness class of bug.
@MainActor
enum ExternalTextEditorLauncher {
    /// The application F4 would hand a file to, or `nil` when nothing resolves — the user's
    /// Settings choice while it is still installed, else the system's plain-text handler. Cheap,
    /// so callers use it to title and enable the menu item as well as to launch.
    static func preferredEditor() -> ApplicationRef? {
        let chosen = AppPreferences.shared.textEditorIdentifier
        return ExternalTextEditor.resolve(
            identifier: chosen.isEmpty ? nil : chosen,
            locateBundle: bundlePath(forIdentifier:),
            defaultPlainTextApplication: defaultPlainTextApplication
        )
    }

    /// Every known editor actually installed, in preference order — the list the Settings picker
    /// offers beneath "Automatic".
    static func installedEditors() -> [ExternalTextEditor] {
        ExternalTextEditor.installed(locateBundle: bundlePath(forIdentifier:))
    }

    /// What **Automatic** resolves to right now, ignoring whatever the user has chosen — so the
    /// picker's "Automatic (TextEdit)" row stays true while another row is selected, which is
    /// exactly when nothing else on screen says what that row means.
    static func automaticEditor() -> ApplicationRef? {
        ExternalTextEditor.resolve(
            identifier: nil,
            locateBundle: bundlePath(forIdentifier:),
            defaultPlainTextApplication: defaultPlainTextApplication
        )
    }

    /// Open `url` in the preferred editor, reporting a launch failure back on the main actor.
    /// `nil` in the completion is success; the editor that was launched is reported alongside so
    /// the caller can name it in a status line.
    static func edit(
        _ url: URL,
        completion: @escaping (ApplicationRef?, Error?) -> Void
    ) {
        guard let editor = preferredEditor() else {
            completion(nil, nil)
            return
        }
        OpenWithLauncher.open([url], with: editor) { error in
            completion(editor, error)
        }
    }

    // MARK: - The LaunchServices probes the core is given

    private static func bundlePath(forIdentifier identifier: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.path
    }

    /// What macOS opens a `.txt` with. Deliberately the handler for **plain text** rather than for
    /// the file's own type: F4 means "edit this as text", while opening a file in whatever owns its
    /// extension is what Enter already does.
    private static func defaultPlainTextApplication() -> ApplicationRef? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else { return nil }
        return OpenWithLauncher.reference(to: url)
    }
}
