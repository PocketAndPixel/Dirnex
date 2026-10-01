import Foundation
import Testing

@testable import DirnexCore

/// Holding back an update the key doesn't cover (PLAN.md §M29 Slice 5). What Sparkle does with each
/// answer was probed against Sparkle 2.9.4 (docs/NOTES.md ▸ Release pipeline); this pins the answers.
@Suite("UpdateCoverageGate")
struct UpdateCoverageGateTests {
    private let notice = UpdateCoverageNotice(
        until: LicenseDay(year: 2027, month: 3, day: 12),
        version: "1.4.0"
    )

    @Test(
        "an uncovered update: the probe goes on, a background check is held back silently, and the user is asked"
    )
    func uncoveredUpdate() {
        let gate = UpdateCoverageGate()
        #expect(gate.decision(notice: notice, build: "50", check: .probe) == .proceed)
        #expect(gate.decision(notice: notice, build: "50", check: .background) == .holdBack)
        #expect(gate.decision(notice: notice, build: "50", check: .userInitiated) == .notify(notice))
    }

    @Test("with no notice due, every check goes on")
    func noNotice() {
        let gate = UpdateCoverageGate()
        for check in UpdateCheckKind.allCases {
            #expect(gate.decision(notice: nil, build: "50", check: check) == .proceed)
        }
    }

    @Test("Update Anyway lets that build through every check, and only that build")
    func updateAnyway() {
        var gate = UpdateCoverageGate()
        gate.allow(build: "50")
        for check in UpdateCheckKind.allCases {
            #expect(gate.decision(notice: notice, build: "50", check: check) == .proceed)
        }
        // A newer release that came out meanwhile is a new question.
        #expect(gate.decision(notice: notice, build: "51", check: .background) == .holdBack)
        #expect(gate.decision(notice: notice, build: "51", check: .userInitiated) == .notify(notice))
    }

    @Test("no check kind is left unanswered: only the probe goes on without asking")
    func onlyTheProbeGoesOn() {
        let gate = UpdateCoverageGate()
        let passing = UpdateCheckKind.allCases.filter {
            gate.decision(notice: notice, build: "50", check: $0) == .proceed
        }
        #expect(passing == [.probe])
    }
}
