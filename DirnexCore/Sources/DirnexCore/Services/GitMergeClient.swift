import Foundation

/// How `Dirnex --git-merge` reaches the app. The command holds a real socket and `/usr/bin/open`
/// behind this, and a test holds a script. Blocking.
public protocol GitMergeClientTransport {
    associatedtype Connection: GitMergeConnection

    /// Try the app's socket once.
    func connect() -> GitMergeConnectResult<Connection>
    /// Start the copy of the app this command belongs to, or bring it to the front if it is up.
    /// `false` when that could not be done.
    func openApp() -> Bool
    func sleep(seconds: Double)
    /// A clock that only moves forward, in seconds.
    func uptime() -> Double
}

public enum GitMergeConnectResult<Connection> {
    case connected(Connection)
    /// Nothing is listening: no socket yet, or one left by a copy that died.
    case notListening
    /// The socket could not be tried, with the system's reason.
    case failed(String)
}

/// The command's whole conversation with the app (PLAN.md §M37 Slice 6): reach it, launching it if
/// it is not up, send the request, and wait for the merge to end.
///
/// The words here are the command's own, in English like the rest of a terminal's tooling. A
/// refusal the app sends is in the app's language.
public enum GitMergeClient {
    /// How long a copy that was just launched gets to start listening. A first launch can sit behind
    /// Gatekeeper's check of the app.
    public static let launchWait = 60.0

    static let pollInterval = 0.05

    /// The environment for the app when this command starts it: a Dock launch's, not the shell's.
    ///
    /// `open` hands the app the environment of whoever ran it (measured 2026-11-09), and `git
    /// mergetool` runs its tool with `GIT_EXEC_PATH`, `GIT_EDITOR=true` and `GIT_PREFIX` set, and
    /// `GIT_DIR` when the user set it. The app outlives this one merge, so those would reach every
    /// `git` it runs and every shell its terminal drawer opens for the rest of the session. Only
    /// what a Dock launch has too is kept, with launchd's own `PATH`.
    public static func launchEnvironment(from environment: [String: String]) -> [String: String] {
        var kept = environment.filter { dockLaunchKeys.contains($0.key) }
        kept["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return kept
    }

    private static let dockLaunchKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"
    ]

    /// How the command ends: the status it exits with, and what it prints on standard error.
    public struct Finished: Sendable, Equatable {
        public let exitCode: Int32
        public let message: String?

        public init(exitCode: Int32, message: String?) {
            self.exitCode = exitCode
            self.message = message
        }

        static func failed(_ message: String) -> Finished {
            Finished(exitCode: 1, message: message)
        }
    }

    /// Run `request` to its end. Blocks for as long as the merge window is open.
    public static func run<Transport: GitMergeClientTransport>(
        _ request: GitMergeRequest,
        transport: Transport
    ) -> Finished {
        let connection: Transport.Connection
        switch reach(transport) {
        case let .success(reached):
            connection = reached
        case let .failure(problem):
            return .failed(problem.message)
        }
        do throws(GitMergeWire.Failure) {
            try GitMergeWire.send(request, over: connection)
            let answer = try GitMergeWire.receive(GitMergeAnswer.self, over: connection)
            return Finished(exitCode: answer.exitCode, message: answer.message)
        } catch {
            return .failed(sentence(for: error))
        }
    }

    private struct Problem: Error {
        let message: String
    }

    private static func sentence(for failure: GitMergeWire.Failure) -> String {
        switch failure {
        case .closed:
            // The app quit or crashed with the window open, so nothing says the result was saved.
            "Dirnex closed before the merge was finished."
        case .malformed:
            "Dirnex sent an answer that couldn't be read."
        case let .failed(reason):
            "Dirnex couldn't be reached: \(reason)"
        }
    }

    /// A connection to the app, launching it first when nothing is listening.
    private static func reach<Transport: GitMergeClientTransport>(
        _ transport: Transport
    ) -> Result<Transport.Connection, Problem> {
        switch transport.connect() {
        case let .connected(connection):
            // The app can't bring itself forward: on this macOS its own activate call does nothing
            // while another app is in front (measured 2026-11-09). A window it opened would sit
            // behind the terminal that is waiting for it. Not being able to is no reason to stop.
            _ = transport.openApp()
            return .success(connection)
        case let .failed(reason):
            return .failure(Problem(message: sentence(for: .failed(reason))))
        case .notListening:
            break
        }
        guard transport.openApp() else {
            return .failure(Problem(message: "Dirnex couldn't be started."))
        }
        let deadline = transport.uptime() + launchWait
        while transport.uptime() < deadline {
            switch transport.connect() {
            case let .connected(connection):
                return .success(connection)
            case let .failed(reason):
                return .failure(Problem(message: sentence(for: .failed(reason))))
            case .notListening:
                transport.sleep(seconds: pollInterval)
            }
        }
        return .failure(Problem(
            message: "Dirnex was started but didn't answer within \(Int(launchWait)) seconds."
        ))
    }
}
