import AppKit
import Testing

@testable import Dirnex

/// Escape's binding on the app's alerts.
///
/// This exists because `NSAlert` binds Escape itself — but it matches the **byte string "Cancel"**,
/// not a localized one. Probed with the process pinned to `ru`, a button titled «Отмена» is given no
/// key equivalent at all, so under any translation AppKit's binding silently stops happening and
/// every alert loses its way out. The old implementation then guessed from a set of *English*
/// titles, which fails for exactly the same reason and in the same silence — an English screenshot
/// looks perfect.
///
/// So the choice must not be readable from a title, and these tests are written to fail if it ever
/// becomes so again: the Russian cases carry no English word anywhere.
@Suite("Escape to dismiss")
@MainActor
struct EscapeToDismissTests {
    private static let escape = "\u{1b}"

    private func alert(_ titles: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "probe"
        for title in titles { alert.addButton(withTitle: title) }
        return alert
    }

    @Test("the last button answers Escape by default — where a Cancel belongs")
    func defaultsToLastButton() {
        let alert = alert(["Replace", "Cancel"])
        alert.enableEscapeToCancel()
        #expect(alert.buttons.last?.keyEquivalent == Self.escape)
        #expect(alert.buttons.first?.keyEquivalent != Self.escape)
    }

    /// The regression the localization audit turned up: with no English title to match, the old
    /// code fell through to the last button in every translated build.
    @Test("a translated Cancel still answers Escape")
    func translatedCancelStillBinds() {
        let alert = alert(["Заменить", "Отмена"])
        alert.enableEscapeToCancel()
        #expect(alert.buttons.last?.keyEquivalent == Self.escape)
    }

    @Test("a named safe response wins over the last-button default")
    func namedResponseWins() {
        let alert = alert(["OK", "Open System Settings"])
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        #expect(alert.buttons.first?.keyEquivalent == Self.escape)
        #expect(alert.buttons.last?.keyEquivalent != Self.escape)
    }

    /// AppKit gives an English "Cancel" Escape as the alert is built. When the caller names a
    /// different button, that stale binding has to be cleared — two buttons answering Escape is
    /// undefined, and the wrong one may win.
    @Test("AppKit's own English binding is moved, not left alongside ours")
    func stalePlatformBindingIsCleared() {
        let alert = alert(["Cancel", "Trust New Key & Connect"])
        // Precondition: this is AppKit's doing, not ours — if it ever stops, the test below is moot.
        #expect(alert.buttons.first?.keyEquivalent == Self.escape)
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        let bound = alert.buttons.filter { $0.keyEquivalent == Self.escape }
        #expect(bound.count == 1)
        #expect(bound.first === alert.buttons.last)
    }

    /// A translated Cancel added *first* to make it rightmost — the host-key alert's shape. AppKit
    /// gives it Return rather than Escape here, so without naming it the alert has no way out.
    @Test("a translated Cancel added first is reachable when it is named")
    func translatedCancelAddedFirst() {
        let alert = alert(["Отмена", "Доверять новому ключу"])
        #expect(alert.buttons.first?.keyEquivalent != Self.escape)
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        #expect(alert.buttons.first?.keyEquivalent == Self.escape)
    }

    /// One button can't carry Return *and* Escape, so a lone-button alert keeps its default and
    /// answers Escape through a zero-size accessory that clicks it.
    @Test("a lone button keeps Return and gets an accessory catcher instead")
    func loneButtonGetsAccessory() {
        let alert = alert(["OK"])
        alert.enableEscapeToCancel()
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.accessoryView is EscapeDismissingView)
    }

    /// An out-of-range response must not crash or bind nothing — it falls back to the default.
    @Test("a response naming a button that isn't there falls back to the last one")
    func outOfRangeResponseFallsBack() {
        let threeButtons = alert(["Retry", "Skip", "Abort"])
        threeButtons.enableEscapeToCancel(safe: .alertThirdButtonReturn)
        #expect(threeButtons.buttons.last?.keyEquivalent == Self.escape)
        // Same response, but there is no third button to hand it to.
        let twoButtons = alert(["Да", "Нет"])
        twoButtons.enableEscapeToCancel(safe: .alertThirdButtonReturn)
        #expect(twoButtons.buttons.last?.keyEquivalent == Self.escape)
    }
}
