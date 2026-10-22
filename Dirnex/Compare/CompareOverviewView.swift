import AppKit

/// The strip at the window's right edge (PLAN.md §M31 Slice 3): every change in the comparison at
/// its place in the whole, the part on screen outlined, and a click or a drag to go there.
///
/// Positions here are proportions of the row count, so unlike the panes it needs nothing from
/// TextKit. The changes are folded into one color per point of height when the strip changes size
/// or content, so a comparison with tens of thousands of changes draws as cheaply as one with ten.
@MainActor
final class CompareOverviewView: NSView {
    var rowCount = 0 {
        didSet { needsBuckets = true }
    }

    var changeRows: [Range<Int>] = [] {
        didSet { needsBuckets = true }
    }

    var kinds: [CompareChangeKind] = [] {
        didSet { needsBuckets = true }
    }

    /// The rows on screen, outlined.
    var visibleRows: ClosedRange<Int>?
    /// Asked to show a row, from a click or a drag.
    var onJump: ((Int) -> Void)?

    static let width: CGFloat = 16

    private var buckets: [CompareChangeKind?] = []
    private var needsBuckets = true

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.height != frame.height {
            needsBuckets = true
        }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        if needsBuckets {
            buckets = Self.buckets(
                height: Int(bounds.height),
                rowCount: rowCount,
                changes: changeRows,
                kinds: kinds
            )
            needsBuckets = false
        }
        var start = 0
        while start < buckets.count {
            guard let kind = buckets[start] else {
                start += 1
                continue
            }
            var end = start + 1
            while end < buckets.count, buckets[end] == kind {
                end += 1
            }
            CompareColors.mark(for: kind).setFill()
            NSRect(x: 4, y: CGFloat(start), width: bounds.width - 7, height: CGFloat(end - start)).fill(
            )
            start = end
        }
        if let visibleRows, rowCount > 0 {
            let top = CGFloat(visibleRows.lowerBound) / CGFloat(rowCount) * bounds.height
            let bottom = CGFloat(visibleRows.upperBound + 1) / CGFloat(rowCount) * bounds.height
            let window = NSRect(
                x: 1.5,
                y: top,
                width: bounds.width - 2.5,
                height: max(4, bottom - top)
            )
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            window.fill()
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: window.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// One change kind per point of height, the strongest where changes share a point: a removal
    /// and an insertion together are a change.
    static func buckets(
        height: Int,
        rowCount: Int,
        changes: [Range<Int>],
        kinds: [CompareChangeKind]
    ) -> [CompareChangeKind?] {
        guard height > 0, rowCount > 0 else { return [] }
        var buckets = [CompareChangeKind?](repeating: nil, count: height)
        let scale = Double(height) / Double(rowCount)
        for (index, rows) in changes.enumerated() {
            let kind = kinds.indices.contains(index) ? kinds[index] : .change
            let first = min(height - 1, Int(Double(rows.lowerBound) * scale))
            // At least two points tall, so a one-line change is still visible on a long file.
            let last = min(height - 1, max(first + 1, Int(Double(rows.upperBound) * scale)))
            for point in first...last {
                if let existing = buckets[point], existing != kind {
                    buckets[point] = .change
                } else {
                    buckets[point] = kind
                }
            }
        }
        return buckets
    }

    override func mouseDown(with event: NSEvent) {
        jump(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        jump(to: event)
    }

    private func jump(to event: NSEvent) {
        guard rowCount > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let fraction = min(max(point.y / bounds.height, 0), 1)
        onJump?(min(rowCount - 1, Int(fraction * CGFloat(rowCount))))
    }
}
