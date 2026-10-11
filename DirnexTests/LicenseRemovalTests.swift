import AppKit
import DirnexCore
import SwiftUI
import Testing

@testable import Dirnex

/// Settings ▸ License's Remove License asks before it forgets the key, and the question says how to
/// get the key back (`LicenseSettingsView`).
///
/// The tab is the real `LicenseSettingsView`, hosted in a window of its own, and the confirmation is
/// the sheet SwiftUI attaches to that window, pressed through its own buttons.
@Suite("Removing a license")
@MainActor
struct LicenseRemovalTests {
    private struct Tab {
        let store: LicenseStore
        let window: NSWindow
    }

    private func licenseTab() throws -> Tab {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        _ = try store.activate(TestLicenseKeys.key()).get()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicenseSettingsView(store: store))
        return Tab(store: store, window: window)
    }

    private func views<View: NSView>(_: View.Type, in root: NSView?) -> [View] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return root.map(all)?.compactMap { $0 as? View } ?? []
    }

    private func button(_ title: LocalizedStringResource, in root: NSView?) -> NSButton? {
        let text = String(localized: title)
        return views(NSButton.self, in: root).first { $0.title == text }
    }

    /// Presses the tab's Remove License and waits for the confirmation to be up.
    private func askToRemove(in tab: Tab) async throws -> NSWindow {
        var remove: NSButton?
        try await settleUntil {
            tab.window.contentView?.layoutSubtreeIfNeeded()
            remove = button("Remove License", in: tab.window.contentView)
            return remove != nil
        }
        try #require(remove).performClick(nil)
        try await settleUntil { tab.window.attachedSheet != nil }
        return try #require(tab.window.attachedSheet)
    }

    @Test("Remove License asks first, and the question says where the key can be had again")
    func asksFirst() async throws {
        let tab = try licenseTab()
        let key = try #require(tab.store.key)
        let sheet = try await askToRemove(in: tab)
        #expect(tab.store.key == key)
        let text = views(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        #expect(text.contains { $0.contains("/account") && $0.contains("support@dirnex.app") })
    }

    @Test("confirming forgets the key, and Return doesn't confirm")
    func confirmRemoves() async throws {
        let tab = try licenseTab()
        let sheet = try await askToRemove(in: tab)
        let remove = try #require(button("Remove License", in: sheet.contentView))
        #expect(remove.keyEquivalent != "\r")
        remove.performClick(nil)
        try await settleUntil { tab.store.key == nil }
        #expect(tab.store.key == nil)
    }

    /// Escape is checked as the key Cancel holds: `NSAlert` gives it only to a button titled "Cancel" in
    /// English (docs/NOTES.md ▸ Escape on a translated alert), so run under a translation too
    /// (`-testLanguage ru`).
    @Test("Cancel, which Escape presses, keeps the key")
    func cancelKeeps() async throws {
        let tab = try licenseTab()
        let key = try #require(tab.store.key)
        let sheet = try await askToRemove(in: tab)
        let cancel = try #require(button("Cancel", in: sheet.contentView))
        #expect(cancel.keyEquivalent == "\u{1b}")
        cancel.performClick(nil)
        try await settleUntil { tab.window.attachedSheet == nil }
        #expect(tab.store.key == key)
    }
}
