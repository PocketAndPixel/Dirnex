import Foundation

/// The key scheme joining `DirnexCore`'s registries to the app's string catalog.
///
/// The core stays resource-free on purpose: it ships no `.xcstrings`, declares no
/// `defaultLocalization`, and its English `title`/`label`/`keywords` are the *fallback*, not the
/// presentation. The app looks each one up by the key built here and falls back to the core's
/// English when a translation is missing — so `swift test` stays hermetic and no catalog test ever
/// has to assert against translated output or pin a locale.
///
/// The load-bearing consequence: **a `Command.id` is a translation key**. Renaming one orphans its
/// translations in every language, exactly as `Command.id`'s own doc comment already promised
/// ("never localized, never changes"). `CommandCatalogTests` pins the id list for that reason.
public enum LocalizationKey {
    /// The command's menu/palette title, e.g. `command.file.copy.title`.
    public static func commandTitle(_ commandID: String) -> String {
        "command.\(commandID).title"
    }

    /// The command's extra palette search terms, e.g. `command.file.copy.keywords`.
    ///
    /// A string catalog value is a string, not a list, so the translated terms are written as one
    /// comma-separated value ("копировать, дублировать") and split by ``splitKeywords(_:)``. The
    /// translated terms are *added* to the core's English ones rather than replacing them, so a
    /// Russian user can still reach a command by typing "copy".
    public static func commandKeywords(_ commandID: String) -> String {
        "command.\(commandID).keywords"
    }

    /// The palette group label and generated menu title, e.g. `commandCategory.file.title`.
    public static func commandCategory(_ category: CommandCategory) -> String {
        "commandCategory.\(category.rawValue).title"
    }

    /// The caption printed on a function-bar button, e.g. `functionBar.file.copy.label`.
    ///
    /// Keyed by the slot's *command id*, not its function key: a user who moves Copy from F5 to F9
    /// should carry its caption with it, and a user script's slot has no catalog entry to inherit.
    public static func functionBarLabel(commandID: String) -> String {
        "functionBar.\(commandID).label"
    }

    /// A first-run tour screen's headline, e.g. `tour.welcome.title`. `TourScreen.id` already carries
    /// the `tour.` prefix, so the key forms directly from it — the same "id is the translation key"
    /// contract the command registry rests on.
    public static func tourTitle(_ screenID: String) -> String {
        "\(screenID).title"
    }

    /// A first-run tour screen's body copy, e.g. `tour.welcome.body`.
    public static func tourBody(_ screenID: String) -> String {
        "\(screenID).body"
    }

    /// A sidebar section header's label, e.g. `sidebar.section.favorites.title`. Keyed by the
    /// section's stable raw value — the same "the case is the key" contract the command registry
    /// rests on, and the very raw value the persisted collapse state keys off, so a rename that
    /// would silently unfold the section for everyone also orphans its translations, which is loud.
    /// `SidebarSection.title` is `DirnexCore` data (English label, stable id), so it gets the
    /// registry treatment the tour screens do rather than an app `String(localized:)` at a variable
    /// display site, which would never extract.
    public static func sidebarSection(_ section: SidebarSection) -> String {
        "sidebar.section.\(section.rawValue).title"
    }

    /// A Find-Files "Kind" filter option's label, e.g. `search.kind.image.title`. `SearchKind.title`
    /// is `DirnexCore` data (English label, stable string raw value) reached through a variable at
    /// the popup — `SearchKind.allCases.map { $0.title }` — so it gets the registry treatment the
    /// sidebar sections do rather than an app `String(localized:)`, which would extract nothing.
    public static func searchKind(_ kind: SearchKind) -> String {
        "search.kind.\(kind.rawValue).title"
    }

    /// A Find-Files "Modified" filter option's label, e.g. `search.age.week.title`. Same data-through-
    /// a-variable situation as ``searchKind(_:)``.
    public static func searchAge(_ age: SearchAge) -> String {
        "search.age.\(age.rawValue).title"
    }

    /// A Finder tag colour's name for the New Tag colour popup, e.g. `tag.color.red.title`.
    /// `FinderTagColor.title` is `DirnexCore` data reached through a variable, so it gets the registry
    /// treatment. Keyed by a stable string token rather than the enum's `Int` raw value (Apple's tag
    /// colour index) so the catalog reads as colour names, not indices, for the translator.
    public static func tagColor(_ color: FinderTagColor) -> String {
        let token: String
        switch color {
        case .none: token = "none"
        case .grey: token = "grey"
        case .green: token = "green"
        case .purple: token = "purple"
        case .blue: token = "blue"
        case .yellow: token = "yellow"
        case .red: token = "red"
        case .orange: token = "orange"
        }
        return "tag.color.\(token).title"
    }

    /// An undo/redo action's name, spliced into the "Undo %@" / "Redo %@" menu title, e.g.
    /// `undo.action.moveToTrash.title`. `UndoActionLabel.title` is `DirnexCore` data reached through
    /// a variable (`record.label`) at the menu, so — like the sidebar sections — the app joins it
    /// here by the label's stable raw value and falls back to the core's English. Keying by the raw
    /// value means renaming a case (which also changes the persisted journal's on-disk form) loudly
    /// orphans its translations rather than silently rendering English.
    public static func undoActionLabel(_ label: UndoActionLabel) -> String {
        "undo.action.\(label.rawValue).title"
    }

    /// Split a translated comma-separated keyword value into terms, dropping empties and
    /// surrounding whitespace. Tolerant on purpose — the value is typed by a translator, and a
    /// stray trailing comma should cost nothing.
    public static func splitKeywords(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
