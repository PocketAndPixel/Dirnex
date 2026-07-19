import Foundation
import Testing

@testable import DirnexCore

@Suite("SFTPLocation")
struct SFTPLocationTests {
    @Test("descriptor encodes user, host, and port")
    func descriptorFormat() {
        let location = SFTPLocation(host: "example.com", port: 2222, username: "oleg")
        #expect(location.descriptor == "sftp://oleg@example.com:2222")
    }

    @Test("default port is 22 and still appears in the descriptor")
    func defaultPort() {
        let location = SFTPLocation(host: "host", username: "me")
        #expect(location.port == 22)
        #expect(location.descriptor == "sftp://me@host:22")
    }

    @Test("descriptor round-trips through a decode")
    func descriptorRoundTrip() {
        let original = SFTPLocation(host: "10.0.0.5", port: 22, username: "root")
        let decoded = SFTPLocation(descriptor: original.descriptor)
        #expect(decoded == original)
    }

    @Test("a backend id round-trips a location")
    func backendIDRoundTrip() {
        let original = SFTPLocation(host: "nas.local", port: 22, username: "admin")
        let id = VFSBackendID.sftp(original)
        #expect(id.isSFTP)
        #expect(id.sftpLocation == original)
    }

    @Test("a non-SFTP id yields no location and reports isSFTP false")
    func nonSFTPBackendID() {
        #expect(!VFSBackendID.local.isSFTP)
        #expect(VFSBackendID.local.sftpLocation == nil)
        // An archive id shares the "scheme prefix" idea but isn't SFTP.
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/x.zip")
        #expect(!archive.isSFTP)
        #expect(archive.sftpLocation == nil)
    }

    @Test("malformed descriptors decode to nil")
    func malformedDescriptors() {
        #expect(SFTPLocation(descriptor: "ftp://user@host:22") == nil) // wrong scheme
        #expect(SFTPLocation(descriptor: "sftp://host:22") == nil) // no username
        #expect(SFTPLocation(descriptor: "sftp://user@host") == nil) // no port
        #expect(SFTPLocation(descriptor: "sftp://user@host:notaport") == nil) // bad port
        #expect(SFTPLocation(descriptor: "sftp://@host:22") == nil) // empty username
        #expect(SFTPLocation(descriptor: "sftp://user@:22") == nil) // empty host
    }

    @Test("the port is split at the last colon so a colon in the host doesn't confuse it")
    func lastColonWinsForPort() {
        // Not valid IPv6 (unbracketed), but proves the split rule: everything before the last
        // colon is the host, the tail is the port.
        let decoded = SFTPLocation(descriptor: "sftp://u@a:b:2200")
        #expect(decoded?.host == "a:b")
        #expect(decoded?.port == 2200)
        #expect(decoded?.username == "u")
    }

    @Test("a location survives JSON Codable round-tripping")
    func codableRoundTrip() throws {
        let original = SFTPLocation(host: "example.org", port: 22, username: "svc")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SFTPLocation.self, from: data)
        #expect(decoded == original)
    }

    @Test("keychain account is the scheme-less user@host:port, stable per account")
    func keychainAccount() {
        let location = SFTPLocation(host: "example.com", port: 2222, username: "oleg")
        #expect(location.keychainAccount == "oleg@example.com:2222")
        // The default port is spelled out too, so two accounts differing only by port don't collide.
        #expect(SFTPLocation(host: "h", username: "u").keychainAccount == "u@h:22")
        #expect(SFTPLocation.keychainService == "com.dirnex.sftp")
    }
}
