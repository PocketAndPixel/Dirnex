import AppKit
import Testing

@testable import Dirnex

/// The New Vault sheet stays up until the vault exists: Create checks and creates on the open sheet,
/// and a failure is said in a row under the form rather than by closing it.
///
/// Geometry rather than text throughout, for the reason `PackAccessoryTests` gives: the app test
/// target inherits whatever `AppleLanguages` the developer has Dirnex pinned to, and a row unhidden
/// without making room for it draws over the passphrase note while every `isHidden` check passes.
/// The sheet itself is never presented — tearing a real `NSAlert` sheet down in the test host
/// segfaults it (docs/NOTES.md ▸ AppKit) — so the routing is asserted on the button and the key
/// catcher, which is everything between a press and `performClick`.
@Suite("New Vault sheet")
@MainActor
struct VaultCreateAccessoryTests {
    private static let short = "The two passphrases don’t match."
    private static let long = String(repeating: "A sentence long enough to wrap. ", count: 8)

    /// Every control but the error row, by frame — what must slide up together and come back.
    private func formFrames(of accessory: VaultCreateAccessory) -> [NSRect] {
        accessory.view.subviews.filter { $0 !== accessory.errorLabel }.map(\.frame)
    }

    @Test("the error row takes no room until there is something to say")
    func hiddenUntilNeeded() {
        let accessory = VaultCreateAccessory.make()
        #expect(accessory.errorLabel.isHidden)
        #expect(accessory.errorLabel.frame.height == 0)
        let floor = formFrames(of: accessory).map(\.minY).min()
        #expect(floor == 0)
    }

    @Test("an error slides the whole form up by exactly the row it adds")
    func errorMakesRoom() throws {
        let accessory = VaultCreateAccessory.make()
        let before = formFrames(of: accessory)
        let height = accessory.view.frame.height
        var relayouts = 0
        accessory.onHeightChange = { relayouts += 1 }

        accessory.showError(Self.short)

        let shift = accessory.view.frame.height - height
        #expect(shift > 0)
        #expect(relayouts == 1)
        #expect(!accessory.errorLabel.isHidden)
        #expect(accessory.errorLabel.frame.minY == 0)
        #expect(accessory.errorLabel.frame.height > 0)
        let after = formFrames(of: accessory)
        #expect(after == before.map { $0.offsetBy(dx: 0, dy: shift) })
        // Nothing overlaps the row: the note it sits under starts above it.
        let floor = try #require(after.map(\.minY).min())
        #expect(floor > accessory.errorLabel.frame.maxY)
    }

    @Test("clearing the error puts every control back where it was")
    func clearingRestores() {
        let accessory = VaultCreateAccessory.make()
        let before = formFrames(of: accessory)
        let height = accessory.view.frame.height

        accessory.showError(Self.short)
        accessory.showError(nil)

        #expect(accessory.errorLabel.isHidden)
        #expect(accessory.view.frame.height == height)
        #expect(formFrames(of: accessory) == before)
    }

    /// The second failure on one sheet is the ordinary case — a mismatch, then a name already taken —
    /// and a row that added its new height to the old one would leave the form drifting upward.
    @Test("a second error re-measures the row rather than stacking on the first")
    func secondErrorReplaces() {
        let twice = VaultCreateAccessory.make()
        twice.showError(Self.short)
        twice.showError(Self.long)

        let once = VaultCreateAccessory.make()
        once.showError(Self.long)

        #expect(twice.view.frame.height == once.view.frame.height)
        #expect(formFrames(of: twice) == formFrames(of: once))
        #expect(twice.errorLabel.frame == once.errorLabel.frame)
        #expect(once.errorLabel.frame.height > NSFont.smallSystemFontSize * 2)
    }

    private func sheet(routedTo accessory: VaultCreateAccessory) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "probe"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        alert.accessoryView = accessory.view
        accessory.routeCreate(through: alert.buttons[0])
        return alert
    }

    @Test("Create runs the check instead of ending the sheet")
    func createIsRouted() {
        let accessory = VaultCreateAccessory.make()
        let alert = sheet(routedTo: accessory)
        var presses = 0
        accessory.onCreate = { presses += 1 }

        alert.buttons[0].performClick(nil)

        #expect(presses == 1)
        #expect(alert.buttons[0].target === accessory)
        // Cancel is left alone: it still ends the sheet through the alert.
        #expect(alert.buttons[1].target === alert)
    }

    /// Return is how most people press Create, and it arrives through `AlertKeyCatcher` rather than
    /// a click — so the catcher has to resolve it to the very button that was retargeted.
    @Test("Return reaches the routed Create button")
    func returnIsRouted() throws {
        let accessory = VaultCreateAccessory.make()
        let alert = sheet(routedTo: accessory)
        let catcher = try #require(
            alert.window.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
        )
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(catcher.button(for: event) === alert.buttons[0])
    }

    /// The buttons are turned off while `hdiutil` runs; that has to stop a second create, not just
    /// gray the button.
    @Test("a disabled Create runs nothing")
    func disabledCreateIsInert() {
        let accessory = VaultCreateAccessory.make()
        let alert = sheet(routedTo: accessory)
        var presses = 0
        accessory.onCreate = { presses += 1 }

        alert.buttons[0].isEnabled = false
        alert.buttons[0].performClick(nil)

        #expect(presses == 0)
    }
}
