import AppKit
import DirnexCore
import SwiftUI
import Testing

@testable import Dirnex

/// `FieldBorder`, the stronger edge on every bezeled text field: which fields get it, and that it
/// darkens the system's own ring outside the field and touches nothing else.
@Suite("Text field border")
@MainActor
struct FieldBorderTests {
    /// `view` in a window of its own, at 20, 20 and `size`.
    private func host(_ view: NSView, size: NSSize = NSSize(width: 260, height: 22)) -> NSWindow {
        FieldBorder.install()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content
        view.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: size)
        content.addSubview(view)
        return window
    }

    @Test("every kind of bezeled field gets one stroke when it joins a window")
    func bezeledFields() {
        let fields: [NSTextField] = [
            NSTextField.singleLine(),
            NSTextField(string: "x"),
            NSSecureTextField(),
            NSTokenField(),
            NSSearchField()
        ]
        for field in fields {
            #expect(FieldBorder.border(of: field) == nil)
            let window = host(field)
            defer { window.close() }
            #expect(FieldBorder.border(of: field) != nil, "\(type(of: field))")
            // Moving to another window keeps the one it has.
            let other = host(field)
            defer { other.close() }
            #expect(field.subviews.count(where: { $0 is FieldBorderView }) == 1)
        }
    }

    @Test("labels, table cells and other unbezeled fields get none")
    func unbezeledFields() {
        let cell = NSTextField()
        cell.isBordered = false
        let rename = NSTextField()
        rename.isBordered = true
        for field in [
            NSTextField(labelWithString: "x"),
            NSTextField(wrappingLabelWithString: "x"),
            cell,
            rename
        ] {
            let window = host(field)
            defer { window.close() }
            #expect(FieldBorder.border(of: field) == nil)
        }
    }

    /// The reason it is a patch on the class: an alert's accessory field is built by the caller, but
    /// it joins the alert's window, which nobody here builds.
    @Test("an alert's accessory field gets one")
    func alertField() {
        FieldBorder.install()
        let field = NSTextField.singleLine()
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.accessoryView = field
        alert.layout()
        #expect(field.window != nil)
        #expect(FieldBorder.border(of: field) != nil)
    }

    /// Settings ▸ License's key field is SwiftUI's, in a grouped `Form`, which draws its fields with no
    /// bezel unless asked: it was the one text field in the app with no border at all.
    @Test("Settings ▸ License's key field is bezeled, and gets the stroke")
    func licenseKeyField() async throws {
        FieldBorder.install()
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicenseSettingsView(store: store))
        defer { window.close() }
        let field = try #require(await editableField(in: window))
        #expect(field.isBezeled)
        #expect(FieldBorder.border(of: field) != nil)
    }

    /// The first editable field in `window`, once SwiftUI has built it.
    ///
    /// 30 s, like the shared `settleUntil`, with one last look after the deadline: in a full run the
    /// main actor stalls for seconds at a time (docs/NOTES.md ▸ Testing).
    private func editableField(in window: NSWindow) async throws -> NSTextField? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func find() -> NSTextField? {
            window.contentView.map(all)?.compactMap { $0 as? NSTextField }.first(where: \.isEditable)
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let found = find() { return found }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return find()
    }

    @Test("the stroke takes no clicks and is no accessibility element")
    func inert() throws {
        let field = NSTextField.singleLine()
        let window = host(field)
        defer { window.close() }
        let border = try #require(FieldBorder.border(of: field))
        #expect(border.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(!border.isAccessibilityElement())
        let children = NSAccessibility.unignoredChildren(from: field.accessibilityChildren() ?? [])
        #expect(!children.contains { ($0 as? NSView) === border })
    }

    @Test("a search field's stroke is a capsule, every other field's has the field's corner")
    func shape() throws {
        let field = NSTextField.singleLine()
        let search = NSSearchField()
        let fieldWindow = host(field)
        let searchWindow = host(search)
        defer {
            fieldWindow.close()
            searchWindow.close()
        }
        let border = try #require(FieldBorder.border(of: field))
        #expect(border.frame == field.bounds.insetBy(dx: -1, dy: -1))
        #expect(border.path.bounds == border.bounds.insetBy(dx: 0.5, dy: 0.5))
        // A point on the centerline just past where a 6.5 pt corner turns lies on the field's ring,
        // and the same point on a capsule of that height lies outside it.
        let ring = border.path.bounds
        let probe = NSPoint(x: ring.minX + 4, y: ring.minY + 0.6)
        #expect(border.path.contains(probe))
        let searchBorder = try #require(FieldBorder.border(of: search))
        let capsule = searchBorder.path.bounds
        #expect(!searchBorder.path.contains(NSPoint(x: capsule.minX + 4, y: capsule.minY + 0.6)))
    }

    /// The point of it, pinned at its position: the stroke falls exactly on the system's ring, the
    /// 1 pt band just outside the frame, and changes no pixel inside the field. A stroke inside the
    /// frame, which is where a first attempt put it, reads as a second border and fails here.
    @Test("only the ring just outside the field gets darker", arguments: [
        NSAppearance.Name.aqua,
        .darkAqua
    ])
    func darkensTheRingOnly(appearance: NSAppearance.Name) throws {
        let field = NSTextField.singleLine()
        field.stringValue = "untitled folder"
        let window = host(field)
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        let content = try #require(window.contentView)
        let border = try #require(FieldBorder.border(of: field))

        let with = try pixels(of: content)
        border.isHidden = true
        let without = try pixels(of: content)
        border.isHidden = false

        let scale = CGFloat(with.pixelsWide) / content.bounds.width
        let frame = field.frame
        // The ring follows the field's rounded corner, so the band is rounded too, with a quarter
        // point either side for the anti-aliasing along the curves.
        let outer = NSBezierPath(
            roundedRect: frame.insetBy(dx: -1.25, dy: -1.25),
            xRadius: 7.25,
            yRadius: 7.25
        )
        let inner = NSBezierPath(
            roundedRect: frame.insetBy(dx: 0.25, dy: 0.25),
            xRadius: 5.75,
            yRadius: 5.75
        )
        var changed = 0
        var outsideTheBand = 0
        for y in 0..<with.pixelsHigh {
            for x in 0..<with.pixelsWide {
                let drawn = try #require(with.colorAt(x: x, y: y))
                let plain = try #require(without.colorAt(x: x, y: y))
                let delta = abs(drawn.redComponent - plain.redComponent)
                    + abs(drawn.greenComponent - plain.greenComponent)
                    + abs(drawn.blueComponent - plain.blueComponent)
                    + abs(drawn.alphaComponent - plain.alphaComponent)
                guard delta > 0.01 else { continue }
                changed += 1
                // The pixel's center, in the content view's points (unflipped).
                let point = NSPoint(
                    x: (CGFloat(x) + 0.5) / scale,
                    y: content.bounds.height - (CGFloat(y) + 0.5) / scale
                )
                if !outer.contains(point) || inner.contains(point) { outsideTheBand += 1 }
            }
        }
        // Most of the perimeter, at least: a stroke that drew nothing would pass the band check.
        let perimeter = Int(2 * (frame.width + frame.height) * scale)
        #expect(changed > perimeter)
        #expect(outsideTheBand == 0)
    }

    private func pixels(of view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
