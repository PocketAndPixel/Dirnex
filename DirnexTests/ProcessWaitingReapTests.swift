import Foundation
import Testing

@testable import Dirnex

/// `ProcessWaiting`'s reap, which replaced `Process.waitUntilExit()` at every spawn site
/// (PLAN.md §M22 ▸ FTP verification).
///
/// The thing under test is a *timing* property, which is normally the worst kind to pin — but this
/// one is unusually well behaved, because what it measures is the absence of a **timer** rather than
/// the presence of speed. `waitUntilExit()` costs a flat ≈71 ms on a child that exited long ago
/// (measured 70.1–72.5 ms over 8 runs), and a timer does not fire sooner on a faster machine, so the
/// bound below is not a stopwatch reading that CI can drift past: the shipped path takes
/// microseconds and the reverted one cannot beat its own poll interval however fast the host is.
@Suite("ProcessWaiting reaps without polling")
struct ProcessWaitingReapTests {
    /// A process that has been dead for a long time is reaped immediately.
    ///
    /// This is the discriminating case, and it is the one `waitUntilExit()` fails: with the child
    /// gone there is nothing left to wait *for*, so any cost is the polling itself.
    @Test("reaping a long-dead process costs nothing")
    func reapsAnAlreadyExitedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        try process.run()

        // Well past `waitUntilExit()`'s ≈71 ms interval, so the child is unambiguously gone and any
        // time the wait then takes belongs to the wait.
        Thread.sleep(forTimeInterval: 0.3)

        let start = Date()
        awaitExit()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.03, "reaping a dead process took \(Int(elapsed * 1000)) ms")
        #expect(process.terminationStatus == 0)
    }

    /// The reap does not merely return early — it returns *because the process was reaped*, which is
    /// the whole of what the call it replaced was being asked for. Reading `terminationStatus`
    /// before termination is a Foundation exception, so a readable non-zero status is the evidence.
    @Test("the reap is what makes the exit status readable")
    func reportsTheExitStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 7"]
        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        try process.run()
        awaitExit()

        #expect(process.terminationStatus == 7)
    }

    /// It waits for a child that is genuinely still working, rather than returning on its own
    /// schedule. The narrowness control for the test above: a reap that answered immediately in
    /// every case would pass that one and be useless.
    @Test("a running process is waited for")
    func waitsForWorkStillInFlight() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.4"]
        let awaitExit = ProcessWaiting.exitWaiter(for: process)

        let start = Date()
        try process.run()
        awaitExit()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.4)
        #expect(process.terminationStatus == 0)
    }

    /// The group spelling, which the three remote transports use so one wait covers the pipe drains
    /// *and* the reap — and which must still complete after a `terminate()`, since that is the path
    /// Stop and the timeout backstop both take.
    @Test("termination joins a group, and terminate still completes it")
    func joinsAGroupAndSurvivesTerminate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)
        try process.run()

        #expect(group.wait(timeout: .now() + .milliseconds(200)) == .timedOut)

        process.terminate()
        #expect(group.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(process.terminationStatus == SIGTERM)
    }
}
