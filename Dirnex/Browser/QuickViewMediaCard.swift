import AppKit
import DirnexCore

/// What Quick View shows for a movie or a sound nothing here can play (PLAN.md §M42 ▸ Slice 2): the
/// file's icon, its name, what it is kept in and the codecs where they are known, and a line saying
/// it will not play.
///
/// In place of Quick Look, which drew these files as their icon and nothing else: the same icon, with
/// the reason beside it. A blank or an icon alone reads as the preview having failed, where the truth
/// is that nothing on this Mac reads the file. Quiet and centered, as the remote placeholder card is,
/// since it is a statement rather than something to read.
@MainActor
final class QuickViewMediaCard: NSView {
    /// What the card says.
    struct Content: Equatable {
        let name: String
        /// The container's name, from the file's bytes, its extension or its type, or `nil` when none
        /// of them says.
        let container: String?
        /// What AVFoundation read of it, when it opened the file and still would not play it. A file it
        /// refuses outright tells it nothing (PLAN.md §M42 ▸ P0).
        let summary: MediaSummary?

        /// "Matroska", "MPEG-4 · DTS", "WebM · 640×360 · VP8 · Vorbis": the container, then the facts
        /// the header would give a file that plays.
        var detail: String {
            [container ?? "", summary?.facts ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private let icon = NSImageView()
    /// Internal, for the tests.
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: QuickViewMediaCard.hint)

    /// The sentence under the facts. One sentence for every reason a file will not play, because the
    /// reasons AVFoundation gives do not tell them apart: an AVI holding H.264 is refused as "may be
    /// damaged" (`-11829`) where nothing about it is.
    static let hint = String(
        localized: "Dirnex can’t play this file.",
        comment: "Quick View card for a movie or sound file that no decoder on this Mac can play."
    )

    init() {
        super.init(frame: .zero)
        // `NSView` does not clip, and `draw(_:)`'s `dirtyRect` can exceed the bounds — the same
        // whole-window bug the surface itself guards against (docs/NOTES.md ▸ AppKit).
        clipsToBounds = true
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ content: Content, icon image: NSImage? = nil) {
        nameLabel.stringValue = FileNameDisplay.visible(content.name)
        detailLabel.stringValue = content.detail
        detailLabel.isHidden = content.detail.isEmpty
        icon.image = image
    }

    private func buildSubviews() {
        icon.imageScaling = .scaleProportionallyUpOrDown
        // An `NSImageView` defends its image's size at priority 750, which in a stack is enough to
        // push a container outward (docs/NOTES.md ▸ AppKit). It is a passenger here.
        icon.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        icon.setContentHuggingPriority(.defaultLow, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        // Wrapping, so it needs the stack's width bound below to wrap within (docs/NOTES.md ▸
        // Localization): a longer translation goes onto two lines rather than off the edge.
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let stack = NSStackView(views: [icon, nameLabel, detailLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(10, after: detailLabel)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The placeholder card's width, preferred rather than required, so a narrow pane still lays
        // out (`QuickViewPlaceholderCard.layOut`).
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 280)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferredWidth,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])
    }

    /// The icon's size: large enough to say which app owns the type, as Quick Look's icon did, and
    /// small enough to leave the text room in a pane's preview.
    private static let iconSize: CGFloat = 64
}
