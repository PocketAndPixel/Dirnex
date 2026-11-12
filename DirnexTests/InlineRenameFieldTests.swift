import AppKit
import Testing

@testable import Dirnex

/// The F2 field's look on the row it opens over. The field is a text box filled with
/// `.textBackgroundColor`, and the row view pushes the cursor's `.emphasized` style onto the cell
/// *after* `beginNameEditing`, which runs `applyStyle` again. Until 2026-11-11 that repainted the
/// name in the cursor's ink, white on the box's white in the light appearance.
///
/// The style is pushed by hand rather than through a table: a row view is emphasized only in a key
/// window, which a test host cannot make (docs/NOTES.md ▸ Drawing rows and cells).
@Suite("Inline rename field")
@MainActor
struct InlineRenameFieldTests {
    private final class Delegate: NSObject, NSTextFieldDelegate {}

    /// Kept for the life of the test host: tearing a test window down can crash a later test
    /// (docs/NOTES.md ▸ Testing, windows in a test).
    private static var retained: [AnyObject] = []

    private func nameCell() -> FileCellView {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.textField?.stringValue = "dirnex-website-de-review.md"
        return cell
    }

    private func openField(in cell: FileCellView) {
        let delegate = Delegate()
        Self.retained.append(delegate)
        cell.applyStyle()
        cell.beginNameEditing(delegate: delegate)
    }

    /// The pixels, because the field editor draws the text and takes its color from the field when
    /// it opens, so the field's `textColor` alone is not the answer. A collapsed selection keeps the
    /// selection's highlight out of the measurement.
    @Test(
        "the field draws dark text on the cursor row in the light appearance",
        arguments: [false, true]
    )
    func darkTextOnTheCursorRow(styleArrivesWhileEditing: Bool) throws {
        let cell = nameCell()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        cell.frame = NSRect(x: 10, y: 8, width: 280, height: 24)
        window.contentView?.addSubview(cell)
        window.orderFront(nil)
        Self.retained.append(window)
        openField(in: cell)
        let field = try #require(cell.textField)

        if !styleArrivesWhileEditing { cell.backgroundStyle = .emphasized }
        window.makeFirstResponder(field)
        defer { window.makeFirstResponder(nil) }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 0, length: 0)
        if styleArrivesWhileEditing {
            cell.backgroundStyle = .normal
            cell.backgroundStyle = .emphasized
        }
        window.displayIfNeeded()

        #expect(editor.textColor == .labelColor)
        #expect(try Self.darkestInk(in: field) < 0.5)
    }

    /// The same push used to undo the rest of the field's look: a hidden file's name went back to
    /// half opacity, and a marked one to bold, inside the box.
    @Test("the field stays opaque and regular weight on a hidden, marked cursor row")
    func fieldKeepsItsLookOnAHiddenMarkedRow() {
        let cell = nameCell()
        cell.dimmed = true
        cell.marked = true
        openField(in: cell)
        cell.backgroundStyle = .emphasized

        #expect(cell.alphaValue == 1)
        #expect(cell.textField?.font == .systemFont(ofSize: NSFont.systemFontSize))
        #expect(cell.textField?.textColor == .labelColor)
    }

    /// The render path styles a recycled cell first and closes its field after (`viewFor`), so
    /// closing the field has to hand the row its own look back, or the next row drawn in this cell
    /// keeps the box's.
    @Test("closing the field gives the row its own look back")
    func closingRestoresTheRowLook() {
        let cell = nameCell()
        openField(in: cell)
        cell.backgroundStyle = .emphasized

        cell.dimmed = true
        cell.marked = true
        cell.applyStyle()
        cell.endNameEditing()

        #expect(!cell.isEditingName)
        #expect(cell.alphaValue == 0.5)
        #expect(cell.textField?.font == .boldSystemFont(ofSize: NSFont.systemFontSize))
        #expect(cell.textField?.textColor == cell.palette.cursorForeground)
    }

    /// The darkest pixel inside `view`, as a 0–1 luminance over white, at 2× whatever the screen.
    /// The inset keeps the field's own border out.
    private static func darkestInk(in view: NSView) throws -> Double {
        let pixels = try BitmapPixels(capturing: view, scale: 2)
        var darkest = 1.0
        for y in 4..<(pixels.height - 4) {
            for x in 8..<(pixels.width - 8) {
                let pixel = pixels.rgba(x: x, y: y)
                let channels = (pixel.x + pixel.y + pixel.z) * pixel.w + 3 * (1 - pixel.w)
                darkest = min(darkest, channels / 3)
            }
        }
        return darkest
    }
}
