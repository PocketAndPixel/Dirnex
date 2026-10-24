import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The date an upload asks for (``WebDAVModificationTime``), against every endpoint. The request is
/// the client's claim and goes to every server alike; whether the date was kept is the server's, and
/// the endpoint says which to expect (``WebDAVLiveEndpoint/keepsUploadDates``).
extension WebDAVLiveIntegrationTests {
    /// 2020-01-02 12:00 UTC, with a fraction the header cannot carry.
    static let uploadDate = Date(timeIntervalSince1970: 1_577_966_400.25)

    @Test(
        "an upload asks for its date, and the server's answer says whether it was kept",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func uploadAsksForItsDate(_ endpoint: WebDAVLiveEndpoint) async throws {
        let run = try await offCooperativePool { () -> DateRun in
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "dates")
            defer { endpoint.discard(root, on: backend) }
            let local = WebDAVLive.scratchFile()
            try Data("dated\n".utf8).write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            try FileManager.default.setAttributes(
                [.modificationDate: Self.uploadDate],
                ofItemAtPath: local.path
            )
            let remote = root.appending("dated.txt")
            let before = backend.metadataTally(at: remote)

            counting.reset()
            try backend.copyFile(
                at: .local(local.path),
                to: remote,
                progress: { _ in },
                isCancelled: { false }
            )
            var run = DateRun()
            run.requests = counting.requests
            run.loss = backend.metadataTally(at: remote).since(before).loss?.aspects
            run.serverDate = try backend.stat(at: remote).modificationDate
            return run
        }
        #expect(run.requests == [.put(.unconditional, askedForDate: true)])
        let wholeSeconds = Self.uploadDate.timeIntervalSince1970.rounded(.down)
        if endpoint.keepsUploadDates {
            #expect(run.serverDate?.timeIntervalSince1970 == wholeSeconds)
            #expect(run.loss == nil, "the server said it kept the date")
        } else {
            #expect(run.serverDate?.timeIntervalSince1970 != wholeSeconds)
            #expect(run.loss == [.modificationTime])
        }
    }

    struct DateRun: Sendable {
        var requests: [CountingWebDAVTransport.Request] = []
        var loss: Set<RemoteMetadataAspect>?
        var serverDate: Date?
    }
}
