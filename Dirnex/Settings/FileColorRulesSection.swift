import DirnexCore
import SwiftUI

/// The file-type colour rules editor (PLAN.md §M15 Slice 3) — Total Commander's signature ordered
/// glob → colour list: add, remove, reorder, first match wins.
///
/// **Order is meaning**, so the list is presented exactly as stored and never sorted: a user puts
/// the specific rule above the general one and that arrangement is the whole content of their
/// intent (the same rule the ACL editor follows). Reordering is explicit ▲/▼ buttons rather than
/// drag alone, so it is reachable from the keyboard and so "which rule wins" is something you *do*
/// rather than something you discover.
///
/// Every edit writes straight through to `FileColorRuleStore`, which posts its change notification,
/// so the open panes recolour while the sheet is still up — the same commit-as-you-go the favorites,
/// saved-search and scripts organizers use.
struct FileColorRulesSection: View {
    @State private var rules = FileColorRuleStore.rules
    @State private var selection: FileColorRule.ID?

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("No colour rules. Files draw in the standard text colour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List(selection: $selection) {
                    ForEach(rules.rules) { rule in
                        FileColorRuleRow(rule: rule) { update($0) }
                            .tag(rule.id)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        rules.move(
                            from: from,
                            to: destination > from ? destination - 1 : destination
                        )
                        persist()
                    }
                }
                .frame(height: 150)
                .alternatingRowBackgrounds()
            }
            controls
        } header: {
            Text("File type colours")
        } footer: {
            // The glob example is in backticks because **a SwiftUI string literal is parsed as
            // Markdown**, and `*.jpg;*.png` is a valid emphasis pair — so written plainly it renders
            // as an italic ".jpg;" followed by ".png", silently teaching the wrong syntax in the one
            // sentence whose job is to teach the right one. Backticks render it as code and keep the
            // asterisks; backslash escapes would work too, but leave `\*` in front of translators.
            Text(
                """
                Files are drawn in the colour of the first rule they match, so put the specific \
                rules above the general ones. Separate several patterns with a semicolon — \
                `*.jpg;*.png`. A marked file keeps its mark colour, and a file’s Git status still \
                wins over both.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Add, remove and reorder. Grouped below the list rather than beside it so the row layout keeps
    /// its full width for the pattern field, which is the one control whose content varies in length.
    ///
    /// Every glyph sits in the same `iconSize` square: `.bordered` hugs its label, and `plus`/`minus`
    /// have a near-square layout box while `chevron.up`/`chevron.down` are short, wide carets — so left
    /// to their natural sizes the four buttons come out at three different heights. A shared frame
    /// centres each glyph at its own drawn size in an identical box, so the buttons match.
    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                add()
            } label: {
                Image(systemName: "plus").frame(width: iconSize, height: iconSize)
            }
            .help(String(
                localized: "Add a colour rule",
                comment: "Tooltip on the add button of the file-type colours editor in Settings."
            ))

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus").frame(width: iconSize, height: iconSize)
            }
            .disabled(selectedIndex == nil)
            .help(String(
                localized: "Remove the selected rule",
                comment: "Tooltip on the remove button of the file-type colours editor in Settings."
            ))

            Divider().frame(height: 16)

            Button {
                moveSelected(by: -1)
            } label: {
                Image(systemName: "chevron.up").frame(width: iconSize, height: iconSize)
            }
            .disabled(!canMoveSelected(by: -1))
            .help(String(
                localized: "Move the rule up, so it is matched sooner",
                comment: "Tooltip on the move-up button of the file-type colours editor in Settings."
            ))

            Button {
                moveSelected(by: 1)
            } label: {
                Image(systemName: "chevron.down").frame(width: iconSize, height: iconSize)
            }
            .disabled(!canMoveSelected(by: 1))
            .help(String(
                localized: "Move the rule down, so it is matched later",
                comment: "Tooltip on the move-down button of the file-type colours editor in Settings."
            ))

            Spacer()
        }
        .buttonStyle(.bordered)
    }

    /// Side of the square each control glyph is centred in — large enough to contain the tallest
    /// (`plus`) at the default control font, so nothing overflows its box.
    private let iconSize: CGFloat = 14

    // MARK: - Editing

    private var selectedIndex: Int? {
        selection.flatMap { id in rules.rules.firstIndex { $0.id == id } }
    }

    /// A new rule starts on the accent colour rather than on nothing: an empty hex would draw no
    /// colour at all, so the row a user just added would appear to do nothing until they opened the
    /// well. Its patterns are left empty, which matches nothing — the harmless direction — so the
    /// pane does not flicker while they type the first one.
    private func add() {
        let rule = FileColorRule(
            colorHex: PanelPalette.hex(from: .controlAccentColor) ?? "#007AFF"
        )
        rules.append(rule)
        selection = rule.id
        persist()
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        rules.remove(at: index)
        // Keep a neighbour selected so a run of deletions doesn't need a click between each.
        selection = rules.rules.indices.contains(index)
            ? rules.rules[index].id
            : rules.rules.last?.id
        persist()
    }

    private func canMoveSelected(by offset: Int) -> Bool {
        guard let index = selectedIndex else { return false }
        return rules.rules.indices.contains(index + offset)
    }

    private func moveSelected(by offset: Int) {
        guard let index = selectedIndex, canMoveSelected(by: offset) else { return }
        rules.move(from: index, to: index + offset)
        persist()
    }

    private func update(_ rule: FileColorRule) {
        rules.update(rule)
        persist()
    }

    private func persist() {
        FileColorRuleStore.save(rules)
    }
}

/// One rule: its colour, what it is called, what it matches, and which kind of row it claims.
///
/// **The name is drawn in the rule's own colour, and that is the live preview** — the row renders
/// the way a file will, over the same window background, with no separate swatch to compare against.
/// A colour that turns out to be illegible here would be illegible in the pane too, which is
/// precisely what a preview is for; the well and the pattern field stay in the standard colour, so
/// the row can always be edited its way back out.
private struct FileColorRuleRow: View {
    let rule: FileColorRule
    let onChange: (FileColorRule) -> Void

    /// Held as a `String` constant rather than written inline, so the call below resolves to
    /// `TextField`'s verbatim overload and the wildcards survive — see the use site.
    private static let patternPlaceholder = "*.jpg;*.png"

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()

            TextField(
                String(
                    localized: "Name",
                    comment: "Placeholder for a colour rule's optional name in Settings, e.g. “Images”."
                ),
                text: nameBinding
            )
            .foregroundStyle(previewColor)
            .frame(minWidth: 90)

            // `Self.patternPlaceholder`, not the literal: a bare `"*.jpg;*.png"` binds to
            // `TextField`'s `LocalizedStringKey` overload, which parses Markdown — and the two
            // asterisks are a valid emphasis pair, so the placeholder renders as ".jpg;.png" with
            // the wildcards eaten. Passing a `String` picks the verbatim overload instead, which is
            // also the honest signature here: a glob example is syntax, not prose to translate.
            TextField(Self.patternPlaceholder, text: patternsBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 110)

            Picker("", selection: targetBinding) {
                ForEach(FileColorTarget.allCases, id: \.self) { target in
                    Text(target.title).tag(target)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// What the name draws in — the rule's colour, or the standard label colour while the stored hex
    /// is unusable, which is exactly what the pane does with the same value.
    private var previewColor: Color {
        PanelPalette.color(fromHex: rule.colorHex).map(Color.init(nsColor:)) ?? Color(
            nsColor: .labelColor
        )
    }

    /// Both closures name their parameter: nesting `edit { $0… }` inside `set: { $0… }` shadows the
    /// new colour with the rule being edited, which is the same bare-closure rebinding NOTES.md
    /// records under "adding a second closure parameter silently re-points every trailing closure".
    private var colorBinding: Binding<Color> {
        Binding(
            get: { previewColor },
            set: { picked in
                edit { rule in rule.colorHex = PanelPalette.hex(from: NSColor(picked)) ?? "" }
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(get: { rule.name }, set: { name in edit { $0.name = name } })
    }

    /// Patterns join and split on `;`.
    ///
    /// Semicolon and **not** whitespace, which is what Total Commander splits on: a file name is
    /// allowed to contain a space, so a space-separated list makes `My Photo*.jpg` unwritable — the
    /// pattern would silently become two patterns, neither of which matches anything. `;` has no
    /// meaning in a glob and none in a macOS file name that a user would reach for, so it costs
    /// nothing to reserve. Empty entries are dropped by `FileColorRule.init`, so a trailing separator
    /// while typing is harmless.
    private var patternsBinding: Binding<String> {
        Binding(
            get: { rule.patterns.joined(separator: ";") },
            set: { text in edit { $0.patterns = text.components(separatedBy: ";") } }
        )
    }

    private var targetBinding: Binding<FileColorTarget> {
        Binding(get: { rule.target }, set: { target in edit { $0.target = target } })
    }

    /// Copy-modify-publish: `FileColorRule` is a value type and the list is the owner, so a row
    /// hands back a whole edited rule rather than mutating one in place.
    ///
    /// Routed through `init` (rather than assigning the fields of a `var` copy) so the pattern
    /// trimming runs on every keystroke, the same way it runs on the way in from disk — otherwise
    /// what the editor holds and what a reload produces would differ by whitespace.
    private func edit(_ change: (inout FileColorRule) -> Void) {
        var edited = rule
        change(&edited)
        onChange(FileColorRule(
            id: edited.id,
            name: edited.name,
            patterns: edited.patterns,
            colorHex: edited.colorHex,
            target: edited.target
        ))
    }
}

// MARK: - Display names

/// The target's user-facing names live here, in the app, and not on the core enum — a presentation
/// decision in the core is a string that can never be translated (NOTES.md ▸ Localization). The core
/// picks the state; this picks the words.
///
/// All three keys are **already in the catalog in 14 languages**, put there by the Get Info
/// recursive-apply scope (`RecursiveApplyScope.title`), which says the same thing about the same two
/// kinds of item — so these inherit their translations rather than needing new ones. That makes the
/// comments a shared resource: they are repeated verbatim at both sites and worded for both, because
/// `String(localized:comment:)` takes a `StaticString` (so a shared comment cannot be hoisted into a
/// constant) and `xcstringstool` keeps only one of two differing comments for the same key.
extension FileColorTarget {
    var title: String {
        switch self {
        case .any:
            return String(
                localized: "Files and folders",
                comment: "Scope of a recursive Get Info change, or of a colour rule: every item."
            )
        case .filesOnly:
            return String(
                localized: "Files only",
                comment: "Scope of a recursive Get Info change, or of a colour rule: not folders."
            )
        case .foldersOnly:
            return String(
                localized: "Folders only",
                comment: "Scope of a recursive Get Info change, or of a colour rule: not files."
            )
        }
    }
}
