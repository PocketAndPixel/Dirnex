import AppKit
import AVFoundation

/// What a file the core reads plays in, Matroska, WebM or AVI (PLAN.md §M42 ▸ Slices 4 and 5): its
/// picture, or its icon for a sound alone, over a slim timeline the mouse can click and drag.
///
/// AVKit's controls belong to `AVPlayer`, which cannot open these files, so the timeline is the one
/// control drawn here. Play and pause are the header's button and ⌘P, as for every other movie, and
/// the ⇧-keys move along the timeline from the file table.
@MainActor
final class QuickViewSampleBufferView: NSView {
    /// Hosts the player's display layer. Internal, for the tests.
    let pictureView = NSView()
    private let iconView = NSImageView()
    /// The file's place, which a click or a drag moves. Internal, for the tests and the surface's hit
    /// test, which lets the mouse through to it alone.
    let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timelineStrip = NSView()
    private var displayLayer: AVSampleBufferDisplayLayer?
    /// What a move of the timeline asks for, in seconds. Set by the media view.
    var onSeek: ((Double) -> Void)?

    static let timelineHeight: CGFloat = 22

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        pictureView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        timeline.controlSize = .small
        timeline.isContinuous = true
        timeline.target = self
        timeline.action = #selector(timelineMoved(_:))
        timeline.setAccessibilityLabel(String(
            localized: "Timeline",
            comment: "Accessibility label of the slider under a playing Matroska, WebM or AVI movie in Quick View."
        ))
        timelineStrip.wantsLayer = true
        timelineStrip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        for view in [pictureView, iconView, timelineStrip, timeline] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(pictureView)
        addSubview(iconView)
        addSubview(timelineStrip)
        timelineStrip.addSubview(timeline)
        NSLayoutConstraint.activate([
            pictureView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pictureView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pictureView.topAnchor.constraint(equalTo: topAnchor),
            pictureView.bottomAnchor.constraint(equalTo: timelineStrip.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: pictureView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: pictureView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
            timelineStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            timelineStrip.heightAnchor.constraint(equalToConstant: Self.timelineHeight),
            timeline.leadingAnchor.constraint(equalTo: timelineStrip.leadingAnchor, constant: 12),
            timeline.trailingAnchor.constraint(equalTo: timelineStrip.trailingAnchor, constant: -12),
            timeline.centerYAnchor.constraint(equalTo: timelineStrip.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Put `player`'s picture up, or `icon` when it has none.
    func show(_ player: SampleBufferPlayer, icon: NSImage?) {
        displayLayer?.removeFromSuperlayer()
        displayLayer = player.displayLayer
        if let layer = player.displayLayer {
            layer.frame = pictureView.bounds
            pictureView.layer?.addSublayer(layer)
        }
        iconView.image = player.displayLayer == nil ? icon : nil
        iconView.isHidden = player.displayLayer != nil
        update(seconds: 0, duration: player.duration)
    }

    /// Let the picture go.
    func clear() {
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        iconView.image = nil
    }

    /// Move the timeline to `seconds` of `duration`, unless the mouse is moving it: a drag is the
    /// place the user wants, and the player catches up with it.
    func update(seconds: Double, duration: Double?) {
        timeline.isEnabled = (duration ?? 0) > 0
        timeline.maxValue = max(duration ?? 1, 0.001)
        guard !isDraggingTimeline else { return }
        timeline.doubleValue = seconds
    }

    /// Set by the timeline's own action while the mouse that moved it is still down.
    private var timelineIsTracking = false

    private var isDraggingTimeline: Bool {
        timelineIsTracking && NSEvent.pressedMouseButtons & 1 == 1
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = pictureView.bounds
        CATransaction.commit()
    }

    @objc private func timelineMoved(_ sender: NSSlider) {
        timelineIsTracking = NSApp.currentEvent.map { $0.type != .leftMouseUp } ?? false
        onSeek?(sender.doubleValue)
    }
}
