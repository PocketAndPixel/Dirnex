import Foundation
import Testing

@testable import DirnexCore

/// Which eject failures mean the volume is in use, and what the processes holding it are called.
@Suite("VolumeUsers")
struct VolumeUsersTests {
    /// The chain the probe met on 2026-11-19: Terminal (an app, under launchd), the root-owned
    /// `login` it starts, and the shell under that. VLC and a `sleep` started by launchd beside it.
    let table: [Int32: VolumeUsers.Process] = [
        82891: .init(parent: 1, name: "Terminal", appName: "Terminal"),
        82897: .init(parent: 82891, name: "", appName: nil),
        82898: .init(parent: 82897, name: "bash", appName: nil),
        75032: .init(parent: 1, name: "VLC", appName: "VLC"),
        16283: .init(parent: 1, name: "sleep", appName: nil),
        1: .init(parent: 0, name: "launchd", appName: "launchd")
    ]

    func names(_ holders: [Int32]) -> [String] {
        VolumeUsers.names(of: holders) { table[$0] }
    }

    @Test("the busy status NSWorkspace throws, and EBUSY, mean in use; nothing else does")
    func inUse() {
        #expect(VolumeUsers.isInUse(NSError(domain: NSOSStatusErrorDomain, code: -47)))
        #expect(VolumeUsers.isInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))))
        #expect(!VolumeUsers.isInUse(NSError(domain: NSOSStatusErrorDomain, code: -36)))
        #expect(!VolumeUsers.isInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(!VolumeUsers.isInUse(NSError(domain: NSCocoaErrorDomain, code: -47)))
        #expect(!VolumeUsers.isInUse(CocoaError(.fileReadNoPermission)))
    }

    @Test("an app is named by its own name")
    func app() {
        #expect(names([75032]) == ["VLC"])
    }

    @Test("a shell is named by the app above it, through a parent with no name of its own")
    func shellInTerminal() {
        #expect(names([82898]) == ["Terminal"])
    }

    @Test("a process with no app above it keeps its own name, and launchd is never the answer")
    func noApp() {
        #expect(names([16283]) == ["sleep"])
    }

    @Test("each name appears once, first seen first")
    func order() {
        #expect(names([82898, 75032, 82891, 16283, 75032]) == ["Terminal", "VLC", "sleep"])
    }

    @Test("a pid that has exited, or a process with no name and no app, is left out")
    func unknown() {
        let nameless: [Int32: VolumeUsers.Process] = [500: .init(parent: 1, name: "", appName: nil)]
        #expect(VolumeUsers.names(of: [4242, 500]) { nameless[$0] } == [])
        #expect(names([]) == [])
    }

    @Test("a loop in the parents ends, and the holder keeps its own name")
    func cycle() {
        let looped: [Int32: VolumeUsers.Process] = [
            10: .init(parent: 11, name: "a", appName: nil),
            11: .init(parent: 10, name: "b", appName: nil)
        ]
        #expect(VolumeUsers.names(of: [10]) { looped[$0] } == ["a"])
    }

    @Test("an app further up than the walk goes is not reached")
    func depth() {
        var chain: [Int32: VolumeUsers.Process] = [2: .init(parent: 1, name: "Far", appName: "Far")]
        let depth = Int32(VolumeUsers.ancestryLimit)
        for pid in 3...depth + 2 {
            chain[pid] = .init(parent: pid - 1, name: "p\(pid)", appName: nil)
        }
        // The holder `depth + 1` is `depth - 1` steps from the app, inside the bound; one further
        // down is `depth` steps away, which the walk does not take.
        #expect(VolumeUsers.names(of: [depth + 1]) { chain[$0] } == ["Far"])
        #expect(VolumeUsers.names(of: [depth + 2]) { chain[$0] } == ["p\(depth + 2)"])
    }
}
