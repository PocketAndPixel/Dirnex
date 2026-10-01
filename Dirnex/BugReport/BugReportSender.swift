import DirnexCore
import Foundation

/// Sends a report's body to the server and says what became of it (PLAN.md §M30).
///
/// The session is ephemeral: no cookies, no cache, nothing kept on disk. It is injected so the tests
/// can answer through a `URLProtocol` stub instead of a network.
@MainActor
final class BugReportSender {
    private let session: URLSession

    init(session: URLSession = BugReportSender.makeSession()) {
        self.session = session
    }

    /// An ephemeral session that gives up after ``BugReportRequest/timeout``.
    nonisolated static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = BugReportRequest.timeout
        configuration.timeoutIntervalForResource = BugReportRequest.timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Posts `body` to `endpoint`. A cancelled task counts as unreachable: whoever cancelled it
    /// already knows, and the report is still in the dialog.
    func send(_ body: Data, to endpoint: URL) async -> BugReportOutcome {
        let request = BugReportRequest.make(to: endpoint, body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return BugReportOutcome(status: http.statusCode, body: data)
        } catch {
            return .unreachable
        }
    }
}
