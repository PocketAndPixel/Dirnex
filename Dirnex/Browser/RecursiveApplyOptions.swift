import AppKit
import DirnexCore

/// The "Apply to enclosed items" control both Get Info sheets show when a folder is involved
/// (PLAN.md §M14 Slice 4).
///
/// It sits in the sheet's **footer**, not in a tab, because it governs the whole Save: the mode grid
/// on Permissions, the dates on General and the list on Sharing all travel together. Putting it under
/// one tab would say it applied to that tab only.
///
/// The target popup is Total Commander's shape rather than Finder's single switch, and it earns its
/// place: the execute bit means opposite things on a file and on a folder, so `rw-r--r--` for files
/// and `rwxr-xr-x` for folders is two passes and has to be sayable. Applying one mode to everything
/// is what `chmod -R 0644` does, and what it does is leave a tree its owner can no longer open.
@MainActor
final class RecursiveApplyOptions {
    /// The live controls, retained by whoever owns this object for the sheet's lifetime.
    private let checkbox: NSButton
    private let targetPopup: NSPopUpButton

    /// Called whenever the checkbox is toggled, so a sheet can restate what Save will do.
    var onChange: (() -> Void)?

    /// Whether the user asked for the change to reach inside.
    var isRecursive: Bool { checkbox.state == .on }

    /// Which enclosed items are in scope. Meaningless while ``isRecursive`` is false, and the popup
    /// is disabled then so it cannot be set to something the run will not honour.
    var target: AttributeApplyScope.Target {
        AttributeApplyScope.Target.allCases.first { $0.tag == targetPopup.selectedTag() }
            ?? .everything
    }

    init() {
        checkbox = NSButton(checkboxWithTitle: String(
            localized: "Apply to enclosed items",
            comment: "Get Info checkbox: also change everything inside the selected folders."
        ), target: nil, action: nil)

        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for target in AttributeApplyScope.Target.allCases {
            let item = NSMenuItem(title: target.title, action: nil, keyEquivalent: "")
            item.tag = target.tag
            targetPopup.menu?.addItem(item)
        }
        targetPopup.selectItem(withTag: AttributeApplyScope.Target.everything.tag)
        targetPopup.isEnabled = false

        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
    }

    @objc private func toggled(_ sender: Any?) {
        targetPopup.isEnabled = isRecursive
        onChange?()
    }

    /// The footer row: the checkbox, the popup it enables, and nothing else. Laid out to the sheet's
    /// content width so it lines up with the tabs above it.
    func makeView(width: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [checkbox, targetPopup, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
}

extension AttributeApplyScope.Target {
    /// A stable, non-zero tag per case, so the popup never routes through a display string — the
    /// "a decision keyed off displayed text is a localization bug waiting for a translator" rule
    /// (docs/NOTES.md), and non-zero because `selectedTag()` answers `0` for no selection.
    var tag: Int {
        switch self {
        case .everything: return 1
        case .filesOnly: return 2
        case .foldersOnly: return 3
        }
    }

    /// What the popup shows. Whole phrases per case rather than a noun spliced into a frame — a
    /// language that inflects the object cannot build one from the other (docs/NOTES.md).
    var title: String {
        switch self {
        case .everything:
            return String(
                localized: "Files and folders",
                comment: "Get Info recursive-apply scope: change every enclosed item."
            )
        case .filesOnly:
            return String(
                localized: "Files only",
                comment: "Get Info recursive-apply scope: leave enclosed folders untouched."
            )
        case .foldersOnly:
            return String(
                localized: "Folders only",
                comment: "Get Info recursive-apply scope: leave enclosed files untouched."
            )
        }
    }
}
