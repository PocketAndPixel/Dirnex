import AppKit
import DirnexCore
import SwiftUI

/// A SwiftUI control for capturing a keyboard shortcut, used by the Settings Shortcuts tab.
/// Wraps an AppKit `RecorderView` because SwiftUI can't intercept raw key-downs (or the
/// ⌘-combinations that would otherwise fire menu items) — the AppKit view becomes first
/// responder while recording and consumes every key event until one resolves to a shortcut.
struct ShortcutRecorder: NSViewRepresentable {
    /// The command's current effective shortcut, shown when idle (`nil` renders the placeholder).
    let shortcut: CommandShortcut?
    /// Draw the pill in a warning tint when this shortcut collides with another command.
    let isConflicting: Bool
    /// Reports the captured shortcut, or `nil` when the user clears it with Delete.
    let onRecord: (CommandShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
        view.update(shortcut: shortcut, conflicting: isConflicting)
    }

    /// The AppKit key-capture control. Idle it shows the current shortcut (or "Add Shortcut");
    /// clicked, it enters recording mode, becomes first responder, and turns the next resolvable
    /// key combination into a `CommandShortcut`. Esc cancels, Delete clears the binding.
    final class RecorderView: NSView {
        var onRecord: ((CommandShortcut?) -> Void)?

        private let label = NSTextField(labelWithString: "")
        private var shortcut: CommandShortcut?
        private var isConflicting = false
        private var isRecording = false {
            didSet { needsDisplay = true; refreshLabel() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            refreshLabel()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 24) }
        override var acceptsFirstResponder: Bool { true }

        func update(shortcut: CommandShortcut?, conflicting: Bool) {
            self.shortcut = shortcut
            isConflicting = conflicting
            refreshLabel()
            needsDisplay = true
        }

        // MARK: - Recording

        override func mouseDown(with event: NSEvent) {
            if isRecording {
                endRecording()
            } else {
                isRecording = true
                window?.makeFirstResponder(self)
            }
        }

        /// While recording, swallow ⌘-combinations that would otherwise dispatch as menu key
        /// equivalents (⌘T, ⌘W …) and turn them into the recorded shortcut instead.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            handle(event)
        }

        private func handle(_ event: NSEvent) {
            switch event.keyCode {
            case 53: // Escape — cancel without changing the binding.
                endRecording()
            case 51, 117: // Delete / Forward Delete — clear the binding.
                onRecord?(nil)
                endRecording()
            default:
                guard let recorded = CommandShortcut(event: event) else { return } // keep waiting
                onRecord?(recorded)
                endRecording()
            }
        }

        private func endRecording() {
            isRecording = false
            if window?.firstResponder == self { window?.makeFirstResponder(nil) }
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        // MARK: - Appearance

        private func refreshLabel() {
            if isRecording {
                label.stringValue = String(localized: "Type shortcut…")
                label.textColor = .secondaryLabelColor
            } else if let shortcut {
                label.stringValue = shortcut.display
                label.textColor = isConflicting ? .systemRed : .labelColor
            } else {
                label.stringValue = String(localized: "Add Shortcut")
                label.textColor = .tertiaryLabelColor
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 5,
                yRadius: 5
            )
            let fill = isRecording
                ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor
            fill.setFill()
            path.fill()
            if isRecording {
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 2
            } else {
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
            }
            path.stroke()
        }
    }
}
