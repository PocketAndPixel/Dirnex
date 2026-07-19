import Foundation

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

    // MARK: - Browsing the operation list

    /// Every operation an automation surface can offer, in presentation order: the whole command
    /// registry followed by the user's own scripts.
    ///
    /// `resolve` above answers "what does this *typed string* mean", which is all AppleScript ever
    /// needs — a script author writes the name. Shortcuts asks the opposite question: it renders a
    /// **picker**, so it needs the list up front. Both doors therefore open onto the same space,
    /// and a user script is a first-class entry in it rather than an afterthought — dropping the
    /// scripts here would quietly make the Shortcuts action less capable than the AppleScript verb
    /// it mirrors, which is the whole reason `UserScript.paletteCommand` already exists.
    ///
    /// Returning `Command` rather than a new automation-only struct is deliberate: it is already the
    /// registry's presentation type (id, title, category, shortcut), the palette already renders
    /// scripts through it, and a parallel type would be one more thing to keep in step.
    public static func all(
        commands: [Command] = CommandCatalog.all,
        userScripts: [UserScript] = []
    ) -> [Command] {
        commands + userScripts.map(\.paletteCommand)
    }

    /// The operations matching `query`, best first — what a Shortcuts search field lists as the user
    /// types. An empty query returns everything in registry order (the picker's resting state).
    ///
    /// This is the palette's own fuzzy ranking (`CommandMatcher`), not `resolve`'s exact matching:
    /// a picker is a search box, so "cop" should surface Copy the way ⌘K does. Exactness is
    /// `resolve`'s job, for the one caller that is handed a finished name.
    public static func search(
        _ query: String,
        commands: [Command] = CommandCatalog.all,
        userScripts: [UserScript] = []
    ) -> [Command] {
        CommandMatcher.search(query, in: all(commands: commands, userScripts: userScripts))
            .map(\.command)
    }

    /// The operations with `ids`, in the order asked for; unknown ids are dropped.
    ///
    /// Matching is by **exact id only** — deliberately stricter than `resolve`. A saved Shortcut
    /// stores the id it was built with, so this is an identity lookup, not a search: if a user
    /// renames or deletes the script a Shortcut points at, the id stops resolving and Shortcuts
    /// shows the action as needing a value. That is the honest outcome. Falling back to fuzzy
    /// matching here would instead let a renamed script silently bind to *some other* operation,
    /// and a shortcut that quietly runs the wrong command is far worse than one that visibly breaks.
    public static func operations(
        ids: [String],
        commands: [Command] = CommandCatalog.all,
        userScripts: [UserScript] = []
    ) -> [Command] {
        let byID = Dictionary(
            all(commands: commands, userScripts: userScripts).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }

    /// Lower-case, whitespace-trimmed, and stripped of a single trailing `…`, so `Rename…`,
    /// `rename`, and `  Rename …` all compare equal to a `rename` query.
    private static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("…") { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
