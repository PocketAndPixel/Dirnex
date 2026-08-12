import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Row-rendering helpers: human-readable size/date strings and per-extension file
/// icons. All main-actor state (formatters, icon cache) lives here so cell setup in
/// the panel stays declarative.
@MainActor
enum FileFormatting {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Size column text. A file shows its own byte size. A directory shows a dash until
    /// a recursive total has been computed for it (Space-on-dir, PLAN.md §M1), then that
    /// byte count — Total Commander's in-place directory sizing.
    static func sizeString(for entry: FileEntry, computedSize: Int64? = nil) -> String {
        if entry.isDirectoryLike {
            return computedSize.map { byteFormatter.string(fromByteCount: $0) } ?? "—"
        }
        return byteFormatter.string(fromByteCount: entry.byteSize)
    }

    static func byteString(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func dateString(for entry: FileEntry) -> String {
        dateFormatter.string(from: entry.modificationDate)
    }

    /// Every shape `dateString(for:)` can take in the current region — what a caller sizing the Date
    /// column measures (`DateColumnMetrics`).
    ///
    /// Sampled through the **same** formatter the rows use rather than reasoned about. A
    /// `.short`/`.short` date is region data and its shape is not ours to predict: measured, `de_DE`
    /// renders `28.12.25, 22:58` where `ko_KR` renders `2025. 12. 28. 오후 10:58` and `fi_FI` puts a
    /// word in the middle (`28.12.2025 klo 22.58`). A second formatter here would be a second
    /// definition of what a row shows, and the two would drift the first time either changed.
    ///
    /// Every month, because a region is free to spell one; both halves of the clock, for the AM/PM
    /// regions; a two-digit day, hour and minute, since those are the widest a numeric field gets.
    static var dateStringShapes: [String] {
        var components = DateComponents()
        components.year = 2025
        components.day = 28
        components.minute = 58
        let calendar = Calendar(identifier: .gregorian)
        return (1...12).flatMap { month in
            [10, 22].compactMap { hour -> String? in
                components.month = month
                components.hour = hour
                return calendar.date(from: components).map { dateFormatter.string(from: $0) }
            }
        }
    }
}

/// Small icons for the name column, cached by extension so scrolling a huge
/// directory never re-hits the workspace icon service per row.
@MainActor
enum FileIconProvider {
    private static var cache: [String: NSImage] = [:]
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let genericIcon = NSWorkspace.shared.icon(for: .data)

    /// Icon for the synthetic `..` parent row. A plain folder icon — the `..` label
    /// carries the meaning, matching how Finder and Total Commander render it.
    static let parentIcon = folderIcon

    static func icon(for entry: FileEntry) -> NSImage {
        if entry.isDirectoryLike { return folderIcon }

        let ext = entry.fileExtension.lowercased()
        guard !ext.isEmpty else { return genericIcon }
        if let cached = cache[ext] { return cached }

        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[ext] = icon
        return icon
    }
}
