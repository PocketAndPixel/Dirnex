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
        let invocation = ExternalDiffTool.fileMerge.invocation(
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

    @Test("installed returns only tools with an installed launcher, in preference order")
    func installedFiltersAndOrders() {
        // FileMerge + BBEdit present, Kaleidoscope absent.
        let installed = ExternalDiffTool.installed(
            where: probe(installed: ["/usr/bin/opendiff", "/usr/local/bin/bbdiff"])
        )
        #expect(installed.map(\.identifier) == ["bbedit", "filemerge"])
    }

    @Test("preferred honors an installed preference, else falls back to the first installed")
    func preferredHonorsChoice() {
        let all = probe(installed: [
            "/usr/bin/opendiff", "/usr/local/bin/bbdiff", "/opt/homebrew/bin/ksdiff"
        ])
        // Explicit, installed preference wins even though Kaleidoscope ranks higher.
        #expect(ExternalDiffTool.preferred(identifier: "bbedit", where: all)?.identifier == "bbedit")
        // No preference → the highest-ranked installed tool (Kaleidoscope).
        #expect(ExternalDiffTool.preferred(where: all)?.identifier == "kaleidoscope")
    }

    @Test("preferred falls back when the chosen tool is not installed")
    func preferredFallsBackWhenChosenMissing() {
        let onlyFileMerge = probe(installed: ["/usr/bin/opendiff"])
        // Kaleidoscope requested but not installed → fall back to the only installed tool.
        #expect(
            ExternalDiffTool.preferred(identifier: "kaleidoscope", where: onlyFileMerge)?.identifier
                == "filemerge"
        )
    }

    @Test("preferred is nil when nothing is installed")
    func preferredNilWhenNoneInstalled() {
        #expect(ExternalDiffTool.preferred(where: probe(installed: [])) == nil)
        #expect(ExternalDiffTool.installed(where: probe(installed: [])).isEmpty)
    }

    @Test("the known registry has unique identifiers and non-empty candidate paths")
    func registryIsWellFormed() {
        let identifiers = ExternalDiffTool.known.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
        for tool in ExternalDiffTool.known {
            #expect(!tool.candidateExecutablePaths.isEmpty)
            #expect(!tool.displayName.isEmpty)
            #expect(tool.candidateExecutablePaths.allSatisfy { $0.hasPrefix("/") })
        }
    }
}
