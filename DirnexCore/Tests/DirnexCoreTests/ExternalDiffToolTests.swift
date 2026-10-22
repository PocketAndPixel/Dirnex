import Foundation
import Testing

@testable import DirnexCore

@Suite("ExternalDiffTool")
struct ExternalDiffToolTests {
    /// A probe that reports the given paths as installed executables.
    private func probe(installed: Set<String>) -> (String) -> Bool {
        { installed.contains($0) }
    }

    @Test("invocation appends the two paths after leading arguments when installed")
    func invocationBuildsArgv() {
        let tool = ExternalDiffTool(
            identifier: "demo",
            displayName: "Demo",
            candidateExecutablePaths: ["/opt/demo/bin/demodiff"],
            leadingArguments: ["--compare"]
        )
        let invocation = tool.invocation(
            comparing: "/a.txt",
            with: "/b.txt",
            executableExists: probe(installed: ["/opt/demo/bin/demodiff"])
        )
        #expect(invocation?.executablePath == "/opt/demo/bin/demodiff")
        #expect(invocation?.arguments == ["--compare", "/a.txt", "/b.txt"])
    }

    @Test("invocation is nil when no candidate launcher is installed")
    func invocationNilWhenMissing() {
        let invocation = ExternalDiffTool.kaleidoscope.invocation(
            comparing: "/a",
            with: "/b",
            executableExists: probe(installed: [])
        )
        #expect(invocation == nil)
    }

    @Test("executablePath picks the first existing candidate in preference order")
    func executablePathPrefersFirst() {
        // Both Homebrew locations present → the Apple-Silicon path (listed first) wins.
        let path = ExternalDiffTool.kaleidoscope.executablePath(
            where: probe(installed: ["/opt/homebrew/bin/ksdiff", "/usr/local/bin/ksdiff"])
        )
        #expect(path == "/opt/homebrew/bin/ksdiff")

        // Only the Intel location present → it is used.
        let intel = ExternalDiffTool.kaleidoscope.executablePath(
            where: probe(installed: ["/usr/local/bin/ksdiff"])
        )
        #expect(intel == "/usr/local/bin/ksdiff")
    }

    /// Where LaunchServices finds FileMerge when Xcode is installed in the usual place.
    private static let xcodeFileMerge = "/Applications/Xcode.app/Contents/Applications/FileMerge.app"
    /// The `opendiff` that ships in that same Xcode.
    private static let xcodeOpendiff = "/Applications/Xcode.app/Contents/Developer/usr/bin/opendiff"

    /// A LaunchServices stand-in that knows FileMerge at `path`, or nothing.
    private func bundles(fileMergeAt path: String?) -> (String) -> String? {
        { $0 == ExternalDiffTool.fileMergeBundleIdentifier ? path : nil }
    }

    @Test("installed returns only tools with an installed launcher, in preference order")
    func installedFiltersAndOrders() {
        // FileMerge + BBEdit present, Kaleidoscope absent.
        let installed = ExternalDiffTool.installed(
            locateBundle: bundles(fileMergeAt: Self.xcodeFileMerge),
            where: probe(installed: [Self.xcodeOpendiff, "/usr/local/bin/bbdiff"])
        )
        #expect(installed.map(\.identifier) == ["bbedit", "filemerge"])
    }

    @Test("FileMerge launches the opendiff in the Xcode that holds it")
    func fileMergeUsesXcodesOwnOpendiff() {
        let tool = ExternalDiffTool.fileMerge(locateBundle: bundles(
            fileMergeAt: "/Users/me/Applications/Xcode-beta.app/Contents/Applications/FileMerge.app"
        ))
        #expect(tool.candidateExecutablePaths == [
            "/Users/me/Applications/Xcode-beta.app/Contents/Developer/usr/bin/opendiff"
        ])
    }

    /// The case M31 Slice 4 fixed: `/usr/bin/opendiff` is a shim on every Mac, and with only the
    /// Command Line Tools it exits 1 with "tool 'opendiff' requires Xcode".
    @Test("FileMerge is not installed on a Mac with the opendiff shim and no Xcode")
    func shimAloneIsNotFileMerge() {
        let shimOnly = probe(installed: ["/usr/bin/opendiff"])
        let installed = ExternalDiffTool.installed(
            locateBundle: bundles(fileMergeAt: nil),
            where: shimOnly
        )
        #expect(installed.isEmpty)
        #expect(CompareTool.preferred(identifier: "filemerge", installed: installed) == .dirnex)
    }

    @Test("FileMerge found outside an Xcode, with no opendiff beside it, is not installed")
    func fileMergeWithoutItsXcodeIsNotInstalled() {
        let installed = ExternalDiffTool.installed(
            locateBundle: bundles(fileMergeAt: "/Applications/FileMerge.app"),
            where: probe(installed: ["/usr/bin/opendiff", Self.xcodeOpendiff])
        )
        #expect(installed.isEmpty)
    }

    @Test("the known registry has unique identifiers, Dirnex's among them, and absolute paths")
    func registryIsWellFormed() {
        let known = ExternalDiffTool.known(locateBundle: bundles(fileMergeAt: Self.xcodeFileMerge))
        let identifiers = known.map(\.identifier) + [CompareTool.dirnexIdentifier]
        #expect(Set(identifiers).count == identifiers.count)
        for tool in known {
            #expect(!tool.candidateExecutablePaths.isEmpty)
            #expect(!tool.displayName.isEmpty)
            #expect(tool.candidateExecutablePaths.allSatisfy { $0.hasPrefix("/") })
        }
    }
}

@Suite("CompareTool")
struct CompareToolTests {
    @Test("an installed preference wins, else the first installed tool")
    func preferredHonorsChoice() {
        let installed: [ExternalDiffTool] = [.kaleidoscope, .bbEdit]
        // Explicit, installed preference wins even though Kaleidoscope ranks higher.
        #expect(
            CompareTool.preferred(identifier: "bbedit", installed: installed) == .external(.bbEdit)
        )
        // No preference → the highest-ranked installed tool.
        #expect(
            CompareTool.preferred(identifier: nil, installed: installed) == .external(.kaleidoscope)
        )
        #expect(
            CompareTool.preferred(identifier: "", installed: installed) == .external(.kaleidoscope)
        )
    }

    @Test("a chosen tool that is no longer installed falls back to automatic")
    func preferredFallsBackWhenChosenMissing() {
        #expect(
            CompareTool.preferred(identifier: "kaleidoscope", installed: [.bbEdit]) == .external(
                .bbEdit
            )
        )
    }

    @Test("Dirnex is automatic only when nothing is installed")
    func dirnexIsTheLastResort() {
        #expect(CompareTool.preferred(identifier: nil, installed: []) == .dirnex)
        #expect(CompareTool.preferred(identifier: "bbedit", installed: []) == .dirnex)
        #expect(CompareTool.preferred(identifier: nil, installed: [.bbEdit]) != .dirnex)
    }

    @Test("Dirnex chosen in Settings wins over every installed tool")
    func dirnexChosenWins() {
        let installed: [ExternalDiffTool] = [.kaleidoscope, .bbEdit]
        #expect(CompareTool.preferred(identifier: "dirnex", installed: installed) == .dirnex)
    }

    @Test("Settings offers Dirnex first, then the installed tools in order")
    func choicesPutDirnexFirst() {
        #expect(CompareTool.choices(installed: [.kaleidoscope, .bbEdit]).map(\.identifier)
            == ["dirnex", "kaleidoscope", "bbedit"])
        #expect(CompareTool.choices(installed: []) == [.dirnex])
        #expect(CompareTool.dirnex.displayName == "Dirnex")
    }
}
