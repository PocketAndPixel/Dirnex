import AppKit
import Testing

@testable import Dirnex

@Suite("Test host lifecycle")
@MainActor
struct TestHostLifecycleTests {
    @Test("the test host does not install the production app delegate")
    func skipsNormalAppLifecycle() {
        // Inspect the running host, not a helper's answer. The delegate is installed before
        // application.run(), so this does not depend on launch notifications finishing.
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        #expect(!(NSApp.delegate is AppDelegate))
    }
}
