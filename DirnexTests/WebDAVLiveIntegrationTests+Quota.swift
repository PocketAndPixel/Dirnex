import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The space a server says is left (``WebDAVQuota``, PLAN.md §M38 Slice 7), asked of every endpoint.
/// One request each, through the real `curl`. A server that reports RFC 4331's quota answers within
/// the quota its account was given (``WebDAVLiveEndpoint/quotaBytes``), and every other answers none.
extension WebDAVLiveIntegrationTests {
    @Test(
        "the root's quota is one request, and only a server that reports one answers it",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func rootQuota(_ endpoint: WebDAVLiveEndpoint) async throws {
        let run = try await offCooperativePool { () -> QuotaRun in
            let (backend, counting) = endpoint.backend()
            counting.reset()
            let quota = try backend.quota()
            return QuotaRun(quota: quota, requests: counting.requests)
        }
        #expect(run.requests == [.propfindQuota])
        if let given = endpoint.quotaBytes {
            let available = try #require(run.quota?.availableBytes, "the server reports a quota")
            // What the suite has stored by now is not known here, since its tests run at once.
            #expect(available > 0 && available <= given)
        } else {
            #expect(run.quota == nil)
        }
    }

    struct QuotaRun: Sendable {
        let quota: WebDAVQuota?
        let requests: [CountingWebDAVTransport.Request]
    }
}
