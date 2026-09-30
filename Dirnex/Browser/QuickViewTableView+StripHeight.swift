import AppKit

/// How tall the strip under Quick View's table is, and dragging it taller or shorter (2026-09-15).
///
/// Until somebody drags it, the strip takes what the selected row needs, up to two fifths of the
/// surface, so it grows and shrinks as the selection moves. A drag sets a height of its own, which
/// then holds for every row, every file, each of Quick View's sizes and the next launch, since the
/// number of fields a file has does not change from one row to the next. A double-click on the edge
/// goes back to fitting the row.
///
/// The height is kept in points rather than as a share of the surface: what it has to fit is lines
/// of text, which are the same size in a pane as in a full window. Where a surface is too short for
/// it, the table keeps room for its header and a couple of rows — under the filter bar, while that is
/// shown (`QuickViewTableView+Filter`).
extension QuickViewTableView {
    /// The shortest the strip can be dragged: its separator and one line.
    static let minimumStripHeight: CGFloat = 36
    /// The room a drag leaves the table above the strip: its header and a couple of rows.
    static let minimumTableHeight: CGFloat = 80
    /// How tall the handle is: the strip's separator, which takes one point of the strip (measured:
    /// the box's 5-point frame is centered on it), and the blank room under it.
    static let stripHandleHeight = 1 + QuickViewRecordStrip.handleRoom
    /// Where a dragged height is kept. Layout state rather than a setting, like a split view's
    /// divider, so it sits beside the tabs' keys rather than under `Dirnex.pref`.
    static let stripHeightKey = "Dirnex.quickView.tableStripHeight"

    /// The height somebody dragged the strip to, or `nil` while it fits its row.
    var chosenStripHeight: CGFloat? {
        get {
            (layoutDefaults.object(forKey: Self.stripHeightKey) as? NSNumber)
                .map { CGFloat($0.doubleValue) }
        }
        set {
            if let newValue {
                layoutDefaults.set(Double(newValue), forKey: Self.stripHeightKey)
            } else {
                layoutDefaults.removeObject(forKey: Self.stripHeightKey)
            }
        }
    }

    /// The strip's height in a surface `surface` points tall, showing a row that needs `fitting`.
    static func stripHeight(chosen: CGFloat?, fitting: CGFloat, surface: CGFloat) -> CGFloat {
        guard let chosen else { return min(fitting, max(surface * 0.4, 48)) }
        return clampedStripHeight(chosen, surface: surface)
    }

    /// `height` within what a drag may set in a surface `surface` points tall.
    static func clampedStripHeight(_ height: CGFloat, surface: CGFloat) -> CGFloat {
        let most = max(surface - minimumTableHeight, minimumStripHeight)
        return min(min(max(height, minimumStripHeight), most), max(surface, 0))
    }

    /// Keep `height`, bounded by this surface, for the strip from now on.
    func resizeStrip(to height: CGFloat) {
        chosenStripHeight = round(Self.clampedStripHeight(height, surface: roomBelowFilterBar))
        needsLayout = true
    }

    /// Forget a dragged height, so the strip fits its row again.
    func fitStripToRow() {
        chosenStripHeight = nil
        needsLayout = true
    }

    /// The height the strip is laid out at now, and whether its edge can be dragged: not while no
    /// row is selected, when there is no strip to size.
    func updateStripHeight() {
        let height = strip.isEmpty ? 0 : Self.stripHeight(
            chosen: chosenStripHeight,
            fitting: strip.fittingHeight(forWidth: bounds.width),
            surface: roomBelowFilterBar
        )
        if let stripHeight, abs(stripHeight.constant - height) > 0.5 {
            stripHeight.constant = height
        }
        stripHandle.isHidden = height == 0
    }

    /// The handle along the strip's top edge: from the separator down over the blank room above the
    /// strip's text view, so nothing under it sets a cursor of its own — neither the table's last row
    /// nor the text (`QuickViewRecordStrip.handleRoom`). Placed and sized by hand, live: it started 3
    /// points up into the table, where the cursor changed over the last row.
    func installStripHandle() {
        stripHandle.translatesAutoresizingMaskIntoConstraints = false
        stripHandle.isHidden = true
        addSubview(stripHandle)
        NSLayoutConstraint.activate([
            stripHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripHandle.topAnchor.constraint(equalTo: strip.topAnchor),
            stripHandle.heightAnchor.constraint(equalToConstant: Self.stripHandleHeight)
        ])
        stripHandle.currentHeight = { [weak self] in self?.strip.frame.height ?? 0 }
        stripHandle.resize = { [weak self] height in self?.resizeStrip(to: height) }
        stripHandle.fit = { [weak self] in self?.fitStripToRow() }
    }
}
