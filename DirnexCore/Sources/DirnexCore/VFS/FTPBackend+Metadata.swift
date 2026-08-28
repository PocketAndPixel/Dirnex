import Foundation

/// Carrying a source's mode and modification time across an FTP transfer (PLAN.md §M25 Slice 2).
///
/// Split from `FTPBackend.swift` for SwiftLint's `file_length`, along the seam the concept implies:
/// there, moving bytes; here, everything that rides with them.
///
/// FTP has no preserve flag, so unlike SFTP there is no free half — every carried fact is an
/// explicit step. What it does have that SFTP lacks is **`MFMT`**, an exact UTC-anchored
/// modification time (RFC 3659), so an FTP upload can carry a timestamp where an SFTP upload cannot.
/// The coarse, year-less, zone-less stamp FTP is known for belongs to `LIST`, not to the protocol.
extension FTPBackend {
    /// Finish a directory the engine recreated by hand, carrying the source's mode and times.
    ///
    /// What `copyMetadata` has always promised and no remote backend has ever done: the default is a
    /// no-op, so every FTP directory copy landed with the umask's mode and the time it was created,
    /// silently (PLAN.md §M25).
    ///
    /// The hint keeps it free. Without one a remote source has to be `stat`ed — over FTP a `LIST` of
    /// the parent, since there is no way to list a single item — and the engine is holding the entry
    /// that listing already produced.
    public func copyMetadata(
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
            hint = RemoteSourceMetadata(try stat(at: source))
                ?? RemoteSourceMetadata(permissions: nil, modificationTime: nil)
        }

        if destination.backend == .local {
            carryOntoLocal(hint, at: destination.path)
        } else if destination.backend == id {
            try carryOntoRemote(hint, at: destination)
        }
    }

    /// Finish a download on this machine. Free — the destination is local, so `chmod` and `utimes`
    /// do all of it and the wire's own limits have no bearing.
    func carryOntoLocal(_ hint: RemoteSourceMetadata?, at localPath: String) {
        guard let hint else { return }
        let carry = hint.plan(with: .localDestination)
        var dropped = carry.dropped
        if !LocalMetadataWriter.apply(carry.steps, to: localPath).isEmpty {
            dropped.formUnion(carry.attemptedAspects)
        }
        metadata.record(dropped: dropped)
    }

    /// Finish an upload on the server, in one invocation of its own.
    ///
    /// Refusals are **not** thrown: the bytes are there and the file is right, so a server that
    /// cannot keep a mode has not failed the copy. They are recorded — latched when the server said
    /// it has no such verb (reply 500, true of every file), counted as this item's loss when it was
    /// the file's own problem (550).
    func carryOntoRemote(_ hint: RemoteSourceMetadata, at destination: VFSPath) throws {
        let carry = metadata.plan(for: hint)
        guard !carry.steps.isEmpty || !carry.dropped.isEmpty else { return }
        var dropped = carry.dropped
        if !carry.steps.isEmpty {
            let refusals = try mapErrors(destination) {
                try transport.applyMetadata(carry.steps, to: destination.path)
            }
            if !refusals.isEmpty { dropped.formUnion(carry.attemptedAspects) }
            // **Latch only what the refusal unambiguously names.** `curl` stops at the first failed
            // quote command, so a run carrying two steps reports *a* refusal without saying which —
            // and latching both would stop attempting a verb the server honours, silently dropping
            // a timestamp it was perfectly willing to keep. That is the dishonest direction, and the
            // one this milestone exists to close. With a single step there is nothing to confuse.
            //
            // Not latching costs one wasted round trip per file on a server that lacks the verb,
            // and nothing else — the cheap direction to be wrong in.
            if carry.steps.count == 1, refusals.contains(where: isUnimplemented) {
                metadata.recordUnsupported(carry.capabilitiesUsed)
            }
        }
        metadata.record(dropped: dropped)
    }

    private func isUnimplemented(_ refusal: RemoteMetadataRefusal) -> Bool {
        if case .verbUnimplemented = refusal { return true }
        return false
    }
}

extension RemoteMetadataPlan {
    /// The capabilities this plan's steps exercised — what to stop attempting when the server
    /// answers that it has no such verb.
    var capabilitiesUsed: RemoteMetadataCapabilities {
        var used: RemoteMetadataCapabilities = []
        for step in steps {
            switch step {
            case .preserveDuringTransfer: used.insert(.preserveFlag)
            case .setMode: used.insert(.changeMode)
            case .setModificationTime: used.insert(.setModificationTime)
            }
        }
        return used
    }
}
