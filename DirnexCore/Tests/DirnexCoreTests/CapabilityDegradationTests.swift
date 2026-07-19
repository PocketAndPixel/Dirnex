import Foundation
import Testing

@testable import DirnexCore

/// "Capability degradation" (PLAN.md §M5): a panel drives what it offers off the *owning*
/// backend's capabilities rather than assuming a full-featured local disk. Two pieces are
/// tested here — the pure `deleteStrategy` decision (Trash vs. confirmed permanent vs.
/// nothing) and the per-path `capabilities(for:)` hook that lets `CopyEngine` skip a doomed
/// clone attempt on a backend without copy-on-write. The SFTP backend that will actually
/// exercise a writable-but-Trash-less location lands later; a `PartialCapabilityBackend`
/// double stands in so the degradation is proven now.
@Suite("Capability degradation")
struct CapabilityDegradationTests {
    // MARK: - deleteStrategy

    @Test("a Trash-capable backend deletes to the Trash")
    func trashBackendUsesTrash() {
        let caps: VFSCapabilities = [.read, .write, .trash, .clone, .rename, .watch]
        #expect(caps.deleteStrategy == .trash)
    }

    @Test("a writable Trash-less backend falls back to a permanent delete")
    func writableTrashlessBackendDeletesPermanently() {
        // The SFTP shape: it can remove files but has no Trash, so F8 must become a
        // confirmed permanent delete rather than silently failing.
        let caps: VFSCapabilities = [.read, .write]
        #expect(caps.deleteStrategy == .permanent)
    }

    @Test("a read-only backend can't delete at all")
    func readOnlyBackendCannotDelete() {
        #expect(VFSCapabilities.read.deleteStrategy == .unsupported)
        // Trash without write is meaningless — still nothing to delete.
        #expect(VFSCapabilities([.read, .trash]).deleteStrategy == .unsupported)
    }

    // MARK: - capabilities(for:)

    @Test("the default capabilities(for:) reports the backend-wide capabilities")
    func defaultPerPathCapabilitiesMatchWide() {
        let backend = LocalBackend()
        #expect(backend.capabilities(for: .local("/tmp")) == backend.capabilities)
    }

    @Test("a routing backend reports capabilities per owning path")
    func routingBackendDegradesPerPath() {
        let router = RoutingStub()
        // A local path keeps the full local capability set…
        #expect(router.capabilities(for: .local("/x")).contains(.clone))
        #expect(router.capabilities(for: .local("/x")).deleteStrategy == .trash)
        // …while a virtual path degrades to read-only.
        let virtual = VFSPath(backend: VFSBackendID("virtual"), path: "/y")
        #expect(router.capabilities(for: virtual) == .read)
        #expect(router.capabilities(for: virtual).deleteStrategy == .unsupported)
    }

    // MARK: - CopyEngine honours the per-path clone capability

    @Test("CopyEngine skips the clone attempt on a backend without .clone")
    func copyEngineSkipsCloneWhenUnsupported() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "payload")
        try tree.makeDir("dest")

        let clones = CallFlag()
        let backend = PartialCapabilityBackend(
            capabilities: [.read, .write], // no .clone — a chunked-only backend
            cloneFlag: clones
        )
        let op = FileOperation(
            kind: .copy,
            sources: [try backend.stat(at: tree.vfsPath("a.txt"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(report.succeeded)
        #expect(clones.calls == 0) // never even asked to clone
        #expect(
            try String(contentsOfFile: tree.path("dest/a.txt"), encoding: .utf8) == "payload"
        )
    }

    @Test("CopyEngine still attempts a clone when the backend advertises .clone")
    func copyEngineAttemptsCloneWhenSupported() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("b.txt", contents: "payload")
        try tree.makeDir("dest")

        let clones = CallFlag()
        let backend = PartialCapabilityBackend(
            capabilities: [.read, .write, .clone], // opts back into cloning
            cloneFlag: clones
        )
        let op = FileOperation(
            kind: .copy,
            sources: [try backend.stat(at: tree.vfsPath("b.txt"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(report.succeeded)
        #expect(clones.calls == 1) // the guard let it through
    }
}

/// Records how many times a decorator's `cloneItem` was invoked, across the value-type copies
/// `CopyEngine` makes of the backend struct.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    func bump() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }
}

/// A `LocalBackend` decorator whose advertised `capabilities` (and thus `capabilities(for:)`)
/// are configurable, and which records every `cloneItem` call — the seam that proves
/// `CopyEngine` consults the capability before attempting a clone. Everything else forwards to
/// a real `LocalBackend` so the copy actually happens on disk.
private struct PartialCapabilityBackend: VFSBackend {
    private let inner = LocalBackend()
    let capabilities: VFSCapabilities
    let cloneFlag: CallFlag

    var id: VFSBackendID { inner.id }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try inner.moveItem(at: source, to: destination)
    }

    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        cloneFlag.bump()
        return try inner.cloneItem(at: source, to: destination)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }

    func volumeIdentifier(for path: VFSPath) -> String? { inner.volumeIdentifier(for: path) }
}

/// A minimal routing backend that mirrors the app's `CompositeBackend` degradation rule —
/// local paths keep the full local capability set, everything else is read-only — so the
/// per-path `capabilities(for:)` contract is tested in core without importing the app target.
private struct RoutingStub: VFSBackend {
    private let local = LocalBackend()

    var id: VFSBackendID { local.id }
    var capabilities: VFSCapabilities { local.capabilities }

    func capabilities(for path: VFSPath) -> VFSCapabilities {
        path.backend == .local ? local.capabilities : .read
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try local.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try local.stat(at: path) }
}
