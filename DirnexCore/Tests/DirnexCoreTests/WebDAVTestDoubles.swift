import Foundation
import Testing

@testable import DirnexCore

extension WebDAVFixtures {
    /// One real `curl` run, replayed through ``WebDAVWriteOut/response(exitCode:standardOutput:standardError:)``:
    /// the stderr captured from it, its exit code (in the fixture's name, `curl-exit<code>-…`), and
    /// the body it wrote, when the run kept one. So a fake fed this is fed what the app's runner
    /// would hand the backend, classification and all.
    static func run(
        _ name: String,
        body: String? = nil,
        bodyExtension: String = "xml"
    ) throws -> WebDAVHTTPResponse {
        let code = try #require(
            name.split(separator: "-").dropFirst().first?.dropFirst("exit".count)
        )
        let exitCode = try #require(Int32(code))
        let standardOutput = try body.map { try data($0, extension: bodyExtension) } ?? Data()
        return try WebDAVWriteOut.response(
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: text(name, extension: "stderr")
        )
    }

    /// A 207 carrying a captured multistatus body.
    static func multistatus(_ name: String) throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 207, body: try data(name))
    }
}

/// A fake ``WebDAVTransport``. Each PROPFIND is answered by ``respond``, which sees the request, so
/// a test can answer a `Depth: 1` and a `Depth: 0` of one path differently — which is the whole of
/// the listing's file fallback. Downloads serve ``fileBytes`` into the local file exactly as `curl`
/// would: whole, or appended from the local length when resuming.
final class FakeWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    struct Propfind: Equatable {
        let path: String
        let depth: WebDAVDepth
        let isCollection: Bool
    }

    struct Download: Equatable {
        let path: String
        let localPath: String
        let resume: Bool
    }

    var respond: (Propfind) throws -> WebDAVHTTPResponse
    /// The file a download serves.
    var fileBytes = Data()
    /// Replaces the download's own answer when set — a refusal, or a run that was cut short.
    var downloadAnswer: (() throws -> WebDAVHTTPResponse)?
    /// Deltas streamed before the download answers, as a real transport reports the destination
    /// growing. Empty means one report at the end.
    var streamedProgress: [Int64] = []

    private(set) var propfinds: [Propfind] = []
    private(set) var downloads: [Download] = []

    init(respond: @escaping (Propfind) throws -> WebDAVHTTPResponse = { _ in
        WebDAVHTTPResponse(status: 404)
    }) {
        self.respond = respond
    }

    func propfind(_ backendPath: String, depth: WebDAVDepth, isCollection: Bool) throws
        -> WebDAVHTTPResponse {
        let request = Propfind(path: backendPath, depth: depth, isCollection: isCollection)
        propfinds.append(request)
        return try respond(request)
    }

    func download(
        _ backendPath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        downloads.append(Download(path: backendPath, localPath: localPath, resume: resume))
        for delta in streamedProgress { progress(delta) }
        if let downloadAnswer { return try downloadAnswer() }
        let url = URL(fileURLWithPath: localPath)
        let served: Data
        if resume, let existing = try? Data(contentsOf: url) {
            served = fileBytes.dropFirst(existing.count)
            try (existing + served).write(to: url)
        } else {
            served = fileBytes
            try served.write(to: url)
        }
        return WebDAVHTTPResponse(
            status: resume ? 206 : 200,
            bytesDownloaded: Int64(served.count)
        )
    }
}

/// A server for the connect probe: one answer per scheme the probe asks with, and a record of the
/// schemes it asked with, in order — which is what says whether a password went out before the
/// server named how it wanted one.
final class FakeWebDAVServer: @unchecked Sendable {
    typealias Answer = (FakeWebDAVTransport.Propfind) throws -> WebDAVHTTPResponse

    /// What the root answers to a request authenticating with each scheme (`nil` is none). The
    /// request is passed in, since Apache answers the root named with and without its slash
    /// differently when it is a file.
    var answers: [WebDAVAuthScheme?: Answer] = [:]
    private(set) var asked: [WebDAVAuthScheme?] = []
    private(set) var requests: [FakeWebDAVTransport.Propfind] = []

    func transport(_ scheme: WebDAVAuthScheme?) -> any WebDAVTransport {
        FakeWebDAVTransport { [self] request in
            asked.append(scheme)
            requests.append(request)
            guard let answer = answers[scheme] else { return WebDAVHTTPResponse(status: 500) }
            return try answer(request)
        }
    }
}

/// A scratch directory for one test's downloads, removed when the test is done with it.
struct WebDAVScratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
