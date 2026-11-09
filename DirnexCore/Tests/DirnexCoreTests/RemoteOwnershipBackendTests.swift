import Foundation
import Testing

@testable import DirnexCore

/// An SFTP backend asking who its account is and writing an owner or group (PLAN.md §M38 Slice 1).
@Suite("Remote owner and group: the SFTP backend")
struct RemoteOwnershipBackendTests {
    private let backendID = RemoteOwnershipFixture.backendID
    private static let macOS = RemoteOwnershipFixture.macOS

    private func backend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: SFTPLocation(host: "srv", username: "oleg"), transport: transport)
    }

    private var path: VFSPath { VFSPath(backend: backendID, path: "/srv/report.txt") }

    @Test("the account is asked once per connection")
    func asksOncePerConnection() throws {
        let transport = FakeSFTPTransport()
        transport.commandOutput = Self.macOS + "\n"
        let backend = backend(transport)
        _ = try backend.accountIdentity(at: path, isCancelled: { false })
        let identity = try backend.accountIdentity(at: path, isCancelled: { false })
        #expect(identity?.user.name == "oleg")
        #expect(transport.commands == [SSHOwnershipCommand.identity])
    }

    @Test("an account with no shell is remembered as one")
    func remembersNoShell() throws {
        let transport = FakeSFTPTransport()
        transport.hasNoExecChannel = true
        let backend = backend(transport)
        #expect(try backend.accountIdentity(at: path, isCancelled: { false }) == nil)
        #expect(try backend.accountIdentity(at: path, isCancelled: { false }) == nil)
        #expect(transport.commands.count == 1)
    }

    @Test("a failed attempt says nothing about the account, and is asked again")
    func failureIsNotRemembered() throws {
        let transport = FakeSFTPTransport()
        transport.commandError = SFTPTransportError.failure("lost")
        let backend = backend(transport)
        #expect(try backend.accountIdentity(at: path, isCancelled: { false }) == nil)
        transport.commandError = nil
        transport.commandOutput = Self.macOS
        #expect(try backend.accountIdentity(at: path, isCancelled: { false }) != nil)
    }

    @Test("a command that could not be asked is not remembered either")
    func noAnswerIsNotRemembered() throws {
        let transport = FakeSFTPTransport()
        let backend = backend(transport)
        #expect(try backend.accountIdentity(at: path, isCancelled: { false }) == nil)
        transport.commandOutput = Self.macOS
        #expect(try backend.accountIdentity(at: path, isCancelled: { false }) != nil)
    }

    @Test("cancelling travels")
    func cancellationTravels() {
        let transport = FakeSFTPTransport()
        transport.commandError = CancellationError()
        let backend = backend(transport)
        #expect(throws: CancellationError.self) {
            try backend.accountIdentity(at: path, isCancelled: { true })
        }
    }

    @Test("the ownership runs over the exec channel, and the mode goes to the batch after it")
    func writesInOrder() throws {
        let transport = FakeSFTPTransport()
        transport.commandOutput = "dirnex-chown-ok\n"
        let mode = POSIXPermissions(rawValue: 0o6755)
        let refusals = try backend(transport).applyMetadata(
            [.setMode(mode), .setOwnership(owner: nil, group: "admin")],
            at: path
        )
        #expect(refusals.isEmpty)
        #expect(transport.commands.count == 1)
        #expect(transport.commands.first?.contains("':admin'") == true)
        #expect(transport.appliedMetadata.map(\.steps) == [[.setMode(mode)]])
    }

    @Test("the exec channel goes first, so a connection lost there sends no mode")
    func execChannelGoesFirst() {
        let transport = FakeSFTPTransport()
        transport.commandError = SFTPTransportError.failure("lost")
        #expect(throws: (any Error).self) {
            try backend(transport).applyMetadata(
                [
                    .setMode(POSIXPermissions(rawValue: 0o6755)),
                    .setOwnership(owner: nil, group: "admin")
                ],
                at: path
            )
        }
        #expect(transport.appliedMetadata.isEmpty)
    }

    @Test("a refused group does not stop the mode, and is answered")
    func refusalIsAnswered() throws {
        let transport = FakeSFTPTransport()
        transport.commandOutput = "chown: you are not a member of group daemon\n"
        let refusals = try backend(transport).applyMetadata(
            [
                .setOwnership(owner: nil, group: "daemon"),
                .setMode(POSIXPermissions(rawValue: 0o644))
            ],
            at: path
        )
        #expect(refusals == [.itemRefused("chown: you are not a member of group daemon")])
        #expect(transport.appliedMetadata.count == 1)
    }

    @Test("a change of ownership alone opens no sftp batch")
    func ownershipAloneNeedsNoBatch() throws {
        let transport = FakeSFTPTransport()
        transport.commandOutput = "dirnex-chown-ok\n"
        _ = try backend(transport).applyMetadata(
            [.setOwnership(owner: nil, group: "admin")],
            at: path
        )
        #expect(transport.appliedMetadata.isEmpty)
    }

    @Test("a backend with no account to ask answers nil")
    func defaultAnswersNil() throws {
        let local = LocalBackend()
        #expect(try local.accountIdentity(at: .local("/tmp"), isCancelled: { false }) == nil)
    }
}
