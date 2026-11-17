import DirnexCore
import Foundation

/// Where an exported page is written before the queue copies it to the folder the user chose
/// (PLAN.md §M39 ▸ Slice 12).
///
/// Each export gets a directory of its own holding the file under its **real name**, Pack's lesson
/// (``DirnexCore/PackStaging``): a transport handed a destination is free to read the local file's
/// name, and the conflict dialog shows it. So the copy is an ordinary F5 of one file, and lands with
/// F5's conflict question, its undo and every backend F5 can write to.
///
/// **The file is kept for the session**, not swept when the copy ends. Undo of a copy removes what
/// landed and redo copies the source again (`UndoJournal`), so a source taken away at the end of the
/// job would make the redo of every export fail. The whole root is cleared at launch instead, as the
/// remote cache's is, before anything can be exporting; an export is a page or a PDF, megabytes.
enum MarkdownExportStaging {
    nonisolated static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexExport", isDirectory: true)
    }

    /// A new, empty directory under ``root`` and the URL `name` will have inside it.
    static func newFile(named name: String) throws -> URL {
        let holder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        return holder.appendingPathComponent(name, isDirectory: false)
    }

    /// Remove the directory `file` was staged in, for an export that failed before the copy.
    static func discard(_ file: URL) {
        let holder = file.deletingLastPathComponent().standardizedFileURL
        guard holder.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: holder)
    }

    /// Remove every staged export. Called once at launch.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The format the export sheet opens on: the one chosen last time, HTML on a first export.
///
/// A remembered choice rather than a Settings preference, like the window's tabs: nothing in Settings
/// shows it. Its own defaults handle, so a test reads and writes a scratch domain.
struct MarkdownExportFormatMemory {
    static let key = "Dirnex.exportFormat"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var format: MarkdownExport.Format {
        get { defaults.string(forKey: Self.key).flatMap(MarkdownExport.Format.init) ?? .html }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
