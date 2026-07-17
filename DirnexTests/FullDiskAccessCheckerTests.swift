import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app-does-I/O half of the Full Disk Access check (PLAN.md §M7). The verdict logic and the
/// error-code classification are `DirnexCore.FullDiskAccess`'s and are pinned there; what is left
/// here is the real filesystem probe — that `FullDiskAccessChecker` reads a file, lists a
/// directory, and tells "absent" apart from "denied" against an actual home layout. Each test builds
/// a throwaway home directory with the sentinel paths under it, so nothing depends on the machine's
/// real Full Disk Access state.
@Suite("FullDiskAccessChecker")
struct FullDiskAccessCheckerTests {
    /// The core's primary sentinel, recreated inside a temp home so a readable copy stands in for a
    /// readable TCC.db (grant present) without needing the real, protected one.
    private static let primarySentinel = FullDiskAccess.sentinelPaths[0]

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-fda-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeSentinel(_ relative: String, bytes: Data, under home: URL) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url)
    }

    @Test("a readable sentinel file reports the grant is in place")
    func readableSentinelIsGranted() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSentinel(Self.primarySentinel, bytes: Data([0x42]), under: home)

        #expect(FullDiskAccessChecker.status(inHomeDirectory: home) == .granted)
    }

    @Test("a home with none of the sentinels present is unknown, never denied")
    func absentSentinelsAreUnknown() throws {
        // The very case that pushes the app to `.unknown` rather than a guessed denial: nothing to
        // read, so nothing to conclude. A brand-new temp home has no Library at all.
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(FullDiskAccessChecker.status(inHomeDirectory: home) == .unknown)
    }

    @Test("an unreadable sentinel file reports the grant is missing")
    func unreadableSentinelIsDenied() throws {
        // Running as root ignores permission bits, so a 000 file stays readable and the probe would
        // (correctly, for root) read `.granted` — skip there rather than assert a false negative.
        try #require(getuid() != 0, "permission bits don't apply to root")

        let home = try makeTempHome()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: home.appendingPathComponent(Self.primarySentinel).path
            )
            try? FileManager.default.removeItem(at: home)
        }
        try writeSentinel(Self.primarySentinel, bytes: Data([0x42]), under: home)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: home.appendingPathComponent(Self.primarySentinel).path
        )

        #expect(FullDiskAccessChecker.status(inHomeDirectory: home) == .denied)
    }
}
