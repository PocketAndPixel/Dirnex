import AppKit
import DirnexCore

/// Dragging a tab chip: along its own strip to reorder, or onto the other pane's strip to move the tab
/// there — and the chip's menu, which offers the move without a drag.
///
/// **A real `NSDraggingSession`, not mouse tracking.** The first strip followed the mouse itself and
/// acted on the mouse-up, which could not see the other pane's strip and drew nothing on the way. A
/// session gets hit testing across both strips, Escape to cancel and the slide back after a refused
/// drop from AppKit, and each strip is simply a drop target for the other.
///
/// The payload is the chip's index under ``TabBarView/tabDragType``, and the bar it came from is the
/// session's source. That is in-process identity, which a real drag preserves; nothing outside the
/// app is offered the drag (`sourceOperationMaskFor`), so dropping a tab on Finder or on a file list
/// does nothing rather than reading it as a folder — the line the sidebar's reorder drag draws too.
///
/// Where a drop lands is `TabSlot`'s: a gap between chips, worked out from their midpoints. A gap that
/// would leave the dragged tab where it is is refused, which lets the image slide back and says
/// "nothing will happen" better than a marker would.
extension TabBarView {
    // MARK: - Starting a drag

    /// Start dragging `chip`, from the `mouseDragged` event that crossed the drag threshold.
    func beginDrag(of chip: TabChipView, with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(String(chip.index), forType: Self.tabDragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(chip.convert(chip.bounds, to: self), contents: chip.dragImage())
        draggedIndex = chip.index
        chip.alphaValue = TabChipView.draggedAlpha
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    // MARK: - Receiving a drag

    /// The bar and chip index a drag carries, or `nil` when it is not a tab chip of this window.
    func draggedTab(in info: NSDraggingInfo) -> (source: TabBarView, index: Int)? {
        guard let source = info.draggingSource as? TabBarView,
              let raw = info.draggingPasteboard.string(forType: Self.tabDragType),
              let index = Int(raw), source.chips.indices.contains(index) else { return nil }
        return (source, index)
    }

    /// The gap a drag at `info`'s pointer would drop into.
    func dropSlot(for info: NSDraggingInfo) -> Int {
        let x = convert(info.draggingLocation, from: nil).x
        return TabSlot.slot(forDropAt: Double(x), chipMidpoints: chipFrames.map { Double($0.midX) })
    }

    /// What a drop at `info`'s pointer would do: `.move` with the marker in its gap, or nothing for
    /// anything that is not a tab, or a tab that would land where it already is.
    func dropOperation(for info: NSDraggingInfo) -> NSDragOperation {
        guard let drag = draggedTab(in: info) else {
            insertionMarker.isHidden = true
            return []
        }
        let slot = dropSlot(for: info)
        if drag.source === self, TabSlot.isNoOpMove(from: drag.index, toSlot: slot) {
            insertionMarker.isHidden = true
            return []
        }
        showInsertionMarker(at: slot)
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionMarker.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        insertionMarker.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { insertionMarker.isHidden = true }
        guard !dropOperation(for: sender).isEmpty, let drag = draggedTab(in: sender) else { return false }
        let slot = dropSlot(for: sender)
        // The strips rebuild before the session reports its end, and a stale index would fade
        // whichever tab now sits where the dragged one was.
        drag.source.draggedIndex = nil
        if drag.source === self {
            delegate?.tabBar(self, didMoveTabFrom: drag.index, toSlot: slot)
        } else {
            delegate?.tabBar(self, didReceiveTabAt: drag.index, from: drag.source, atSlot: slot)
        }
        return true
    }

    /// Each chip's frame in this view's coordinates, in strip order.
    private var chipFrames: [NSRect] {
        chips.map { $0.convert($0.bounds, to: self) }
    }

    /// Draw the marker in the middle of the gap `slot` names: before chip `slot`, or after the last.
    private func showInsertionMarker(at slot: Int) {
        let frames = chipFrames
        guard let last = frames.last else { return }
        let gap = Self.chipSpacing / 2
        let x = frames.indices.contains(slot) ? frames[slot].minX - gap : last.maxX + gap
        let width: CGFloat = 2
        insertionMarker.frame = NSRect(
            x: max(x - width / 2, 0),
            y: last.minY - 1,
            width: width,
            height: last.height + 2
        )
        insertionMarker.layer?.backgroundColor = AppPreferences.shared.palette.resolvedAccent.cgColor
        insertionMarker.isHidden = false
    }

    // MARK: - The chip's menu

    /// The menu a right-click (or ⌃-click) on `chip` shows. Its items carry the chip's index from
    /// when the menu was built, rather than reading the active tab, because the chip clicked need
    /// not be the one showing (docs/NOTES.md ▸ AppKit, right-click menu items).
    func chipMenu(for chip: TabChipView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canLeave = chips.count > 1
        menu.addItem(chipMenuItem(
            "window.moveTabToOtherPanel", action: #selector(moveChipToOtherPanel(_:)), chip: chip,
            enabled: canLeave
        ))
        menu.addItem(.separator())
        menu.addItem(chipMenuItem(
            "file.closeTab", action: #selector(closeChip(_:)), chip: chip, enabled: canLeave
        ))
        return menu
    }

    /// One item of a chip's menu, titled as the command of the same name everywhere else. No key
    /// equivalent: the command's key acts on the tab showing, which need not be this one.
    private func chipMenuItem(
        _ commandID: String,
        action: Selector,
        chip: TabChipView,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: LocalizedCatalog.command(for: commandID)?.title ?? commandID,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = chip.index
        item.isEnabled = enabled
        return item
    }

    @objc private func moveChipToOtherPanel(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        delegate?.tabBar(self, didRequestOtherPanelForTabAt: index)
    }

    @objc private func closeChip(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        delegate?.tabBar(self, didCloseTabAt: index)
    }
}

// MARK: - NSDraggingSource

extension TabBarView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        delegate?.tabBar(self, tabDragIsInFlight: true)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        draggedIndex = nil
        for chip in chips { chip.alphaValue = 1 }
        delegate?.tabBar(self, tabDragIsInFlight: false)
    }
}

// MARK: - The drag image

extension TabChipView {
    /// The chip as the pointer carries it: drawn rather than snapshotted, because its fill is a layer
    /// property a view snapshot does not reliably capture. An inactive chip has no fill of its own,
    /// so it is given the control background and a hairline to stand out from what it passes over.
    ///
    /// The glyph and the label are drawn where the live chip lays them out, so the image is the chip
    /// rather than a second layout of it. The glyph is colored by its configuration rather than
    /// tinted: a template image drawn by hand comes out black.
    func dragImage() -> NSImage {
        let (background, text) = colors
        let fill = background.alphaComponent > 0 ? background : NSColor.controlBackgroundColor
        let title = title
        let iconFrame = iconFrame
        let labelFrame = labelFrame
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfiguration.applying(.init(paletteColors: [text])))
        return NSImage(size: bounds.size, flipped: false) { rect in
            let chip = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 5,
                yRadius: 5
            )
            fill.setFill()
            chip.fill()
            NSColor.separatorColor.setStroke()
            chip.stroke()
            symbol?.draw(in: iconFrame)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: text
            ]
            let height = NSString(string: title).size(withAttributes: attributes).height
            NSString(string: title).draw(
                in: NSRect(
                    x: labelFrame.minX,
                    y: (rect.height - height) / 2,
                    width: max(labelFrame.width, 0),
                    height: height
                ),
                withAttributes: attributes
            )
            return true
        }
    }
}
