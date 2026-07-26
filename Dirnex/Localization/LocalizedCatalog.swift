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
        let title = L10n.string(LocalizationKey.commandTitle(command.id), fallback: command.title)
        return Command(
            id: command.id,
            title: title,
            category: command.category,
            keywords: keywords(for: command, displayedAs: title),
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

    /// A pack-dialog archive format's label, translated. `ArchivePacking.Format.displayName` is
    /// `DirnexCore` data reached through a variable (`Format.allCases`), so it is joined here by the
    /// format's stable raw value rather than wrapped at the popup, which would extract nothing.
    static func title(for format: ArchivePacking.Format) -> String {
        L10n.string(LocalizationKey.archiveFormat(format), fallback: format.displayName)
    }

    /// An undo/redo action's name, translated — spliced into the "Undo %@" / "Redo %@" menu title
    /// and the "finished with issues" alert. `UndoActionLabel.title` is `DirnexCore` data reached
    /// through a variable (`record.label`), so — like the sidebar sections — the app joins it here
    /// by the label's stable raw value and falls back to the core's English.
    static func title(for label: UndoActionLabel) -> String {
        L10n.string(LocalizationKey.undoActionLabel(label), fallback: label.title)
    }

    /// Why an operation is unsupported, translated — the sentence `VFSErrorText` puts under an
    /// alert's title. `VFSUnsupportedReason.sentence` is `DirnexCore` data reached through a return
    /// value, so it is joined here by the reason's stable key and falls back to the core's English.
    ///
    /// The arguments are spliced *after* the lookup, into whichever format won: a translation may
    /// reorder them positionally (`%1$@`), which is the whole reason the reason carries its
    /// arguments separately instead of a finished sentence.
    static func sentence(for reason: VFSUnsupportedReason) -> String {
        guard let format = L10n.translation(LocalizationKey.vfsUnsupported(reason)) else {
            return reason.sentence
        }
        guard !reason.arguments.isEmpty else { return format }
        return String(format: format, arguments: reason.arguments)
    }

    /// A script template's name, translated — what the scripts organizer's **+** menu prints.
    /// `UserScriptTemplate.title` is `DirnexCore` data reached through a variable
    /// (`UserScriptTemplate.all`), so it is joined here by the template's stable id rather than
    /// wrapped at the menu, which would extract nothing.
    static func title(for template: UserScriptTemplate) -> String {
        L10n.string(
            LocalizationKey.userScriptTemplateTitle(template.id),
            fallback: template.title
        )
    }

    /// The script a template seeds, named and keyworded in the user's language.
    ///
    /// The name matters more here than at most display sites: it is saved into the user's list and
    /// becomes the script's *identity*, so a Spanish user gets a script actually called "Copiar
    /// rutas" rather than an English name they would have to rename by hand. The **body** is not
    /// translated — it is shell code.
    static func script(for template: UserScriptTemplate) -> UserScript {
        let name = title(for: template)
        return template.script(
            name: name,
            keywords: keywords(for: template, displayedAs: name)
        )
    }

    /// A search's label for the tab chip and the path-bar crumb ("Results for …").
    ///
    /// `SpotlightQuery` hands over the *term* that stands for the query and no words at all, so both
    /// the generic fallback and a lone kind are translated here — the kind through the same join the
    /// Find-Files popup uses, so the crumb and the popup always read alike. The quotes are a format
    /// rather than literal characters, because a language that quotes with «…» should say so.
    static func summary(of query: SpotlightQuery) -> String {
        switch query.summaryTerm {
        case let .name(text), let .content(text), let .tag(text):
            return String(
                localized: "“\(text)”",
                comment: "A search's crumb when it is named by a term the user typed; %@ is the term."
            )
        case let .kind(kind):
            return title(for: kind)
        case .generic:
            return String(
                localized: "Search results",
                comment: "A search's crumb when only a size or date filter names it."
            )
        }
    }

    /// The same label without the display quotes — the editable default the "Save Search…" prompt
    /// prefills, which takes a lone tag as a name where the crumb would not.
    static func plainName(of query: SpotlightQuery) -> String {
        switch query.plainNameTerm {
        case let .name(text), let .content(text), let .tag(text):
            return text
        case let .kind(kind):
            return title(for: kind)
        case .generic:
            return String(
                localized: "Search results",
                comment: "A search's crumb when only a size or date filter names it."
            )
        }
    }

    /// English keywords plus the **English title** plus the translated ones, English first and
    /// duplicates dropped.
    ///
    /// Additive rather than replacing on purpose: a Russian- or Ukrainian-speaking user typing on a
    /// Latin layout — the common case, not the exotic one — and anyone who has read the English
    /// docs must still reach the command by its English name. **Never make a translated keyword
    /// value replace these.**
    ///
    /// Folding the English *title* in is the half that is easy to miss, because it is the half the
    /// registry cannot supply. A translated title *replaces* the English one, so the single most
    /// obvious search term for a command is exactly the one that disappears: `file.copy`'s keywords
    /// are `f5, duplicate, transfer`, so with a Russian title of «Копировать на другую панель»,
    /// typing "copy" matched **nothing at all** until the title joined the terms here.
    private static func keywords(for command: Command, displayedAs title: String) -> [String] {
        merged(
            english: command.keywords + englishName(command.title, shownAs: title),
            key: LocalizationKey.commandKeywords(command.id)
        )
    }

    /// The same additive treatment for a script template's keywords — they are seeded into a script
    /// the user then owns, so this is the one chance to give them searchable terms in their own
    /// language without taking the English ones away.
    private static func keywords(
        for template: UserScriptTemplate,
        displayedAs name: String
    ) -> [String] {
        merged(
            english: template.keywords + englishName(template.title, shownAs: name),
            key: LocalizationKey.userScriptTemplateKeywords(template.id)
        )
    }

    /// The English name as a search term, or nothing when it is still what the user sees.
    ///
    /// Kept whole rather than split into words: `CommandMatcher` matches a subsequence, so "copy"
    /// hits "Copy to Other Panel" as a prefix and scores the boundary bonuses it would in English,
    /// while splitting would add "to", "by" and "the" as terms of their own and make every stopword
    /// query rank the whole registry.
    private static func englishName(_ english: String, shownAs displayed: String) -> [String] {
        displayed.caseInsensitiveCompare(english) == .orderedSame ? [] : [english]
    }

    private static func merged(english: [String], key: String) -> [String] {
        let translated = LocalizationKey.splitKeywords(L10n.translation(key) ?? "")
        var seen = Set<String>()
        return (english + translated).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension CommandCategory {
    /// The section name for the palette's group label and the generated menu title.
    var localizedTitle: String {
        L10n.string(LocalizationKey.commandCategory(self), fallback: title)
    }
}
