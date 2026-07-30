import Foundation
import Testing

@testable import DirnexCore

/// The subject resolver, checked against the OS's *own* answer rather than against itself: an ACL is
/// written for the current user through `chmod`, and the GUID `acl_to_text` resolves for that entry
/// must equal what ``ACLIdentity`` computes from the same uid. If the `dlsym`'d `mbr_*` symbol ever
/// moves, this fails loudly instead of silently pinning the wrong identity.
@Suite("ACLIdentity")
struct ACLIdentityTests {
    @Test("a resolved uid GUID is a well-formed, uppercase UUID")
    func wellFormed() throws {
        let guid = try #require(ACLIdentity.guid(forUserID: getuid()))
        #expect(guid.count == 36)
        #expect(guid == guid.uppercased())
        #expect(try #require(UUID(uuidString: guid)) == UUID(uuidString: guid))
    }

    @Test("both a uid and a gid resolve")
    func bothResolve() {
        #expect(ACLIdentity.guid(forUserID: getuid()) != nil)
        #expect(ACLIdentity.guid(forGroupID: getgid()) != nil)
    }

    /// The independent judge: the GUID the OS itself put in the ACL text must match ours.
    @Test("the resolved GUID matches what the OS writes into an ACL")
    func matchesOSResolution() throws {
        let tree = try TempTree(); defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))

        // Have the OS author an entry for the current user, then read the GUID it chose.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "\(NSUserName()) allow read", path.path]
        try chmod.run()
        chmod.waitUntilExit()

        let osGUID = try #require(try AccessControlListIO.read(at: path).entries.first?.subject.guid)
        #expect(ACLIdentity.guid(forUserID: getuid()) == osGUID)
    }
}
