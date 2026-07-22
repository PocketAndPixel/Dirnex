import AppKit

/// What a full-size Quick View says about the file it is showing (PLAN.md §M11): the name, and
/// where it sits in the pane's list. In pane mode the file list is right there beside the preview;
/// in the two full modes it is behind it, and arrowing through files you cannot see is flying
/// blind — this is the readout that replaces the row you would otherwise be looking at.
struct QuickViewCaption: Equatable {
    let name: String
    /// The cursor's 1-based position among the pane's visible rows, and how many there are.
    /// Counts *rows*, `..` included, so it matches what the list underneath would show.
    let position: Int
    let count: Int

    /// "3 of 42" — the position half of the header, rendered beside the name.
    var positionText: String { "\(position) of \(count)" }
}

/// The name-and-position strip a full-size Quick View draws across its top. A vibrant bar rather
/// than a flat one because it sits over arbitrary content — a white page in full window, a photo
/// bled to the edges in full screen — where any fixed colour is wrong against half of it.
@MainActor
final class QuickViewHeaderView: NSVisualEffectView {
    static let height: CGFloat = 30

    private let nameLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")

    /// The file being previewed, or `nil` when there is nothing under the cursor — which blanks
    /// the strip rather than hiding it, so the preview underneath doesn't jump.
    var caption: QuickViewCaption? {
        didSet {
            guard caption != oldValue else { return }
            nameLabel.stringValue = caption?.name ?? ""
            positionLabel.stringValue = caption?.positionText ?? ""
        }
    }

    init(material: NSVisualEffectView.Material) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = .withinWindow
        // `.active` rather than `.followsWindowActiveState`: in full screen the window may not be
        // key while the user is looking at a photo, and a strip that goes flat then reads as a bug.
        state = .active
        translatesAutoresizingMaskIntoConstraints = false
        buildLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLabels() {
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        // Middle truncation, like the path bar: the extension is what says which *kind* of file
        // this is, and a tail-truncated name throws exactly that away.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        positionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        positionLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, positionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        // The name yields first: it is the one label that can be arbitrarily long, and the
        // position readout is short, fixed-width and useless when clipped.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: positionLabel.leadingAnchor,
                constant: -12
            ),
            positionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
