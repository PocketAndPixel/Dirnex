import Testing

/// Wait for an async gesture, allowing for main-actor delays in the full app suite.
/// Like the remote-fetch tests, allow 30 seconds; completed work returns on the next poll.
/// Check the result before the deadline so a late resume cannot reject work already completed.
/// Sleeping yields the main actor to callbacks; spinning the run loop does not.
@MainActor
func settleUntil(
    within: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + within
    while !predicate() {
        guard ContinuousClock.now < deadline else {
            Issue.record(
                "timed out waiting for the gesture to settle",
                sourceLocation: sourceLocation
            )
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
