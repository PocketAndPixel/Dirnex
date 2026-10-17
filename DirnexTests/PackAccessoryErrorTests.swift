import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The pack sheet stays up when the passphrases are empty or don't match: Pack checks them on the
/// open sheet, and a failure is said in a row under the form rather than by closing it.
///
/// The error row shares the accessory with the passphrase block's collapse, so most of this is about
/// the two not drifting each other — geometry rather than text throughout, for the reason
/// `PackAccessoryTests` gives. The sheet itself is never presented, for the reason
/// `VaultCreateAccessoryTests` gives, so the routing is asserted on the button and the key catcher.
@Suite("Pack sheet error row and routing")
@MainActor
struct PackAccessoryErrorTests {
    private func accessory(encryption: ArchiveEncryption = .none) -> PackAccessory {
        PackAccessory.make(PackAccessory.Defaults(baseName: "probe", encryption: encryption))
    }

    /// Drive a popup the way AppKit does, as `PackAccessoryTests` does — `selectItem(at:)` alone
    /// sends no action.
    private func choose(_ index: Int, in popup: NSPopUpButton) {
        popup.selectItem(at: index)
        guard let action = popup.action else {
            Issue.record("popup has no action — the accessory never wired itself up")
            return
        }
        NSApp.sendAction(action, to: popup.target, from: popup)
    }

    private var aes256: Int { ArchiveEncryption.allCases.firstIndex(of: .aes256) ?? 1 }
    private var noCipher: Int { ArchiveEncryption.allCases.firstIndex(of: .none) ?? 0 }

    private func passphraseRows(of accessory: PackAccessory) -> [NSView] {
        [accessory.passphraseField, accessory.confirmField, accessory.hideNamesCheckbox]
    }

    private static let short = "The two passphrases don’t match."
    private static let long = String(repeating: "A sentence long enough to wrap. ", count: 8)

    /// Every control but the error row, by frame, hidden ones included — the passphrase block has to
    /// keep its place while it is collapsed, or it comes back in the wrong one.
    private func formFrames(of accessory: PackAccessory) -> [NSRect] {
        accessory.view.subviews.filter { $0 !== accessory.errorLabel }.map(\.frame)
    }

    @Test("the error row takes no room until there is something to say")
    func errorHiddenUntilNeeded() {
        for encryption in ArchiveEncryption.allCases {
            let accessory = accessory(encryption: encryption)
            #expect(accessory.errorLabel.isHidden)
            #expect(accessory.errorLabel.frame.height == 0)
            let floor = accessory.view.subviews
                .filter { $0 !== accessory.errorLabel && !$0.isHidden }
                .map(\.frame.minY).min()
            #expect(floor == 0, "with encryption \(encryption)")
        }
    }

    @Test("an error slides the whole form up by exactly the row it adds")
    func errorMakesRoom() throws {
        let accessory = accessory(encryption: .aes256)
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
        // Nothing overlaps the row: the footer note it sits under starts above it.
        let floor = try #require(after.map(\.minY).min())
        #expect(floor > accessory.errorLabel.frame.maxY)
    }

    @Test("clearing the error puts every control back where it was")
    func clearingRestores() {
        let accessory = accessory(encryption: .aes256)
        let before = formFrames(of: accessory)
        let height = accessory.view.frame.height

        accessory.showError(Self.short)
        accessory.showError(nil)

        #expect(accessory.errorLabel.isHidden)
        #expect(accessory.view.frame.height == height)
        #expect(formFrames(of: accessory) == before)
    }

    /// An empty passphrase and then a mismatch on one sheet is the ordinary case, and a row that
    /// added its new height to the old one would leave the form drifting upward.
    @Test("a second error re-measures the row rather than stacking on the first")
    func secondErrorReplaces() {
        let twice = accessory(encryption: .aes256)
        twice.showError(Self.short)
        twice.showError(Self.long)

        let once = accessory(encryption: .aes256)
        once.showError(Self.long)

        #expect(twice.view.frame.height == once.view.frame.height)
        #expect(formFrames(of: twice) == formFrames(of: once))
        #expect(twice.errorLabel.frame == once.errorLabel.frame)
        #expect(once.errorLabel.frame.height > NSFont.smallSystemFontSize * 2)
    }

    /// The error is about rows the collapse takes away, so it goes with them — in the same relayout,
    /// and onto exactly the geometry a sheet that never had a cipher opens with.
    @Test("choosing no cipher clears the error and lands on the plain collapsed form")
    func collapseClearsError() {
        let accessory = accessory(encryption: .aes256)
        accessory.showError(Self.long)
        var relayouts = 0
        accessory.onHeightChange = { relayouts += 1 }

        choose(noCipher, in: accessory.encryptionPopup)

        #expect(relayouts == 1)
        #expect(accessory.errorLabel.isHidden)
        #expect(accessory.errorLabel.frame.height == 0)
        #expect(accessory.encryptionPopup.frame.minY == 0)
        let fresh = self.accessory()
        #expect(accessory.view.frame.height == fresh.view.frame.height)
        #expect(formFrames(of: accessory) == formFrames(of: fresh))
    }

    /// The two shifts run on overlapping sets of rows — the error row moves the hidden block, the
    /// collapse does not — so any mix-up between them shows as drift after a few trips, not at once.
    @Test("errors and collapses in any order never drift the form")
    func errorAndCollapseDoNotDrift() {
        let accessory = accessory()
        choose(aes256, in: accessory.encryptionPopup)
        accessory.showError(Self.short)
        choose(noCipher, in: accessory.encryptionPopup)
        choose(aes256, in: accessory.encryptionPopup)
        accessory.showError(Self.long)
        let leaveZip = ArchivePacking.Format.allCases.firstIndex(of: .tar) ?? 1
        let zip = ArchivePacking.Format.allCases.firstIndex(of: .zip) ?? 0
        choose(leaveZip, in: accessory.formatPopup)
        choose(zip, in: accessory.formatPopup)
        choose(aes256, in: accessory.encryptionPopup)
        accessory.showError(Self.long)

        let fresh = self.accessory(encryption: .aes256)
        fresh.showError(Self.long)
        #expect(accessory.view.frame.height == fresh.view.frame.height)
        #expect(formFrames(of: accessory) == formFrames(of: fresh))
        #expect(accessory.errorLabel.frame == fresh.errorLabel.frame)
        let shown = passphraseRows(of: accessory).allSatisfy { !$0.isHidden }
        #expect(shown)
    }

    @Test("with an error up, every visible row is inside the frame and clear of the row")
    func errorRowStaysInsideTheFrame() {
        let accessory = accessory(encryption: .aes256)
        accessory.showError(Self.long)
        let bounds = accessory.view.bounds
        let error = accessory.errorLabel.frame
        #expect(bounds.contains(error))
        for subview in accessory.view.subviews
            where !subview.isHidden && subview !== accessory.errorLabel {
            #expect(bounds.contains(subview.frame), "\(subview.frame) escapes \(bounds)")
            #expect(!subview.frame.intersects(error), "\(subview.frame) overlaps \(error)")
        }
    }

    // MARK: - Routing

    private func sheet(routedTo accessory: PackAccessory) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "probe"
        alert.addButton(withTitle: "Pack")
        alert.addButton(withTitle: "Cancel")
        alert.enableEscapeToCancel()
        alert.accessoryView = accessory.view
        accessory.routePack(through: alert.buttons[0])
        return alert
    }

    @Test("Pack runs the check instead of ending the sheet")
    func packIsRouted() {
        let accessory = accessory(encryption: .aes256)
        let alert = sheet(routedTo: accessory)
        var presses = 0
        accessory.onPack = { presses += 1 }

        alert.buttons[0].performClick(nil)

        #expect(presses == 1)
        #expect(alert.buttons[0].target === accessory)
        // Cancel is left alone: it still ends the sheet through the alert.
        #expect(alert.buttons[1].target === alert)
    }

    /// Return is how most people press Pack, and it arrives through `AlertKeyCatcher` rather than a
    /// click — so the catcher has to resolve it to the very button that was retargeted.
    @Test("Return reaches the routed Pack button")
    func returnIsRouted() throws {
        let accessory = accessory(encryption: .aes256)
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
}
