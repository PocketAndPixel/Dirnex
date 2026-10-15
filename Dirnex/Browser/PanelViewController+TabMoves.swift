import AppKit
import DirnexCore

/// Moving tabs: along a pane's strip from the keyboard (⌥⌘[ and ⌥⌘]), and to the other pane by
/// keyboard (⇧⌘M), from a chip's menu, or by dropping a chip on the other pane's strip. Where a tab
/// lands and which one shows afterwards is `TabList`'s; what lives here is handing a tab from one
/// pane to the other and keeping both panes' chrome, watchers and saved tabs in step.
///
/// A tab takes everything that is its own, because it is the same `PanelTab` object in its new pane:
/// the directory, cursor, marks, history, columns, shape, and a search's question. Both panes list
/// through the window's one backend, so a tab on a server, inside an archive or in a vault moves as it
/// is. What belongs to the *pane* — its folder watcher, the Git watcher, the remote poll, a size walk
/// — is re-pointed by `activateTab` on both sides, the funnel every tab switch already goes through.
///
/// Not carried across: undoing a marking change. The journal records it against a side and a folder
/// (`applyUndoSelection`), so ⌘Z after the tab has moved finds no matching tab on that side and does
/// nothing. It never marks the wrong rows, which is why it is left.
extension PanelViewController {
    // MARK: - Menu actions

    @objc func moveTabLeft(_ sender: Any?) {
        moveActiveTab(by: -1)
    }

    @objc func moveTabRight(_ sender: Any?) {
        moveActiveTab(by: 1)
    }

    @objc func moveTabToOtherPanel(_ sender: Any?) {
        moveTabToOtherPanel(at: activeTabIndex)
    }

    /// Whether each of the three applies to this pane now, or `nil` for any other item. A step needs
    /// a neighbour on that side; sending needs a tab to leave behind and a pane to receive it.
    func validateTabMoveItem(_ menuItem: NSMenuItem) -> Bool? {
        let list = TabList(tabs: tabs, activeIndex: activeTabIndex)
        switch menuItem.action {
        case #selector(moveTabLeft(_:)):
            return list.canMoveActive(by: -1)
        case #selector(moveTabRight(_:)):
            return list.canMoveActive(by: 1)
        case #selector(moveTabToOtherPanel(_:)):
            return list.canRemove && host?.panelCounterpart(of: self) != nil
        default:
            return nil
        }
    }

    // MARK: - Along the strip

    /// Step the showing tab `offset` places along this pane's strip. Nothing happens at either end.
    func moveActiveTab(by offset: Int) {
        guard updateTabList({ $0.moveActive(by: offset) }) else { return }
        refreshTabBar()
        persistState()
    }

    // MARK: - To the other pane

    /// Send the tab at `index` to the other pane, into `slot` of its strip or else beside the tab it
    /// is showing, and follow it there with the focus.
    func moveTabToOtherPanel(at index: Int, atSlot slot: Int? = nil) {
        guard let destination = host?.panelCounterpart(of: self) else { return }
        handOverTab(at: index, to: destination, atSlot: slot)
    }

    /// Move the tab at `index` into `destination`, show it there and focus that pane: the tab that
    /// moved is the one being worked in. `slot` defaults to the gap after the tab `destination` is
    /// showing, which is where ⌘Return opens a folder over there too. Refused, with nothing changed,
    /// for this pane's last tab, since a pane always shows one.
    func handOverTab(at index: Int, to destination: PanelViewController, atSlot slot: Int? = nil) {
        guard destination !== self, let tab = detachTab(at: index) else { return }
        destination.receive(tab, atSlot: slot ?? destination.activeTabIndex + 1)
        destination.focusTable()
    }

    /// Take the tab at `index` out of this pane, showing whichever tab takes over if it was the one
    /// on screen.
    private func detachTab(at index: Int) -> PanelTab? {
        let wasShowing = index == activeTabIndex
        guard let tab = updateTabList({ $0.remove(at: index) }) else { return nil }
        if wasShowing {
            // A listing still in flight was asked for the tab that just left. Landing on the tab that
            // takes over, it would put one folder's rows under another folder's path.
            loadToken += 1
            activateTab()
        } else {
            refreshTabBar()
        }
        persistState()
        return tab
    }

    /// Show `tab`, arriving from the other pane, in `slot` of this one.
    private func receive(_ tab: PanelTab, atSlot slot: Int) {
        updateTabList { $0.insert(tab, atSlot: slot) }
        activateTab()
        persistState()
    }

    // MARK: - Dragging

    /// Show the other pane's strip while one of this pane's chips is being dragged, even when it has
    /// a single tab and would hide it, so there is somewhere to drop; `false` puts it back.
    func revealCounterpartTabBar(_ reveal: Bool) {
        guard let other = host?.panelCounterpart(of: self) else { return }
        other.tabBar.isRevealedForDrag = reveal
        other.refreshTabBar()
    }
}
