import Foundation
import Testing

@testable import DirnexCore

/// Writing and reading a real ACL, with the OS as the independent judge — the exit criterion is that
/// an ACL authored in Dirnex reads back **in the order Dirnex showed**, under both `acl_get_file` and
/// `ls -le`. These run as the current user, so they use that user's own GUID (resolved through
/// ``ACLIdentity``), the one identity an owner can always write entries for unprivileged.
@Suite("AccessControlListIO")
struct AccessControlListIOTests {
    private func meSubject() throws -> ACLSubject {
        let uid = getuid()
        let guid = try #require(ACLIdentity.guid(forUserID: uid))
        return ACLSubject(kind: .user, guid: guid, name: NSUserName(), numericID: uid)
    }

    /// A deny placed *before* an allow — the order that is the whole point.
    private func denyThenAllow(_ subject: ACLSubject) -> AccessControlList {
        AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.write]),
            ACLEntry(subject: subject, disposition: .allow, rights: [.read, .write])
        ])
    }

    @Test("an ACL written by Dirnex reads back with entry order preserved")
    func writeReadRoundTrip() throws {
        let tree = try TempTree(); defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        let written = denyThenAllow(try meSubject())

        try AccessControlListIO.write(written, to: path)
        let readBack = try AccessControlListIO.read(at: path)

        #expect(readBack.entries.count == 2)
        #expect(readBack.entries[0].disposition == .deny)
        #expect(readBack.entries[0].rights == [.write])
        #expect(readBack.entries[1].disposition == .allow)
        #expect(readBack.entries[1].rights == [.read, .write])
    }

    /// `ls -le` is the second, independent judge that the kernel stored the entries in the order
    /// Dirnex wrote them — deny on line 0, allow on line 1.
    @Test("ls -le shows the entries in the order Dirnex wrote them")
    func lsAgreesOnOrder() throws {
        let tree = try TempTree(); defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        try AccessControlListIO.write(denyThenAllow(try meSubject()), to: path)

        let listing = try runLS(path.path)
        let entryLines = listing.split(whereSeparator: \.isNewline).filter { $0.contains(": ") }
        #expect(entryLines.count >= 2)
        #expect(entryLines[0].contains("deny"))
        #expect(entryLines[1].contains("allow"))
    }

    @Test("a file with no ACL reads back as an empty list")
    func noACLIsEmpty() throws {
        let tree = try TempTree(); defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        #expect(try AccessControlListIO.read(at: path).isEmpty)
    }

    @Test("writing an empty list removes the ACL")
    func writingEmptyRemoves() throws {
        let tree = try TempTree(); defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        try AccessControlListIO.write(denyThenAllow(try meSubject()), to: path)
        #expect(!(try AccessControlListIO.read(at: path).isEmpty))

        try AccessControlListIO.write(AccessControlList(), to: path)
        #expect(try AccessControlListIO.read(at: path).isEmpty)
    }

    // MARK: - Helper

    private func runLS(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-le", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
