import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// That the shipped transport is actually wired to the routes the backend offers it.
///
/// **The class of bug this exists for is a seam whose good answer is also its default**, which this
/// project has now paid for twice — `subtreeListing` inheriting "walk instead" because
/// `CompositeBackend` never forwarded it, and `metadataTally` inheriting `.zero` so every job looked
/// lossless (docs/NOTES.md ▸ Design lessons). Both were invisible: every test passed, nothing logged,
/// and the only symptom was a bill or a wait.
///
/// A segmented upload has exactly that shape. The protocol's default sends the parts **one at a
/// time** and reports progress per part just as the concurrent implementation does — so a build that
/// lost `SFTPProcessTransport+SegmentedUpload.swift` would keep every other assertion in this repo
/// green, including the live suite's, while uploading over one connection at a time and paying for
/// the slices, the scratch and the join anyway. Nothing but this can see it.
@Suite("SFTPProcessTransport wiring")
struct SFTPProcessTransportWiringTests {
    private static let transport = SFTPProcessTransport(
        location: SFTPLocation(host: "ssh.example", username: "u"),
        authentication: .key(identityFile: "/dev/null")
    )

    @Test("the shipped transport declares that it sends an upload's parts at once")
    func partsGoAtOnce() {
        // Needs no server: what is asserted is the declaration the backend's fork reads, which is a
        // fact about this build.
        #expect(Self.transport.sendsPartsConcurrently)
    }

    @Test("the protocol's default declares the opposite, so the route is withheld by construction")
    func theDefaultWithholdsTheRoute() {
        // The other half, and the reason the assertion above is not vacuous: `false` is what a
        // transport that has not implemented the concurrent send answers, and the backend refuses to
        // split for it. Without this the test above could be reading a constant nobody consults.
        #expect(!MinimalTransport().sendsPartsConcurrently)
    }
}

/// A transport that implements nothing beyond the protocol's requirements, so every default is what
/// answers. It cannot be `SFTPProcessTransport` — that one implements the verb, which is exactly
/// what has to be absent here.
private struct MinimalTransport: SFTPTransport {
    func listDirectory(_: String) throws -> String { "" }
    func createSymbolicLink(_: String, target _: String) throws {}
    func makeDirectory(_: String) throws {}
    func createEmptyFile(_: String) throws {}
    func rename(_: String, to _: String) throws {}
    func removeFile(_: String) throws {}
    func removeDirectory(_: String) throws {}
    func download(
        _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }
    func upload(
        _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }
}
