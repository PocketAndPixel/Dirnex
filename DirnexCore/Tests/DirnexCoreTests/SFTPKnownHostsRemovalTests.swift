import Testing

@testable import DirnexCore

/// Which `known_hosts` entry a changed-key repair removes. It has to be the name OpenSSH refused on,
/// which a connection dialed through the Bonjour fallback does not share with its location: a server
/// saved as `nas` is contacted as `nas.local`, so removing `nas` removed nothing and the trust dialog
/// came back every time it was accepted.
@Suite("SFTPKnownHosts removal target for a changed-key refusal")
struct SFTPKnownHostsRemovalTests {
    /// The refusal a server saved as `nas` produced after a reinstall, captured from a real Synology
    /// NAS on 2026-09-14 (OpenSSH 10.3). The connection dials the Bonjour fallback, so the stale pin
    /// OpenSSH refused on belongs to `nas.local` — a name the user never typed.
    private static let fallbackRefusal = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
    Someone could be eavesdropping on you right now (man-in-the-middle attack)!
    It is also possible that a host key has just been changed.
    The fingerprint for the ED25519 key sent by the remote host is
    SHA256:r7SfFljymcCOod2otuc0Y54h9+jlF49uoFgpCjv6lNo.
    Please contact your system administrator.
    Add correct host key in /Users/oleg/.ssh/known_hosts to get rid of this message.
    Offending ED25519 key in /Users/oleg/.ssh/known_hosts:73
    Host key for nas.local has changed and you have requested strict checking.
    Host key verification failed.
    """

    /// The same refusal on a non-default port, captured from a throwaway `sshd` on 2224 dialed as
    /// `LocalHost`: OpenSSH names the host lowercased and bracketed, the form `known_hosts` keys on.
    private static let bracketedRefusal = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
    Someone could be eavesdropping on you right now (man-in-the-middle attack)!
    It is also possible that a host key has just been changed.
    The fingerprint for the ED25519 key sent by the remote host is
    SHA256:X8eyAWgHhPMDMUZAJ3bFsfD+k3xSGhRzpWbyqUnSKzg.
    Please contact your system administrator.
    Add correct host key in /tmp/kh to get rid of this message.
    Offending ED25519 key in /tmp/kh:1
    Host key for [localhost]:2224 has changed and you have requested strict checking.
    Host key verification failed.
    """

    private static func change(host: String) -> SFTPHostKeyChange {
        SFTPHostKeyChange(host: host, keyType: "", fingerprint: "", knownHostsFile: "", line: 0)
    }

    @Test(
        "a refusal on a Bonjour-completed name removes the pin OpenSSH refused on, not the typed one"
    )
    func followsTheDialedName() throws {
        let change = try #require(SFTPHostKeyChange.parse(stderr: Self.fallbackRefusal))
        #expect(change.host == "nas.local")
        #expect(SFTPKnownHosts.removalTarget(for: change, host: "nas", port: 22) == "nas.local")
    }

    @Test("a non-default port's bracketed name is used as OpenSSH wrote it, whatever case was typed")
    func keepsThePortForm() throws {
        let change = try #require(SFTPHostKeyChange.parse(stderr: Self.bracketedRefusal))
        let target = SFTPKnownHosts.removalTarget(for: change, host: "LocalHost", port: 2224)
        #expect(target == "[localhost]:2224")
    }

    @Test("a name this connection could not have dialed never becomes the removal target")
    func refusesAForeignName() throws {
        let change = try #require(SFTPHostKeyChange.parse(stderr: Self.fallbackRefusal))
        // Another server's name, and the same name on a port OpenSSH did not refuse on.
        #expect(SFTPKnownHosts.removalTarget(for: change, host: "backup", port: 22) == "backup")
        #expect(SFTPKnownHosts.removalTarget(for: change, host: "nas", port: 2222) == "[nas]:2222")
        // A refusal that named nothing keeps the typed target.
        let unnamed = Self.change(host: "")
        #expect(SFTPKnownHosts.removalTarget(for: unnamed, host: "nas", port: 22) == "nas")
    }

    @Test("a refusal on the address exactly as typed removes that address, as it always did")
    func typedAddressIsUnchanged() {
        let typed = Self.change(host: "192.168.1.50")
        let target = SFTPKnownHosts.removalTarget(for: typed, host: "192.168.1.50", port: 22)
        #expect(target == "192.168.1.50")
    }
}
