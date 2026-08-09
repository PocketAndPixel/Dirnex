import AppKit
import DirnexCore

/// What the queue bar's status line says, per operation kind.
///
/// Split out of `QueueBarView` when the file reached SwiftLint's 500-line ceiling, along a seam that
/// is a real one: everything here is *wording*, and it grows by one branch every time the queue
/// learns a new kind of job — while the view around it is geometry and does not. docs/NOTES.md's
/// rule for the ceiling is to split by concept rather than shave lines, and "the words" is the
/// concept.
///
/// Whole sentences per branch rather than a verb spliced into a template: a language that inflects
/// the object or reorders the clause cannot build "Copying <name>" from a bare verb.
extension QueueBarView {
    /// What a running job is doing, named by kind.
    ///
    /// Whole sentences per branch rather than a verb spliced into a template: a language that
    /// inflects the object or reorders the clause cannot build "Copying <name>" from a bare verb
    /// (docs/NOTES.md). Verifying and computing share one phrasing — from the bar's point of view
    /// both are "reading this file to hash it", and the sheet that follows says which it was.
    static func activeStatus(kind: FileOperation.Kind, name: String) -> String {
        switch kind {
        case .copy:
            return String(
                localized: "Copying \(name)",
                comment: "Queue-bar status; %@ is the file being copied."
            )
        case .move:
            return String(
                localized: "Moving \(name)",
                comment: "Queue-bar status; %@ is the file being moved."
            )
        case .checksum:
            return String(
                localized: "Checksumming \(name)",
                comment: "Queue-bar status; %@ is the file being hashed."
            )
        case .attributes:
            return String(
                localized: "Changing \(name)",
                comment: "Queue-bar status; %@ is the item whose attributes are being changed."
            )
        case .pack:
            // "Encrypting" rather than "Packing": only the encrypted path is queued at all (an
            // ordinary pack is one `bsdtar` spawn), and encryption is the reason this job is slow
            // enough to have a bar in the first place — so it is what the user needs told.
            return String(
                localized: "Encrypting \(name)",
                comment: "Queue-bar status; %@ is the file being added to an encrypted archive."
            )
        }
    }

    static func preparingStatus(kind: FileOperation.Kind) -> String {
        switch kind {
        case .copy:
            return String(
                localized: "Copying…",
                comment: "Queue-bar status while a copy is being prepared."
            )
        case .move:
            return String(
                localized: "Moving…",
                comment: "Queue-bar status while a move is being prepared."
            )
        case .checksum:
            return String(
                localized: "Checksumming…",
                comment: "Queue-bar status while a checksum run is being prepared."
            )
        case .attributes:
            return String(
                localized: "Changing permissions…",
                comment: "Queue-bar status while a recursive attributes change is being prepared."
            )
        case .pack:
            return String(
                localized: "Encrypting…",
                comment: "Queue-bar status while an encrypted archive is being prepared."
            )
        }
    }
}
