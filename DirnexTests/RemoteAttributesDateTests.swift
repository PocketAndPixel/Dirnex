import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The remote panel's date control on a stamp it was given exactly (2026-10-21).
///
/// FTP is the one connection whose modification time the panel edits (`MFMT`), and an `MLSD` stamp
/// may carry a fraction of a second: RFC 3659 allows `modify=20260101000000.250`, and the core's facts
/// parser keeps the `.250` (`FTPFactsParserTests`). So "nobody touched the date" has to be decided
/// against what the picker was **given**, the rule docs/NOTES.md ▸ ACLs and file attributes states
/// for the local panel, or a mode change would carry a date nobody edited along with it.
///
/// These run the real panel and its real picker, which on macOS 26.7.1 hands the stamp back exactly,
/// so they pin the behavior end to end. A picker coarser than the stamp can't be produced here; that
/// case is pinned against the rule itself in `RemoteAttributeEditTests`.
@Suite("Remote Get Info ▸ an untouched date")
@MainActor
struct RemoteAttributesDateTests {
    /// What `modify=20260101000000.250` reads as.
    private let stamp = Date(timeIntervalSince1970: 1_767_225_600.25)
    private let backendID = VFSBackendID.ftp(FTPLocation(host: "nas", username: "oleg"))

    private func entry(permissions: UInt16 = 0o644) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backendID, path: "/share/report.txt"),
            name: "report.txt",
            kind: .file,
            byteSize: 10,
            modificationDate: stamp,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: permissions,
            inode: 1
        )
    }

    private func panel() -> (RemoteAttributesController, WritingBackend) {
        let backend = WritingBackend(id: backendID, offers: .ftp)
        let controller = RemoteAttributesController(
            entry: entry(),
            backend: backend,
            editability: RemoteAttributeEditability.decide(
                for: entry(),
                capabilities: backend.editableMetadata(at: entry().path)
            )
        )
        controller.loadViewIfNeeded()
        return (controller, backend)
    }

    @Test("a panel opened on a fractional stamp has nothing to send")
    func untouchedFractionalStampSendsNothing() throws {
        let (controller, _) = panel()
        // The narrowness half: the date control is really there and editable, so an empty change is
        // not the answer of a panel that drew no picker.
        _ = try #require(controller.modificationPicker)
        #expect(controller.pendingChange.isEmpty)
    }

    @Test("a mode change sends the mode and leaves the date alone")
    func modeChangeCarriesNoDate() async throws {
        let (controller, backend) = panel()
        backend.landed = entry(permissions: 0o664)
        let write = try #require(controller.modeBoxes.first {
            $0.cls == .group && $0.access == .write
        })
        write.box.state = .on
        controller.editChanged(nil)
        #expect(controller.pendingChange.modificationTime == nil)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settleUntil { applied == 1 }
        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o664))]])
    }

    /// The negative control: without it, the two tests above pass for a panel that never sends a
    /// date at all.
    @Test("a date the user did change is sent")
    func editedDateIsSent() throws {
        let (controller, _) = panel()
        let picker = try #require(controller.modificationPicker)
        let edited = stamp.addingTimeInterval(86_400)
        picker.dateValue = edited
        controller.editChanged(nil)
        #expect(controller.pendingChange.modificationTime == edited)
    }
}
