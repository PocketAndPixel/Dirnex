import Foundation
import Testing

@testable import DirnexCore

@Suite("Workspaces")
struct WorkspacesTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    private func pane(_ paths: [String], active: Int = 0) -> WorkspacePane {
        WorkspacePane(tabs: paths.map { WorkspaceTab(path: path($0)) }, activeTabIndex: active)
    }

    private func workspace(
        _ name: String,
        left: [String] = ["/l"],
        right: [String] = ["/r"]
    ) -> Workspace {
        Workspace(name: name, left: pane(left), right: pane(right))
    }

    // MARK: - WorkspaceTab / WorkspacePane

    @Test("a tab defaults to the default sort")
    func tabDefaultSort() {
        #expect(WorkspaceTab(path: path("/a")).sort == .default)
    }

    @Test("a pane clamps its active index into range")
    func paneClampsActiveIndex() {
        #expect(pane(["/a", "/b", "/c"], active: 9).activeTabIndex == 2)
        #expect(pane(["/a", "/b", "/c"], active: -3).activeTabIndex == 0)
        #expect(pane([], active: 4).activeTabIndex == 0)
    }

    @Test("decoding re-clamps a stored active index and defaults a missing one")
    func paneDecodeClamps() throws {
        let tabs = [WorkspaceTab(path: path("/a")), WorkspaceTab(path: path("/b"))]
        let tabsJSON = String(data: try JSONEncoder().encode(tabs), encoding: .utf8)!
        let overshoot = try JSONDecoder().decode(
            WorkspacePane.self,
            from: Data("{\"tabs\":\(tabsJSON),\"activeTabIndex\":9}".utf8)
        )
        #expect(overshoot.activeTabIndex == 1)

        let missing = try JSONDecoder().decode(
            WorkspacePane.self,
            from: Data("{\"tabs\":\(tabsJSON)}".utf8)
        )
        #expect(missing.activeTabIndex == 0)
    }

    // MARK: - Collection

    @Test("a fresh collection is empty")
    func startsEmpty() {
        #expect(Workspaces().workspaces.isEmpty)
    }

    @Test("save appends a new name and reports it did not replace")
    func saveAppends() {
        var workspaces = Workspaces()
        // Hoist mutating results into a `let`: the #expect macro captures its receiver as
        // immutable, so a `mutating` call can't be evaluated inside it.
        let replacedFirst = workspaces.save(workspace("Work"))
        let replacedSecond = workspaces.save(workspace("Play"))
        #expect(!replacedFirst)
        #expect(!replacedSecond)
        #expect(workspaces.workspaces.map(\.name) == ["Work", "Play"])
    }

    @Test("saving an existing name overwrites in place and reports the replacement")
    func saveOverwritesInPlace() {
        var workspaces = Workspaces()
        workspaces.save(workspace("Work", left: ["/old"]))
        workspaces.save(workspace("Play"))

        let replaced = workspaces.save(workspace("Work", left: ["/new"]))
        #expect(replaced)
        // Position is preserved (still first), and the payload is the new one.
        #expect(workspaces.workspaces.map(\.name) == ["Work", "Play"])
        #expect(workspaces.workspace(named: "Work")?.left.tabs.first?.path == path("/new"))
    }

    @Test("lookup by name finds the workspace or nil")
    func lookupByName() {
        var workspaces = Workspaces()
        workspaces.save(workspace("Work"))
        #expect(workspaces.contains(name: "Work"))
        #expect(workspaces.workspace(named: "Work")?.name == "Work")
        #expect(!workspaces.contains(name: "Missing"))
        #expect(workspaces.workspace(named: "Missing") == nil)
    }

    @Test("remove by name and by index")
    func remove() {
        var workspaces = Workspaces(workspaces: [workspace("A"), workspace("B"), workspace("C")])
        // Hoist mutating results out of #expect (its receiver is captured immutable).
        let removed = workspaces.remove(name: "B")
        #expect(removed)
        #expect(workspaces.workspaces.map(\.name) == ["A", "C"])
        let removedAgain = workspaces.remove(name: "B")
        #expect(!removedAgain)

        workspaces.remove(at: 0)
        #expect(workspaces.workspaces.map(\.name) == ["C"])
        workspaces.remove(at: 9) // no crash, no change
        #expect(workspaces.workspaces.map(\.name) == ["C"])
    }

    @Test("rename applies, but rejects empty, collisions, and unknown names")
    func rename() {
        var workspaces = Workspaces(workspaces: [workspace("A"), workspace("B")])

        let renamed = workspaces.rename(name: "A", to: "Alpha")
        #expect(renamed)
        #expect(workspaces.workspaces.map(\.name) == ["Alpha", "B"])

        // Renaming onto another workspace's name is rejected so two never collapse into one.
        let collided = workspaces.rename(name: "B", to: "Alpha")
        #expect(!collided)
        #expect(workspaces.workspaces.map(\.name) == ["Alpha", "B"])

        let emptied = workspaces.rename(name: "Alpha", to: "")
        #expect(!emptied) // empty rejected
        let unknown = workspaces.rename(name: "Missing", to: "X")
        #expect(!unknown) // unknown rejected
        let sameName = workspaces.rename(name: "B", to: "B")
        #expect(sameName) // same-name no-op succeeds
        #expect(workspaces.workspaces.map(\.name) == ["Alpha", "B"])
    }

    @Test("move reorders using resulting-array semantics")
    func moveReorders() {
        func fresh() -> Workspaces {
            Workspaces(workspaces: [workspace("A"), workspace("B"), workspace("C")])
        }

        var toEnd = fresh()
        toEnd.move(from: 0, to: 2)
        #expect(toEnd.workspaces.map(\.name) == ["B", "C", "A"])

        var toStart = fresh()
        toStart.move(from: 2, to: 0)
        #expect(toStart.workspaces.map(\.name) == ["C", "A", "B"])

        var outOfRange = fresh()
        outOfRange.move(from: 5, to: 0) // ignored
        #expect(outOfRange.workspaces.map(\.name) == ["A", "B", "C"])
    }

    // MARK: - Codable

    @Test("Codable round-trips both panes, tabs, sort, and active index")
    func codableRoundTrips() throws {
        let byDate = FileSort(key: .modified, ascending: false)
        let original = Workspaces(workspaces: [
            Workspace(
                name: "Work",
                left: WorkspacePane(
                    tabs: [
                        WorkspaceTab(path: path("/Users/me/Projects"), sort: byDate),
                        WorkspaceTab(path: path("/Users/me/Downloads"))
                    ],
                    activeTabIndex: 1
                ),
                right: pane(["/tmp"])
            )
        ])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Workspaces.self, from: data)
        #expect(restored == original)
        #expect(restored.workspace(named: "Work")?.left.tabs.first?.sort.key == .modified)
    }

    @Test("initializer and decoding both collapse duplicate names")
    func duplicatesCollapseOnLoad() throws {
        let withDupes = [
            workspace("Dup", left: ["/first"]),
            workspace("Dup", left: ["/second"]),
            workspace("Other")
        ]
        let workspaces = Workspaces(workspaces: withDupes)
        #expect(workspaces.workspaces.map(\.name) == ["Dup", "Other"])
        #expect(workspaces.workspace(named: "Dup")?.left.tabs.first?.path == path("/first"))

        // A store that somehow serialized duplicate names is sanitized when decoded.
        let json = try JSONEncoder().encode(["workspaces": withDupes])
        let decoded = try JSONDecoder().decode(Workspaces.self, from: json)
        #expect(decoded.workspaces.map(\.name) == ["Dup", "Other"])
    }
}
