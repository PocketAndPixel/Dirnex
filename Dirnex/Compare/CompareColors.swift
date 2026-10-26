import AppKit

/// The compare window's colors (PLAN.md §M31 Slice 3).
///
/// **GitHub's split-diff palette**, the way `SyntaxTheme` borrows VS Code's: a reader has seen these
/// tints next to code for years, and red for what the left side had and green for what the right
/// side has needs no legend. Both halves are authored. The dark ones are GitHub's translucent tints
/// composited onto `.textBackgroundColor`'s `#1E1E1E`, so they are solid colors that draw the same
/// under text whatever is behind them.
///
/// Not main-actor isolated: a pane's rows read their color inside TextKit's layout-manager delegate,
/// which is not (`CompareRowColoring`).
enum CompareColors {
    /// A line only the left side has, or the left side of a changed row.
    static let removedRow = pair(light: 0xFFEBE9, dark: 0x3F2625)
    /// A line only the right side has, or the right side of a changed row.
    static let insertedRow = pair(light: 0xE6FFEC, dark: 0x203124)
    /// The words that differ inside a changed row, on each side.
    static let removedWords = pair(light: 0xFFC1BF, dark: 0x753230)
    static let insertedWords = pair(light: 0xACF2BD, dark: 0x24522D)
    /// A gap: the side that has nothing opposite the other's line.
    static let gapRow = pair(light: 0xF2F2F2, dark: 0x2A2A2A)

    /// The merge window's rows (PLAN.md §M34 Slice 3), from the same palette: GitHub's accent,
    /// severe and success tints, the dark ones composited at 15 % onto `#1E1E1E` as above. A change
    /// one side made, or both made alike, which merges on its own.
    static let changedRow = pair(light: 0xDDF4FF, dark: 0x222E3F)
    /// A conflict nobody has chosen for yet.
    static let conflictRow = pair(light: 0xFFF1E5, dark: 0x3A2A1F)
    /// A conflict with a choice.
    static let resolvedRow = pair(light: 0xDAFBE1, dark: 0x203224)

    /// A change's mark in the band and the overview strip, by what the change does.
    static let removalMark = pair(light: 0xCF222E, dark: 0xF85149)
    static let insertionMark = pair(light: 0x1A7F37, dark: 0x3FB950)
    static let changeMark = pair(light: 0x0969DA, dark: 0x58A6FF)
    /// The merge window's marks for an open conflict and a chosen one.
    static let conflictMark = pair(light: 0xBC4C00, dark: 0xDB6D28)
    static let resolvedMark = insertionMark

    /// A row's background in one pane, or `nil` for a row that is the same on both sides.
    static func rowFill(_ row: AlignedRowFill) -> NSColor? {
        switch row {
        case .same: nil
        case .gap: gapRow
        case .removed: removedRow
        case .inserted: insertedRow
        case .changed: changedRow
        case .conflict: conflictRow
        case .resolved: resolvedRow
        }
    }

    static func mark(for kind: CompareChangeKind) -> NSColor {
        switch kind {
        case .removal: removalMark
        case .insertion: insertionMark
        case .change: changeMark
        case .conflict: conflictMark
        case .resolved: resolvedMark
        }
    }

    private static func pair(light: UInt32, dark: UInt32) -> NSColor {
        let light = color(light)
        let dark = color(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// How one pane paints one row.
enum AlignedRowFill: Equatable {
    case same
    case gap
    case removed
    case inserted
    /// The merge window's (PLAN.md §M34 Slice 3): a line of a change that merges on its own.
    case changed
    /// A line of a conflict nobody has chosen for, or the result's gap where its lines will go.
    case conflict
    /// A line of a conflict with a choice.
    case resolved
}

/// What a change does, for its mark in the band and the overview strip.
enum CompareChangeKind: Equatable {
    /// Lines only the left side has.
    case removal
    /// Lines only the right side has.
    case insertion
    /// Lines on both sides; in the merge window, a change that merges on its own.
    case change
    /// The merge window's conflict nobody has chosen for yet.
    case conflict
    /// The merge window's conflict with a choice.
    case resolved

    /// The one mark for two kinds that share a point of the overview strip: an open conflict over
    /// anything, then a chosen one, and a removal beside an insertion is a change.
    func combined(with other: CompareChangeKind) -> CompareChangeKind {
        if self == other { return self }
        if self == .conflict || other == .conflict { return .conflict }
        if self == .resolved || other == .resolved { return .resolved }
        return .change
    }
}
