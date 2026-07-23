import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's own decisions about Git awareness (PLAN.md §M6). What Git's bytes *mean* is
/// `DirnexCore`'s and is tested there; spawning `git` and caching its answers is non-hermetic and
/// is exercised live, as with `SMBMounter`. What is left — and is here — are the two places the app
/// makes a call of its own: how a branch reads in the path bar, and the rule that keeps a column
/// which comes and goes out of the user's persisted layout.
@Suite("Git branch chip")
@MainActor
struct GitBranchChipTests {
    @Test("a branch level with its upstream is just its name")
    func inSync() {
        let branch = GitBranch(name: "Dev", upstream: "origin/Dev")
        #expect(GitBranchChipView.text(for: branch) == "Dev")
    }

    @Test("drift from the upstream shows in both directions")
    func divergence() {
        let ahead = GitBranch(name: "Dev", upstream: "origin/Dev", ahead: 2)
        #expect(GitBranchChipView.text(for: ahead) == "Dev ↑2")

        let behind = GitBranch(name: "Dev", upstream: "origin/Dev", behind: 1)
        #expect(GitBranchChipView.text(for: behind) == "Dev ↓1")

        let both = GitBranch(name: "Dev", upstream: "origin/Dev", ahead: 2, behind: 1)
        #expect(GitBranchChipView.text(for: both) == "Dev ↑2 ↓1")
    }

    @Test("a detached HEAD says so rather than showing an empty chip")
    func detached() {
        // Against the localized primitive, not the English literal — the stand-in moved out of
        // `GitBranch.displayName` and into the app so it could be translated (PLAN.md §M12
        // Slice 11), and the app test target inherits whatever language is pinned (docs/NOTES.md).
        let expected = String(localized: "detached HEAD")
        #expect(GitBranchChipView.text(for: .detached) == expected)
        #expect(!expected.isEmpty, "a nameless branch must never render as an empty chip")
    }

    @Test("the tooltip spells out what the arrows meant")
    func toolTip() {
        let branch = GitBranch(name: "Dev", upstream: "origin/Dev", ahead: 1, behind: 3)
        let text = GitBranchChipView.toolTip(for: branch)
        // Assert against the localized primitives, not English literals, so the suite passes whatever
        // language the app test target inherits (docs/NOTES.md). Still pins the segment order, the
        // " · " join, and the singular/plural selection (1 → "commit", 3 → "commits").
        let expected = [
            String(localized: "Branch \("Dev")"),
            String(localized: "Tracking \("origin/Dev")"),
            String(localized: "\(1) commits to push"),
            String(localized: "\(3) commits to pull")
        ].joined(separator: " · ")
        #expect(text == expected)
    }

    @Test("a fresh repository reports having no commits, not a missing branch")
    func noCommits() {
        let branch = GitBranch(name: "main", hasNoCommits: true)
        #expect(GitBranchChipView.text(for: branch) == "main")
        let expected = [
            String(localized: "Branch \("main")"),
            String(localized: "No commits yet")
        ].joined(separator: " · ")
        #expect(GitBranchChipView.toolTip(for: branch) == expected)
    }
}

/// The Git gutter is *contextual* — installed only inside a repository — which is only safe because
/// it never enters a tab's stored column layout. If it did, every step into or out of a repository
/// would look like the user rearranging their columns, and would be persisted as such.
@Suite("Git status column")
@MainActor
struct GitStatusColumnTests {
    @Test("the Git column is contextual; the real columns are not")
    func contextual() {
        #expect(PanelViewController.Column.git.isContextual)
        for column in [PanelViewController.Column.name, .size, .date] {
            #expect(!column.isContextual)
        }
    }

    @Test("the default layout excludes the Git column")
    func defaultLayoutOmitsGit() {
        let ids = PanelViewController.defaultColumnLayout.map(\.id)
        #expect(ids == ["name", "size", "date"])
    }

    @Test("the gutter is not sortable; every real column is")
    func sortability() {
        #expect(PanelViewController.Column.git.sortKey == nil)
        #expect(PanelViewController.Column.name.sortKey == .name)
        #expect(PanelViewController.Column.size.sortKey == .size)
        #expect(PanelViewController.Column.date.sortKey == .modified)
    }

    @Test("the gutter is fixed-width — it holds one letter, not data")
    func fixedWidth() {
        #expect(
            PanelViewController.Column.git.minWidth == PanelViewController.Column.git.defaultWidth
        )
    }
}
