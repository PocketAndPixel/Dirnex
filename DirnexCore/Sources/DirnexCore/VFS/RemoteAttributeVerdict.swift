import Foundation

/// What a remote attribute write actually achieved — judged by **re-reading the item**, not by the
/// absence of an error (PLAN.md §M25 Slice 5).
///
/// **The whole reason this type exists is a measurement.** `sftp`'s `chmod` reports success for a
/// mode the server did not store: probed 2026-08-28 against a real `sshd`, `chmod 2755` on a file
/// whose group the account is not a member of exits **0**, prints **nothing**, and leaves the file
/// at `100755` — set-gid silently gone. The same command on a file in a group the account *is* in
/// stores `102755`, which is the control that makes it a fact about the write rather than about the
/// server. It is POSIX's rule for `chmod(2)` rather than OpenSSH's choice, and from a client there
/// is no way to tell the two runs apart except by looking.
///
/// So a panel that reported "saved" on a clean exit would be doing precisely what this milestone
/// exists to prevent: claiming a carry that did not happen. One `stat` is what makes the difference,
/// and a gesture the user made can afford one where a bulk copy cannot — which is why the *carry*
/// (Slice 2) deliberately does not read back and this does.
///
/// **The mode is verifiable and the time is not, and that asymmetry is not a gap.** A remote
/// `stat` here is a listing row: `sftp`'s `ls -la` has minute resolution and drops the time of day
/// entirely for anything older than about six months, and FTP's `LIST` stamp is zone-less on the
/// *server's* clock (docs/NOTES.md ▸ Parsing a year-less timestamp). Comparing a written time
/// against one of those would report a false refusal for a write that was exact — an hour off for
/// every user in a different zone from their server. `MFMT` is exact and answers for itself (RFC
/// 3659, and every refusal is `curl` exit 21 with a reply code), so the time rests on the verb's own
/// answer and the mode rests on the file's.
public struct RemoteAttributeVerdict: Sendable, Equatable {
    /// What the user asked for and the server did not do. Empty is the good case.
    ///
    /// A field lands here whether the transport *said* it was refused or the read-back simply
    /// disagrees — the two are one fact to whoever is reading the panel, and separating them would
    /// invite a caller to report the loud one and skip the quiet one.
    public let refused: Set<RemoteAttributeField>
    /// What the item carries now, read back after the write. The panel redraws from this rather than
    /// from what it sent, so what is on screen is the server's answer even where it disagrees.
    public let landed: FileEntry

    public init(refused: Set<RemoteAttributeField>, landed: FileEntry) {
        self.refused = refused
        self.landed = landed
    }

    /// Whether everything asked for arrived.
    public var isComplete: Bool { refused.isEmpty }

    /// Weigh a write: what was asked, what the transport said, and what the item reads as now.
    ///
    /// - Parameters:
    ///   - change: what the panel sent. A field it did not set can never be reported refused.
    ///   - refusals: what the transport answered — a step that came back named. Attributed to
    ///     **every** field the change set rather than to one, for the reason
    ///     ``SFTPBackend/record(_:against:)`` already gives: `sftp` names the failing *path* and not
    ///     the failing attribute, so two steps in one batch produce one indistinguishable line. Over-
    ///     reporting a loss is the safe direction; claiming a write that did not land is not.
    ///   - landed: the item re-read after the write.
    public static func weigh(
        _ change: RemoteAttributeChange,
        refusals: [RemoteMetadataRefusal],
        landed: FileEntry
    ) -> RemoteAttributeVerdict {
        var refused: Set<RemoteAttributeField> = refusals.isEmpty ? [] : change.fields
        // The read-back, which is the half a clean exit cannot speak for. Only the mode: see the
        // type's own doc for why a listing's timestamp is not an instrument.
        if let asked = change.permissions, landed.permissions != asked.rawValue {
            refused.insert(.permissions)
        }
        return RemoteAttributeVerdict(refused: refused, landed: landed)
    }
}
