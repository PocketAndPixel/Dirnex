import Foundation
import Testing

@testable import DirnexCore

@Suite("ClosedTabs")
struct ClosedTabsTests {
    @Test("nothing to reopen before a tab is closed")
    func startsEmpty() {
        var closed = ClosedTabs<String>()
        #expect(closed.isEmpty)
        #expect(closed.popLast() == nil)
    }

    @Test("the last tab closed comes back first, with the pane and the place it left")
    func lastClosedComesBackFirst() {
        var closed = ClosedTabs<String>()
        closed.push("docs", from: .left, at: 2)
        closed.push("logs", from: .right, at: 0)

        let first = closed.popLast()
        #expect(first?.tab == "logs")
        #expect(first?.pane == .right)
        #expect(first?.slot == 0)
        #expect(closed.popLast()?.tab == "docs")
        #expect(closed.isEmpty)
    }

    @Test("past its capacity the oldest closed tab is let go of, and handed back")
    func capacityDropsTheOldest() {
        var closed = ClosedTabs<String>(capacity: 2)
        #expect(closed.push("one", from: .left, at: 0) == nil)
        #expect(closed.push("two", from: .left, at: 0) == nil)
        #expect(closed.push("three", from: .left, at: 0) == "one")
        #expect(closed.entries.map(\.tab) == ["two", "three"])
    }

    @Test("forgetting takes out only the tabs named, keeping the order of the rest")
    func forgetRemovesNamedTabs() {
        var closed = ClosedTabs<String>()
        closed.push("/Volumes/Vault/a", from: .left, at: 0)
        closed.push("/Users/me", from: .right, at: 1)
        closed.push("/Volumes/Vault/b", from: .left, at: 1)
        closed.forget { $0.hasPrefix("/Volumes/Vault") }
        #expect(closed.entries.map(\.tab) == ["/Users/me"])
    }

    @Test("a negative index is kept as the first slot")
    func negativeIndexIsTheFirstSlot() {
        var closed = ClosedTabs<String>()
        closed.push("tab", from: .left, at: -3)
        #expect(closed.popLast()?.slot == 0)
    }
}
