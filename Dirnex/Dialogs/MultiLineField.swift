import AppKit

/// A multi-line text view that looks like a text field: the same rounded bezel and fill, the same
/// focus ring, and its first line where a field puts its text.
///
/// Report a Bug…'s two text boxes and its read-only preview, and the scripts organizer's Command, were
/// `.bezelBorder` scroll views beside modern text fields — square, gray-edged and ringless — and read
/// as another generation of control. (The app's bordered *lists* keep that border: a field's look
/// around a table reads as somewhere to type.) None of the field's look is drawn here, because on macOS 26 none of it can be drawn by
/// hand. Probed 2026-10-08:
///
/// - **A field's bezel is a private subview, not its cell.** `NSTextField` draws it through
///   `_NSCoreHostingView<AppKitTextField>`, and `NSTextFieldCell.draw(withFrame:in:)` called by hand
///   differed from a real field in almost every pixel in Dark Mode. So the bezel *is* a field, built
///   the way the email field is, lying inert behind a transparent scroll view: unfocused, the box
///   came out pixel-identical to a real field. It stays editable, because a non-editable field draws
///   its border differently in Dark Mode (~90 more pixels off). Refusing first responder keeps it off
///   the Tab loop, ``hitTest(_:)`` hands its clicks to the text, and ``accessibilityChildren()``
///   keeps it from VoiceOver.
/// - **A text view inside a scroll view is never asked for a focus ring**, whatever its
///   `focusRingType` (`drawFocusRingMask` was called 0 times). Its scroll view is asked once its own
///   type is `.exterior`, and then draws the system ring while the text view has focus. The ring
///   appeared with Keyboard navigation off, as a field's does.
/// - **The field's own ring shape can't be borrowed**: its `focusRingMaskBounds` is empty, since the
///   hosting view draws that ring itself. So the mask is a rounded rectangle over the bezel, and its
///   radius was measured against a focused 96 pt field: at 6 pt only anti-aliasing on the corner arcs
///   differed, while 5.5 or 6.5 pt left about twice as many pixels off, in both appearances.
/// - The scroll view sits 1 pt in from the sides and 3 pt in from the top and bottom, which puts the
///   first line's ink exactly where a field's sits, 6.5 pt in and 6.5 pt down. So the text view takes
///   no inset of its own.
///
/// The box takes its size from its caller, fixed or stretched, never from the field behind it, which
/// would otherwise hug its one-line height.
@MainActor
final class MultiLineField: NSView {
    /// The scroll view's distance from the bezel's edges.
    static let textInset = NSSize(width: 1, height: 3)

    let textView: NSTextView
    private let bezel = NSTextField.singleLine()
    let scrollView: NSScrollView = BezelRingScrollView()

    init(_ textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        bezel.refusesFirstResponder = true
        bezel.translatesAutoresizingMaskIntoConstraints = false
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            bezel.setContentHuggingPriority(.init(1), for: orientation)
            bezel.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        addSubview(bezel)

        textView.drawsBackground = false
        textView.textContainerInset = .zero
        // Wraps at the box's width and grows downward, so the scroll view scrolls only vertically.
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // A scroller only once there is something to scroll: a legacy scroller's track would
        // otherwise sit inside the bezel all the time.
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .exterior
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let inset = Self.textInset
        NSLayoutConstraint.activate([
            bezel.topAnchor.constraint(equalTo: topAnchor),
            bezel.bottomAnchor.constraint(equalTo: bottomAnchor),
            bezel.leadingAnchor.constraint(equalTo: leadingAnchor),
            bezel.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: inset.height),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.height),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.width),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.width)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Off, the box draws as a disabled field does, beside fields that are disabled with it, and its
    /// text can't take focus. Set this rather than the text view's own `isEditable`.
    var isEnabled = true {
        didSet {
            bezel.isEnabled = isEnabled
            textView.textColor = isEnabled ? .textColor : .disabledControlTextColor
            updateTextView()
        }
    }

    /// Off, the text can be selected and copied but not changed, and the box draws as a read-only
    /// field does. Probed 2026-10-09: a read-only field draws differently from an editable one in both
    /// appearances, and one clicked into takes focus and shows its selection but draws **no** focus
    /// ring, so the box draws none either. Set this rather than the text view's own `isEditable`.
    var isEditable = true {
        didSet {
            bezel.isEditable = isEditable
            scrollView.focusRingType = isEditable ? .exterior : .none
            updateTextView()
        }
    }

    private func updateTextView() {
        textView.isEditable = isEnabled && isEditable
        textView.isSelectable = isEnabled
    }

    /// A click on the bezel's margin goes to the text, as a click anywhere in a field does.
    /// VoiceOver's pointer follows it there too, since AppKit's accessibility hit test asks this.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === bezel || hit.isDescendant(of: bezel) ? textView : hit
    }

    /// The text and its scroller, and nothing of the bezel. Marking the bezel itself as no element
    /// is not enough: measured in the running app, that left an empty `AXTextField` the size of the
    /// box in the tree, the field's private hosting view promoted into its place.
    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: [scrollView])
    }
}

/// Draws the focus ring for its text view, around the bezel it sits inside (``MultiLineField``).
private final class BezelRingScrollView: NSScrollView {
    /// The bezel's corner radius, measured (``MultiLineField``).
    static let cornerRadius: CGFloat = 6

    override var focusRingMaskBounds: NSRect {
        superview.map { convert($0.bounds, from: $0) } ?? bounds
    }

    override func drawFocusRingMask() {
        let radius = Self.cornerRadius
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: radius, yRadius: radius).fill()
    }
}
