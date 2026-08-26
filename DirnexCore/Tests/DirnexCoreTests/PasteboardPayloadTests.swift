import Foundation
import Testing

@testable import DirnexCore

/// The carrier M23 puts on the pasteboard so ⌘C and drag reach a backend that has no `file://` URL.
///
/// What is worth pinning is the **round trip across backends** — the whole point is that a payload
/// names a bucket or a server, which the previous carrier could not express — and the two ways a
/// read can fail. A decode that returns `nil` is a fallback signal (the reader tries file URLs
/// next), so a payload that decoded to a *wrong* location would be far worse than one that refused,
/// and the refusal cases are tested for that reason rather than for completeness.
@Suite("PasteboardPayload")
struct PasteboardPayloadTests {
    private func entry(
        _ path: VFSPath,
        name: String,
        kind: FileEntry.Kind = .file,
        size: Int64 = 1234,
        symlink: String? = nil
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 99,
            symlinkDestination: symlink
        )
    }

    @Test("a location on every backend survives the round trip, backend included")
    func roundTripsEveryBackend() throws {
        let paths: [VFSPath] = [
            .local("/Users/oleg/a.txt"),
            VFSPath(backend: VFSBackendID("sftp://user@host"), path: "/srv/data/report.pdf"),
            VFSPath(backend: VFSBackendID("s3://bucket"), path: "/prefix/object.bin"),
            VFSPath(backend: .archive(forArchiveAt: "/tmp/pkg.zip"), path: "/docs/x.md"),
            VFSPath(backend: .trash, path: "/deleted.txt")
        ]
        for path in paths {
            let payload = PasteboardPayload(entry(path, name: path.lastComponent))
            let data = try #require(payload.encoded())
            let decoded = try #require(PasteboardPayload.decode(data))
            #expect(decoded.path == path)
            #expect(decoded.path.backend == path.backend, "backend lost for \(path)")
            #expect(decoded == payload)
        }
    }

    @Test("every kind round-trips, so a folder never arrives as a file")
    func roundTripsEveryKind() throws {
        for kind in [FileEntry.Kind.file, .directory, .symlink, .other] {
            let payload = PasteboardPayload(entry(.local("/tmp/x"), name: "x", kind: kind))
            let data = try #require(payload.encoded())
            let decoded = try #require(PasteboardPayload.decode(data))
            #expect(decoded.kind == kind)
        }
    }

    @Test("a symlink carries its raw target, which is what the engine recreates")
    func carriesSymlinkTarget() throws {
        let payload = PasteboardPayload(
            entry(.local("/tmp/link"), name: "link", kind: .symlink, symlink: "../elsewhere")
        )
        let data = try #require(payload.encoded())
        let decoded = try #require(PasteboardPayload.decode(data))
        #expect(decoded.symlinkDestination == "../elsewhere")
        #expect(decoded.entry.symlinkDestination == "../elsewhere")
    }

    @Test("the rebuilt entry carries what CopyEngine reads, and nothing invented")
    func rebuildsWhatTheEngineReads() {
        let source = entry(
            VFSPath(backend: VFSBackendID("s3://bucket"), path: "/a/b.bin"),
            name: "b.bin",
            kind: .file,
            size: 4096
        )
        let rebuilt = PasteboardPayload(source).entry
        // What the engine reads off a source entry.
        #expect(rebuilt.path == source.path)
        #expect(rebuilt.name == source.name)
        #expect(rebuilt.kind == source.kind)
        #expect(rebuilt.byteSize == source.byteSize)
        // What it does not: neutral, never a plausible invention. A caller wanting these must stat.
        #expect(rebuilt.modificationDate == FileEntry.unknownDate)
        #expect(!rebuilt.hasModificationDate)
        #expect(rebuilt.permissions == 0)
        #expect(rebuilt.inode == 0)
    }

    @Test("a dot-file rebuilds as hidden — the one derived field, and it is derivable")
    func rebuildsHiddenFromTheName() {
        #expect(PasteboardPayload(entry(.local("/tmp/.git"), name: ".git")).entry.isHidden)
        #expect(!PasteboardPayload(entry(.local("/tmp/git"), name: "git")).entry.isHidden)
    }

    @Test("bytes that are not our JSON decode to nil rather than to a location")
    func refusesForeignData() {
        // Another app may legitimately write a type of the same name; a reader must not guess.
        for junk in ["", "{}", "not json at all", #"{"v":1}"#, #"{"v":1,"b":"local"}"#] {
            #expect(
                PasteboardPayload.decode(Data(junk.utf8)) == nil,
                "should have refused \(junk)"
            )
        }
    }

    @Test("a payload from a newer build decodes to nil rather than being half-read")
    func refusesAFutureVersion() throws {
        let future = PasteboardPayload(
            version: PasteboardPayload.currentVersion + 1,
            path: .local("/tmp/x"),
            name: "x",
            kind: .file,
            byteSize: 1
        )
        let data = try #require(future.encoded())
        #expect(PasteboardPayload.decode(data) == nil)
        // The control: the identical payload at the current version is readable, so the refusal
        // above is about the version and not about the encoding.
        let current = PasteboardPayload(
            path: .local("/tmp/x"), name: "x", kind: .file, byteSize: 1
        )
        let currentData = try #require(current.encoded())
        #expect(PasteboardPayload.decode(currentData) != nil)
    }

    @Test("the type identifier is one string, shared by whoever writes and whoever reads")
    func namesOneType() {
        #expect(PasteboardPayload.typeIdentifier == "com.dirnex.locations")
    }
}
