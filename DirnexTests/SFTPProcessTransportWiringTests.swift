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

    @Test("a key-auth child is armed with the locale, which is the path that used to inherit none")
    func keyAuthChildrenCarryTheLocale() throws {
        // Reported 2026-09-08 as an upload renaming files: `DSC_0697-Панорама.jpg` listed back as
        // `DSC_0697-\320\237…`, and every verb built from that name then answered "not found" for a
        // row in front of the user. The cause is this environment. Key auth used to leave it nil and
        // inherit the app's own — and a LaunchServices-launched app has no locale at all, so `sftp`
        // ran under `C` and octal-escaped every non-ASCII byte (``SFTPChildEnvironment``).
        //
        // Needs no server: what is asserted is that the funnel every spawn site goes through applies
        // the rule. The rule's own edges are pinned in the core's `SFTPChildEnvironment` suite.
        let environment = try Self.transport.childEnvironment()
        #expect(environment["LC_CTYPE"] == "UTF-8")
        #expect(environment["LC_TIME"] == "C")
        #expect(environment["LC_ALL"] == nil)
    }

    @Test("and it amends the parent environment rather than replacing it")
    func theChildKeepsWhatItInherits() throws {
        // `ssh` finds `known_hosts` through `HOME`, and the password path layers `SSH_ASKPASS` onto
        // this same dictionary — so a pin that built a fresh environment would take the host-key
        // trust record and the password wiring with it, which is a much louder failure than the one
        // being fixed and would land on a different path.
        let environment = try Self.transport.childEnvironment()
        #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
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
