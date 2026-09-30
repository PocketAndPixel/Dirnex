import Foundation
import Testing

@testable import DirnexCore

/// Renaming a **folder** on S3, end to end: `moveItem` answers `EXDEV`, `CopyEngine` copies the
/// subtree under the new name and then removes the source.
///
/// It needs a *stateful* double, and that is the whole reason this suite exists rather than another
/// case in `S3BackendWriteTests`. ``FakeS3Transport`` hands out queued pages by call index, which is
/// right for a flow whose requests are countable; a folder rename issues a listing per directory on
/// the way down and another to sweep the source, and what has to be asserted is not the requests but
/// **what is left in the bucket**. Reported 2026-08-22 as a rename that left the folder under both
/// names, which is a statement about the keyspace and nothing else.
///
/// The double is deliberately thin — a key→size map and the list document real buckets send. Its XML
/// is the shape `S3Fixtures` carries, and every claim made against it is about which keys survive,
/// so it is never asked to be an authority on anything S3 itself decides.
final class StatefulS3Bucket: S3Transport, @unchecked Sendable {
    /// The keyspace, exactly as a bucket has one: a flat map, with no folders in it.
    var store: [String: Int64] = [:]
    /// Whether the endpoint honours `encoding-type=url` and echoes it. AWS does; several
    /// S3-compatible servers do not, and the two spell a space differently on the wire.
    var honorsEncoding = true

    private func formEncoded(_ key: String) -> String {
        guard honorsEncoding else { return key }
        var out = ""
        for scalar in key.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || "-_.~/".unicodeScalars.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " {
                out += "+"
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
        }
        return out
    }

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken _: String?
    ) throws -> S3Response {
        var contents: [(key: String, size: Int64)] = []
        var commonPrefixes: Set<String> = []
        for (key, size) in store where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let delimiter, let cut = rest.range(of: delimiter) {
                commonPrefixes.insert(prefix + rest[rest.startIndex..<cut.upperBound])
            } else {
                contents.append((key, size))
            }
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix>\(formEncoded(prefix))</Prefix>\
        <KeyCount>\(contents.count + commonPrefixes.count)</KeyCount><MaxKeys>1000</MaxKeys>\
        <IsTruncated>false</IsTruncated>
        """
        if honorsEncoding { xml += "<EncodingType>url</EncodingType>" }
        for row in contents.sorted(by: { $0.key < $1.key }) {
            xml += """
            <Contents><Key>\(formEncoded(row.key))</Key>\
            <LastModified>2026-08-20T10:00:00.000Z</LastModified>\
            <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>\(row.size)</Size>\
            <StorageClass>STANDARD</StorageClass></Contents>
            """
        }
        for common in commonPrefixes.sorted() {
            xml += "<CommonPrefixes><Prefix>\(formEncoded(common))</Prefix></CommonPrefixes>"
        }
        return S3Response(status: 200, body: Data((xml + "</ListBucketResult>").utf8))
    }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        guard let size = store[sourceKey] else {
            return S3Response(status: 404, body: Data("<Error><Code>NoSuchKey</Code></Error>".utf8))
        }
        store[destinationKey] = size
        return S3Response(status: 200)
    }

    /// Idempotent, exactly as S3 is: a key that was never there still answers 204. That is what let
    /// the undecoded sweep report success while deleting nothing.
    func deleteObject(key: String) throws -> S3Response {
        store[key] = nil
        return S3Response(status: 204)
    }

    func deleteObjects(keys: [String]) throws -> S3Response {
        for key in keys { store[key] = nil }
        return S3Response(status: 200, body: Data(S3Fixtures.deleteQuiet.utf8))
    }

    func putEmptyObject(key: String) throws -> S3Response {
        store[key] = 0
        return S3Response(status: 200)
    }

    func putEmptyObject(key: String, condition _: S3WriteCondition) throws -> S3Response {
        try putEmptyObject(key: key)
    }

    func head(key: String) throws -> S3Response {
        guard let size = store[key] else { return S3Response(status: 404) }
        return S3Response(status: 200, contentLength: size)
    }

    // A folder rename is server-side copies and deletes only — no byte ever leaves the bucket — so
    // the transfer and multipart verbs are unreachable here and refuse rather than pretend.
    func download(
        key _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 501)
    }

    func upload(
        localPath _: String,
        to _: String,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 501)
    }

    func createMultipartUpload(key _: String) throws -> S3Response { S3Response(status: 501) }

    func uploadPart(
        _: S3PartRequest,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 501)
    }

    func completeMultipartUpload(
        key _: String,
        uploadID _: String,
        parts _: [S3UploadedPart]
    ) throws -> S3Response {
        S3Response(status: 501)
    }

    func abortMultipartUpload(key _: String, uploadID _: String) throws -> S3Response {
        S3Response(status: 200)
    }
}

@Suite("S3 — renaming a folder")
struct S3FolderRenameTests {
    private static let location = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "amzn-s3-df",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    /// Rename `old` to `new` at the bucket root the way the pane does, and hand back what is left.
    private func rename(
        _ old: String,
        to new: String,
        in keys: [String: Int64],
        honorsEncoding: Bool = true
    ) throws -> (keys: [String], report: OperationReport) {
        let transport = StatefulS3Bucket()
        transport.honorsEncoding = honorsEncoding
        transport.store = keys
        let backend = S3Backend(location: Self.location, transport: transport)
        let root = VFSPath(backend: backend.id, path: "/")
        let entry = try backend.stat(at: root.appending(old))
        // The operation the pane builds once `moveItem` has refused with `EXDEV`
        // (`PanelViewController+RenameQueue`).
        let report = CopyEngine.run(
            FileOperation(renaming: entry, to: new, in: root),
            using: backend
        )
        return (transport.store.keys.sorted(), report)
    }

    /// The reported bug, in the shape it was reported: after the rename the folder was under **both**
    /// names. Every request had succeeded — the copies landed, and the batch delete answered 200 over
    /// keys that had never existed, because they were still form-encoded.
    @Test("a folder whose name has a space does not survive its own rename")
    func spacedFolderLeavesNothingBehind() throws {
        let (keys, report) = try rename(
            "untitled folder",
            to: "renamed folder",
            in: [
                "untitled folder/": 0,
                "untitled folder/DSC_0004.NEF": 28,
                "untitled folder/sub dir/файл.txt": 12,
                "DSC_0697.jpg": 14
            ]
        )
        #expect(report.failures.isEmpty)
        #expect(keys == [
            "DSC_0697.jpg",
            "renamed folder/",
            "renamed folder/DSC_0004.NEF",
            "renamed folder/sub dir/",
            "renamed folder/sub dir/файл.txt"
        ])
    }

    /// An **empty** folder is the same rename with nothing but a marker to move, and it is what F7
    /// leaves. Worth its own case because the marker is the one key that exists only as the folder
    /// itself, so it is the whole of what the sweep has to find.
    @Test("an empty folder's marker moves with it")
    func emptyFolderMovesItsMarker() throws {
        let (keys, report) = try rename(
            "untitled folder",
            to: "renamed",
            in: ["untitled folder/": 0, "DSC_0697.jpg": 14]
        )
        #expect(report.failures.isEmpty)
        #expect(keys == ["DSC_0697.jpg", "renamed/"])
    }

    /// The narrowness control, and the reason the decode is keyed on the server's echo rather than
    /// applied everywhere: on an endpoint that ignores `encoding-type`, a `+` in a key is a literal
    /// plus, and a rename must move *that* key rather than one with a space in it.
    @Test("a literal plus survives a rename on an endpoint that declares no encoding")
    func literalPlusSurvivesWhereNothingIsDeclared() throws {
        let (keys, report) = try rename(
            "a+b",
            to: "c+d",
            in: ["a+b/": 0, "a+b/plus+file.txt": 1],
            honorsEncoding: false
        )
        #expect(report.failures.isEmpty)
        #expect(keys == ["c+d/", "c+d/plus+file.txt"])
    }
}
