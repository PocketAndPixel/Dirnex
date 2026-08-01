import Foundation
import Testing

@testable import DirnexCore

/// Propagating a **directory's** access-control list onto the files inside it (PLAN.md §M14 Slice 4).
///
/// The rule exists because the kernel does not enforce it and fails in the quiet direction. Probed
/// 2026-08-01 against real files: `acl_set_file` accepts a directory's canonical text on a regular
/// file, returns `0`, and `acl_get_file` reads it back **verbatim** — `delete_child` and the
/// inheritance flags still stored — while `ls -le` shows only the four data rights. So propagating
/// unchanged would put directory-only bits on a file's rights matrix in Dirnex's own Sharing tab,
/// which is the one surface whose whole job is that answer.
@Suite("AccessControlList kind adjustment")
struct AccessControlListKindTests {
    /// The exact text `acl_to_text` produced for a directory carrying
    /// `list,search,add_file,add_subdirectory,delete_child,file_inherit,directory_inherit` —
    /// captured from the live probe, not written by hand.
    private static let directoryACL = """
    !#acl 1
    group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow,file_inherit,directory_inherit:\
    read,write,execute,append,delete_child
    """

    private func parsed(_ text: String) throws -> AccessControlList {
        try AccessControlList.parse(text)
    }

    @Test("A directory keeps its list exactly, bit for bit")
    func directoryIsUntouched() throws {
        let list = try parsed(Self.directoryACL)
        #expect(list.adjusted(for: .directory) == list)
    }

    @Test("A file loses delete_child and the inheritance controls, and keeps everything else")
    func fileStripsDirectoryOnlyBits() throws {
        let adjusted = try parsed(Self.directoryACL).adjusted(for: .file)
        let entry = try #require(adjusted.entries.first)

        #expect(!entry.rights.contains(.deleteChild))
        #expect(entry.rights == [.read, .write, .execute, .append])
        #expect(entry.inheritance.isDisjoint(with: ACLInheritance.directoryOnly))
        #expect(entry.subject.name == "everyone", "the subject is untouched")
        #expect(entry.disposition == .allow)
    }

    @Test("A symlink is adjusted like a file — its own ACL, not its target's")
    func symlinkIsAdjustedLikeAFile() throws {
        let list = try parsed(Self.directoryACL)
        #expect(list.adjusted(for: .symlink) == list.adjusted(for: .file))
    }

    /// The `inherited` marker records where an entry came from; it is not one of the four controls,
    /// and a file can legitimately carry one.
    @Test("The inherited marker survives the adjustment")
    func inheritedMarkerSurvives() throws {
        let text = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow,file_inherit,inherited:read
        """
        let entry = try #require(try parsed(text).adjusted(for: .file).entries.first)
        #expect(entry.isInherited)
        #expect(!entry.inheritance.contains(.fileInherit))
    }

    /// `chmod +a "everyone allow delete_child" f` on a file exits 0 and leaves
    /// `0: group:everyone allow` — an entry occupying a position in the evaluation order and
    /// deciding nothing. The editor refuses to create one, so the recursion must not create one
    /// through the back door.
    @Test("An entry reduced to nothing is dropped, not written as a do-nothing entry")
    func emptiedEntryIsDropped() throws {
        let text = """
        !#acl 1
        user:FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5:oleg:501:allow:delete_child
        user:FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5:oleg:501:allow:read
        """
        let adjusted = try parsed(text).adjusted(for: .file)

        #expect(adjusted.entries.count == 1, "only the entry that still means something survives")
        #expect(adjusted.entries.first?.rights == [.read])
    }

    @Test(
        "An entry whose only rights are unknown tokens survives, since they may not be ours to drop"
    )
    func unknownRightsKeepAnEntryAlive() throws {
        let text = """
        !#acl 1
        user:FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5:oleg:501:allow:delete_child,future_right
        """
        let adjusted = try parsed(text).adjusted(for: .file)

        #expect(adjusted.entries.count == 1)
        #expect(adjusted.entries.first?.unrecognizedRights == ["future_right"])
    }

    @Test("An empty list adjusts to an empty list")
    func emptyStaysEmpty() {
        #expect(AccessControlList().adjusted(for: .file).isEmpty)
    }

    /// The adjustment is what the platform's own front end does, so the proof is the OS: write the
    /// adjusted list to a real file and have `acl_to_text` read back exactly what was written.
    @Test("What the adjustment writes is what the OS reads back")
    func roundTripsThroughTheKernel() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("f.txt", contents: "x")
        let path = tree.vfsPath("f.txt")

        let adjusted = try parsed(Self.directoryACL).adjusted(for: .file)
        try AccessControlListIO.write(adjusted, to: path)

        let readBack = try AccessControlListIO.read(at: path)
        #expect(readBack == adjusted)
        #expect(readBack.entries.first?.rights == [.read, .write, .execute, .append])
        #expect(readBack.entries.first?.inheritance == [])
    }

    /// The negative control: hand the kernel the *unadjusted* directory text and it stores it whole.
    /// Without this, an adjustment that stopped being needed would leave the rule vestigial and
    /// every test above still green.
    @Test("Unadjusted, the kernel stores a directory's bits on a file and hands them straight back")
    func kernelDoesNotStripOnItsOwn() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("g.txt", contents: "x")
        let path = tree.vfsPath("g.txt")

        let unadjusted = try parsed(Self.directoryACL)
        try AccessControlListIO.write(unadjusted, to: path)

        let readBack = try AccessControlListIO.read(at: path)
        let entry = try #require(readBack.entries.first)
        #expect(entry.rights.contains(.deleteChild), "the kernel kept a directory-only right")
        #expect(entry.inheritance.contains(.fileInherit), "and a directory-only flag")
    }
}
