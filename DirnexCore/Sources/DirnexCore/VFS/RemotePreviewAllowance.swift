import Foundation

/// How far past the Settings preview limit Quick View may fetch by itself on one connection, because
/// the user has already said yes to a file about that size there (2026-09-12).
///
/// **Learned from an answer rather than set in advance**, which is what the Settings limit cannot
/// be. That limit is a standing statement about every server and every session, so it has to be
/// conservative; a click on the placeholder card's Download button is a statement about *these*
/// files, on *this* connection, *now*. Reported as the gap between the two: a photographer arrowing
/// through a folder of 23–36 MB camera RAW files on S3 had to reach for the mouse on every single
/// one, having answered the same question a moment earlier.
///
/// What makes a learned ceiling defensible is what already bounds the automatic fetch
/// (`RemoteFetchPolicy`, and the app's settle delay and abandonment): a sweep costs nothing and
/// leaving the row stops the transfer, so a higher ceiling spends bandwidth only on files the user
/// actually stops on. The rules below are what keep the inference narrow:
///
/// - **Only an agreement beyond the Settings limit counts.** A ⌃Q on a 9 MB file under a 10 MB limit
///   agreed to nothing the limit had not already allowed, and must not quietly double it.
/// - **A limit of zero ignores all of it.** Zero is "download nothing unasked", and a click there
///   answers for one file.
/// - **The largest agreement wins.** A smaller one lowers nothing — the card only offers Download
///   for a file over the current ceiling, so "largest" and "last" are nearly always the same anyway.
/// - **Per connection.** Yes to 23 MB from a bucket on a fast link says nothing about a NAS over a
///   phone hotspot, which is the same reason the Settings limit is described as a fact about the
///   user's files *and their connection*.
/// - **Stop withdraws it.** Stopping a download larger than the Settings limit forgets that
///   connection's allowance outright, rather than lowering it below the stopped file: a click on a
///   2 GB video by mistake would otherwise leave every 1.9 GB one downloading on arrival.
///
/// It lives in memory for the life of the app and is never persisted — a guess about one session
/// that silently outlived it would be worse than asking again, the argument M27 made for a declared
/// code page.
///
/// Read only by the two *preview* rows of `RemoteFetchPolicy`'s table. Every other row is expressed
/// against the Settings limit, so feeding this into that limit instead would let one click on a
/// 300 MB photograph stop ⌥F5 and a checksum run from confirming up to 600 MB.
public struct RemotePreviewAllowance: Sendable, Equatable {
    /// How much larger than the largest file somebody agreed to a preview may fetch unasked.
    ///
    /// Twice rather than a fifth more, measured against the folder that reported the gap: its RAW
    /// files were 22.9, 23.1, 28.5 and 36.1 MB. After agreeing to the 23.1 MB one, +20 % gives
    /// 27.7 MB, so the 28.5 MB NEF (0.8 MB over) and the 36.1 MB RW2 each still needed a click;
    /// twice gives 46.2 MB and the folder needs one. Headroom is cheap because leaving the row stops
    /// the transfer. A policy number rather than a measurement, and the part expected to move.
    public static let headroomFactor: Int64 = 2

    private var ceilings: [VFSBackendID: Int64] = [:]

    public init() {}

    /// Whether nobody has agreed to anything on any connection.
    public var isEmpty: Bool { ceilings.isEmpty }

    /// The size up to which a preview on `backend` may fetch unasked on this allowance's say-so —
    /// zero where nobody has agreed to anything, which leaves the Settings limit in charge.
    public func ceiling(for backend: VFSBackendID) -> Int64 {
        ceilings[backend] ?? 0
    }

    /// Record that the user agreed to fetch `byteSize` bytes for a preview on `backend`, given the
    /// Settings limit that was in force.
    ///
    /// A negative size is "the server did not say", and agrees to nothing: an unknown size is
    /// exactly when a fetch is worth asking about, and no ceiling can be derived from it.
    public mutating func recordAgreement(
        toFetch byteSize: Int64,
        on backend: VFSBackendID,
        previewLimit: Int64
    ) {
        let limit = RemoteFetchPolicy.clampedPreviewLimit(previewLimit)
        guard limit > 0, byteSize > limit else { return }
        // Saturating rather than wrapping: a size near `Int64.max` is nonsense from a server, and a
        // wrapped ceiling would be negative — i.e. silently no allowance at all.
        let (doubled, overflowed) = byteSize.multipliedReportingOverflow(by: Self.headroomFactor)
        let ceiling = overflowed ? Int64.max : doubled
        ceilings[backend] = max(ceilings[backend] ?? 0, ceiling)
    }

    /// Record that the user stopped a preview download of `byteSize` bytes on `backend`.
    ///
    /// Withdraws that connection's allowance when the file was larger than the Settings limit —
    /// i.e. when an agreement, rather than the limit, is what let it through. Stopping a file the
    /// limit covers says nothing about the allowance and leaves it alone.
    public mutating func recordStop(
        ofByteSize byteSize: Int64,
        on backend: VFSBackendID,
        previewLimit: Int64
    ) {
        guard byteSize > RemoteFetchPolicy.clampedPreviewLimit(previewLimit) else { return }
        ceilings[backend] = nil
    }

    /// Forget every connection's allowance — what a change to the Settings limit does, since the
    /// user's explicit statement supersedes anything inferred before it.
    public mutating func removeAll() {
        ceilings.removeAll()
    }
}
