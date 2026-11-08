import AppKit
import DirnexCore

/// Moving through the byte view (PLAN.md §M37 Slice 2): the toolbar's arrows, a click in the overview
/// strip, and the keys, which are the text window's where it has the same thing to do.
///
/// A local monitor, as in the text window, so the menu bar does not take the keys first.
/// - ⌥⌘↓ / ⌥⌘↑: the next and the previous difference.
/// - ⌘W and ⎋: close the window.
///
/// The arrows, Page Up and Page Down, Home and End are the table's own.
extension BinaryCompareWindowController {
    /// Go to the change holding `offset`.
    func goToChange(at offset: Int64) {
        currentChangeOffset = offset
        let row = min(rowCount - 1, Int(BinaryHexLayout.row(containing: offset)))
        isMovingSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        isMovingSelection = false
        reveal(row: row)
        refreshCounter()
    }

    /// The offset the next and previous are counted from: the current change, else the selected
    /// row, else the top of the screen.
    private var positionOffset: Int64 {
        if let currentChangeOffset {
            return currentChangeOffset
        }
        let row = table.selectedRow >= 0 ? table.selectedRow : firstVisibleRow
        return BinaryHexLayout.offset(ofRow: Int64(row))
    }

    func goToNextChange() {
        guard let comparison else { return NSSound.beep() }
        // With no current change, one starting exactly at the position counts as the next.
        let after = currentChangeOffset ?? (positionOffset - 1)
        guard let next = comparison.change(after: after) else { return NSSound.beep() }
        goToChange(at: next.lowerBound)
    }

    func goToPreviousChange() {
        guard let previous = comparison?.change(before: positionOffset) else { return NSSound.beep() }
        goToChange(at: previous.lowerBound)
    }

    /// Show `row` with a few rows above it, so what leads up to a change is in view.
    ///
    /// The column header floats over the top of the clip view, so the clip's own top edge is under
    /// it (docs/NOTES.md ▸ Columns, headers, scrolling and zoom). Where the clip rests when pushed
    /// past the document's start says how much is covered, whatever the window's style makes of it.
    func reveal(row: Int) {
        let clip = scrollView.contentView
        let target = NSPoint(
            x: clip.bounds.minX,
            y: table.rect(ofRow: row).minY - 3 * table.rowHeight + restingTop
        )
        clip.scroll(
            to: clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
        )
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where the clip view's top rests at the start of the document: negative by whatever floats
    /// over it.
    var restingTop: CGFloat {
        let clip = scrollView.contentView
        let pastTheStart = NSRect(
            origin: NSPoint(x: clip.bounds.minX, y: -1_000_000),
            size: clip.bounds.size
        )
        return clip.constrainBoundsRect(pastTheStart).origin.y
    }

    /// Show `row`, from the overview strip: no change is the current one after that.
    func jump(toRow row: Int) {
        currentChangeOffset = nil
        reveal(row: min(row, rowCount - 1))
        refreshCounter()
    }

    /// Say which change is current, and how many there are so far. Nothing at all until the scan
    /// has found a change or finished, since "No differences" would be a claim about bytes nobody
    /// has compared yet.
    func refreshCounter() {
        guard let comparison, comparison.isFinished || !comparison.changes.isEmpty else {
            toolbar.counter.stringValue = ""
            toolbar.navigation.setEnabled(false, forSegment: 0)
            toolbar.navigation.setEnabled(false, forSegment: 1)
            return
        }
        let current = currentChangeOffset.flatMap(comparison.changeIndex(containing:))
        toolbar.showCounter(current: current, count: comparison.changes.count)
    }

    // MARK: - Keys

    func windowDidBecomeKey(_ notification: Notification) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        removeKeyMonitor()
    }

    func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// What a key does in this window: `true` when it was taken.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch (event.specialKey, modifiers) {
        case (.downArrow?, [.option, .command]):
            goToNextChange()
            return true
        case (.upArrow?, [.option, .command]):
            goToPreviousChange()
            return true
        default:
            break
        }
        if event.charactersIgnoringModifiers?.lowercased() == "w", modifiers == [.command] {
            window?.performClose(nil)
            return true
        }
        guard event.keyCode == 53, modifiers.isEmpty else { return false }
        window?.performClose(nil)
        return true
    }
}
