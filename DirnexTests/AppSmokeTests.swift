import Testing

/// App-target smoke tests.
///
/// Per PLAN.md §2 the app contains no file-manipulation logic, so the
/// interesting tests live in `DirnexCore`. This target exists so that
/// `xcodebuild test` on the app scheme is meaningful and green from M0 on;
/// M1 will add real UI/keyboard smoke coverage here.
@Suite("Dirnex app smoke")
struct AppSmokeTests {
    @Test("test target is wired up")
    func testTargetRuns() {
        #expect(Bool(true))
    }
}
