import Foundation

/// Writing a carried mode and modification time onto a destination **on this machine**.
///
/// Shared by both remote backends, because a *download*'s destination is local whatever protocol
/// brought the bytes: nothing here touches the network, which is what makes the download direction
/// free once the source's metadata is handed down rather than asked for (``RemoteSourceMetadata``).
///
/// It is the reason ``RemoteMetadataCapabilities/localDestination`` exists: reading the wire's
/// limits into this direction would have an FTP download drop a modification time the local disk was
/// perfectly able to take, and blame the protocol for it.
public enum LocalMetadataWriter {
    /// Apply a plan's steps to a local destination, answering the ones that did not take.
    ///
    /// In the ordinary SFTP download this loop has **nothing to do**: `get -p` has already carried
    /// the nine mode bits and both timestamps exactly, so only the three special bits it silently
    /// drops are left, and most files have none. Over FTP, where no such flag exists, it does all
    /// of the work.
    static func apply(
        _ steps: [RemoteMetadataStep],
        to localPath: String
    ) -> [RemoteMetadataRefusal] {
        var refusals: [RemoteMetadataRefusal] = []
        for step in steps {
            switch step {
            case let .setMode(mode):
                if chmod(localPath, mode_t(mode.rawValue)) != 0 {
                    refusals.append(.itemRefused(String(cString: strerror(errno))))
                }
            case let .setModificationTime(date):
                if !setModificationTime(date, on: localPath) {
                    refusals.append(.itemRefused(String(cString: strerror(errno))))
                }
            case .preserveDuringTransfer:
                continue // the transfer's own flag; nothing left to do here
            }
        }
        return refusals
    }

    /// Set a local file's modification time, keeping its access time as it stands.
    ///
    /// The access time is read back and re-sent rather than left out, because `utimes` writes
    /// **both** or neither — passing a zero there would stamp the file's atime with the epoch. It is
    /// read from the file itself rather than carried in the plan for the reason
    /// ``RemoteMetadataPlan/carrying(permissions:modificationTime:accessTime:capabilities:)`` gives:
    /// nothing this app parses reports a source's access time, and the act of reading a file changes
    /// it anyway.
    private static func setModificationTime(_ date: Date, on localPath: String) -> Bool {
        var info = Darwin.stat()
        guard lstat(localPath, &info) == 0 else { return false }
        let seconds = date.timeIntervalSince1970
        var times = [
            timeval(tv_sec: info.st_atimespec.tv_sec, tv_usec: 0),
            timeval(
                tv_sec: Int(seconds.rounded(.down)),
                tv_usec: Int32(((seconds - seconds.rounded(.down)) * 1_000_000).rounded())
            )
        ]
        return utimes(localPath, &times) == 0
    }
}

extension RemoteMetadataPlan {
    /// The aspects this plan set out to carry — what a refusal costs, as opposed to what was known
    /// to be unreachable before it was attempted (``dropped``).
    var attemptedAspects: Set<RemoteMetadataAspect> {
        var aspects: Set<RemoteMetadataAspect> = []
        for step in steps {
            switch step {
            case .preserveDuringTransfer: aspects.formUnion([.mode, .modificationTime])
            case .setMode: aspects.formUnion([.mode, .specialModeBits])
            case .setModificationTime: aspects.insert(.modificationTime)
            }
        }
        return aspects
    }
}

extension RemoteMetadataPlan {
    /// The aspects only ``RemoteMetadataStep/preserveDuringTransfer`` was going to carry — what is
    /// lost when the transfer verb's own flag never ran, as on a segmented download assembled from
    /// exec channels.
    ///
    /// The mode is not among them: a plan that names a mode at all also carries a
    /// ``RemoteMetadataStep/setMode(_:)`` whenever `-p` could not express it, and a local follow-up
    /// applies that. The **times** are the half with no other route, since nothing but the flag
    /// carries them unless the hint held one.
    var aspectsOnlyPreserveCarries: Set<RemoteMetadataAspect> {
        guard usesPreserveFlag else { return [] }
        var aspects: Set<RemoteMetadataAspect> = []
        if !steps.contains(
            where: { if case .setModificationTime = $0 { return true }; return false }
        ) {
            aspects.insert(.modificationTime)
        }
        return aspects
    }
}
