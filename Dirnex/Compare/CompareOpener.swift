import AppKit
import DirnexCore

/// One file of a comparison: the copy on this disk that is read, and where the user sees the file.
struct CompareFile: Sendable {
    /// A local path: the file itself, or the copy brought down for a file that is not on this disk.
    let path: VFSPath
    /// Where the file lives, which the window's header names. A server object's or an archive
    /// member's own location, never the temporary copy's.
    let origin: VFSPath
    /// Where a save of the copy goes back to: the server file or the archive member F4 would write
    /// back (PLAN.md §M33 Slice 4). `nil` for a local file, which is saved in place, and for a file
    /// with nowhere to go back to, such as a member of an archive inside another archive.
    var writeBack: EditDestination?

    /// Whether the copy read is the file itself, a local file a save writes in place. A copy brought
    /// down from a server or out of an archive goes back through ``writeBack`` instead.
    var isSavedInPlace: Bool {
        origin.backend == .local && path == origin
    }
}

/// A file the compare window could not read, and why.
struct CompareReadFailure: Error, Equatable {
    let name: String
    let reason: ComparedText.Failure
}

/// Opens Dirnex's compare window on two local files (PLAN.md §M31 Slice 4): both are read whole off
/// the main thread, then the window opens, or the caller is handed what its alert should say. ⌥F3,
/// the Synchronize sheet and the conflict dialog all open the window through here.
@MainActor
enum CompareOpener {
    /// Read the pair and open the window on it, or hand `failed` the alert's detail.
    ///
    /// `leftDetail` and `rightDetail` are what each pane's header says under the file's name: where
    /// the file is, as the user knows it. `saving` is where the window's saves keep their undo
    /// (PLAN.md §M33 Slice 3); without it the window changes neither file, as the conflict dialog's
    /// must, whose right-hand file is a copy waiting on that dialog.
    static func openWindow(
        _ left: CompareFile,
        detail leftDetail: String,
        _ right: CompareFile,
        detail rightDetail: String,
        saving: CompareSaving? = nil,
        failed: @escaping @MainActor (String) -> Void
    ) {
        Task {
            let sources = await BlockingWork.run {
                Self.sources(left, detail: leftDetail, right, detail: rightDetail)
            }
            switch sources {
            case let .success((leftSource, rightSource)):
                CompareWindowController.present(
                    left: leftSource,
                    right: rightSource,
                    allowsCopies: saving != nil,
                    saving: saving ?? .none
                )
            case let .failure(failure):
                failed(failureDetail(failure))
            }
        }
    }

    /// Both sides as the window receives them, or the first one that cannot be compared as text.
    /// Blocking; call it off the main thread.
    nonisolated static func sources(
        _ left: CompareFile,
        detail leftDetail: String,
        _ right: CompareFile,
        detail rightDetail: String
    ) -> Result<(CompareSource, CompareSource), CompareReadFailure> {
        do {
            return try .success((
                source(left, detail: leftDetail),
                source(right, detail: rightDetail)
            ))
        } catch {
            return .failure(error)
        }
    }

    /// One side: the text read whole, named after the file where it lives, and colored by the
    /// grammar Quick View would pick for it.
    ///
    /// A file a save can write is either a local file read as itself (PLAN.md §M33 Slice 3) or a
    /// copy that goes back where it came from (Slice 4), so what the file read looks like is taken
    /// just before the read, for the save to be checked against.
    nonisolated static func source(
        _ file: CompareFile,
        detail: String
    ) throws(CompareReadFailure) -> CompareSource {
        let name = file.origin.lastComponent
        let saveable = file.isSavedInPlace || file.writeBack != nil
        let target = saveable ? ComparedFileSave.Target.reading(file.path.path) : nil
        do {
            let document = try ComparedDocument.read(
                contentsOf: URL(fileURLWithPath: file.path.path)
            )
            let opening = document.text(ofFirstLines: SyntaxLanguage.contentsLineLimit)
            return CompareSource(
                name: name,
                detail: detail,
                origin: file.origin,
                document: document,
                language: SyntaxLanguage.forFile(named: name, text: opening),
                target: target,
                writeBack: file.writeBack
            )
        } catch {
            throw CompareReadFailure(name: name, reason: error)
        }
    }

    /// What an alert says about a file the window could not read.
    static func failureDetail(_ failure: CompareReadFailure) -> String {
        let name = failure.name
        switch failure.reason {
        case let .tooLarge(_, limit):
            return limitDetail(limit)
        case .binary:
            return String(
                localized: "“\(name)” isn’t a text file. Dirnex compares text files only.",
                comment: "Compare failure detail; %@ is a file name."
            )
        case .undecodable:
            return String(
                localized: "“\(name)” isn’t text in any encoding Dirnex can read.",
                comment: "Compare failure detail; %@ is a file name."
            )
        case .unreadable:
            return String(
                localized: "“\(name)” couldn’t be read.",
                comment: "Compare failure detail; %@ is a file name."
            )
        }
    }

    /// The largest file Dirnex's window compares, said as a limit.
    static func limitDetail(_ limit: Int64) -> String {
        String(
            localized: "Dirnex compares files of up to \(FileFormatting.byteString(limit)).",
            comment: "Compare failure detail; %@ is a formatted byte size."
        )
    }

    /// The alert title for a pair that could not be compared.
    static var failureTitle: String {
        String(
            localized: "Couldn’t compare these files",
            comment: """
            Alert title when the two files to compare can't be downloaded, extracted or read as text.
            """
        )
    }
}

extension CompareTool {
    /// The tool's row in Settings ▸ Operations: an external tool's own name, or "Built-in" for
    /// Dirnex's window. The other rows are apps and Dirnex's window is not one, so it is named the
    /// way macOS names a Mac's own parts ("Built-in Display"), and translated.
    var settingsTitle: String {
        switch self {
        case let .external(tool):
            tool.displayName
        case .dirnex:
            String(
                localized: "Built-in",
                comment: "Settings compare-tool choice: Dirnex's own compare window, not another app."
            )
        }
    }

    /// What a menu item or button that compares two files says: the external tool it opens, or
    /// "Compare Contents…" for Dirnex's own window. The main menu's item says "Compare By
    /// Contents…" for the window instead, the command's own catalog title.
    var compareItemTitle: String {
        switch self {
        case let .external(tool):
            String(
                localized: "Compare with \(tool.displayName)…",
                comment: "Menu item or button: open two files in an external diff tool; %@ is the tool name."
            )
        case .dirnex:
            String(
                localized: "Compare Contents…",
                comment: "Menu item or button: show how two files differ, in Dirnex's own compare window."
            )
        }
    }
}
