import Foundation

/// The scripting verbs Dirnex exposes to AppleScript (an `.sdef` suite) and, later, Shortcuts
/// (App Intents) — PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs (reveal, copy, run-op)".
///
/// The verb *names* live here, in `DirnexCore`, for the same reason `FunctionBar` and `UserScript`
/// do: they are data the app, the `.sdef`, and the tests must agree on, and a value here is the one
/// place that agreement is pinned (a test asserts the names are distinct and non-empty). The actual
/// Apple-event plumbing — `NSScriptCommand` subclasses reading a direct parameter — is inherently
/// AppKit and lives in the app; this type is what those handlers, their error strings, and the
/// `.sdef`'s human-readable command names all reference so none of them drift.
public enum AutomationVerb: String, CaseIterable, Sendable {
    /// `reveal "<posix path>"` — bring the active panel to the item's container and select it, the
    /// Finder-`reveal` gesture. Resolves a path via `AutomationRevealTarget`.
    case reveal
    /// `copy selection` — the F5 "copy to other panel" operation on the current selection. A named
    /// convenience verb; the same thing is reachable as `run operation "file.copy"`.
    case copySelection
    /// `run operation "<id or title>"` — invoke any Dirnex command by its `CommandCatalog` id or
    /// menu title, or a user script by name. The generic bridge to the whole action registry;
    /// resolves a requested string via `AutomationOperation.resolve`.
    case runOperation

    /// The command name as it reads in AppleScript and in the `.sdef` (`reveal`, `copy selection`,
    /// `run operation`). Multi-word names are legal AppleScript terminology (cf. the standard `open
    /// location`), and reading better than a squashed identifier is the whole point of a verb.
    public var commandName: String {
        switch self {
        case .reveal: return "reveal"
        case .copySelection: return "copy selection"
        case .runOperation: return "run operation"
        }
    }
}

/// Where a `reveal` should take the active panel: the directory to show, and the item to put the
/// cursor on inside it. `reveal` mirrors Finder — it selects the item *in its container*, so a path
/// to a folder shows the folder highlighted in its parent rather than entering it.
public struct AutomationRevealTarget: Equatable, Sendable {
    /// The directory the panel navigates to.
    public let container: VFSPath
    /// The item to select once `container` is listed, or `nil` when the target is a backend root
    /// (which has no container to select it in — the panel simply shows the root).
    public let item: VFSPath?

    public init(container: VFSPath, item: VFSPath?) {
        self.container = container
        self.item = item
    }
}

/// Turns a script-supplied POSIX path into the `(container, item)` a panel navigates to for a
/// `reveal` (PLAN.md §M6). Kept in the core, and tested, because the rules — reject a relative
/// path, treat the root specially, otherwise show the parent and select the item — are exactly the
/// kind of lexical decision that belongs beside `VFSPath` rather than in an Apple-event handler.
public enum AutomationReveal {
    /// The reveal target for `posixPath`, or `nil` when the path is empty or not absolute. The path
    /// is taken as a `.local` location (the only backend a Finder-style POSIX path can name);
    /// `VFSPath` normalizes duplicate/trailing slashes, so `/Users/me/` and `/Users//me` both land
    /// on `/Users` selecting `me`.
    public static func target(forPOSIXPath posixPath: String) -> AutomationRevealTarget? {
        let trimmed = posixPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let path = VFSPath.local(trimmed)
        guard let parent = path.parent else {
            // The root itself: nothing contains it, so just show it with no selection.
            return AutomationRevealTarget(container: path, item: nil)
        }
        return AutomationRevealTarget(container: parent, item: path)
    }
}

/// Resolves the free-text operation name a `run operation` script passes into a canonical command
/// id the app can dispatch (PLAN.md §M6). A script author should be able to write the id
/// (`file.copy`), the menu title (`Copy to Other Panel`, case- and ellipsis-insensitive), or a user
/// script's name (`To WebP`) and have it hit the same action the palette would — so this is the one
/// spot that maps all three spellings onto the flat command-id space `CommandBinding` dispatches.
///
/// Pure and tested: it takes the available `commands` and `userScripts` as input (the app feeds it
/// `CommandCatalog.all` and `UserScriptStore.load()`), so the matching rules never depend on AppKit.
public enum AutomationOperation {
    /// The canonical command id for `query`, or `nil` when nothing matches. Matching is, in order:
    /// an exact command id; an exact menu title; a `userScript.<name>` id; a user-script name — all
    /// case-insensitive and ignoring a title's trailing `…`. A user-script match returns the
    /// script's `commandID` (the `userScript.` form the app routes to the script runner).
    public static func resolve(
        _ query: String,
        commands: [Command] = CommandCatalog.all,
        userScripts: [UserScript] = []
    ) -> String? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return nil }

        if let command = commands.first(where: { normalized($0.id) == needle }) {
            return command.id
        }
        if let command = commands.first(where: { normalized($0.title) == needle }) {
            return command.id
        }
        if let script = userScripts.first(where: {
            normalized($0.commandID) == needle || normalized($0.name) == needle
        }) {
            return script.commandID
        }
        return nil
    }

    /// Lower-case, whitespace-trimmed, and stripped of a single trailing `…`, so `Rename…`,
    /// `rename`, and `  Rename …` all compare equal to a `rename` query.
    private static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("…") { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
