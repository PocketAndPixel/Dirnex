import Foundation

/// An external text editor Dirnex can hand a file to — the whole of F4 "Edit" (PLAN.md §M11).
///
/// Dirnex deliberately ships no editor of its own: a real one is encoding detection, line-ending
/// preservation, a binary gate, undo grouping and find/replace, and every Mac already has one the
/// user has already chosen. So F4 hands the file over, exactly the way ⌥F3 hands two files to
/// FileMerge — a pure, tested descriptor here, a thin launcher in the app, a Settings picker
/// between them.
///
/// **Resolved by bundle identifier, not by a command-line launcher.** That is the one deliberate
/// deviation from `ExternalDiffTool`, which probes for `bbdiff` / `opendiff` because a diff tool
/// *is* invoked as a command. An editor's shim (`code`, `subl`) is an optional install most users
/// never perform, so probing for it would report "VS Code isn't installed" to someone staring at
/// its icon in the Dock. Opening by bundle is also what `OpenWithApplications` already does, which
/// is why a resolution here comes back as an `ApplicationRef` — the same value the "Open With"
/// menu launches.
public struct ExternalTextEditor: Sendable, Hashable, Identifiable {
    public var id: String { identifier }

    /// A stable identifier, used to persist the user's chosen editor. Ours, not Apple's — an
    /// editor may answer to more than one bundle identifier and still be one choice in the picker.
    public let identifier: String
    /// The name shown in Settings and in a status line ("Opening in BBEdit…").
    public let displayName: String
    /// The bundle identifiers this editor may be installed under, most-preferred first: a stable
    /// release before its insiders/preview channel, a newer major version before an older one.
    /// The first one that resolves wins.
    public let bundleIdentifiers: [String]

    public init(identifier: String, displayName: String, bundleIdentifiers: [String]) {
        self.identifier = identifier
        self.displayName = displayName
        self.bundleIdentifiers = bundleIdentifiers
    }

    /// This editor as something to open a file with, or `nil` when it isn't installed.
    ///
    /// `locateBundle` answers a bundle identifier with the bundle's path (LaunchServices, in the
    /// app; a dictionary, in the tests). The reference carries **our** display name rather than
    /// the bundle's, so the picker and the status line read the same whichever channel resolved.
    public func application(locateBundle: (String) -> String?) -> ApplicationRef? {
        for bundleIdentifier in bundleIdentifiers {
            guard let path = locateBundle(bundleIdentifier) else { continue }
            return ApplicationRef(
                bundlePath: path,
                displayName: displayName,
                bundleIdentifier: bundleIdentifier
            )
        }
        return nil
    }
}

public extension ExternalTextEditor {
    static let bbEdit = ExternalTextEditor(
        identifier: "bbedit",
        displayName: "BBEdit",
        bundleIdentifiers: ["com.barebones.bbedit"]
    )

    static let visualStudioCode = ExternalTextEditor(
        identifier: "vscode",
        displayName: "Visual Studio Code",
        bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
    )

    static let sublimeText = ExternalTextEditor(
        identifier: "sublimetext",
        displayName: "Sublime Text",
        bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3", "com.sublimetext.2"]
    )

    static let zed = ExternalTextEditor(
        identifier: "zed",
        displayName: "Zed",
        bundleIdentifiers: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
    )

    static let nova = ExternalTextEditor(
        identifier: "nova",
        displayName: "Nova",
        bundleIdentifiers: ["com.panic.Nova"]
    )

    static let textMate = ExternalTextEditor(
        identifier: "textmate",
        displayName: "TextMate",
        bundleIdentifiers: ["com.macromates.TextMate"]
    )

    static let cotEditor = ExternalTextEditor(
        identifier: "coteditor",
        displayName: "CotEditor",
        bundleIdentifiers: ["com.coteditor.CotEditor"]
    )

    static let xcode = ExternalTextEditor(
        identifier: "xcode",
        displayName: "Xcode",
        bundleIdentifiers: ["com.apple.dt.Xcode"]
    )

    static let textEdit = ExternalTextEditor(
        identifier: "textedit",
        displayName: "TextEdit",
        bundleIdentifiers: ["com.apple.TextEdit"]
    )

    /// The editors the Settings picker knows by name, in preference order: dedicated text editors
    /// first, then the two that ship with (or alongside) macOS. Only ever consulted as a *fallback*
    /// — the automatic choice is the system's own plain-text handler, below.
    static let known: [ExternalTextEditor] = [
        .bbEdit, .visualStudioCode, .sublimeText, .zed, .nova, .textMate, .cotEditor,
        .xcode, .textEdit
    ]

    /// The known editors actually installed, in preference order — the list the picker offers
    /// under "Automatic".
    static func installed(locateBundle: (String) -> String?) -> [ExternalTextEditor] {
        known.filter { $0.application(locateBundle: locateBundle) != nil }
    }

    /// The application F4 should open a file in, or `nil` when nothing can be resolved at all.
    ///
    /// - Parameters:
    ///   - preferredIdentifier: the user's Settings choice, or `nil`/empty for **automatic**.
    ///   - locateBundle: a bundle identifier's install path, or `nil` when it isn't installed.
    ///   - defaultPlainTextApplication: the app macOS opens `public.plain-text` with.
    ///
    /// Automatic is the system's plain-text handler rather than the first name on our list, so a
    /// user who never opens Settings gets exactly what double-clicking a `.txt` already gives them.
    /// It is deliberately the handler for **plain text** and not for the file's own type: F4 means
    /// "edit this as text", while opening a file in whatever owns its extension is what Enter
    /// already does.
    ///
    /// A chosen editor that has since been uninstalled falls through to automatic rather than
    /// failing, matching `ExternalDiffTool.preferred`; the stale preference is left alone, so
    /// reinstalling the editor restores the choice without a visit to Settings.
    static func resolve(
        identifier preferredIdentifier: String?,
        locateBundle: (String) -> String?,
        defaultPlainTextApplication: () -> ApplicationRef?
    ) -> ApplicationRef? {
        if let preferredIdentifier, !preferredIdentifier.isEmpty,
           let chosen = known.first(where: { $0.identifier == preferredIdentifier }),
           let application = chosen.application(locateBundle: locateBundle) {
            return application
        }
        if let system = defaultPlainTextApplication() { return system }
        // No plain-text handler at all is not a state a healthy Mac reaches; falling back to the
        // preference order keeps F4 working rather than reporting a failure nobody can act on.
        return installed(locateBundle: locateBundle)
            .first?.application(locateBundle: locateBundle)
    }
}
