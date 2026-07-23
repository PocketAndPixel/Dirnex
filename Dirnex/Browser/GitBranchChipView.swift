import AppKit
import DirnexCore

/// The branch indicator at the trailing end of the path bar (PLAN.md §M6 "Git awareness: branch in
/// path bar"): a branch glyph, the branch name, and — only when the branch has actually drifted —
/// how far ahead of and behind its upstream it is.
///
/// Deliberately inert: it shows, it does not act. A file manager that offers a click here is
/// offering to switch branches, and the one thing worse than not having Git operations in a file
/// manager is having them where a misclick rewrites the working tree.
@MainActor
final class GitBranchChipView: NSView {
    /// The branch to show; `nil` hides the chip entirely (not in a repository). Setting it is
    /// cheap and idempotent — the pane pushes the branch on every chrome update, most of which
    /// change nothing.
    var branch: GitBranch? {
        didSet {
            guard branch != oldValue else { return }
            render()
        }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        icon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: String(
                localized: "Git branch",
                comment: "Accessibility label for the branch glyph in the path bar."
            )
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // The chip is the shortest thing in the bar and names where you are — the crumbs truncate
        // around it rather than it around them. Still below the 250 the panes' split items hold at,
        // so like everything else in this bar it can never widen the pane past the user's divider.
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(245), for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(245),
            for: .horizontal
        )
    }

    private func render() {
        guard let branch else {
            isHidden = true
            return
        }
        isHidden = false
        label.stringValue = Self.text(for: branch)
        toolTip = Self.toolTip(for: branch)
    }

    /// `Dev`, or `Dev ↑2↓1` when it has drifted from its upstream. The arrows are the one piece of
    /// shorthand here, and they are the same ones `git status`'s own long form spells out.
    static func text(for branch: GitBranch) -> String {
        var text = branch.displayName
        if branch.ahead > 0 {
            text += " ↑\(branch.ahead)"
        }
        if branch.behind > 0 {
            text += " ↓\(branch.behind)"
        }
        return text
    }

    /// The long form, for the hover the shorthand earns: what the arrows meant, and which upstream
    /// they were measured against.
    static func toolTip(for branch: GitBranch) -> String {
        var lines = [
            branch.isDetached
                ? String(
                    localized: "Detached HEAD",
                    comment: "Git branch tooltip: HEAD is not on a branch."
                )
                : String(
                    localized: "Branch \(branch.displayName)",
                    comment: "Git branch tooltip; %@ is the branch name."
                )
        ]
        if branch.hasNoCommits {
            lines.append(String(
                localized: "No commits yet",
                comment: "Git branch tooltip: the branch has no commits."
            ))
        }
        if let upstream = branch.upstream {
            lines.append(String(
                localized: "Tracking \(upstream)",
                comment: "Git branch tooltip; %@ is the upstream ref."
            ))
        }
        // Catalog plurals rather than a hand-rolled commit/commits (docs/NOTES.md).
        if branch.ahead > 0 {
            lines.append(String(
                localized: "\(branch.ahead) commits to push",
                comment: "Git branch tooltip; %lld commits are ahead of upstream. Plural."
            ))
        }
        if branch.behind > 0 {
            lines.append(String(
                localized: "\(branch.behind) commits to pull",
                comment: "Git branch tooltip; %lld commits are behind upstream. Plural."
            ))
        }
        return lines.joined(separator: " · ")
    }
}
