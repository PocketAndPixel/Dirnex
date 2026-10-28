import Foundation

/// A lone tap of one modifier key: pressed with no other modifier held, released within
/// ``maximumDuration``, with no key, click or scroll in between. A tap of ⌥ opens the pane's
/// context menu over the cursor row (2026-10-25). This is the rule; the app's event monitor feeds
/// it.
///
/// ⌥ starts more gestures here than any other modifier: ⌥F5, ⌥↓, ⌥-click, ⌥-drag, and ⌥E for é in
/// type-to-filter. Each one puts a key, a click or a second modifier between the press and the
/// release, and that spoils the tap. The menu opens on the release, so it never catches the rest
/// of a chord. A press held past ``maximumDuration`` is a chord given up on, not a tap.
///
/// The app reports every change of the four modifier keys (⌃⌥⇧⌘; Caps Lock and fn are left out)
/// through ``modifiersChanged(to:at:)``, and anything else that happens through ``interrupt()``.
public struct ModifierTap: Sendable, Equatable {
    /// The key whose tap this recognizes.
    public let modifier: CommandShortcut.Modifiers
    /// The longest press that still counts as a tap, in seconds.
    public let maximumDuration: TimeInterval

    /// The modifiers held as of the last change reported.
    private var held: CommandShortcut.Modifiers = []
    /// When ``modifier`` went down alone, while that press can still become a tap.
    private var pressedAt: TimeInterval?

    public init(modifier: CommandShortcut.Modifiers, maximumDuration: TimeInterval) {
        self.modifier = modifier
        self.maximumDuration = maximumDuration
    }

    /// The modifiers held changed to `now`, at `time` (seconds, on any clock that only moves
    /// forward). `true` when this change ends a tap.
    ///
    /// Only a press from nothing held starts a tap. ⌥ left held when ⇧ is let go is not one, and
    /// neither is the second ⌥ key going down while the first is held, which reports the same
    /// modifiers again.
    public mutating func modifiersChanged(
        to now: CommandShortcut.Modifiers,
        at time: TimeInterval
    ) -> Bool {
        defer { held = now }
        if now == modifier, held.isEmpty {
            pressedAt = time
            return false
        }
        guard now.isEmpty, held == modifier, let start = pressedAt else {
            pressedAt = nil
            return false
        }
        pressedAt = nil
        return time - start <= maximumDuration
    }

    /// Something other than a modifier happened (a key, a click, a scroll): the press under way is
    /// no longer a tap. What is held is unchanged.
    public mutating func interrupt() {
        pressedAt = nil
    }

    /// Start again from what the keyboard holds now, with no tap under way. For when changes may
    /// have been missed, such as while another app was active.
    public mutating func reset(holding now: CommandShortcut.Modifiers) {
        held = now
        pressedAt = nil
    }
}
