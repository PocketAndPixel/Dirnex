import AppKit

/// "Showing the first 4 MB of this file", floated over the bottom of a table or a tree, in the words
/// the text preview uses (`QuickViewTextView.truncationText`). A view of its own once a second surface
/// wanted it (the JSON tree, 2026-09-15). A vibrant bar for the reason the header is one: it sits over
/// the file's own rows, where any fixed color is wrong against half of them.
@MainActor
final class QuickViewTruncationNotice: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: QuickViewTextView.truncationText)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Float the notice in `container`, centered, 12 points above `bottom`.
    func install(in container: NSView, above bottom: NSLayoutYAxisAnchor) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottomAnchor.constraint(equalTo: bottom, constant: -12)
        ])
    }
}
