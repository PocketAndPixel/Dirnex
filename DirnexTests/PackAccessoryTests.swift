import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The pack sheet's accessory collapses its passphrase block when no cipher is chosen, so the sheet
/// is not asking for a passphrase it will not use.
///
/// Every assertion here is geometry rather than text: the app test target inherits whatever
/// `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md), so a test resting on a
/// caption's words fails on the machine of anyone checking a translation. Geometry also happens to
/// be the thing that actually goes wrong — hiding a row without reclaiming its space leaves a hole
/// no `isHidden` assertion can see, and a sign error in the shift leaves the form drifting a little
/// further off the floor with every trip through the popup.
@Suite("Pack sheet accessory")
@MainActor
struct PackAccessoryTests {
    private func accessory(
        encryption: ArchiveEncryption = .none,
        format: ArchivePacking.Format = .zip
    ) -> PackAccessory {
        PackAccessory.make(
            PackAccessory.Defaults(baseName: "probe", format: format, encryption: encryption)
        )
    }

    /// Drive a popup the way AppKit does — `selectItem(at:)` alone changes the selection without
    /// sending the action, so a test built on it would prove nothing about the wiring.
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

    @Test("with no cipher the passphrase rows are off screen, not merely grayed")
    func collapsedByDefault() {
        let accessory = accessory()
        let hidden = passphraseRows(of: accessory).allSatisfy(\.isHidden)
        #expect(hidden)
    }

    @Test("choosing a cipher brings them back")
    func choosingCipherExpands() {
        let accessory = accessory()
        choose(aes256, in: accessory.encryptionPopup)
        let shown = passphraseRows(of: accessory).allSatisfy { !$0.isHidden }
        #expect(shown)
        #expect(accessory.encryption == .aes256)
    }

    /// The assertion a screenshot would make. Hiding the rows without sliding the rest down leaves
    /// the encryption popup floating above an empty strip — every `isHidden` check still passes, and
    /// the sheet has a hole in it.
    @Test("the encryption row sits on the floor once the block below it is gone")
    func collapseReclaimsTheSpace() {
        let collapsed = accessory()
        #expect(collapsed.encryptionPopup.frame.minY == 0)

        let expanded = accessory(encryption: .aes256)
        #expect(expanded.encryptionPopup.frame.minY > 0)
    }

    @Test("the accessory is exactly as much shorter as the block it put away")
    func heightTracksTheBlock() throws {
        let collapsed = accessory()
        let expanded = accessory(encryption: .aes256)
        let delta = expanded.view.frame.height - collapsed.view.frame.height
        // The block is the two passphrase rows, the checkbox and the footer note — i.e. everything
        // that used to sit under the encryption row, which is where that row now sits.
        #expect(delta == expanded.encryptionPopup.frame.minY)
        #expect(delta > 0)
    }

    /// A sign error shows up as drift rather than as a wrong first answer, so the round trip is the
    /// test that catches it.
    @Test("a round trip through the popup lands back on the original geometry")
    func roundTripIsExact() {
        let accessory = accessory()
        let collapsedHeight = accessory.view.frame.height
        let collapsedNameY = accessory.nameField.frame.minY

        choose(aes256, in: accessory.encryptionPopup)
        let expandedHeight = accessory.view.frame.height
        #expect(expandedHeight > collapsedHeight)

        choose(noCipher, in: accessory.encryptionPopup)
        #expect(accessory.view.frame.height == collapsedHeight)
        #expect(accessory.nameField.frame.minY == collapsedNameY)

        // And again, because one trip can hide a halved or doubled delta.
        choose(aes256, in: accessory.encryptionPopup)
        #expect(accessory.view.frame.height == expandedHeight)
    }

    /// Moving off zip resets the cipher to None — so the passphrase block has to follow, even though
    /// nobody touched the encryption popup.
    @Test("leaving zip collapses the block along with the cipher it resets")
    func leavingZipCollapses() throws {
        let accessory = accessory(encryption: .aes256)
        let expandedHeight = accessory.view.frame.height
        let tar = try #require(ArchivePacking.Format.allCases.firstIndex(of: .tar))

        choose(tar, in: accessory.formatPopup)
        #expect(accessory.encryption == .none)
        #expect(accessory.view.frame.height < expandedHeight)
        let hidden = passphraseRows(of: accessory).allSatisfy(\.isHidden)
        #expect(hidden)
    }

    /// The presenter re-lays out the alert on every call, so a format change that leaves the cipher
    /// where it was must not make one — otherwise picking a compression level twitches the sheet.
    @Test("the height callback fires on a real change and stays quiet otherwise")
    func callbackOnlyOnRealChange() throws {
        let accessory = accessory()
        var calls = 0
        accessory.onHeightChange = { calls += 1 }

        // zip → 7-Zip: both refuse a cipher, so nothing about the block changes.
        let sevenZip = try #require(ArchivePacking.Format.allCases.firstIndex(of: .sevenZip))
        choose(sevenZip, in: accessory.formatPopup)
        #expect(calls == 0)

        let zip = try #require(ArchivePacking.Format.allCases.firstIndex(of: .zip))
        choose(zip, in: accessory.formatPopup)
        #expect(calls == 0)

        choose(aes256, in: accessory.encryptionPopup)
        #expect(calls == 1)
        choose(noCipher, in: accessory.encryptionPopup)
        #expect(calls == 2)
    }

    /// Whatever the state, every row that is on screen has to be inside the frame the alert reserves
    /// space from — the one way this layout can fail invisibly.
    @Test("no visible row is drawn outside the accessory in either state")
    func visibleRowsStayInsideTheFrame() {
        for encryption in ArchiveEncryption.allCases {
            let accessory = accessory(encryption: encryption)
            let bounds = accessory.view.bounds
            for subview in accessory.view.subviews where !subview.isHidden {
                #expect(
                    bounds.contains(subview.frame),
                    "\(subview.frame) escapes \(bounds) with encryption \(encryption)"
                )
            }
        }
    }
}
