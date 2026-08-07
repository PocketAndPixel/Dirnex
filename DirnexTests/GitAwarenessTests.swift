import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's own decisions about Git awareness (PLAN.md §M6). What Git's bytes *mean* is
/// `DirnexCore`'s and is tested there; spawning `git` and caching its answers is non-hermetic and
/// is exercised live, as with `SMBMounter`. What is left — and is here — are the two places the app
/// makes a call of its own: how a branch reads in the path bar, and how a file's status reads in the
/// name cell now that it is a badge rather than a column.
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

/// Git's status letter rides at the trailing edge of the name cell, outside the tag dots and the
/// cloud badge — it was a contextual 20 pt column until it wasn't, and `GitBadgeView` argues the
/// move. What is worth pinning is what the move could break: the badge must cost an ordinary row
/// nothing, it must not displace the two badges that were already there, and the column it used to
/// be must be gone from the layout machinery rather than merely never installed.
@Suite("Git status badge")
@MainActor
struct GitStatusBadgeTests {
    private func nameCell() -> FileCellView {
        FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
    }

    /// A status with no letter would be a badge that reserves width and draws nothing.
    @Test("every status the badge can show has a letter")
    func everyVisibleStatusHasACode() {
        for status in GitFileStatus.allCases where status != .unmodified {
            #expect(status.code != nil, "no letter for \(status)")
        }
        // The one that renders nothing, and the reason `gitStatus(for:)` collapses it to `nil`.
        #expect(GitFileStatus.unmodified.code == nil)
    }

    @Test("every status has tooltip text")
    func everyStatusHasALabel() {
        for status in GitFileStatus.allCases {
            #expect(!GitStatusStyle.label(for: status).isEmpty)
        }
        // Distinct, or the tooltip cannot tell two states apart — which is the whole reason a
        // one-letter badge carries one.
        let labels = GitFileStatus.allCases.map(GitStatusStyle.label(for:))
        #expect(Set(labels).count == labels.count)
    }

    /// The bargain the whole move rests on: a row outside a repository must give its name the full
    /// cell, exactly as it did before the badge existed.
    @Test("a badge with nothing to say takes no width, and one with something does")
    func widthIsPaidOnlyWhenThereIsSomethingToShow() {
        let badge = GitBadgeView()
        #expect(badge.intrinsicContentSize.width == 0)

        badge.status = .modified
        #expect(badge.intrinsicContentSize.width > 0)

        badge.status = nil
        #expect(badge.intrinsicContentSize.width == 0)
    }

    /// Every letter is centred in one slot, so a repository's rows read as a column rather than a
    /// ragged edge: `!` is 4 pt wide and `M` is 11, and right-aligning them would show it.
    @Test("the badge is the same width whichever letter it holds")
    func widthDoesNotFollowTheLetter() {
        let badge = GitBadgeView()
        badge.status = .modified
        let widest = badge.intrinsicContentSize.width
        for status in GitFileStatus.allCases where status != .unmodified {
            badge.status = status
            #expect(badge.intrinsicContentSize.width == widest)
        }
    }

    @Test("the name cell carries a badge and every other column does not")
    func onlyTheNameCellHasABadge() {
        #expect(nameCell().gitBadge != nil)

        let size = FileCellView(showsImage: false, identifier: .init("size"))
        #expect(size.gitBadge == nil)
        // Setting a status on a column that has no badge is a no-op, not a crash: the table's
        // render pass sets it on the name column only, but the accessor is on every cell.
        size.gitStatus = .modified
        #expect(size.gitStatus == nil)
    }

    /// The user's stated order — dots, cloud, Git — and the property that makes it safe to add a
    /// third badge at all: each one holds its own measured place and steps aside only for a badge
    /// that is really there.
    @Test("the letter sits outside the cloud, which sits outside the dots")
    func badgeOrderIsDotsThenCloudThenGit() throws {
        let cell = nameCell()
        cell.frame = NSRect(x: 0, y: 0, width: 293.5, height: 22)
        cell.tags = [FinderTag(name: "Red", color: .red)]
        cell.syncStatus = .notDownloaded
        cell.gitStatus = .modified
        cell.layoutSubtreeIfNeeded()

        let dots = try #require(cell.tagDots)
        let cloud = try #require(cell.syncBadge)
        let git = try #require(cell.gitBadge)
        #expect(dots.frame.maxX <= cloud.frame.minX + 0.01)
        #expect(cloud.frame.maxX <= git.frame.minX + 0.01)
    }

    /// The regression the third badge could have shipped: the Git badge shares the cloud's trailing
    /// anchor — which hangs 4 pt into the intercell gutter — so an *empty* one must be zero-width
    /// and land exactly on that edge, leaving the cloud where `SyncBadgeTests` measured it. Anything
    /// else would drag the cloud (and the dots behind it) inward on every row outside a repository,
    /// which is most rows on most Macs.
    @Test("no Git status leaves the cloud badge exactly where it was")
    func emptyBadgeDoesNotDisplaceTheCloud() throws {
        let cell = nameCell()
        cell.frame = NSRect(x: 0, y: 0, width: 293.5, height: 22)
        cell.syncStatus = .notDownloaded
        cell.layoutSubtreeIfNeeded()
        let cloud = try #require(cell.syncBadge)
        #expect(cloud.frame.maxX > cell.bounds.maxX)
    }

    /// Renaming (F2) hands the editor the whole cell — all three badges, not the two that predate it.
    @Test("beginning a rename clears the badge so the editor gets the full width")
    func renameEditorReclaimsTheBadgeWidth() {
        let cell = nameCell()
        cell.gitStatus = .modified
        #expect(cell.gitBadge?.intrinsicContentSize.width ?? 0 > 0)

        cell.beginNameEditing(delegate: RenameDelegate())
        #expect(cell.gitStatus == nil)
        #expect(cell.gitBadge?.intrinsicContentSize.width == 0)
    }

    /// `..` is not an entry, and its cell comes out of the *same* reuse pool as the real name cells
    /// — so a badge left on a recycled cell would hang a scrolled-away file's status on the way out
    /// of the folder.
    @Test("clearing badges empties all three")
    func clearBadgesEmptiesEveryOne() {
        let cell = nameCell()
        cell.tags = [FinderTag(name: "Red", color: .red)]
        cell.syncStatus = .notDownloaded
        cell.gitStatus = .modified

        cell.clearBadges()
        #expect(cell.tags.isEmpty)
        #expect(cell.syncStatus == nil)
        #expect(cell.gitStatus == nil)
    }

    /// The gutter is gone from the layout machinery, not merely never installed. It never entered a
    /// stored layout while it existed (that is what made a contextual column safe), so nothing has
    /// to be migrated — but a `Column` case left behind would be a column the user could be handed
    /// by a stale layout, drawing nothing.
    @Test("there is no Git column left to install")
    func noGitColumnRemains() {
        #expect(PanelViewController.Column(rawValue: "git") == nil)
        let ids = PanelViewController.defaultColumnLayout.map(\.id)
        #expect(ids == ["name", "size", "date"])
    }

    private final class RenameDelegate: NSObject, NSTextFieldDelegate {}
}
