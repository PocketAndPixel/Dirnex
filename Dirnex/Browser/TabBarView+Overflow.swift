import AppKit
import DirnexCore

/// The tabs that do not fit: a strip too narrow for every chip at a readable width shows a run of
/// them, and a » after the last chip lists the rest.
///
/// A chip shrinks with the others (`TabBarView.chipCap`) until its label is about six letters, and
/// past that its tab leaves the strip rather than shrink further. Which tabs stay is `TabOverflow`'s
/// call: a run of adjacent tabs holding the active one, which moves only when the active tab leaves
/// it. The strip never asks its pane for more room, because its stack gives way below the pane's own
/// priorities, so tabs that do not fit cannot push the split divider into the other pane.
extension TabBarView {
    func configureOverflowButton() {
        let title = String(
            localized: "More Tabs",
            comment: "Label and tooltip of the » button listing the tabs that don't fit on a pane's tab strip."
        )
        overflowButton.image = NSImage(
            systemSymbolName: "chevron.right.2",
            accessibilityDescription: title
        )
        overflowButton.imageScaling = .scaleProportionallyDown
        overflowButton.isBordered = false
        overflowButton.bezelStyle = .inline
        overflowButton.setButtonType(.momentaryChange)
        overflowButton.controlSize = .small
        overflowButton.contentTintColor = .secondaryLabelColor
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu(_:))
        overflowButton.toolTip = title
        overflowButton.isHidden = true
    }

    /// Decide which tabs get a chip at the strip's width now, and hide the rest behind the ».
    func updateOverflow() {
        let strip = TabOverflow.Strip(
            minimumWidths: chips.map { Double($0.minimumWidth) },
            spacing: Double(Self.chipSpacing),
            // The new-tab button, and the gaps before it and after it, are spent whatever fits.
            width: Double(bounds.width - newButton.intrinsicContentSize.width - 2 * Self.chipSpacing),
            overflowControlWidth: Double(overflowButton.intrinsicContentSize.width)
        )
        let range = TabOverflow.visibleRange(
            in: strip,
            activeIndex: activeIndex,
            previousStart: runStart
        )
        runStart = range.lowerBound
        visibleRange = range
        // Only what changed, so a layout that moves nothing leaves the stack's arrangement alone.
        for chip in chips where chip.isHidden == range.contains(chip.index) {
            chip.isHidden.toggle()
            capConstraints[chip.index].isActive = !chip.isHidden
        }
        let overflows = range.count < chips.count
        if overflowButton.isHidden == overflows {
            overflowButton.isHidden.toggle()
        }
    }

    /// The menu the » shows: every tab without a chip, in strip order, with a separator between the
    /// tabs before the run on the strip and those after it.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for chip in chips where !visibleRange.contains(chip.index) {
            if chip.index == visibleRange.upperBound, !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(
                title: chip.title,
                action: #selector(selectOverflowTab(_:)),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: chip.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(TabChipView.symbolConfiguration)
            item.target = self
            item.representedObject = chip.index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showOverflowMenu(_ sender: NSButton) {
        let below = NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4)
        overflowMenu().popUp(positioning: nil, at: below, in: sender)
    }

    @objc private func selectOverflowTab(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        delegate?.tabBar(self, didSelectTabAt: index)
    }
}
