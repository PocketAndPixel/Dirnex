import Foundation
import Testing

@testable import DirnexCore

/// The Photos library is the one connection that can say when it changed, so a pane on it is woken
/// by the library rather than by a clock (PLAN.md §M28 Slice 4).
///
/// A suite of its own rather than more of `RemoteRefreshPolicyTests`, because what it pins is the
/// *exception* to that file's rule — and an exception is exactly what a later edit to the rule could
/// quietly take away, or quietly widen.
@Suite("Remote refresh — woken by the library")
struct RemoteRefreshLibraryChangeTests {
    private let servers: [VFSBackendID] = [
        .sftp(SFTPLocation(host: "h", username: "u")),
        .ftp(FTPLocation(host: "h", username: "u")),
        .s3(S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")),
        .s3Account(S3Account(host: "h", region: "r", accessKeyID: "k"))
    ]

    @Test("the Photos library is woken by its own changes, and never by a timer")
    func libraryIsWokenByChanges() {
        #expect(RemoteRefreshPolicy.trigger(for: .photos) == .libraryChange)
        #expect(!RemoteRefreshPolicy.polls(.photos))
        #expect(
            RemoteRefreshPolicy.interval(afterRefreshTaking: 0.33, floor: 15, backend: .photos) == nil
        )
    }

    /// The narrowness control, and the half that matters more: "the library can notify" must not
    /// become "nothing needs a timer", which would leave every server pane silently stale again.
    @Test("every server is still asked on a timer, and nothing that is not a connection is woken")
    func othersKeepTheirTrigger() {
        for server in servers {
            #expect(RemoteRefreshPolicy.trigger(for: server) == .timer, "\(server)")
        }
        let unconnected: [VFSBackendID] = [.local, .search, .archive(forArchiveAt: "/a.zip")]
        for backend in unconnected {
            #expect(RemoteRefreshPolicy.trigger(for: backend) == nil, "\(backend)")
        }
    }

    /// The floor's promise is about contacting a server, and a library change contacts nothing — so
    /// zero, which silences every server, must not silence the library.
    @Test("a visible library pane listens whatever the floor, zero included")
    func floorDoesNotSilenceTheLibrary() {
        for floor: TimeInterval in [0, 15, 3600] {
            #expect(RemoteRefreshPolicy.shouldPoll(backend: .photos, floor: floor, isOnScreen: true))
        }
        #expect(!RemoteRefreshPolicy.shouldPoll(backend: .photos, floor: 15, isOnScreen: false))
        for server in servers {
            #expect(!RemoteRefreshPolicy.shouldPoll(backend: server, floor: 0, isOnScreen: true))
        }
    }

    /// One gesture in Photos delivered twice, 0.315 s apart (measured 2026-09-13), so the settle
    /// delay has to outlast that gap or the one gesture costs two refreshes.
    @Test("a change waits out one gesture's burst before the pane re-lists")
    func burstSettles() {
        let settle = RemoteRefreshPolicy.librarySettleDelay
        #expect(settle > 0.315)
        #expect(
            RemoteRefreshPolicy.delayAfterLibraryChange(
                afterRefreshTaking: nil, finishedSecondsAgo: nil
            ) == settle
        )
        #expect(
            RemoteRefreshPolicy.delayAfterLibraryChange(
                afterRefreshTaking: 0.004, finishedSecondsAgo: nil
            ) == settle
        )
    }

    /// A month of 300 costs ~0.33 s of names after every change, and a library that keeps changing
    /// must not have it read back to back.
    @Test("an expensive library refresh backs itself off by the duty cycle")
    func expensiveRefreshBacksOff() {
        let delay = RemoteRefreshPolicy.delayAfterLibraryChange(
            afterRefreshTaking: 0.33, finishedSecondsAgo: nil
        )
        #expect(abs(delay - 0.33 / RemoteRefreshPolicy.dutyCycle) < 1e-9)
    }

    @Test("the time since the last refresh is subtracted, but never below the settle delay")
    func elapsedIsSubtracted() {
        let spacing = 0.33 / RemoteRefreshPolicy.dutyCycle
        let partway = RemoteRefreshPolicy.delayAfterLibraryChange(
            afterRefreshTaking: 0.33, finishedSecondsAgo: 3
        )
        #expect(abs(partway - (spacing - 3)) < 1e-9)
        #expect(
            RemoteRefreshPolicy.delayAfterLibraryChange(
                afterRefreshTaking: 0.33, finishedSecondsAgo: 100
            ) == RemoteRefreshPolicy.librarySettleDelay
        )
    }

    @Test("an unmeasured, negative or non-finite duration or elapsed time is ignored")
    func unknownInputsAreIgnored() {
        let settle = RemoteRefreshPolicy.librarySettleDelay
        for bad: TimeInterval in [-1, .nan, .infinity] {
            #expect(
                RemoteRefreshPolicy.delayAfterLibraryChange(
                    afterRefreshTaking: bad, finishedSecondsAgo: nil
                ) == settle
            )
            let unsubtracted = RemoteRefreshPolicy.delayAfterLibraryChange(
                afterRefreshTaking: 0.33, finishedSecondsAgo: bad
            )
            #expect(abs(unsubtracted - 0.33 / RemoteRefreshPolicy.dutyCycle) < 1e-9)
        }
    }
}
