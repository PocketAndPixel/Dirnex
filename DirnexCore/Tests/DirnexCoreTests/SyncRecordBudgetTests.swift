import Foundation
import Testing

@testable import DirnexCore

/// What the sync records keep when they cannot keep everything (PLAN.md §M37 Slice 7).
@Suite("SyncRecordBudget")
struct SyncRecordBudgetTests {
    private func held(_ size: Int64, at time: TimeInterval, id: Int = 0) -> SyncRecordBudget.Held {
        let name = String(format: "00000000-0000-0000-0000-%012d", id)
        return .init(
            file: UUID(uuidString: name) ?? UUID(),
            byteSize: size,
            keptAt: Date(timeIntervalSince1970: time)
        )
    }

    @Test("a file that does not fit is passed over, and smaller ones after it are still taken")
    func admission() {
        let budget = SyncRecordBudget(bytes: 10)
        #expect(budget.admitted([6, 6, 4]) == [true, false, true])
        #expect(budget.admitted([10, 0, 1]) == [true, true, false])
        #expect(budget.admitted([11]) == [false])
        #expect(budget.admitted([]).isEmpty)
    }

    @Test("a budget cannot be negative, and of none only empty files fit")
    func noBudget() {
        let budget = SyncRecordBudget(bytes: -5)
        #expect(budget.bytes == 0)
        #expect(budget.admitted([0, 1]) == [true, false])
    }

    @Test("nothing goes while everything fits, exactly at the edge included")
    func fits() {
        let budget = SyncRecordBudget(bytes: 10)
        #expect(budget.evictions(held: [held(6, at: 1)], incoming: 4).isEmpty)
        #expect(budget.evictions(held: [], incoming: 10).isEmpty)
    }

    @Test("the oldest goes first, and only as many as it takes")
    func oldestFirst() {
        let budget = SyncRecordBudget(bytes: 10)
        let old = held(4, at: 1, id: 1)
        let middle = held(4, at: 2, id: 2)
        let new = held(2, at: 3, id: 3)
        #expect(budget.evictions(held: [new, old, middle], incoming: 3) == [old.file])
        #expect(budget.evictions(held: [middle, new, old], incoming: 5) == [old.file, middle.file])
        #expect(budget.evictions(held: [middle, new, old], incoming: 10)
            == [old.file, middle.file, new.file])
    }

    @Test("versions kept together go in one order, however they were listed")
    func tiesAreSettled() {
        let budget = SyncRecordBudget(bytes: 4)
        let versions = (1...8).map { held(2, at: 7, id: $0) }
        let expected = versions.prefix(6).map(\.file)
        var rng = SeededGenerator(seed: 0x0037_0701)
        for _ in 0..<50 {
            #expect(budget.evictions(held: versions.shuffled(using: &rng), incoming: 0) == expected)
        }
    }
}
