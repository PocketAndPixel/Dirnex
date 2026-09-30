import AppKit
import DirnexCore
import Testing
@testable import Dirnex

/// Copy Path inside a browsed archive, from both of its entry points: the pane's right-click menu
/// and the path bar's crumb menu. Both used to copy `VFSPath.path`, which inside an archive is the
/// inner path, so the archive's own crumb and the empty space at its root copied `/` (reported
/// 2026-09-21). The rule itself is `CopyPathText`'s and is tested in the core; these pin that both
/// surfaces actually ask it, with the chain of the right mount.
@MainActor
@Suite("Copy Path inside an archive")
struct CopyPathReachTests {
    private let zip = "/Users/tester/Downloads/mvpn/openvpn-install.exe.zip"

    private func pane(at path: VFSPath, host: StubPanelHost = StubPanelHost()) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.host = host
        return pane
    }

    private func copied(by item: NSMenuItem) -> [String] {
        item.representedObject as? [String] ?? []
    }

    @Test("the pane copies an archive's root and members as paths through the archive file")
    func paneCopiesThroughTheArchive() {
        let root = VFSPath(backend: .archive(forArchiveAt: zip), path: "/")
        let pane = pane(at: root)

        #expect(copied(by: pane.copyPathItem(for: [root])) == [zip])
        #expect(
            copied(by: pane.copyPathItem(for: [root.appending("setup.exe"), root.appending("docs")]))
                == [zip + "/setup.exe", zip + "/docs"]
        )
    }

    /// The narrowness control: an ordinary row keeps the path it always copied.
    @Test("a local row still copies its own path")
    func localRowsAreUnchanged() {
        let directory = VFSPath.local("/Users/tester/Downloads")
        let pane = pane(at: directory)

        #expect(copied(by: pane.copyPathItem(for: [directory.appending("a.txt")]))
            == ["/Users/tester/Downloads/a.txt"])
    }

    /// Asked per location, so the chain is the member's own mount: a nested archive is browsed from
    /// a temp extraction, and that directory must not be what lands on the clipboard.
    @Test("a nested archive's member is copied through the member it came from")
    func nestedMembersFollowTheChain() {
        let extracted = "/tmp/dirnex-nested/inner.zip"
        let host = StubPanelHost()
        host.nestedArchiveRegistry.record(
            mountOnDiskPath: extracted,
            origin: VFSPath(backend: .archive(forArchiveAt: zip), path: "/sub/inner.zip")
        )
        let member = VFSPath(backend: .archive(forArchiveAt: extracted), path: "/notes.txt")
        let pane = pane(
            at: VFSPath(backend: .archive(forArchiveAt: extracted), path: "/"),
            host: host
        )

        #expect(copied(by: pane.copyPathItem(for: [member])) == [zip + "/sub/inner.zip/notes.txt"])
    }

    /// The `..` row's Copy Path copies where `..` leads. At an archive's root that is the folder
    /// holding the archive, which `panel.parentPath` (nil there) cannot answer.
    @Test("`..` at an archive's root leads to the archive's own folder, and inside it to the parent")
    func parentRowTarget() {
        let root = VFSPath(backend: .archive(forArchiveAt: zip), path: "/")
        let atRoot = pane(at: root)
        #expect(atRoot.archiveParent()?.destination == .local("/Users/tester/Downloads/mvpn"))
        #expect(atRoot.archiveParent()?.focus == .local(zip))

        let inside = pane(at: root.appending("docs"))
        #expect(inside.archiveParent()?.destination == root)

        #expect(pane(at: .local("/Users/tester")).archiveParent() == nil)
    }

    @Test("the path bar's archive crumb copies the archive file, and an inner crumb its full path")
    func crumbMenusCopyThroughTheArchive() {
        let bar = PathBarView()
        bar.setPath(VFSPath(backend: .archive(forArchiveAt: zip), path: "/docs"))

        let byTitle = Dictionary(
            bar.crumbStack.arrangedSubviews.compactMap { $0 as? NSButton }.map { button in
                (button.title, button.menu?.items.first?.representedObject as? String)
            },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byTitle["openvpn-install.exe.zip"] == zip)
        #expect(byTitle["docs"] == zip + "/docs")
        // A local ancestor crumb is untouched.
        #expect(byTitle["mvpn"] == "/Users/tester/Downloads/mvpn")
    }

    /// A crumb in an *outer* frame of a nested chain copies only the part of the chain above it.
    @Test("a nested trail's outer crumbs copy their own frame's path")
    func nestedCrumbs() {
        let extracted = "/tmp/dirnex-nested/inner.zip"
        let bar = PathBarView()
        bar.setPath(
            VFSPath(backend: .archive(forArchiveAt: extracted), path: "/deep"),
            archiveAncestry: [VFSPath(backend: .archive(forArchiveAt: zip), path: "/sub/inner.zip")]
        )

        let copies = bar.crumbStack.arrangedSubviews.compactMap { $0 as? NSButton }
            .compactMap { $0.menu?.items.first?.representedObject as? String }
        #expect(Array(copies.suffix(4)) == [
            zip,
            zip + "/sub",
            zip + "/sub/inner.zip",
            zip + "/sub/inner.zip/deep"
        ])
    }
}
