import Foundation

/// What a backend gets for free — the requirements of ``VFSBackend`` that have a sensible answer for
/// a backend that has never heard of them.
///
/// Split from the protocol declaration when that file crossed SwiftLint's 500-line ceiling, along
/// the seam the two halves already had: there, what a backend *must* answer; here, what it need not.
/// Every default in this file is one of two kinds and the distinction is load-bearing — a
/// **forwarding** default, safe only where the two spellings produce the identical result (a backend
/// that ignores a size hint is slower, never wrong), and a **refusing** one, where the honest answer
/// is that this backend cannot and the caller must be told rather than served something plausible.
/// Getting that backwards is how a capability silently becomes a claim (PLAN.md §M25).
public extension VFSBackend {
    func capabilities(for path: VFSPath) -> VFSCapabilities {
        capabilities // a single-backend implementation is uniform across all its paths
    }

    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        nil // no shortcut here — the caller walks
    }

    func createDirectory(at path: VFSPath) throws {
        throw VFSError.unsupported(.createDirectory)
    }

    func createFile(at path: VFSPath) throws {
        throw VFSError.unsupported(.createFile)
    }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.unsupported(.moveItem)
    }

    func removeItem(at path: VFSPath) throws {
        throw VFSError.unsupported(.removeItem)
    }

    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath? {
        throw VFSError.unsupported(.trash)
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        false // no copy-on-write here — the engine falls back to a chunked copy
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        throw VFSError.unsupported(.copyFile)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        // The hint is an optimization, so a backend that has no use for it copies exactly as before.
        try copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        hint: CopySourceHint,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        // Dropping the metadata half *is* the old behaviour: a backend that cannot carry it copies
        // the bytes and nothing else, exactly as it always did.
        try copyFile(
            at: source,
            to: destination,
            expectedSize: hint.expectedSize,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        throw VFSError.unsupported(.symbolicLink)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        // Backends without metadata to preserve need do nothing.
    }

    func copyMetadata(
        at source: VFSPath,
        to destination: VFSPath,
        sourceMetadata _: RemoteSourceMetadata?
    ) throws {
        // Ignoring the hint is the old behaviour, and it is honest: a backend that does not use it
        // is one that was not carrying metadata in the first place.
        try copyMetadata(at: source, to: destination)
    }

    func mayAttemptInternalCopy(from _: VFSPath, to _: VFSPath) -> Bool {
        false // no verb to try, so nothing to be refused
    }

    func metadataTally(at _: VFSPath) -> RemoteMetadataTally {
        .zero // nothing here crosses a wire, so nothing can be dropped on the way
    }

    func editableMetadata(at _: VFSPath) -> RemoteMetadataCapabilities {
        [] // no write verbs, so the panel over this backend's rows stays read-only
    }

    func applyMetadata(
        _: [RemoteMetadataStep],
        at path: VFSPath
    ) throws -> [RemoteMetadataRefusal] {
        throw VFSError.unsupported(.attributeChangeNeedsConnection(name: path.lastComponent))
    }

    @discardableResult
    func writeBack(
        localPath: String,
        to destination: VFSPath,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Bool {
        // A condition this backend cannot carry is refused, never quietly dropped: the caller has
        // been told its write is guarded, and an unguarded write under that promise is the one
        // outcome worse than not offering the feature (see the requirement's doc).
        guard !condition.isConditional else {
            throw S3WriteConditionUnsupported(key: destination.path)
        }
        try copyFile(
            at: .local(localPath),
            to: destination,
            progress: progress,
            isCancelled: isCancelled
        )
        return false
    }

    func resolvingSymlinkTargets(in entries: [FileEntry]) -> [FileEntry] {
        entries // this backend's listing already said whatever it knows
    }

    func volumeIdentifier(for path: VFSPath) -> String? {
        nil // "one indistinguishable volume" — the queue serializes such a backend's jobs
    }
}
