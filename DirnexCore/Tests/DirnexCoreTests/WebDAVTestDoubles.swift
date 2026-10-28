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

    /// One request of the write half, as the backend asked for it.
    enum Write: Equatable {
        case mkcol(String)
        case upload(localPath: String, path: String, condition: S3WriteCondition)
        case putEmpty(String, condition: S3WriteCondition)
        case move(String, to: String)
        case copy(String, to: String)
        case delete(String)
    }

    var respond: (Propfind) throws -> WebDAVHTTPResponse
    /// The file a download serves.
    var fileBytes = Data()
    /// Replaces the download's own answer when set — a refusal, or a run that was cut short.
    var downloadAnswer: (() throws -> WebDAVHTTPResponse)?
    /// Deltas streamed before the download answers, as a real transport reports the destination
    /// growing. Empty means one report at the end.
    var streamedProgress: [Int64] = []
    /// What every write answers. A 201 unless a test says otherwise.
    var answerWrite: (Write) throws -> WebDAVHTTPResponse = { _ in WebDAVHTTPResponse(status: 201) }
    /// Deltas an upload streams before it answers, as `curl`'s meter would.
    var streamedUploadProgress: [Int64] = []

    private(set) var propfinds: [Propfind] = []
    private(set) var downloads: [Download] = []
    private(set) var writes: [Write] = []
    /// The date each upload asked the server for, in order — kept beside ``writes`` rather than in
    /// it, so a test about a write's shape need not spell a date.
    private(set) var uploadTimes: [Date?] = []
    /// Each batched run, as the paths it carried.
    private(set) var batches: [[String]] = []
    /// Every section a batched run actually sent, in order, across all runs.
    private(set) var batchedRequests: [String] = []
    /// Replaces a batched run's own answers when set — a transport that answered the wrong number,
    /// or one that could not run at all.
    var batchAnswer: (([String]) throws -> [WebDAVBatchAnswer])?

    /// One segmented download, as the backend asked for it.
    struct SegmentRun: Equatable {
        let path: String
        let entityTag: String
        let ranges: [Range<Int64>]
    }

    /// Each segmented download, in order.
    private(set) var segmentRuns: [SegmentRun] = []
    /// Replaces a segmented run's answers when set — a captured run's
    /// (``WebDAVSegmentWriteOut/answers(segments:standardOutput:)``). Each piece is then written as
    /// its answer says the server sent it: a 206's bytes from its range's start, a 200's from the
    /// file's, and nothing for a refusal or a section that got no answer.
    var segmentAnswer: (([DownloadSegment]) throws -> [WebDAVBatchAnswer])?
    /// Called after the pieces land and before the run answers, as a Stop pressed mid-run would be.
    var duringSegments: (() -> Void)?

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

    /// A batched run as `curl` was measured to run one (``WebDAVProcessArguments/listings(session:requests:credentials:)``):
    /// each section answered by ``respond`` as a `Depth: 1` PROPFIND of a collection, the run
    /// stopping after a first section answered 400 or above (`fail`), or after any section whose
    /// answer is a thrown transport failure (`--fail-early`).
    func propfindBatch(_ backendPaths: [String], isCancelled: () -> Bool) throws
        -> [WebDAVBatchAnswer] {
        batches.append(backendPaths)
        if let batchAnswer { return try batchAnswer(backendPaths) }
        var answers: [WebDAVBatchAnswer] = []
        for (index, path) in backendPaths.enumerated() {
            if isCancelled() { throw CancellationError() }
            batchedRequests.append(path)
            let answer: WebDAVBatchAnswer
            do {
                answer = try .response(
                    respond(Propfind(path: path, depth: .one, isCollection: true))
                )
            } catch let WebDAVResponseError.transport(failure) {
                answer = .noAnswer(failure)
            }
            answers.append(answer)
            let stops: Bool
            switch answer {
            case let .response(response): stops = index == 0 && response.status >= 400
            case .noAnswer, .notSent: stops = true
            }
            if stops { break }
        }
        return answers + Array(repeating: .notSent, count: backendPaths.count - answers.count)
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

    /// A segmented run as `curl` was measured to run one: by default every section a 206 holding
    /// exactly its range of ``fileBytes``, each piece reported as one delta when it lands.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of file: WebDAVTaggedFile,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVSegmentedDownload {
        segmentRuns.append(SegmentRun(
            path: file.backendPath,
            entityTag: file.entityTag,
            ranges: segments.map(\.range)
        ))
        let answers = try segmentAnswer?(segments) ?? segments.map {
            .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: $0.length))
        }
        for (segment, answer) in zip(segments, answers) {
            guard case let .response(response) = answer,
                  response.status == 206 || response.status == 200 else { continue }
            let start = response.status == 206 ? Int(segment.range.lowerBound) : 0
            let end = min(start + Int(response.bytesDownloaded), fileBytes.count)
            try fileBytes.subdata(in: start..<end).write(to: URL(fileURLWithPath: segment.localPath))
            progress(Int64(end - start))
        }
        duringSegments?()
        return .segments(answers)
    }

    func mkcol(_ backendPath: String) throws -> WebDAVHTTPResponse {
        try record(.mkcol(backendPath))
    }

    func upload(
        localPath: String,
        to backendPath: String,
        headers: WebDAVPutHeaders,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        for delta in streamedUploadProgress { progress(delta) }
        uploadTimes.append(headers.modificationTime)
        return try record(
            .upload(localPath: localPath, path: backendPath, condition: headers.condition)
        )
    }

    func putEmpty(_ backendPath: String, condition: S3WriteCondition) throws -> WebDAVHTTPResponse {
        try record(.putEmpty(backendPath, condition: condition))
    }

    func move(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse {
        try record(.move(backendPath, to: destinationPath))
    }

    func copy(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse {
        try record(.copy(backendPath, to: destinationPath))
    }

    func delete(_ backendPath: String) throws -> WebDAVHTTPResponse {
        try record(.delete(backendPath))
    }

    private func record(_ write: Write) throws -> WebDAVHTTPResponse {
        writes.append(write)
        return try answerWrite(write)
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
