import DirnexCore
import Foundation

/// The app's localized view of `DirnexCore`'s command registry.
///
/// `DirnexCore` ships no resources on purpose (see `LocalizationKey`): its `title`, `label` and
/// `keywords` are English *data*, and the translation lives in the app's string catalog keyed by the
/// command's stable id. This type is the join — the app reads commands from here instead of from
/// `CommandCatalog`, so every downstream `command.title` is already translated and no display site
/// has to remember to ask.
///
/// A missing translation falls back to the core's English rather than to a raw key, which is why
/// these lookups pass the core's string as the fallback value instead of using the compiler-checked
/// `String(localized:)` form. That form is still the right one for the app's own literals — those
/// use the English text as its own key and are extracted automatically.
enum LocalizedCatalog {
    /// Every registry command with its title and keywords translated, in catalog order.
    ///
    /// Computed once: the display language cannot change without a relaunch (`LanguageSettings`),
    /// so there is nothing to invalidate.
    static let all: [Command] = CommandCatalog.all.map(localized)

    private static let byID: [String: Command] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// The translated command with `id`, or `nil` if unknown — the localized twin of
    /// `CommandCatalog.command(for:)`.
    static func command(for id: String) -> Command? {
        byID[id]
    }

    /// Translate one command. Public to the app so a command assembled outside the registry (a user
    /// script's palette entry) can be passed through harmlessly — an unknown id simply keeps its
    /// own strings.
    static func localized(_ command: Command) -> Command {
        Command(
            id: command.id,
            title: L10n.string(LocalizationKey.commandTitle(command.id), fallback: command.title),
            category: command.category,
            keywords: keywords(for: command),
            shortcut: command.shortcut
        )
    }

    /// The short caption for a function-bar button.
    ///
    /// Keyed by command id, so a slot the user moved to another key keeps its caption, and a user
    /// script's slot (which has no catalog entry) keeps the name the user gave it.
    static func label(for slot: FunctionBarSlot) -> String {
        L10n.string(
            LocalizationKey.functionBarLabel(commandID: slot.commandID),
            fallback: slot.label
        )
    }

    /// A first-run tour screen's headline, translated — the tour's twin of `localized(_:)`. The
    /// screen is `DirnexCore` data (English `title`/`body`, stable id), so the app translates it here
    /// by the screen's id and falls back to the core's English, exactly as commands do.
    static func title(for screen: TourScreen) -> String {
        L10n.string(LocalizationKey.tourTitle(screen.id), fallback: screen.title)
    }

    /// A first-run tour screen's body copy, translated.
    static func body(for screen: TourScreen) -> String {
        L10n.string(LocalizationKey.tourBody(screen.id), fallback: screen.body)
    }

    /// A sidebar section header's label, translated. Like the tour screens, `SidebarSection.title`
    /// is `DirnexCore` data (English label, stable id), so the app joins it here by the section's id
    /// and falls back to the core's English — never `String(localized: section.title)`, which reads
    /// a variable and so extracts nothing.
    static func title(for section: SidebarSection) -> String {
        L10n.string(LocalizationKey.sidebarSection(section), fallback: section.title)
    }

    /// A Find-Files "Kind" filter option's label, translated. `SearchKind.title` is `DirnexCore`
    /// data reached through a variable at the popup, so — like the sidebar sections — the app joins
    /// it here by the kind's stable id and falls back to the core's English.
    static func title(for kind: SearchKind) -> String {
        L10n.string(LocalizationKey.searchKind(kind), fallback: kind.title)
    }

    /// A Find-Files "Modified" filter option's label, translated.
    static func title(for age: SearchAge) -> String {
        L10n.string(LocalizationKey.searchAge(age), fallback: age.title)
    }

    /// A Finder tag colour's name for the New Tag colour popup, translated. `FinderTagColor.title`
    /// is `DirnexCore` data reached through a variable, so it is joined here rather than wrapped at
    /// the display site.
    static func title(for color: FinderTagColor) -> String {
        L10n.string(LocalizationKey.tagColor(color), fallback: color.title)
    }

    /// An undo/redo action's name, translated — spliced into the "Undo %@" / "Redo %@" menu title
    /// and the "finished with issues" alert. `UndoActionLabel.title` is `DirnexCore` data reached
    /// through a variable (`record.label`), so — like the sidebar sections — the app joins it here
    /// by the label's stable raw value and falls back to the core's English.
    static func title(for label: UndoActionLabel) -> String {
        L10n.string(LocalizationKey.undoActionLabel(label), fallback: label.title)
    }

    /// English keywords plus the translated ones, English first and duplicates dropped.
    ///
    /// Additive rather than replacing on purpose: a Russian-speaking user who has read the English
    /// docs, or who reaches for "copy" out of habit, must still find the command. Order matters only
    /// for stability — `CommandMatcher` scores terms, it does not rank by position.
    private static func keywords(for command: Command) -> [String] {
        let translated = LocalizationKey.splitKeywords(
            L10n.translation(LocalizationKey.commandKeywords(command.id)) ?? ""
        )
        var seen = Set<String>()
        return (command.keywords + translated).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension CommandCategory {
    /// The section name for the palette's group label and the generated menu title.
    var localizedTitle: String {
        L10n.string(LocalizationKey.commandCategory(self), fallback: title)
    }
}
