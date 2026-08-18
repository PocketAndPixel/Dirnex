import Foundation
import Testing

@testable import DirnexCore

/// What `encoding-type=url` actually does to a key, over the bytes a real bucket sent.
///
/// A suite of its own for the reason the whitespace suite next door has one: these rest on bytes no
/// other endpoint can produce, and saying so is half of what they are worth. AWS encodes a listing
/// as `application/x-www-form-urlencoded` — **a space arrives as `+`** and a literal plus as `%2B`
/// — which `removingPercentEncoding` alone reads straight past, leaving the plus standing. Every
/// key holding a space was then misnamed in the pane, and since each byte-moving verb re-encodes
/// that name into a URL (where a literal `+` becomes `%2B`), each one addressed an object that is
/// not there: `stat` and F5 answered `notFound` for a visible row, and F8 reported success having
/// deleted nothing. Slice 8's trim, one layer over.
///
/// It could not be reached before 2026-08-18, and the two reasons are mirror images. The
/// S3-compatible endpoint Slice 8's fixtures came from **ignores the parameter** and never echoes
/// it, so `isURLEncoded` is false there and no decoding happens at all; the public AWS buckets the
/// other fixtures came from have **no spaces in any key**. Neither corpus can carry the case, which
/// is why it took a bucket somebody wrote a file name with a space into.
@Suite("S3 form encoding")
struct S3FormEncodingTests {
    @Test("a page of real AWS bytes names a key with a space the way the bucket holds it")
    func decodesFormEncodedKeys() throws {
        let page = try S3ListingParser.parse(Data(S3Fixtures.formEncodedPage.utf8))
        #expect(page.isURLEncoded)
        let directory = VFSPath(
            backend: VFSBackendID("s3://K@h:443/r/b"),
            path: "/dirnex-live-probe/slice10"
        )
        let names = S3ListingParser.entries(from: page, in: directory).map(\.name)
        #expect(names == ["a+b.txt", "c d.txt", "trailing "])
    }

    @Test("stat finds the object whose name carries a space, and not one carrying a plus")
    func statsAFormEncodedKey() throws {
        // The failure this fixes, in the shape it arrived in (2026-08-18, against a real bucket):
        // `stat` lists with `prefix=` the key and takes the row matching **exactly**, so a name
        // mis-decoded by one character answers `notFound` for an object sitting in the pane. The
        // second half keeps that exact match honest — `c+d.txt` names no object in this page, and
        // the old decoder would have matched it while missing the one that is really there.
        let page = try S3ListingParser.parse(Data(S3Fixtures.formEncodedPage.utf8))
        let base = "dirnex-live-probe/slice10"
        let path = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/\(base)/c d.txt")
        let found = try #require(
            S3ListingParser.entry(forKey: "\(base)/c d.txt", in: page, at: path)
        )
        #expect(found.name == "c d.txt")
        #expect(found.kind == .file)
        #expect(S3ListingParser.entry(forKey: "\(base)/c+d.txt", in: page, at: path) == nil)
    }
}
