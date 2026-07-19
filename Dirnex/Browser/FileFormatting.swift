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
