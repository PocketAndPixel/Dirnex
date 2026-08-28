import Foundation

/// Carrying a source's mode and times across an SFTP transfer, and saying so when it could not be
/// done (PLAN.md §M25 Slice 2).
///
/// Split from `SFTPBackend.swift` for SwiftLint's `file_length`, along the seam the concept already
/// implies: there, moving bytes; here, everything that rides with them.
public extension SFTPBackend {
    /// Finish a directory the engine recreated by hand, carrying the source's mode and times.
    ///
    /// This is what `copyMetadata` has always promised and no remote backend has ever done: the
    /// default is a no-op, so every SFTP directory copy landed with the umask's mode and the time it
    /// was created, silently (PLAN.md §M25).
    ///
    /// The hint is what keeps it cheap. Without one the source has to be `stat`ed, which for a
    /// remote directory is a whole connection; the engine holds the `FileEntry` it listed, so in
    /// practice nothing is asked. A local source is read directly either way, since there it is one
    /// syscall.
    func copyMetadata(
        at source: VFSPath,
        to destination: VFSPath,
        sourceMetadata: RemoteSourceMetadata?
    ) throws {
        let hint: RemoteSourceMetadata
        if let sourceMetadata {
            hint = sourceMetadata
        } else if source.backend == .local {
            hint = .ofLocalFile(source.path)
        } else {
            let entry = try stat(at: source)
            hint = RemoteSourceMetadata(entry) ?? RemoteSourceMetadata(
                permissions: nil,
                modificationTime: nil
            )
        }

        if destination.backend == .local {
            // Everything lands with plain syscalls, so the local destination's full capabilities
            // apply — no preserve flag, because there is no transfer verb here to carry one.
            let carry = hint.plan(with: .localDestination)
            let refusals = LocalMetadataWriter.apply(carry.steps, to: destination.path)
            var dropped = carry.dropped
            if !refusals.isEmpty { dropped.formUnion(carry.attemptedAspects) }
            metadata.record(dropped: dropped)
        } else if destination.backend == id {
            // No transfer to ride on, so the mode goes as its own batch line and the times have no
            // route at all — `sftp`'s batch language has no verb that sets one, which is why
            // `RemoteMetadataCapabilities.sftp` omits it and the plan counts it dropped.
            let carry = metadata.planWithoutTransferFlag(for: hint)
            let refusals = try mapErrors(destination) {
                try transport.applyMetadata(carry.steps, to: destination.path)
            }
            record(RemoteTransferOutcome(bytes: 0, refusals: refusals), against: carry)
        }
    }
}

public extension SFTPBackend {
    /// What Get Info may change on this account (PLAN.md §M25 Slice 5).
    ///
    /// `changeMode` and nothing else, less whatever this connection has since refused. There is no
    /// modification time here and that is the protocol rather than an omission: `sftp`'s batch
    /// language has no verb that sets one — `help` lists `chmod`, `chown` and `chgrp` and stops —
    /// so an SFTP row's date is readable and not writable, where an FTP row's is both.
    func editableMetadata(at path: VFSPath) -> RemoteMetadataCapabilities {
        guard path.backend == id else { return [] }
        return metadata.capabilities.intersection(.changeMode)
    }

    /// Write one item's mode. One batch, one connection, and the refusal is answered rather than
    /// thrown — a server that will not keep a mode has not broken anything.
    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        at path: VFSPath
    ) throws -> [RemoteMetadataRefusal] {
        try requireOwnBackend(path)
        guard !steps.isEmpty else { return [] }
        return try mapErrors(path) { try transport.applyMetadata(steps, to: path.path) }
    }
}

extension SFTPBackend {
    /// Weigh what a transfer's metadata steps did, and record it against this connection.
    ///
    /// The transport reports *whether* a step was refused; only the backend knows *what* the steps
    /// were carrying, because it built the plan — so the mapping from a refusal to a lost aspect
    /// lives here.
    ///
    /// A refusal is attributed to everything the plan set out to carry, which over-reports rather
    /// than under-reports and does so deliberately. `sftp` names the failing path and not the
    /// failing *attribute* — a `put -p` whose `setstat` was refused and a follow-up `chmod` that was
    /// refused print the identical line — so the honest answer is "part of this did not arrive" over
    /// a set the user can act on. Claiming a carry that did not happen is the one failure this
    /// milestone exists to prevent (PLAN.md §M25).
    func record(_ outcome: RemoteTransferOutcome, against plan: RemoteMetadataPlan) {
        for refusal in outcome.refusals {
            // SFTP has no "this server lacks the verb" answer to give: SETSTAT is not optional in
            // the protocol, so a refusal is always about the item. A transport that ever reports
            // otherwise is still honoured, rather than second-guessed here.
            if case .verbUnimplemented = refusal {
                metadata.recordUnsupported(.changeMode)
            }
        }
        var dropped = plan.dropped
        if !outcome.refusals.isEmpty { dropped.formUnion(plan.attemptedAspects) }
        metadata.record(dropped: dropped)
    }
}
