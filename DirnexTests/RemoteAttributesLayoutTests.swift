import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// How tall the remote Get Info panel's body is.
///
/// The panel shipped with its scrolling body squeezed to nothing — a header, an empty band and the
/// buttons, every row laid out but scrolled out of sight — and nothing caught it, because the other
/// suites ask which rows the panel builds, not whether any of them can be seen. The observable here
/// is the scroll view's own laid-out height against its content's, with no window presented: laying
/// the view out is enough, and a real window in the test host destabilizes its neighbours
/// (docs/NOTES.md ▸ Testing).
@Suite("Remote Get Info layout")
@MainActor
struct RemoteAttributesLayoutTests {
    private func entry(on backend: VFSBackendID, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: "/home/oleg/report.txt"),
            name: "report.txt",
            kind: kind,
            byteSize: 10,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            ownerName: "oleg",
            groupName: "wheel",
            inode: 0,
            symlinkDestination: kind == .symlink ? "/etc/hosts" : nil
        )
    }

    private struct Measured {
        let body: NSScrollView
        let content: NSView
        let panel: NSView
    }

    /// The laid-out body and its content, for a panel built the way the app builds it.
    private func measure(
        _ entry: FileEntry,
        editability: RemoteAttributeEditability
    ) throws -> Measured {
        let controller = RemoteAttributesController(
            entry: entry,
            backend: LocalBackend(),
            editability: editability
        )
        controller.loadViewIfNeeded()
        let panel = controller.view
        panel.setFrameSize(panel.fittingSize)
        panel.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let body = try #require(all(panel).lazy.compactMap { $0 as? NSScrollView }.first)
        let content = try #require(body.documentView)
        return Measured(body: body, content: content, panel: panel)
    }

    @Test(
        "the body is as tall as its content, for every shape of the panel",
        arguments: [
            ("sftp, mode editable", true),
            ("sftp, read-only", false)
        ]
    )
    func bodyShowsItsContent(label: String, editable: Bool) throws {
        let sftp = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))
        let measured = try measure(
            entry(on: sftp),
            editability: editable ? RemoteAttributeEditability(editable: [.permissions]) : .readOnly
        )
        #expect(measured.content.frame.height > 100)
        #expect(measured.body.frame.height == measured.content.frame.height)
    }

    @Test("an FTP panel with both fields editable, and a symlink's, show all of their rows too")
    func tallerShapesShowTheirContent() throws {
        let ftp = VFSBackendID.ftp(FTPLocation(host: "srv", username: "oleg"))
        let sftp = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))
        let shapes: [(FileEntry, RemoteAttributeEditability)] = [
            (entry(on: ftp), RemoteAttributeEditability(editable: [.permissions, .modificationTime])),
            (entry(on: sftp, kind: .symlink), .readOnly)
        ]
        for (entry, editability) in shapes {
            let measured = try measure(entry, editability: editability)
            #expect(measured.body.frame.height == measured.content.frame.height)
            #expect(measured.panel.frame.height <= AttributesControllerLayout.sheetHeight)
        }
    }

    /// No shape reaches the cap in English — values truncate to one line and only the notes wrap — so
    /// the content is made taller than any translation could by adding a block to it, which is what
    /// a long language does to the notes.
    @Test("content taller than the local Get Info scrolls instead of growing the panel")
    func tallContentScrolls() throws {
        let sftp = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))
        let controller = RemoteAttributesController(
            entry: entry(on: sftp),
            backend: LocalBackend(),
            editability: .readOnly
        )
        controller.loadViewIfNeeded()
        let panel = controller.view
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let body = try #require(all(panel).lazy.compactMap { $0 as? NSScrollView }.first)
        let rows = try #require(body.documentView?.subviews.first as? NSStackView)
        let block = NSView()
        block.translatesAutoresizingMaskIntoConstraints = false
        block.heightAnchor.constraint(equalToConstant: 1_000).isActive = true
        rows.addArrangedSubview(block)

        panel.setFrameSize(panel.fittingSize)
        panel.layoutSubtreeIfNeeded()
        let content = try #require(body.documentView)
        #expect(content.frame.height > 1_000)
        #expect(panel.frame.height == AttributesControllerLayout.sheetHeight)
        #expect(body.frame.height < content.frame.height)
    }
}
