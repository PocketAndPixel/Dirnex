import Foundation
import Testing

@testable import DirnexCore

/// Putting an item back out of a network share's `#recycle` bin (PLAN.md §M8 restore, 2026-09-20).
///
/// Every expectation here is taken from a live Synology DSM share mounted over SMB rather than from
/// the documentation, because the mirroring rule is the whole feature: deleting
/// `probe/sub/nested.txt` from the share root left it at `#recycle/probe/sub/nested.txt`, and the
/// bin's own two originals (`DSCF8564.JPG`, `desktop.ini`) sat at its top level because they had
/// been deleted from the root.
@Suite("Share recycle bin")
struct ShareRecycleBinTests {
    private let share = "/Volumes/home"

    private func item(_ relative: String) -> VFSPath {
        VFSPath.local("\(share)/#recycle/\(relative)")
    }

    // MARK: - Where an item goes back to

    /// The measured case, and the one the whole gesture rests on.
    @Test("a nested item goes back to the path the bin mirrors")
    func nestedItemRestoresToMirroredPath() throws {
        let origin = try #require(ShareRecycleBin.origin(of: item("probe/sub/nested.txt")))
        #expect(origin.directory == VFSPath.local("/Volumes/home/probe/sub"))
        #expect(origin.name == "nested.txt")
        #expect(origin.destination == VFSPath.local("/Volumes/home/probe/sub/nested.txt"))
    }

    @Test("an item at the bin's top level goes back to the share root")
    func topLevelItemRestoresToShareRoot() throws {
        let origin = try #require(ShareRecycleBin.origin(of: item("DSCF8564.JPG")))
        #expect(origin.destination == VFSPath.local("/Volumes/home/DSCF8564.JPG"))
    }

    /// **Relative to the bin's parent, never to the volume.** DSM keeps one bin per shared folder,
    /// so mounting `homes` rather than `home` puts the bin a level down — and a rule anchored on the
    /// volume root would restore this into `/Volumes/homes/reports` instead.
    @Test("a bin below the volume root restores relative to its own parent")
    func binBelowVolumeRootRestoresRelativeToItsParent() throws {
        let deep = VFSPath.local("/Volumes/homes/dirnex-test/#recycle/reports/q3.pdf")
        let origin = try #require(ShareRecycleBin.origin(of: deep))
        #expect(origin.destination == VFSPath.local("/Volumes/homes/dirnex-test/reports/q3.pdf"))
    }

    /// The first bin wins: a deleted folder that was itself called `#recycle` lands at
    /// `#recycle/#recycle`, and taking the *last* occurrence would restore it into the bin it is
    /// already sitting in — a move that either fails or does nothing, and reports success.
    @Test("a deleted folder named #recycle goes back beside the bin, not into it")
    func selfNamedFolderRestoresOutOfTheBin() throws {
        let origin = try #require(ShareRecycleBin.origin(of: item("#recycle")))
        #expect(origin.destination == VFSPath.local("/Volumes/home/#recycle"))
        #expect(origin.directory == VFSPath.local("/Volumes/home"))
    }

    @Test("the backend travels with the path, so a bin reached over SFTP restores on that server")
    func originKeepsThePathsBackend() throws {
        let remote = VFSPath(backend: VFSBackendID("sftp://nas"), path: "/home/#recycle/a/b.txt")
        let origin = try #require(ShareRecycleBin.origin(of: remote))
        #expect(origin.destination.backend == VFSBackendID("sftp://nas"))
        #expect(origin.destination.path == "/home/a/b.txt")
    }

    // MARK: - The bin that governs a share

    /// Where a delete on this share would land, which is the question the delete confirmation asks
    /// before it promises anything about permanence.
    @Test("a share's own bin sits at its root")
    func shareBinSitsAtTheRoot() {
        #expect(ShareRecycleBin.bin(atShareRoot: VFSPath.local(share))
            == VFSPath.local("/Volumes/home/#recycle"))
    }

    // MARK: - The bin an item sits in

    /// What a restore prunes back up to. It stops at the bin: sweeping further would start
    /// removing the share's own folders.
    @Test("a nested item names the bin holding it")
    func nestedItemNamesItsBin() {
        #expect(ShareRecycleBin.binRoot(of: item("probe/sub/nested.txt"))
            == VFSPath.local("/Volumes/home/#recycle"))
    }

    @Test("the bin itself names no bin, so nothing is pruned above it")
    func theBinNamesNoBin() {
        #expect(ShareRecycleBin.binRoot(of: VFSPath.local("\(share)/#recycle")) == nil)
        #expect(ShareRecycleBin.binRoot(of: VFSPath.local("\(share)/a.txt")) == nil)
    }

    // MARK: - What is not an item in a bin

    /// The narrowness control for the gate. Without it, "inside a bin" would include the bin, and
    /// Put Back would offer to move the share's own recycle folder out of the share.
    @Test("the bin directory itself is not something to put back")
    func theBinItselfHasNoOrigin() {
        #expect(ShareRecycleBin.origin(of: VFSPath.local("\(share)/#recycle")) == nil)
        #expect(ShareRecycleBin.holds(VFSPath.local("\(share)/#recycle")) == false)
    }

    @Test("an ordinary path is untouched")
    func ordinaryPathHasNoOrigin() {
        #expect(ShareRecycleBin.origin(of: VFSPath.local("\(share)/DSCF8566.JPG")) == nil)
        #expect(ShareRecycleBin.holds(VFSPath.local("/Users/oleg/Documents/a.txt")) == false)
    }

    /// A name that merely *contains* the bin's name is a different folder, and a prefix test would
    /// sweep it in — `#recycled/` is an ordinary directory somebody is allowed to have.
    @Test("a component that only resembles the bin's name is not a bin")
    func similarlyNamedComponentIsNotABin() {
        #expect(ShareRecycleBin.holds(VFSPath.local("\(share)/#recycled/a.txt")) == false)
        #expect(ShareRecycleBin.holds(VFSPath.local("\(share)/my#recycle/a.txt")) == false)
    }

    @Test("a bin at the filesystem root still resolves")
    func binAtRootResolves() throws {
        let origin = try #require(ShareRecycleBin.origin(of: VFSPath.local("/#recycle/a.txt")))
        #expect(origin.destination == VFSPath.local("/a.txt"))
    }
}
