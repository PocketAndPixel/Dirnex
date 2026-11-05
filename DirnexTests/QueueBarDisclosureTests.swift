import Foundation
import Testing

@testable import Dirnex

/// The queue bar's disclosure chevron names what a click will do, in its tooltip as well as its
/// accessibility label. Reported 2026-11-05: with the list expanded, the chevron pointed down but
/// the tooltip still read "Show operation details", because `configure` set the tooltip once at
/// build time and `refreshDisclosure` only swapped the image.
@MainActor
@Suite("Queue bar disclosure")
struct QueueBarDisclosureTests {
    private let show = String(
        localized: "Show operation details",
        comment: "Queue-bar disclosure button: reveal the per-operation list."
    )
    private let hide = String(
        localized: "Hide operation details",
        comment: "Queue-bar disclosure button: collapse the per-operation list."
    )

    @Test("the tooltip follows the chevron through expand and collapse")
    func toolTipFollowsState() {
        let bar = QueueBarView(frame: .init(x: 0, y: 0, width: 600, height: 64))
        #expect(bar.disclosureToolTip == show, "a collapsed bar offers to show")

        bar.clickDisclosure()
        #expect(bar.isExpanded, "the click reached the chevron's action")
        #expect(bar.disclosureToolTip == hide, "an expanded bar offers to hide")

        bar.clickDisclosure()
        #expect(!bar.isExpanded)
        #expect(bar.disclosureToolTip == show, "collapsing puts the first tooltip back")
    }
}
