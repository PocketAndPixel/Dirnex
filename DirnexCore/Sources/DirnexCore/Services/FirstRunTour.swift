import Foundation

/// One screen of the first-run tour (PLAN.md §M7 "First-run tour: palette-centric, 5 screens max").
///
/// The tour is data, not AppKit — the same split `FunctionBar` and `CommandCatalog` draw — so the
/// walkthrough's copy, its order, its length, and the fact that every action it points at is a real
/// command are all unit-testable, and the app is left only with the drawing. A screen names its
/// highlighted actions by `CommandCatalog` **id** rather than baking in a title or a glyph: the app
/// resolves each id to the command's title and its *effective* shortcut (through the user's
/// `KeyBindings`), so the tour prints exactly what the menu and the ⌘K palette print, and a rebind
/// is reflected here too — the tour can never advertise a key the app no longer honours.
public struct TourScreen: Sendable, Equatable, Identifiable {
    /// Stable, dotted identity ("tour.palette") — the persistence-free key a test pins a screen by,
    /// never localized.
    public let id: String
    /// The SF Symbol drawn above the headline. A presentation hint the app renders; kept here so the
    /// whole screen is one value rather than a parallel table the app has to keep in step.
    public let symbol: String
    /// The headline, a few words ("Move files between panels").
    public let title: String
    /// One or two sentences under the headline. Deliberately free of shortcut glyphs where a
    /// highlighted command already carries one — the app draws those as chips, so hard-coding "⌘K"
    /// into the prose would drift the moment the user rebinds it.
    public let body: String
    /// The `CommandCatalog` ids this screen puts in front of the user, in display order. Each
    /// resolves to a real command (a test pins that, exactly as `FunctionBar.defaultSlots` is
    /// pinned); the app renders each as a title-plus-shortcut chip. Empty on the pure-welcome screen,
    /// which introduces the app rather than any one action.
    public let commandIDs: [String]

    public init(
        id: String,
        symbol: String,
        title: String,
        body: String,
        commandIDs: [String] = []
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.body = body
        self.commandIDs = commandIDs
    }
}

/// The first-run tour's script (PLAN.md §M7 "First-run tour: palette-centric, 5 screens max"): a
/// short, ordered walkthrough shown once on a fresh install and reopenable from the palette or the
/// app menu anytime.
///
/// It is **palette-centric** by design — the second screen is the command palette itself, and the
/// last screen sends the user straight into it — because the palette is the one thing a newcomer has
/// to learn to reach everything else. A file manager with F-keys and a hundred commands is
/// intimidating; "press one key and type what you want" is not, and it is also true.
public enum FirstRunTour {
    /// The most screens the tour is ever allowed to be — PLAN.md's "5 screens max". A hard ceiling
    /// pinned by a test so the walkthrough can never quietly grow past a first-run's worth of
    /// attention: the whole point is that a stranger reads it, so it stays short enough to read.
    public static let maximumScreens = 5

    /// The tour, in the order the user pages through it. Every screen but the first highlights real
    /// `CommandCatalog` commands (pinned by a test); the palette command appears so the "search for
    /// anything" idea is anchored to the exact action that does it.
    public static let screens: [TourScreen] = [
        TourScreen(
            id: "tour.welcome",
            symbol: "rectangle.split.2x1",
            title: "Welcome to Dirnex",
            body: """
            Two panels, side by side, driven from the keyboard. One holds the files you're working \
            with, the other where they're going — and you reach for the mouse only when you want to.
            """
        ),
        TourScreen(
            id: "tour.palette",
            symbol: "command",
            title: "Everything is one search away",
            body: """
            Open the command palette and start typing what you want to do — copy, pack, connect to a \
            server, tag. It fuzzy-matches every action, so there's nothing to memorize and no menu \
            to hunt through.
            """,
            commandIDs: ["view.commandPalette"]
        ),
        TourScreen(
            id: "tour.files",
            symbol: "arrow.left.arrow.right",
            title: "Move files between panels",
            body: """
            The active panel is the source, the other the destination. Copy or move what's selected \
            across, make a folder, or send files to the Trash — from the buttons along the bottom, \
            the function keys, or the palette.
            """,
            commandIDs: ["file.copy", "file.move", "file.newFolder", "file.trash"]
        ),
        TourScreen(
            id: "tour.navigate",
            symbol: "location",
            title: "Get anywhere fast",
            body: """
            Jump straight to a path, open a second tab, or pin the folders you live in. Location, \
            tabs, and Favorites keep even a deep folder tree a single keystroke away.
            """,
            commandIDs: ["go.editLocation", "file.newTab", "go.favorites"]
        ),
        TourScreen(
            id: "tour.ready",
            symbol: "checkmark.seal",
            title: "You're ready",
            body: """
            macOS keeps a few folders private — other users' homes, Mail, Time Machine backups. \
            Grant Full Disk Access when you first need one. You can reopen this tour anytime from \
            the command palette.
            """,
            commandIDs: ["app.fullDiskAccess"]
        )
    ]
}
