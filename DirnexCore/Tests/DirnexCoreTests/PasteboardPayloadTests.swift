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

    /// A row as a listing reports it, with the two facts a remote copy carries either present or not.
    private func listed(_ path: VFSPath, mode: UInt16?, date: Date?) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: 10,
            modificationDate: date ?? FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: mode,
            inode: 0
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
    func rebuildsWhatTheEngineReads() throws {
        let source = entry(
            VFSPath(backend: VFSBackendID("ftp://user@host"), path: "/a/b.xml"),
            name: "b.xml",
            kind: .file,
            size: 4096
        )
        let data = try #require(PasteboardPayload(source).encoded())
        let rebuilt = try #require(PasteboardPayload.decode(data)).entry
        // What the engine reads off a source entry. The mode and the date are what a remote copy
        // carries since PLAN.md §M25 Slice 2.
        #expect(rebuilt.path == source.path)
        #expect(rebuilt.name == source.name)
        #expect(rebuilt.kind == source.kind)
        #expect(rebuilt.byteSize == source.byteSize)
        #expect(rebuilt.permissions == 0o644)
        #expect(rebuilt.modificationDate == source.modificationDate)
        // What it does not: neutral, never a plausible invention. A caller wanting these must stat.
        #expect(rebuilt.creationDate == FileEntry.unknownDate)
        #expect(rebuilt.inode == 0)
    }

    @Test("a pasted row hands the copy engine the same hint F5 hands it")
    func pastedRowHintMatchesTheListing() throws {
        let path = VFSPath(backend: VFSBackendID("ftp://user@host"), path: "/AGENCE/a.xml")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let sources = [
            listed(path, mode: 0o644, date: when),
            listed(path, mode: nil, date: when),
            listed(path, mode: 0o600, date: nil),
            // Fractional seconds, as a local `stat` reports them, so the encoding has to be exact.
            listed(.local("/tmp/a.xml"), mode: 0o755, date: when.addingTimeInterval(0.123_456_789))
        ]
        for source in sources {
            let data = try #require(PasteboardPayload(source).encoded())
            let pasted = try #require(PasteboardPayload.decode(data)).entry
            #expect(CopySourceHint(pasted) == CopySourceHint(source))
        }
    }

    @Test("a row with no mode and no date is absent on the far side, never mode 000")
    func absentStaysAbsent() throws {
        // S3 and FTP's DOS dialect list no mode. The carry applies any mode it is handed, so a `0`
        // here was `chmod 000` on the copy: a file dragged off a server landed unreadable.
        let source = listed(
            VFSPath(backend: VFSBackendID("s3://bucket"), path: "/a/b.bin"), mode: nil, date: nil
        )
        let data = try #require(PasteboardPayload(source).encoded())
        let rebuilt = try #require(PasteboardPayload.decode(data)).entry
        #expect(rebuilt.permissions == nil)
        #expect(!rebuilt.hasModificationDate)
        #expect(CopySourceHint(rebuilt).metadata == nil)
    }

    @Test("a payload from a build before the mode and date carries nothing, rather than mode 000")
    func olderPayloadCarriesNothing() throws {
        // Minted by hand, because the subject is the reader: this is what a build before 2026-10-19
        // put on the board, and a paste across an update reads exactly these bytes.
        let older = #"{"v":1,"b":"ftp://user@host","p":"/a.xml","n":"a.xml","k":"f","s":10}"#
        let rebuilt = try #require(PasteboardPayload.decode(Data(older.utf8))).entry
        #expect(rebuilt.permissions == nil)
        #expect(!rebuilt.hasModificationDate)
        #expect(CopySourceHint(rebuilt).metadata == nil)
    }

    @Test("the mode is a plain number and the date is seconds since 2001, under m and t")
    func readsTheWireSpelling() throws {
        // Minted by hand for the same reason: a live check that seeds the board writes these keys.
        let minted = #"{"v":1,"b":"local","p":"/tmp/x","n":"x","k":"f","s":1,"m":420,"t":0}"#
        let rebuilt = try #require(PasteboardPayload.decode(Data(minted.utf8))).entry
        #expect(rebuilt.permissions == 0o644)
        #expect(rebuilt.modificationDate == Date(timeIntervalSinceReferenceDate: 0))
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
