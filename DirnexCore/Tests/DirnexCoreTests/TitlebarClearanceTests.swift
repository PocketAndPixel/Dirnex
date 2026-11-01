import Foundation
import Testing

@testable import DirnexCore

/// How far a tab strip stays clear of the title bar's controls.
///
/// Every window here is 1300 wide, with controls reaching 118 in from the left, as the traffic lights
/// and the sidebar toggle do, and 100 in from the right. A strip sits 8 inside its pane.
@Suite("TitlebarClearance")
struct TitlebarClearanceTests {
    private let controls = TitlebarClearance.Controls(fromLeft: 118, fromRight: 100)

    private func clearance(
        from minX: Double,
        to maxX: Double,
        controls: TitlebarClearance.Controls? = nil
    ) -> TitlebarClearance {
        TitlebarClearance(
            stripMinX: minX,
            stripMaxX: maxX,
            windowWidth: 1300,
            controls: controls ?? self.controls
        )
    }

    @Test("with the sidebar open the left strip starts past every control")
    func sidebarOpen() {
        #expect(clearance(from: 158, to: 700) == .none)
    }

    @Test("with the sidebar closed the left strip starts under the controls")
    func sidebarClosed() {
        #expect(clearance(from: 8, to: 640) == TitlebarClearance(leading: 110, trailing: 0))
    }

    @Test("half way through the sidebar's animation only what is still covered is cleared")
    func sidebarMoving() {
        #expect(clearance(from: 60, to: 660).leading == 58)
        #expect(clearance(from: 118, to: 660).leading == 0)
    }

    @Test("the right strip stops short of the controls at the window's right edge")
    func rightStrip() {
        #expect(clearance(from: 660, to: 1292) == TitlebarClearance(leading: 0, trailing: 92))
    }

    @Test("with nothing at the right edge the right strip runs to its end")
    func rightEdgeEmpty() {
        let bare = TitlebarClearance.Controls(fromLeft: 118, fromRight: 0)
        #expect(clearance(from: 660, to: 1292, controls: bare) == .none)
    }

    @Test("in full screen there is nothing to clear, wherever the strip is")
    func fullScreen() {
        #expect(clearance(from: 8, to: 640, controls: TitlebarClearance.Controls.none) == .none)
        #expect(clearance(from: 660, to: 1292, controls: TitlebarClearance.Controls.none) == .none)
    }
}
