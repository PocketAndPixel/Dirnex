import AppKit
import DirnexCore
import SwiftUI
import Testing

@testable import Dirnex

/// Tab reaching the Settings window's push buttons with the system's Keyboard navigation switch off
/// (`SettingsButton`). Found in the M29 Slice 6 beta: Tab never reached **Buy a License…** in
/// Settings ▸ License, because a SwiftUI `Button` in a `Form` has no `NSButton` behind it for
/// `KeyboardReachableControls` to patch.
///
/// The observable is the key view loop, walked from the license key field as a Tab from it would,
/// like `KeyboardReachableControlsTests`. The tab is the real `LicenseSettingsView`, hosted in a
/// window of its own, so a button left as a SwiftUI `Button` fails here.
@Suite(
    "Settings buttons on the Tab loop",
    .enabled { await MainActor.run { !NSApp.isFullKeyboardAccessEnabled } }
)
@MainActor
struct SettingsButtonTests {
    private func window(showing view: some View) -> NSWindow {
        KeyboardReachableControls.install()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func views<View: NSView>(_: View.Type, in window: NSWindow) -> [View] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return window.contentView.map(all)?.compactMap { $0 as? View } ?? []
    }

    /// Waits for SwiftUI to build what `find` looks for, laying the window out as it goes.
    private func built<Found>(in window: NSWindow, _ find: () -> Found?) async throws -> Found? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let found = find() { return found }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func button(_ title: LocalizedStringResource, in window: NSWindow) async throws -> NSButton {
        let text = String(localized: title)
        return try #require(
            await built(in: window) { views(NSButton.self, in: window).first { $0.title == text } }
        )
    }

    private func keyField(in window: NSWindow) async throws -> NSTextField {
        try #require(
            await built(in: window) { views(NSTextField.self, in: window).first(where: \.isEditable) }
        )
    }

    /// The views Tab visits after `start`, in order, until the loop comes back round.
    private func tabStops(in window: NSWindow, from start: NSView) -> [NSView] {
        window.recalculateKeyViewLoop()
        var stops: [NSView] = []
        var current = start
        for _ in 0..<16 {
            window.selectKeyView(following: current)
            guard var next = window.firstResponder as? NSView else { break }
            if let editor = next as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                next = field
            }
            if next === start || stops.contains(where: { $0 === next }) { break }
            stops.append(next)
            current = next
        }
        return stops
    }

    private func licenseTab(key: String? = nil, buildReleaseDay: String? = nil) throws -> NSWindow {
        let store = LicenseStore(
            defaults: ScratchDefaults.fresh(),
            buildReleaseDay: buildReleaseDay.flatMap(LicenseDay.init)
        )
        if let key { _ = try store.activate(key).get() }
        return window(showing: LicenseSettingsView(store: store))
    }

    @Test(
        "no key: Tab from the key field reaches Buy a License…, and skips Activate while it's disabled"
    )
    func unlicensedTab() async throws {
        let window = try licenseTab()
        let field = try await keyField(in: window)
        let buy = try await button("Buy a License…", in: window)
        let activate = try await button("Activate", in: window)
        let stops = tabStops(in: window, from: field)
        #expect(stops.contains { $0 === buy })
        #expect(!activate.isEnabled)
        #expect(!stops.contains { $0 === activate })
    }

    @Test("with a key: Remove License and Renew… are Tab stops, and Remove is marked destructive")
    func licensedTab() async throws {
        let window = try licenseTab(key: TestLicenseKeys.key())
        let field = try await keyField(in: window)
        let remove = try await button("Remove License", in: window)
        let renew = try await button("Renew…", in: window)
        let stops = tabStops(in: window, from: field)
        #expect(stops.contains { $0 === remove })
        #expect(stops.contains { $0 === renew })
        #expect(remove.hasDestructiveAction)
        #expect(!renew.hasDestructiveAction)
        #expect(renew.bezelColor == nil)
    }

    @Test("a key that doesn't cover this build makes Renew… prominent, and still a Tab stop")
    func lapsedTab() async throws {
        let window = try licenseTab(
            key: TestLicenseKeys.key(until: "2027-03-12"),
            buildReleaseDay: "2027-04-01"
        )
        let field = try await keyField(in: window)
        let renew = try await button("Renew…", in: window)
        #expect(renew.bezelColor == .controlAccentColor)
        #expect(tabStops(in: window, from: field).contains { $0 === renew })
    }

    @Test("pressing a SettingsButton runs its action")
    func pressRunsAction() async throws {
        final class Count { var value = 0 }
        let count = Count()
        let window = window(
            showing: Form { SettingsButton("Relaunch") { count.value += 1 } }.formStyle(.grouped)
        )
        let relaunch = try await button("Relaunch", in: window)
        relaunch.performClick(nil)
        #expect(count.value == 1)
    }

    /// The reason `SettingsButton` exists, pinned: on macOS 26 a SwiftUI `Button` in a grouped `Form`
    /// is drawn by SwiftUI, with no `NSButton` for `KeyboardReachableControls` to put on the loop. If a
    /// later macOS backs it with one again, this fails, and `SettingsButton` may no longer be needed.
    @Test("a SwiftUI Button in a Form has no NSButton behind it")
    func swiftUIButtonIsNotAnNSButton() async throws {
        let window = window(
            showing: Form {
                TextField("Field", text: .constant("text"))
                Button("Plain SwiftUI") {}
                SettingsButton("Relaunch") {}
            }
            .formStyle(.grouped)
        )
        _ = try await keyField(in: window)
        _ = try await button("Relaunch", in: window)
        #expect(!views(NSButton.self, in: window).contains { $0.title == "Plain SwiftUI" })
    }
}
