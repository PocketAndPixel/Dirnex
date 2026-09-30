import Testing

@MainActor
@Suite("Waiting for a gesture")
struct GestureWaitTests {
    /// A delayed main-actor resume can reach the deadline after the gesture has already finished.
    /// A zero budget checks that boundary without blocking the main actor or relying on timing.
    @Test("a completed gesture succeeds even when its wait budget is spent")
    func completedAtDeadline() async throws {
        try await settleUntil(within: .zero) { true }
    }

    @Test("a gesture that never completes reports a timeout at its caller")
    func missingCompletionTimesOut() async throws {
        let location = #_sourceLocation
        try await withKnownIssue("The missing completion must report a timeout") {
            try await settleUntil(within: .zero, sourceLocation: location) { false }
        } matching: { issue in
            issue.sourceLocation == location
        }
    }
}
