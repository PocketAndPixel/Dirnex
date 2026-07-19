import AppKit

/// An `NSSplitView` whose thin divider is tinted to match the file list's column-header
/// hairline (`separatorColor`) rather than the darker system default. This makes the
/// vertical seam between the two panes read as the same gray as the header borders.
final class HairlineSplitView: NSSplitView {
    override var dividerColor: NSColor { .separatorColor }
}
