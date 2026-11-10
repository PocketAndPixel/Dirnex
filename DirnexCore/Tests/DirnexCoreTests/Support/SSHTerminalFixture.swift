import Foundation
import Testing

@testable import DirnexCore

/// Runs the scripts Open in Terminal writes through a real `/bin/sh`, with a stand-in for `ssh` that
/// writes down what it was given. What the shell actually hands over is the question, since the
/// script is quoted text and only a shell can say what it means.
struct SSHTerminalFixture {
    let directory: String

    init() throws {
        directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("SSHTerminalFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try Self.writeExecutable(Self.standIn, to: standInPath)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    var standInPath: String { path("ssh-stand-in") }

    func path(_ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    /// Make the script at `scriptPath` run the stand-in rather than the real `ssh`.
    func substituteStandIn(in scriptPath: String) throws {
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let quotedReal = SSHShellQuote.quote(SSHTerminalSession.sshPath)
        #expect(script.contains(quotedReal))
        try script.replacingOccurrences(of: quotedReal, with: SSHShellQuote.quote(standInPath))
            .write(toFile: scriptPath, atomically: false, encoding: .utf8)
    }

    /// Write `text` as a script and run it through the stand-in.
    func scriptFile(_ text: String) throws -> String {
        let scriptPath = path("session-\(UUID().uuidString).command")
        try Self.writeExecutable(text, to: scriptPath)
        try substituteStandIn(in: scriptPath)
        return scriptPath
    }

    /// Run the script, with the stand-in ending in `standInStatus`.
    @discardableResult
    func run(_ scriptPath: String, standInStatus: Int32 = 0) throws -> (
        status: Int32,
        output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "RECORD": directory,
            "STAND_IN_STATUS": String(standInStatus)
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // At end-of-file at once, so the pause after a failure answers immediately.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    /// The argument vector the stand-in received.
    func recordedArguments() throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path("argv")))
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(bytes: $0, encoding: .utf8) ?? "" }
    }

    /// What the stand-in wrote to `name`: `askpass`, `require` or `answer`.
    func recorded(_ name: String) throws -> String {
        try String(contentsOfFile: path(name), encoding: .utf8)
    }

    private static func writeExecutable(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private static let standIn = #"""
    #!/bin/sh
    : > "$RECORD/argv"
    for argument in "$@"; do printf '%s\0' "$argument" >> "$RECORD/argv"; done
    printf '%s' "${SSH_ASKPASS-unset}" > "$RECORD/askpass"
    printf '%s' "${SSH_ASKPASS_REQUIRE-unset}" > "$RECORD/require"
    if [ -n "${SSH_ASKPASS-}" ]; then "$SSH_ASKPASS" > "$RECORD/answer"; fi
    exit "$STAND_IN_STATUS"
    """#
}
