import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Colour rules by file type (PLAN.md §M15 Slice 3), on the app side: the precedence a rule takes in
/// a cell, and the store the panes read it through. The matching itself is the core's and is tested
/// in `FileColorRulesTests`; what is here is the presentation, the way `PanelPaletteTests` and
/// `SyncBadgeTests` already are.
@Suite("File colour rules — rendering")
@MainActor
struct FileColorRuleRenderingTests {
    private func cell() -> FileCellView {
        FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
    }

    private func textColor(of cell: FileCellView) -> NSColor? {
        cell.applyStyle()
        return cell.textField?.textColor
    }

    // MARK: - Precedence

    /// The whole point of giving the type colour a slot of its own rather than reusing
    /// `accentColor`: **a marked file must stay unmistakably marked.** If the type colour outranked
    /// the mark, a marked photograph in a folder of photographs would look exactly like an unmarked
    /// one at the moment F5 is aimed at it — silent, and in the expensive direction.
    @Test("the mark outranks a type colour")
    func markOutranksTypeColor() {
        let view = cell()
        view.palette = PanelPalette(mark: .systemRed)
        view.typeColor = .systemTeal
        view.marked = true
        #expect(textColor(of: view) == .systemRed)

        view.marked = false
        #expect(textColor(of: view) == .systemTeal)
    }

    /// Git keeps the top slot it already had: the letter *is* the information, and there is nowhere
    /// else on the row to put it. A modified `.jpg` in a repository still shows its orange `M`.
    @Test("Git status outranks both the mark and a type colour")
    func gitOutranksEverything() {
        let view = cell()
        view.palette = PanelPalette(mark: .systemRed)
        view.typeColor = .systemTeal
        view.marked = true
        view.accentColor = GitStatusStyle.color(for: .modified)
        #expect(textColor(of: view) == GitStatusStyle.color(for: .modified))
    }

    /// And the cursor still wins over all three, with the foreground derived from whatever colour the
    /// cursor row is drawn in — otherwise a pale cursor under a pale type colour is an invisible row.
    @Test("the cursor row's derived foreground outranks a type colour")
    func cursorOutranksTypeColor() {
        let view = cell()
        view.typeColor = .systemTeal
        view.palette = PanelPalette(cursor: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1))
        view.backgroundStyle = .emphasized
        #expect(textColor(of: view) == .black)
        #expect(textColor(of: view) != .systemTeal)
    }

    /// The untouched install, and the state every row is in when the rule list is empty.
    @Test("no rule leaves the row in the standard label colour")
    func noRuleIsLabelColor() {
        let view = cell()
        view.typeColor = nil
        #expect(textColor(of: view) == .labelColor)
    }

    /// A type colour does not change the mark's *weight*, only the mark's colour claim — a marked
    /// row is bold whatever else is true of it.
    @Test("a type colour leaves the marked row bold")
    func typeColorKeepsMarkBold() {
        let view = cell()
        view.typeColor = .systemTeal
        view.marked = true
        view.applyStyle()
        let size = NSFont.systemFontSize
        #expect(view.textField?.font == .boldSystemFont(ofSize: size))
    }

    // MARK: - Resolving a rule to pixels

    /// The degradation the core deliberately leaves to the app: a hex it cannot parse draws **no**
    /// colour, never a colour nobody chose. Same call the three palette colours already make.
    @Test("an unusable colour hex draws no colour rather than a wrong one")
    func unusableHexDrawsNothing() {
        #expect(PanelPalette.color(fromHex: "") == nil)
        #expect(PanelPalette.color(fromHex: "not a colour") == nil)
        #expect(PanelPalette.color(fromHex: "#12345") == nil)
        #expect(PanelPalette.color(fromHex: "#008080") != nil)
    }

    // MARK: - The store

    /// The store caches in memory because the render loop reads it per cell, which is the one way it
    /// differs from `UserScriptStore` — so the cache has to actually follow a save, or the Settings
    /// editor would write rules the panes never see.
    @Test("saving publishes the new rules to the next read")
    func saveUpdatesTheCachedRules() {
        let original = FileColorRuleStore.rules
        defer {
            FileColorRuleStore.save(original)
            FileColorRuleStore.invalidateCache()
        }

        let rule = FileColorRule(name: "Images", patterns: ["*.jpg"], colorHex: "#008080")
        FileColorRuleStore.save(FileColorRules(rules: [rule]))
        #expect(FileColorRuleStore.rules.rules.map(\.name) == ["Images"])
        #expect(FileColorRuleStore.rules.firstMatch(name: "a.jpg", isDirectory: false) != nil)

        FileColorRuleStore.save(FileColorRules())
        #expect(FileColorRuleStore.rules.isEmpty)
    }

    /// A store that survives a relaunch, which is the slice's own exit criterion. Dropping the cache
    /// is what makes this a test of the *defaults domain* rather than of the in-memory copy.
    @Test("rules survive being re-read from the defaults domain")
    func rulesRoundTripThroughDefaults() {
        let original = FileColorRuleStore.rules
        defer {
            FileColorRuleStore.save(original)
            FileColorRuleStore.invalidateCache()
        }

        FileColorRuleStore.save(FileColorRules(rules: [
            FileColorRule(name: "Images", patterns: ["*.jpg", "*.png"], colorHex: "#008080"),
            FileColorRule(
                name: "Folders",
                patterns: ["*"],
                colorHex: "#4A90D9",
                target: .foldersOnly
            )
        ]))
        FileColorRuleStore.invalidateCache()

        let reloaded = FileColorRuleStore.rules
        #expect(reloaded.rules.map(\.name) == ["Images", "Folders"])
        #expect(reloaded.rules[1].target == .foldersOnly)
        #expect(reloaded.firstMatch(name: "photo.PNG", isDirectory: false)?.colorHex == "#008080")
        #expect(reloaded.firstMatch(name: "Pictures", isDirectory: true)?.colorHex == "#4A90D9")
        // A file the folders rule's `*` matches by name is still not a folder, so nothing claims it.
        #expect(reloaded.firstMatch(name: "Pictures", isDirectory: false) == nil)
        // And first-match-wins is about *order*, not about specificity: a folder that happens to be
        // named like an image takes the Images colour, because that rule is above and accepts both
        // kinds. Surprising the first time, and exactly what the ordered list promises.
        #expect(reloaded.firstMatch(name: "photo.PNG", isDirectory: true)?.colorHex == "#008080")
    }

    // MARK: - Localization

    /// Every target the picker offers has to be translatable, and the titles live in the app for the
    /// reason NOTES.md gives — a presentation decision in the core is a string that can never be
    /// translated. Asserting they are non-empty and distinct is what catches a case added to the core
    /// enum without a title here, which would otherwise render as a blank menu item.
    @Test("every colour-rule target has a distinct, non-empty title")
    func everyTargetIsNamed() {
        let titles = FileColorTarget.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == FileColorTarget.allCases.count)
    }
}
