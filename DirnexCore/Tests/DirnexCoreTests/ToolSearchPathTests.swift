import Foundation
import Testing

@testable import DirnexCore

@Suite("ToolSearchPath")
struct ToolSearchPathTests {
    private let home = "/Users/someone"

    /// A throwaway `/etc` holding `paths` (when given) and the named `paths.d` files.
    private func makeRoot(paths: String?, pathsD: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-etc-\(UUID().uuidString)", isDirectory: true)
        let pathsDirectory = root.appendingPathComponent("paths.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pathsDirectory,
            withIntermediateDirectories: true
        )
        if let paths {
            try Data(paths.utf8).write(to: root.appendingPathComponent("paths"))
        }
        for (name, text) in pathsD {
            try Data(text.utf8).write(to: pathsDirectory.appendingPathComponent(name))
        }
        return root
    }

    // MARK: - One file

    @Test("a paths file names one directory per line, trimmed, with blank lines skipped")
    func parsesLines() {
        let text = "/usr/local/bin\n\n  /opt/tools/bin \t\n\r\n/last/without/newline"
        #expect(ToolSearchPath.directories(inPathsFile: text, home: home) == [
            "/usr/local/bin", "/opt/tools/bin", "/last/without/newline"
        ])
    }

    @Test("a leading tilde is expanded against home, and a ~user entry is skipped")
    func expandsTilde() {
        let text = "~/.dotnet/tools\n~\n~other/bin\n"
        #expect(ToolSearchPath.directories(inPathsFile: text, home: home) == [
            "/Users/someone/.dotnet/tools", "/Users/someone"
        ])
    }

    @Test("a relative entry, or one holding a colon, is never put on PATH")
    func skipsEntriesThatAreNotOneAbsoluteDirectory() {
        let text = "bin\n./tools\n# a comment\n/a:/b\n/kept\n"
        #expect(ToolSearchPath.directories(inPathsFile: text, home: home) == ["/kept"])
    }

    // MARK: - The whole list

    @Test("paths comes first, then paths.d in byte order of the file names")
    func readsInPathHelperOrder() throws {
        // Byte order puts `10-` before `100-` and `Zeta` before `dotnet`. A numeric or
        // case-insensitive comparison would order these differently.
        let root = try makeRoot(paths: "/usr/bin\n/bin\n", pathsD: [
            "dotnet-cli-tools": "/from/dotnet-cli-tools",
            "dotnet": "/from/dotnet\n",
            "Zeta": "/from/Zeta\n",
            "100-rvictl": "/from/100-rvictl\n",
            "10-pmk": "/from/10-pmk\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ToolSearchPath.systemDirectories(in: root, home: home) == [
            "/usr/bin", "/bin",
            "/from/10-pmk", "/from/100-rvictl", "/from/Zeta", "/from/dotnet",
            "/from/dotnet-cli-tools"
        ])
    }

    @Test("a directory named twice keeps its first place")
    func removesDuplicates() throws {
        let root = try makeRoot(paths: "/usr/bin\n/usr/local/bin\n", pathsD: [
            "a": "/usr/local/bin\n/opt/a\n",
            "b": "/opt/a\n/usr/bin\n/opt/b\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ToolSearchPath.systemDirectories(in: root, home: home) == [
            "/usr/bin", "/usr/local/bin", "/opt/a", "/opt/b"
        ])
    }

    @Test("dotfiles, folders and files that are not UTF-8 text in paths.d name nothing")
    func skipsWhatIsNotAPathsFile() throws {
        let root = try makeRoot(paths: nil, pathsD: [
            ".DS_Store": "/from/dotfile\n",
            "kept": "/from/kept\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let pathsDirectory = root.appendingPathComponent("paths.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pathsDirectory.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: false
        )
        try Data([0x2F, 0x6F, 0x70, 0x74, 0xFF, 0xFE, 0x0A])
            .write(to: pathsDirectory.appendingPathComponent("binary"))

        #expect(ToolSearchPath.systemDirectories(in: root, home: home) == ["/from/kept"])
    }

    @Test("a root without paths or paths.d names nothing")
    func emptyRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-no-etc-\(UUID().uuidString)", isDirectory: true)
        #expect(ToolSearchPath.systemDirectories(in: root, home: home).isEmpty)
    }

    @Test("agrees with path_helper on this Mac, apart from expanding a tilde")
    func agreesWithPathHelper() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/path_helper")
        process.arguments = ["-s"]
        // An empty PATH makes path_helper print only what the files name.
        process.environment = ["PATH": ""]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        process.waitUntilExit()

        // `PATH="/usr/local/bin:…"; export PATH;`
        let value = try #require(output?.split(separator: "\"").dropFirst().first)
        let home = NSHomeDirectory()
        let expected = value.split(separator: ":").map { entry in
            entry.hasPrefix("~/") ? home + entry.dropFirst() : String(entry)
        }
        #expect(ToolSearchPath.systemDirectories(home: home) == expected)
    }

    // MARK: - Widening

    @Test("the inherited PATH keeps its order, and only missing directories are appended")
    func widensWithoutReordering() {
        let widened = ToolSearchPath.widening(
            "/usr/local/bin:/usr/bin:/bin:/custom",
            adding: ["/usr/bin", "/usr/local/share/dotnet", "/opt/homebrew/bin"]
        )
        let directories = widened.split(separator: ":").map(String.init)
        #expect(Array(directories.prefix(4)) == ["/usr/local/bin", "/usr/bin", "/bin", "/custom"])
        // The fixed tool list comes before the system list, and nothing appears twice.
        #expect(directories == [
            "/usr/local/bin", "/usr/bin", "/bin", "/custom",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/sbin", "/usr/sbin", "/sbin",
            "/usr/local/share/dotnet"
        ])
    }

    @Test("with no inherited PATH, the result is the tool list and then the system list")
    func widensNothing() {
        #expect(ToolSearchPath.widening(nil, adding: ["/usr/local/share/dotnet"]) == (
            ToolSearchPath.toolDirectories + ["/usr/local/share/dotnet"]
        ).joined(separator: ":"))
    }
}
