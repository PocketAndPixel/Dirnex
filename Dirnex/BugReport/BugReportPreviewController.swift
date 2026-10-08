import AppKit

/// *Show What Will Be Sent…* (PLAN.md §M30): the exact body Send would send, as a sheet over the
/// dialog. Read-only, but selectable, so a part of it can be copied.
@MainActor
final class BugReportPreviewController: NSViewController {
    let body: Data
    let textView = NSTextView()

    init(body: Data) {
        self.body = body
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The body as text. Exactly the bytes, as UTF-8; the body is always UTF-8.
    var text: String {
        String(bytes: body, encoding: .utf8) ?? ""
    }

    override func loadView() {
        // Narrower than the dialog it hangs from: a sheet wider than its window is cut off at both
        // edges (seen live at 640 over the dialog's 560).
        let width = BugReportController.contentWidth - 2 * DialogLayout.inset
        let inner = width - 2 * DialogLayout.inset
        let label = NSTextField(labelWithString: String(
            localized: "This is exactly what Send sends:",
            comment: "Report a Bug preview: the line above the report's text."
        ))

        textView.string = text
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.setAccessibilityLabel(label.stringValue)

        // Drawn as a read-only field is drawn, under the dialog's editable ones (``MultiLineField``).
        let box = MultiLineField(textView)
        box.isEditable = false

        let close = NSButton(
            title: String(localized: "OK"),
            target: self,
            action: #selector(close(_:))
        )
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        let row = NSStackView(views: [NSView(), close])
        row.orientation = .horizontal

        let container = EscapeDismissingView()
        container.dismissesWhileEditing = true
        container.onEscape = { [weak self] in self?.close(nil) }
        DialogLayout.fill(container, with: [label, box, row])
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            box.widthAnchor.constraint(equalToConstant: inner),
            box.heightAnchor.constraint(equalToConstant: 400),
            row.widthAnchor.constraint(equalToConstant: inner)
        ])
        view = container
    }

    @objc func close(_ sender: Any?) {
        dismiss(sender)
    }
}
