import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// The AppKit half of "Open With" (PLAN.md §M6): supplies `OpenWithApplications` with real
/// LaunchServices answers and launches the app the user picks. The *rule* — which apps can open a
/// whole selection, which one is promoted, what order they sit in — lives in the core and has
/// tests; this is the thin shell over it, the same split as `ExternalDiffLauncher`.
///
/// The core is keyed on **type identifiers rather than paths** because LaunchServices answers per
/// type: `urlsForApplications(toOpen: UTType)` returns exactly what the per-URL overload returns
/// for a file of that type (verified against both before this was written), and asking costs ~25x
/// what reading a file's type does. So a selection collapses to its distinct types first, and a
/// thousand marked photos ask LaunchServices once.
@MainActor
enum OpenWithLauncher {
    /// The applications that can open every one of `urls`.
    static func candidates(for urls: [URL]) -> OpenWithCandidates {
        OpenWithApplications.candidates(
            for: urls.map(\.path),
            typeOf: contentTypeIdentifier(ofFileAt:),
            applications: applications(forType:),
            defaultApplication: defaultApplication(forType:)
        )
    }

    /// Open `urls` in `application`, reporting a launch failure back on the main actor.
    ///
    /// All of the URLs go to **one** launch, not one launch each: that is what makes "Open With ▸
    /// Preview" on twelve images one Preview window with twelve tabs rather than twelve cold
    /// starts, and it is how a double-click in Finder behaves.
    static func open(
        _ urls: [URL],
        with application: ApplicationRef,
        completion: @escaping (Error?) -> Void
    ) {
        let bundleURL = URL(fileURLWithPath: application.bundlePath)
        // The `async` overload rather than the callback one: that callback is `@Sendable` and fires
        // off-main, so `completion` would have to cross isolation to reach it. This `Task` inherits
        // the main actor from the enclosing method, so the caller is answered where it can act —
        // the same shape `ExternalDiffLauncher` uses.
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    urls,
                    withApplicationAt: bundleURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// A menu-sized icon for an application.
    static func icon(for application: ApplicationRef) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: application.bundlePath)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - The LaunchServices probes the core is given

    /// A file's uniform type identifier, or `nil` when macOS can't type it — which is also what a
    /// file that has been deleted since the pane listed it answers. The core treats `nil` as "no
    /// application opens this", which is the safe reading of both cases.
    private static func contentTypeIdentifier(ofFileAt path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        return values?.contentType?.identifier
    }

    private static func applications(forType identifier: String) -> [ApplicationRef] {
        guard let type = UTType(identifier) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type).map(reference(to:))
    }

    private static func defaultApplication(forType identifier: String) -> ApplicationRef? {
        guard let type = UTType(identifier),
              let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return reference(to: url)
    }

    /// Describe an application bundle.
    ///
    /// The name comes from the bundle's own `CFBundleDisplayName`/`CFBundleName`, not from
    /// `localizedName` or `FileManager.displayName` — those answer "TextEdit.app", extension and
    /// all, whenever the user has Finder's hide-extensions off, and a menu of `.app` suffixes is
    /// not what Finder shows. Falling back to the bundle's filename minus its extension covers an
    /// app with no Info.plist name at all.
    static func reference(to bundleURL: URL) -> ApplicationRef {
        let bundle = Bundle(url: bundleURL)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return ApplicationRef(
            bundlePath: bundleURL.path,
            displayName: name,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }
}
