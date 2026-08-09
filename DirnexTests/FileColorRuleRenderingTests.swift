import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Color rules by file type (PLAN.md §M15 Slice 3), on the app side: the precedence a rule takes in
/// a cell, and the store the panes read it through. The matching itself is the core's and is tested
/// in `FileColorRulesTests`; what is here is the presentation, the way `PanelPaletteTests` and
/// `SyncBadgeTests` already are.
@Suite("File color rules — rendering")
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

    /// The whole point of giving the type color a slot of its own rather than reusing
    /// `accentColor`: **a marked file must stay unmistakably marked.** If the type color outranked
    /// the mark, a marked photograph in a folder of photographs would look exactly like an unmarked
    /// one at the moment F5 is aimed at it — silent, and in the expensive direction.
    @Test("the mark outranks a type color")
    func markOutranksTypeColor() {
        let view = cell()
        view.palette = PanelPalette(mark: .systemRed)
        view.typeColor = .systemTeal
        view.marked = true
        #expect(textColor(of: view) == .systemRed)

        view.marked = false
        #expect(textColor(of: view) == .systemTeal)
    }

    /// Git used to hold the slot *above* the mark, because in the status gutter the colored letter
    /// was the whole cell and there was nowhere else to put it. Now that the letter is a badge with
    /// a color of its own (`GitBadgeView`), it competes with nothing: a marked, modified `.jpg`
    /// keeps the mark's red on its name *and* shows its orange `M`, where before the mark's color
    /// was the thing that gave way.
    @Test("Git status no longer claims the row's text color")
    func gitDoesNotTouchTheText() {
        let view = cell()
        view.palette = PanelPalette(mark: .systemRed)
        view.typeColor = .systemTeal
        view.marked = true
        view.gitStatus = .modified
        #expect(textColor(of: view) == .systemRed)

        view.marked = false
        #expect(textColor(of: view) == .systemTeal)
        // …and the status is still on the row, in the badge that owns it.
        #expect(view.gitStatus == .modified)
    }

    /// And the cursor still wins over all three, with the foreground derived from whatever color the
    /// cursor row is drawn in — otherwise a pale cursor under a pale type color is an invisible row.
    @Test("the cursor row's derived foreground outranks a type color")
    func cursorOutranksTypeColor() {
        let view = cell()
        view.typeColor = .systemTeal
        view.palette = PanelPalette(cursor: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1))
        view.backgroundStyle = .emphasized
        #expect(textColor(of: view) == .black)
        #expect(textColor(of: view) != .systemTeal)
    }

    /// The untouched install, and the state every row is in when the rule list is empty.
    @Test("no rule leaves the row in the standard label color")
    func noRuleIsLabelColor() {
        let view = cell()
        view.typeColor = nil
        #expect(textColor(of: view) == .labelColor)
    }

    /// A type color does not change the mark's *weight*, only the mark's color claim — a marked
    /// row is bold whatever else is true of it.
    @Test("a type color leaves the marked row bold")
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
    /// color, never a color nobody chose. Same call the three palette colors already make.
    @Test("an unusable color hex draws no color rather than a wrong one")
    func unusableHexDrawsNothing() {
        #expect(PanelPalette.color(fromHex: "") == nil)
        #expect(PanelPalette.color(fromHex: "not a color") == nil)
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
        // named like an image takes the Images color, because that rule is above and accepts both
        // kinds. Surprising the first time, and exactly what the ordered list promises.
        #expect(reloaded.firstMatch(name: "photo.PNG", isDirectory: true)?.colorHex == "#008080")
    }

    // MARK: - Localization

    /// Every target the picker offers has to be translatable, and the titles live in the app for the
    /// reason NOTES.md gives — a presentation decision in the core is a string that can never be
    /// translated. Asserting they are non-empty and distinct is what catches a case added to the core
    /// enum without a title here, which would otherwise render as a blank menu item.
    @Test("every color-rule target has a distinct, non-empty title")
    func everyTargetIsNamed() {
        let titles = FileColorTarget.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == FileColorTarget.allCases.count)
    }
}
