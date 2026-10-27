import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Tab in the merge window: the panes on screen, left to right, then the toolbar's controls and
/// round again, and the mark on the pane Find acts on. The compare window's twin (`CompareTabTests`).
///
/// Until this, the loop held the panes only, and a toolbar control that had the keyboard kept it.
@Suite("Merge window Tab")
@MainActor
struct MergeTabTests {
    /// A window on screen with its first conflict current, so the takes join the loop.
    private func rig() throws -> MergeRig {
        KeyboardReachableControls.install()
        let rig = try MergeRig()
        let window = try #require(rig.controller.window)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        return rig
    }

    private func close(_ rig: MergeRig) {
        rig.controller.window?.orderOut(nil)
        rig.cleanup()
    }

    /// What holds the keyboard, by name, so a wrong stop says which it is.
    private func holder(_ controller: MergeWindowController) -> String {
        let toolbar = controller.toolbar
        let named: [(NSResponder, String)] = [
            (controller.basePane.textView, "base"),
            (controller.yoursPane.textView, "yours"),
            (controller.resultPane.textView, "result"),
            (controller.theirsPane.textView, "theirs"),
            (toolbar.navigation, "conflicts"),
            (toolbar.take, "take"),
            (toolbar.showBase, "show base"),
            (toolbar.save, "save")
        ]
        let responder = controller.window?.firstResponder
        return named.first { $0.0 === responder }?.1 ?? responder.map { "\(type(of: $0))" } ?? "nothing"
    }

    @Test("Tab goes along the panes and then the toolbar, and ⇧Tab the other way")
    func tabGoesRound() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        // Both conflicts chosen, so Save is enabled and joins the loop; the second stays current.
        controller.take(.yours)
        controller.take(.theirs)
        #expect(controller.canSave)
        #expect(controller.currentConflict == 1)
        #expect(window.makeFirstResponder(controller.yoursPane.textView))

        let stops = [
            "result", "theirs",
            "conflicts", "take", "show base", "save",
            "yours"
        ]
        var forwards: [String] = []
        for _ in stops {
            pressTab(in: window)
            forwards.append(holder(controller))
        }
        #expect(forwards == stops)

        var backwards: [String] = []
        for _ in stops {
            pressTab(in: window, backwards: true)
            backwards.append(holder(controller))
        }
        #expect(backwards == Array(stops.dropLast().reversed()) + ["yours"])
    }

    @Test("Save is passed over until it can save, and the base is a stop only while it is shown")
    func stopsFollowTheWindow() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        #expect(!controller.toolbar.save.isEnabled)
        #expect(window.makeFirstResponder(controller.toolbar.showBase))
        pressTab(in: window)
        #expect(holder(controller) == "yours", "Save passed over, and no base while it is hidden")

        controller.setBaseShown(true)
        #expect(window.makeFirstResponder(controller.toolbar.showBase))
        pressTab(in: window)
        #expect(holder(controller) == "base")
        pressTab(in: window)
        #expect(holder(controller) == "yours")
    }

    @Test("the pane holding the keyboard is marked, and keeps the mark while the toolbar has it")
    func markFollowsTheKeyboard() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        let accent = AppPreferences.shared.palette.resolvedAccent
        #expect(controller.resultPane.holdsKeyboard, "the window opens with the result's keyboard")
        #expect(controller.resultPane.nameLabel.textColor == accent)
        #expect(controller.yoursPane.nameLabel.textColor == .labelColor)

        #expect(window.makeFirstResponder(controller.resultPane.textView))
        pressTab(in: window)
        #expect(controller.theirsPane.holdsKeyboard)
        #expect(!controller.resultPane.holdsKeyboard)
        #expect(controller.theirsPane.nameLabel.textColor == accent)

        pressTab(in: window)
        #expect(holder(controller) == "conflicts")
        #expect(controller.theirsPane.holdsKeyboard, "the toolbar takes the keyboard, not the mark")
        #expect(controller.focusedPane === controller.theirsPane)
    }

    @Test("hiding the base moves its mark to the result, wherever the keyboard is")
    func hidingTheBaseMovesItsMark() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        controller.setBaseShown(true)
        #expect(window.makeFirstResponder(controller.basePane.textView))
        #expect(controller.basePane.holdsKeyboard)

        // Show Base unticked from the keyboard: the checkbox has it, and the base the mark.
        #expect(window.makeFirstResponder(controller.toolbar.showBase))
        controller.toolbar.showBase.performClick(nil)
        #expect(!controller.isBaseShown)
        #expect(holder(controller) == "show base")
        #expect(controller.resultPane.holdsKeyboard)
        #expect(!controller.basePane.holdsKeyboard)
        #expect(controller.focusedPane === controller.resultPane)
    }
}
