import Foundation
import Testing

@testable import DirnexCore

/// The `VFSPath` ⇄ object-key translation — "S3 is not a filesystem", in one place.
@Suite("S3Key")
struct S3KeyTests {
    private static func path(_ path: String) -> VFSPath {
        VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: path)
    }

    // MARK: - Keys and prefixes

    @Test("a path's key is its path without the leading slash")
    func keyDropsLeadingSlash() {
        #expect(S3Key.key(for: Self.path("/docs/report.pdf")) == "docs/report.pdf")
    }

    @Test("the bucket root is the empty key, not a slash")
    func rootIsTheEmptyKey() {
        // `/` would be a one-character key whose name is a slash. That is legal to create and is
        // not what the root means, so a root listing asking `prefix=/` returns nothing at all.
        #expect(S3Key.key(for: Self.path("/")).isEmpty)
        #expect(S3Key.listingPrefix(for: Self.path("/")).isEmpty)
    }

    @Test("a directory's listing prefix ends in the delimiter")
    func listingPrefixIsDelimited() {
        #expect(S3Key.listingPrefix(for: Self.path("/docs")) == "docs/")
    }

    @Test("the trailing delimiter is what stops a folder matching its siblings")
    func listingPrefixIsNotABareStringMatch() {
        // `prefix=doc` matches `docs/`, `document.txt` and `doctor/` alike — a prefix is a string
        // comparison and knows nothing about path components, so a folder named `doc` would list
        // its neighbours' contents as its own.
        let prefix = S3Key.listingPrefix(for: Self.path("/doc"))
        #expect(prefix == "doc/")
        #expect(!"document.txt".hasPrefix(prefix))
        #expect("doc/inside.txt".hasPrefix(prefix))
    }

    // MARK: - Display names

    @Test("a whole key is displayed by its last component")
    func displayNameIsTheLeaf() {
        #expect(S3Key.displayName(ofKey: "tiles/1/C/GENERAL_QUALITY.xml") == "GENERAL_QUALITY.xml")
    }

    @Test("a folder prefix loses its trailing delimiter before its leaf is taken")
    func displayNameOfPrefix() {
        // Without dropping the slash first, the last component of `tiles/1/C/` is the empty string
        // and every folder row comes out nameless.
        #expect(S3Key.displayName(ofKey: "tiles/1/C/") == "C")
    }

    @Test("a top-level key is its own name")
    func displayNameAtRoot() {
        #expect(S3Key.displayName(ofKey: "notes.txt") == "notes.txt")
    }

    // MARK: - Directory markers

    @Test("the marker for the listed prefix is recognized")
    func recognizesOwnMarker() {
        #expect(S3Key.isDirectoryMarker(key: "docs/", forPrefix: "docs/"))
    }

    @Test("a deeper marker and a same-named file are not the listed prefix's marker")
    func doesNotOverReach() {
        #expect(!S3Key.isDirectoryMarker(key: "docs/sub/", forPrefix: "docs/"))
        #expect(!S3Key.isDirectoryMarker(key: "docs", forPrefix: "docs/"))
    }

    // MARK: - Percent-encoding

    @Test("a path keeps its separators and encodes everything reserved")
    func pathEncodingKeepsSlashes() {
        #expect(S3Key.encodedForPath("docs/my file.txt") == "docs/my%20file.txt")
    }

    @Test("a key's sub-delimiters are encoded, so they cannot change which object is named")
    func pathEncodingIsStricterThanFoundation() {
        // `CharacterSet.urlPathAllowed` permits these. A key containing `?` or `#` left literal
        // ends the path, turning the rest of a legal object name into a query or a fragment.
        #expect(S3Key.encodedForPath("a?b#c") == "a%3Fb%23c")
        #expect(S3Key.encodedForPath("a;b,c=d") == "a%3Bb%2Cc%3Dd")
    }

    @Test("unreserved characters are never escaped")
    func pathEncodingKeepsUnreserved() {
        #expect(S3Key.encodedForPath("a-b_c.d~e9") == "a-b_c.d~e9")
    }

    @Test("non-ASCII is encoded as UTF-8 bytes")
    func pathEncodingHandlesUnicode() {
        #expect(S3Key.encodedForPath("файл") == "%D1%84%D0%B0%D0%B9%D0%BB")
    }

    @Test("a query value encodes the delimiter too")
    func queryEncodingEncodesSlash() {
        #expect(S3Key.encodedForQuery("docs/sub/") == "docs%2Fsub%2F")
    }

    @Test("a real continuation token survives the encoding AWS requires")
    func queryEncodingFixesPagination() {
        // The exact token a real listing of `sentinel-s2-l1c` handed back on 2026-08-12. Sent raw
        // it answers `InvalidArgument` — "The continuation token provided is incorrect"; sent
        // encoded, the same token in the same run returned the next page. Base64's `+`, `/` and
        // `=` are all three meaningful in a query string, and a token that happens to carry none
        // of them round-trips raw perfectly — which is what makes this fail intermittently, on
        // large buckets only.
        let token = "1UIXF3wSs9sVkphr6HBPT4+x/+5qYkB81jpDwVavKeJXON3mn08bAWQ=="
        let encoded = S3Key.encodedForQuery(token)
        #expect(encoded == "1UIXF3wSs9sVkphr6HBPT4%2Bx%2F%2B5qYkB81jpDwVavKeJXON3mn08bAWQ%3D%3D")
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test("a url-encoded key decodes back to itself")
    func decodesRoundTrip() {
        #expect(S3Key.decodingURLEncoding("my%20file%20%2B%20one.txt") == "my file + one.txt")
    }

    @Test("a space arrives as a plus, which is what `encoding-type=url` actually means")
    func decodesFormEncodedSpace() {
        // Real bytes: keys stored as `c d.txt` and `trailing ` came back this way from a live
        // bucket 2026-08-18, and came back with their spaces intact when the same three keys were
        // listed again with no `encoding-type` at all. `removingPercentEncoding` alone leaves the
        // plus standing, and the URL built back from that name asks for `%2B` — a key that is not
        // there, which is what made `stat` answer `notFound` for a row visible in the pane.
        #expect(S3Key.decodingURLEncoding("c+d.txt") == "c d.txt")
        #expect(S3Key.decodingURLEncoding("trailing+") == "trailing ")
    }

    @Test("a literal plus survives, because that one arrives as %2B")
    func keepsLiteralPlus() {
        // The narrowness control, and the reason the substitution runs *before* the percent decode
        // rather than after: `a+b.txt` was in the same response, spelled `a%2Bb.txt`. Decoding
        // first would collapse both spellings onto a space and lose the distinction entirely.
        #expect(S3Key.decodingURLEncoding("a%2Bb.txt") == "a+b.txt")
        #expect(S3Key.decodingURLEncoding("both+%2B.txt") == "both +.txt")
    }

    @Test("a key that is not valid escaping decodes to nothing rather than to garbage")
    func rejectsBadEscaping() {
        #expect(S3Key.decodingURLEncoding("100%.txt") == nil)
    }
}
