import AppKit
import Testing

@testable import Dirnex

/// Every fixed line under a merge pane's title fits the pane in every language it ships in, with
/// the base shown at the window's opening size (PLAN.md §M34 Slice 6).
///
/// Four panes at ``MergeWindowController/openingSize`` leave each line about 299 pt, and the label
/// truncates in the middle, so an over-long line loses the words between its ends. "Saved to the
/// working tree; git add marks it resolved" measured 270 pt in English and 302–392 pt in nine of its
/// first translations, and the Russian was seen live as «Сохраняется в рабочем д…етит его как
/// разрешённый». Those nine were shortened. The line under Result for a server file names the
/// server and path, which no wording can bound, and is left out.
///
/// Whether a line is cut is AppKit's answer rather than arithmetic: `expansionFrame(withFrame:in:)`
/// on the real label in the real pane (docs/NOTES.md ▸ Layout under a longer translation).
@Suite("Merge pane subtitle widths")
@MainActor
struct MergeSubtitleWidthTests {
    /// The lines `BrowserWindowController+WriteBackMerge` and `PanelViewController+ResolveConflictWords`
    /// put under a pane's title, keyed by their English text.
    nonisolated static let keys = [
        "Where your edit started",
        "Your edit",
        "On the server now",
        "Saved to the working tree; git add marks it resolved",
        "HEAD, the branch you’re on",
        "HEAD, the branch being rebased onto",
        "The branch being merged in",
        "The commit being replayed",
        "The commit being picked",
        "The commit being reverted, undone",
        "The patch being applied",
        "The changes being merged in",
        "The common ancestor",
        "None: both sides added the file"
    ]

    /// A merge window at its opening size with the base shown, laid out. The rig's window is never
    /// placed, so no saved frame reaches it.
    private func fourPanes() throws -> (rig: MergeRig, pane: ComparePaneView) {
        let rig = try MergeRig()
        let window = try #require(rig.controller.window)
        rig.controller.toolbar.showBase.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentView?.frame.size == MergeWindowController.openingSize)
        #expect(rig.controller.isBaseShown)
        return (rig, rig.controller.resultPane)
    }

    /// Whether `pane` cuts `text` short when it is the line under the title.
    private func isCut(_ text: String, in pane: ComparePaneView) -> Bool {
        pane.setTitle("Result", detail: text)
        pane.window?.contentView?.layoutSubtreeIfNeeded()
        let label = pane.pathLabel
        guard let cell = label.cell else { return true }
        return cell.expansionFrame(withFrame: label.bounds, in: label) != .zero
    }

    @Test("every fixed subtitle fits a pane of four in every language", arguments: keys)
    func subtitleFits(key: String) throws {
        let all = ConnectPlaceholderWidthTests.translations(of: key)
        #expect(all.count >= 14, "expected all 14 shipped languages for \(key), found \(all.count)")
        let (rig, pane) = try fourPanes()
        defer { rig.cleanup() }
        let cut = all.filter { isCut($0.text, in: pane) }.map { "\($0.language): \($0.text)" }
        #expect(cut.isEmpty, "cut short in four panes: \(cut.joined(separator: "; "))")
    }

    /// The negative control: the check must be able to fail, on the Russian seen cut live, while
    /// the English of the same line fits.
    @Test("the pane cuts the Russian that was seen cut, and not the English")
    func paneCutsTheWordingSeenCut() throws {
        let (rig, pane) = try fourPanes()
        defer { rig.cleanup() }
        #expect(!isCut("Saved to the working tree; git add marks it resolved", in: pane))
        #expect(isCut("Сохраняется в рабочем дереве; git add отметит его как разрешённый", in: pane))
    }
}
