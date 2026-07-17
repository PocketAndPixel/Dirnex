import Foundation
import Testing

@testable import DirnexCore

/// The pure half of the Full Disk Access onboarding (PLAN.md §M7). Every read is injected, so the
/// whole verdict machine is exercised without a real grant, a real disk, or System Settings.
@Suite("FullDiskAccess")
struct FullDiskAccessTests {
    // MARK: - The sentinels and the deep link

    @Test("the primary sentinel is the always-present, FDA-only TCC database")
    func primarySentinelIsTCCDatabase() {
        // Ordered most-reliably-present first: TCC.db exists on every account and is readable only
        // with the grant, so it must be the one the app tries before the may-not-exist app folders.
        #expect(
            FullDiskAccess.sentinelPaths.first == "Library/Application Support/com.apple.TCC/TCC.db"
        )
        #expect(FullDiskAccess.sentinelPaths.contains("Library/Mail"))
        #expect(!FullDiskAccess.sentinelPaths.isEmpty)
    }

    @Test("the System Settings deep link points at the Full Disk Access pane")
    func deepLinkAnchor() {
        // Pinned because a typo drops the user on the top of Privacy & Security with nothing
        // selected — a failure that still looks like it worked. `Privacy_AllFilesAccess` is the
        // stable anchor from the System Settings rewrite through macOS 26.
        #expect(
            FullDiskAccess.systemSettingsURLString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess"
        )
        // And it must actually parse as a URL the app can open.
        #expect(URL(string: FullDiskAccess.systemSettingsURLString) != nil)
    }

    // MARK: - Classifying a failed read

    @Test("permission errors — from Cocoa or POSIX — read as denied")
    func permissionErrorsMapToDenied() {
        // Probed live on macOS 26.5.2: a denied read is EPERM at the POSIX layer, which Foundation
        // surfaces as NSFileReadNoPermissionError. Both spellings, plus EACCES and the write twin,
        // must land on .permissionDenied or the check would miss the very signal it exists for.
        #expect(FullDiskAccess.outcome(domain: NSCocoaErrorDomain, code: 257) == .permissionDenied)
        #expect(FullDiskAccess.outcome(domain: NSCocoaErrorDomain, code: 513) == .permissionDenied)
        #expect(
            FullDiskAccess.outcome(domain: NSPOSIXErrorDomain, code: Int(EPERM)) == .permissionDenied
        )
        #expect(
            FullDiskAccess.outcome(domain: NSPOSIXErrorDomain, code: Int(EACCES)) == .permissionDenied
        )
    }

    @Test("a missing file reads as missing, not denied")
    func missingErrorsMapToMissing() {
        // The whole reason the fallback sentinels are fallbacks: a user who never ran Mail has no
        // ~/Library/Mail, and that absence must never be mistaken for a revoked grant.
        #expect(FullDiskAccess.outcome(domain: NSCocoaErrorDomain, code: 260) == .missing)
        #expect(FullDiskAccess.outcome(domain: NSCocoaErrorDomain, code: 4) == .missing)
        #expect(FullDiskAccess.outcome(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) == .missing)
    }

    @Test("an unrecognised code or foreign domain reads as other failure")
    func otherErrorsMapToOtherFailure() {
        #expect(FullDiskAccess.outcome(domain: NSCocoaErrorDomain, code: 999_999) == .otherFailure)
        #expect(FullDiskAccess.outcome(domain: NSURLErrorDomain, code: 257) == .otherFailure)
        #expect(
            FullDiskAccess.outcome(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) == .otherFailure
        )
    }

    // MARK: - Folding outcomes into a verdict

    @Test("any readable sentinel proves the grant is on")
    func oneReadableIsGranted() {
        // Even sitting behind two denied reads, a single readable settles it: we read a protected
        // file, so the access is real.
        let status = FullDiskAccess.status { path in
            path == FullDiskAccess.sentinelPaths.first ? .readable : .permissionDenied
        }
        #expect(status == .granted)
    }

    @Test("the readable sentinel short-circuits the rest")
    func grantedShortCircuits() {
        // The app should not read ~/Library/Mail once TCC.db has already answered. Recording which
        // paths the fold asks for proves it stops at the first readable.
        var asked: [String] = []
        let status = FullDiskAccess.status { path in
            asked.append(path)
            return .readable
        }
        #expect(status == .granted)
        #expect(asked == [FullDiskAccess.sentinelPaths.first])
    }

    @Test("a permission-denied read with nothing readable means denied")
    func deniedWhenNoReadable() {
        // TCC.db present but locked, every fallback absent — the textbook no-grant machine.
        let status = FullDiskAccess.status { path in
            path == FullDiskAccess.sentinelPaths.first ? .permissionDenied : .missing
        }
        #expect(status == .denied)
    }

    @Test("all-missing and all-other failures are unknown, never a guessed denial")
    func unknownWhenInconclusive() {
        #expect(FullDiskAccess.status { _ in .missing } == .unknown)
        #expect(FullDiskAccess.status { _ in .otherFailure } == .unknown)
        // A denial anywhere in the mix still outranks the inconclusive ones.
        let mixed = FullDiskAccess.status { path in
            path == "Library/Mail" ? .permissionDenied : .otherFailure
        }
        #expect(mixed == .denied)
    }

    @Test("only .granted reports the access is in place")
    func isGrantedMatchesTheCase() {
        for status in FullDiskAccessStatus.allCases {
            #expect(status.isGranted == (status == .granted))
        }
    }
}
