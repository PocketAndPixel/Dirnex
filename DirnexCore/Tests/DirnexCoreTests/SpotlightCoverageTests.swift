import Foundation
import Testing

@testable import DirnexCore

/// Asking Spotlight whether it covers a folder before ⌥F7 trusts it with one (PLAN.md §M40 Slice 3).
/// The outputs are the shapes `mdfind -0` and `mdutil -s` printed on this Mac on 2026-11-18.
@Suite("Spotlight coverage")
struct SpotlightCoverageTests {
    /// `mdfind -0`'s output: each path, then a NUL.
    private func output(_ paths: [String]) -> Data {
        Data(paths.map { $0 + "\0" }.joined().utf8)
    }

    @Test("a folder is looked up by its exact name in its parent")
    func arguments() {
        #expect(
            SpotlightCoverage.mdfindArguments(forFolder: "/Users/oleg/Dev")
                == ["-0", "-onlyin", "/Users/oleg", #"kMDItemFSName == "Dev""#]
        )
        // A slash typed at the end is not part of the name.
        #expect(
            SpotlightCoverage.mdfindArguments(forFolder: "/Volumes/media/Movies/")
                == ["-0", "-onlyin", "/Volumes/media", #"kMDItemFSName == "Movies""#]
        )
        #expect(
            SpotlightCoverage.mdfindArguments(forFolder: "/Users")
                == ["-0", "-onlyin", "/", #"kMDItemFSName == "Users""#]
        )
    }

    /// Escaped as a search term is, so a name cannot close the literal; probed: `quo"te` finds itself.
    @Test("a quote or backslash in the name stays inside the literal")
    func escaping() {
        #expect(
            SpotlightCoverage.mdfindArguments(forFolder: #"/tmp/quo"te\x"#)?.last
                == #"kMDItemFSName == "quo\"te\\x""#
        )
    }

    @Test("the root has no parent to ask")
    func root() {
        #expect(SpotlightCoverage.mdfindArguments(forFolder: "/") == nil)
    }

    /// `-onlyin` covers the parent's whole subtree, so folders of the same name deeper down come back
    /// too — six of them for `/Users/oleg` when probed.
    @Test("the folder itself must be among the hits, not merely one of its name")
    func folderItselfMustMatch() {
        let hits = output([
            "/Users/oleg/swtest/oleg",
            "/Users/oleg",
            "/Users/oleg/Dev/RadiantFall/Content/Developers/oleg"
        ])
        #expect(SpotlightCoverage.output(hits, namesFolder: "/Users/oleg"))
        #expect(SpotlightCoverage.output(hits, namesFolder: "/Users/oleg/"))

        let elsewhere = output(["/Users/oleg/swtest/oleg"])
        #expect(!SpotlightCoverage.output(elsewhere, namesFolder: "/Users/oleg"))
    }

    @Test("nothing printed is not covered")
    func emptyOutput() {
        #expect(!SpotlightCoverage.output(Data(), namesFolder: "/private/tmp"))
    }

    /// `mdfind` prints every path decomposed, and a name on disk is usually composed.
    @Test("a decomposed hit names a composed folder")
    func normalization() {
        let composed = "/Users/oleg/build/\u{FC}n\u{EF} c\u{F6}d\u{E9}"
        let decomposed = "/Users/oleg/build/u\u{308}ni\u{308} co\u{308}de\u{301}"
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        #expect(SpotlightCoverage.output(output([decomposed]), namesFolder: composed))
    }

    /// A name can hold a newline, which is why the arguments ask for `-0`.
    @Test("a path holding a newline is one record")
    func newlineInName() {
        let folder = "/tmp/two\nlines"
        #expect(SpotlightCoverage.output(output([folder]), namesFolder: folder))
        #expect(!SpotlightCoverage.output(output(["/tmp/two"]), namesFolder: folder))
    }

    @Test("a volume is covered only when mdutil says indexing is enabled")
    func volumes() {
        // As printed, trailing space included.
        #expect(SpotlightCoverage.volumeIsIndexed(mdutilOutput: "/:\n\tIndexing enabled. \n"))
        #expect(!SpotlightCoverage.volumeIsIndexed(
            mdutilOutput: "/System/Volumes/Data/Volumes/media:\n\tIndexing disabled.\n"
        ))
        #expect(!SpotlightCoverage.volumeIsIndexed(
            mdutilOutput: "/System/Volumes/Data/Users/oleg:\n\tError: unknown indexing state.\n"
        ))
        #expect(
            !SpotlightCoverage.volumeIsIndexed(
                mdutilOutput: "/Volumes/srv:\n\tServer search enabled.\n"
            )
        )
        #expect(!SpotlightCoverage.volumeIsIndexed(mdutilOutput: ""))
    }
}
