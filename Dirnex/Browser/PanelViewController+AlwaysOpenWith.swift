import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Open With ▸ Always Open “.m4v” Files With ▸ (2026-11-12): make an application the one macOS opens
/// every file of the selection's type with, which is Finder's Get Info ▸ Change All….
///
/// A submenu at the foot of Open With rather than a second command: it is the same list of
/// applications, reached the same way from the File menu and the right-click menu, and the
/// difference between opening these files once and opening every file like them is the one word
/// the submenu's title says. The rule for which files the change reaches is
/// `DefaultApplicationScope`'s, in the core.
///
/// **There is no confirmation here, because macOS asks.** Every change raised the system's own
/// "Do you want all documents with the extension “.m4v” to open with “VLC”, or to keep using
/// “TV”?" in the probes (`OpenWithLauncher.makeDefault`), so a question of ours first would be the
/// same question twice. Oleg's call, 2026-11-12.
///
/// **And the files are opened in the application once it is the default**, as Finder's Open With ▸
/// Other… with Always Open With ticked does: it is still Open With (Oleg, the same day). Through
/// Open With's own path, so a row on a server is brought down first. Keeping the old application
/// in macOS's dialog opens nothing: the user said no to the question the choice put.
extension PanelViewController {
    /// The submenu for `rows`, listing the same applications Open With does, or `nil` when the rows
    /// are not one document type.
    func alwaysOpenWithItem(for rows: [FileEntry], candidates: OpenWithCandidates) -> NSMenuItem? {
        guard let scope = OpenWithLauncher.defaultApplicationScope(for: rows) else { return nil }
        let menu = NSMenu()
        if let current = candidates.defaultApplication {
            // Ticked rather than left out, so the submenu also says what opens these files today.
            // Choosing it again asks nothing, changes nothing, and opens the files in it.
            let item = alwaysOpenWithItem(for: current, rows: rows, scope: scope)
            item.state = .on
            menu.addItem(item)
            if !candidates.others.isEmpty { menu.addItem(.separator()) }
        }
        for application in candidates.others {
            menu.addItem(alwaysOpenWithItem(for: application, rows: rows, scope: scope))
        }
        if !candidates.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(
            title: String(
                localized: "Other…",
                comment: "Open With menu item: pick an application by hand."
            ),
            action: #selector(alwaysOpenWithOther(_:)),
            keyEquivalent: ""
        )
        other.target = self
        other.representedObject = DefaultApplicationRequest(
            rows: rows,
            scope: scope,
            application: nil
        )
        menu.addItem(other)
        let item = NSMenuItem(
            title: Self.alwaysOpenWithTitle(for: scope),
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = menu
        return item
    }

    /// "Always Open “.m4v” Files With", or the type's own name when the rows' extensions differ.
    static func alwaysOpenWithTitle(for scope: DefaultApplicationScope) -> String {
        switch scope.name {
        case let .fileExtension(fileExtension):
            String(
                localized: "Always Open “.\(fileExtension)” Files With",
                comment: """
                Open With menu, submenu that makes an app the default for every file with this \
                extension; %@ is the extension without its dot, such as m4v.
                """
            )
        case .typeDescription:
            String(
                localized: "Always Open “\(Self.typeDescription(of: scope))” Files With",
                comment: """
                Open With menu, submenu that makes an app the default for every file of this type; \
                %@ is the type’s name, such as JPEG image.
                """
            )
        }
    }

    private static func typeDescription(of scope: DefaultApplicationScope) -> String {
        UTType(scope.typeIdentifier)?.localizedDescription ?? scope.typeIdentifier
    }

    private func alwaysOpenWithItem(
        for application: ApplicationRef,
        rows: [FileEntry],
        scope: DefaultApplicationScope
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: application.displayName,
            action: #selector(alwaysOpenWith(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = DefaultApplicationRequest(
            rows: rows,
            scope: scope,
            application: application
        )
        item.image = OpenWithLauncher.icon(for: application)
        return item
    }

    @objc private func alwaysOpenWith(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? DefaultApplicationRequest,
              let application = request.application else { return }
        makeDefault(application, for: request)
    }

    /// Other… — any application, picked by hand, as Open With's own Other… does.
    @objc private func alwaysOpenWithOther(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? DefaultApplicationRequest else { return }
        let panel = NSOpenPanel()
        panel.title = String(
            localized: "Choose an Application",
            comment: "Open panel title for picking an app in Open With ▸ Other…"
        )
        panel.prompt = String(
            localized: "Choose",
            comment: """
            Open panel button for picking the app that opens a kind of file from now on, in \
            Open With ▸ Always Open … With ▸ Other…
            """
        )
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let choice = panel.url else { return }
            self?.makeDefault(OpenWithLauncher.reference(to: choice), for: request)
        }
    }

    /// Ask macOS to make the change, which puts its own question to the user, then open the files in
    /// the application and ask again for the type icons.
    ///
    /// The pane is held until macOS answers, which is as long as its dialog is up.
    private func makeDefault(_ application: ApplicationRef, for request: DefaultApplicationRequest) {
        Task {
            let error = await OpenWithLauncher.makeDefault(
                application,
                forType: request.scope.typeIdentifier
            )
            switch Self.outcome(of: error) {
            case .changed:
                FileIconProvider.forgetTypeIcons()
                open(request.rows, with: application)
            case .kept:
                return
            case .failed:
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t make “\(application.displayName)” the default application.",
                        comment: """
                        Alert title when changing which app opens a kind of file failed; %@ is the app name.
                        """
                    ),
                    detail: error?.localizedDescription ?? ""
                )
            }
        }
    }

    /// What macOS's answer to a change means for the files.
    enum DefaultChangeOutcome: Equatable {
        /// The application is the default now: open the files in it.
        case changed
        /// The user kept the old application in macOS's dialog: do nothing, say nothing.
        case kept
        /// It did not happen for another reason: say so.
        case failed
    }

    static func outcome(of error: Error?) -> DefaultChangeOutcome {
        guard let error else { return .changed }
        return isDeclined(error) ? .kept : .failed
    }

    /// Whether `error` is the user keeping the application they had, in macOS's own dialog, which is
    /// an answer rather than a failure and needs no alert.
    ///
    /// Measured 2026-11-12: Keep “VLC” answered `NSCocoaErrorDomain` 256, "The file couldn’t be
    /// opened.", with `userCanceledErr` (-128) as its underlying error, and the default unchanged. So
    /// the cancel is looked for down the chain of underlying errors, and the outer code, which says
    /// nothing, is not read. The live run that found it showed that sentence as an alert.
    static func isDeclined(_ error: Error) -> Bool {
        var next: NSError? = error as NSError
        while let error = next {
            if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError { return true }
            if error.domain == NSOSStatusErrorDomain, error.code == Int(userCanceledErr) { return true }
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// What an Always Open With item carries: the rows to open, the files the change reaches, and the
/// application, which Other… leaves out until one is picked.
struct DefaultApplicationRequest {
    let rows: [FileEntry]
    let scope: DefaultApplicationScope
    let application: ApplicationRef?
}
