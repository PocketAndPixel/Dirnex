import Foundation
import Testing

@testable import DirnexCore

/// `X-OC-Mtime` (``WebDAVModificationTime``): an upload asks every server for its date, and the
/// date counts as kept only on Nextcloud's own `X-OC-MTime: accepted`. The answers are runs captured
/// through the shipped builder on 2026-10-24, from Nextcloud 34 and from macOS's Apache sent the same
/// header.
@Suite("WebDAV: an upload's date")
struct WebDAVModificationTimeTests {
    private static let location = WebDAVNextcloudTests.location
    private static let folder = WebDAVNextcloudTests.folder
    /// 2020-01-02 12:00 UTC: a date no transfer here could produce by itself.
    private static let past = Date(timeIntervalSince1970: 1_577_966_400)

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    private func backend(_ transport: FakeWebDAVTransport) -> WebDAVBackend {
        WebDAVBackend(location: Self.location, transport: transport)
    }

    private func transport(answering name: String) -> FakeWebDAVTransport {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = { _ in try WebDAVNextcloudTests.nextcloud(name, body: false) }
        return transport
    }

    @Test("an upload asks for its date in whole seconds, and only a date a server would take")
    func uploadAsksForTheDate() {
        let session = WebDAVSession(location: Self.location)
        let arguments = { (date: Date?) in
            WebDAVProcessArguments.upload(
                session: session,
                localPath: "/tmp/a",
                backendPath: "/a",
                modificationTime: date
            )
        }
        let dated = arguments(Date(timeIntervalSince1970: 1_577_880_000.75))
        let header = dated.firstIndex(of: "X-OC-Mtime: 1577880000")
        #expect(header.map { dated[$0 - 1] } == "-H")
        #expect(header.map { $0 < (dated.firstIndex(of: "--upload-file") ?? 0) } == true)

        let undated = arguments(nil)
        #expect(!undated.contains { $0.hasPrefix("X-OC-Mtime") })
        #expect(undated == arguments(Date(timeIntervalSince1970: 0)))

        // Nextcloud answers 500 to one day or less, and writes the bytes anyway (measured).
        #expect(WebDAVModificationTime.headerValue(for: Date(timeIntervalSince1970: 86400)) == nil)
        #expect(WebDAVModificationTime.headerValue(for: Date(timeIntervalSince1970: 86400.5)) == nil)
        #expect(
            WebDAVModificationTime.headerValue(for: Date(timeIntervalSince1970: 86401)) == "86401"
        )
        #expect(WebDAVModificationTime.headerValue(for: Date(timeIntervalSince1970: -86400)) == nil)
        #expect(WebDAVModificationTime.headerValue(for: .distantFuture) != nil)
    }

    @Test("only the server's own 'accepted' says the date was kept")
    func onlyAcceptedKeepsTheDate() throws {
        #expect(
            WebDAVModificationTime.wasKept(
                by: try WebDAVNextcloudTests.nextcloud("put-mtime-201", body: false)
            )
        )
        #expect(
            WebDAVModificationTime.wasKept(
                by: try WebDAVNextcloudTests.nextcloud("put-mtime-204", body: false)
            )
        )
        #expect(
            !WebDAVModificationTime.wasKept(
                by: try WebDAVNextcloudTests.nextcloud("put-201", body: false)
            )
        )
        // macOS's Apache, sent the same header through the same builder: the file was dated now.
        #expect(
            !WebDAVModificationTime.wasKept(
                by: try WebDAVBackendWriteTests.apache("put-mtime-201", body: "")
            )
        )
        #expect(WebDAVModificationTime.wasKept(by: WebDAVHTTPResponse(
            status: 201,
            headers: ["X-OC-MTime": [" Accepted"]]
        )))
        #expect(!WebDAVModificationTime.wasKept(by: WebDAVHTTPResponse(
            status: 201,
            headers: ["X-OC-MTime": ["refused"]]
        )))
    }

    @Test("an upload Nextcloud dated counts nothing lost; one it did not, the date")
    func uploadKeepsTheDate() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = scratch.path("payload.bin")
        try Data(repeating: 7, count: 6).write(to: URL(fileURLWithPath: local))
        try FileManager.default.setAttributes([.modificationDate: Self.past], ofItemAtPath: local)
        let destination = path(Self.folder + "/w/dated.txt")
        let upload = { (dav: WebDAVBackend) in
            try dav.copyFile(
                at: .local(local),
                to: destination,
                progress: { _ in },
                isCancelled: { false }
            )
        }

        let dated = transport(answering: "put-mtime-201")
        let kept = backend(dated)
        try upload(kept)
        #expect(dated.uploadTimes == [Self.past])
        #expect(kept.metadataTally(at: destination) == .zero)

        let ignored = FakeWebDAVTransport()
        ignored.answerWrite = { _ in try WebDAVBackendWriteTests.apache("put-mtime-201", body: "") }
        let lost = backend(ignored)
        try upload(lost)
        #expect(ignored.uploadTimes == [Self.past], "asked of every server alike")
        #expect(lost.metadataTally(at: destination).loss?.aspects == [.modificationTime])
    }

    @Test("a save-back asks for no date")
    func saveBackSendsNoDate() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = scratch.path("edited.txt")
        try Data("edit".utf8).write(to: URL(fileURLWithPath: local))
        let transport = transport(answering: "put-mtime-204")
        try backend(transport).writeBack(
            localPath: local,
            to: path(Self.folder + "/w/dated.txt"),
            condition: .unconditional,
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.uploadTimes == [nil])
    }
}
