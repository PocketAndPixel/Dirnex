import Foundation
import Testing

@testable import DirnexCore

/// The rule deciding when a pane on a connected server asks it again
/// (docs/LOCATION-SUPPORT.md ▸ "No live refresh on a server").
///
/// Two halves, in two suites because they fail for different reasons: *which* panes poll is a
/// policy question the compiler cannot check and a backend added later inherits silently, and *how
/// often* is arithmetic whose whole job is to stay small on a folder that turns out to be expensive.
@Suite("Remote refresh — who polls")
struct RemoteRefreshPolicyBackendTests {
    /// Every connected backend together rather than one test each: they answer through the single
    /// `isRemoteConnection` predicate, and asserting them separately would keep passing if the rule
    /// were re-keyed on a list of cases that a fifth backend later missed.
    @Test("every connected remote backend polls")
    func remotesPoll() {
        let remotes: [VFSBackendID] = [
            .sftp(SFTPLocation(host: "h", username: "u")),
            .ftp(FTPLocation(host: "h", username: "u")),
            .s3(S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")),
            .s3Account(S3Account(host: "h", region: "r", accessKeyID: "k"))
        ]
        for backend in remotes {
            #expect(RemoteRefreshPolicy.polls(backend), "\(backend) should re-list on a timer")
        }
    }

    /// The narrowness control, and the half that matters more: "poll what nothing tells us about"
    /// must not quietly become "poll everything". A local pane polling would spend a re-list against
    /// an FSEvents stream that already reported the change exactly.
    @Test("a local pane never polls — FSEvents already tells it")
    func localDoesNotPoll() {
        #expect(!RemoteRefreshPolicy.polls(.local))
    }

    /// An archive re-reads on its file's identity changing (`ArchiveIdentity`), and a `.search`
    /// listing is a snapshot of a question asked once. Both would be a *different* feature, so they
    /// are pinned rather than left to the predicate.
    @Test("an archive and a results snapshot never poll")
    func virtualListingsDoNotPoll() {
        #expect(!RemoteRefreshPolicy.polls(.archive(forArchiveAt: "/a.zip")))
        #expect(!RemoteRefreshPolicy.polls(.search))
    }

    /// `interval` reads `polls` rather than restating it, and this is what keeps the two from
    /// drifting into two spellings of one question.
    @Test("a pane that does not poll gets no interval, whatever the floor")
    func nonPollingBackendsGetNoInterval() {
        for backend: VFSBackendID in [.local, .search] {
            #expect(
                RemoteRefreshPolicy.interval(
                    afterRefreshTaking: 0.65, floor: 15, backend: backend
                ) == nil
            )
        }
    }
}

@Suite("Remote refresh — how often")
struct RemoteRefreshPolicyIntervalTests {
    private let s3 = VFSBackendID.s3(
        S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")
    )

    /// The ordinary case, and the one the floor exists for: a single `ListObjectsV2` at the
    /// measured 0.601–0.699 s is 4 % of a 15 s gap, so the duty cycle is slack and the user's
    /// number decides.
    @Test("an ordinary S3 listing is governed by the floor, not by the duty cycle")
    func ordinaryListingUsesFloor() throws {
        let interval = try #require(
            RemoteRefreshPolicy.interval(afterRefreshTaking: 0.65, floor: 15, backend: s3)
        )
        #expect(interval == 15)
    }

    /// The case a per-backend table cannot express, which is the whole argument for measuring: a
    /// 50 000-object prefix pages at 1000 keys, so one refresh is fifty billed requests and ~32 s.
    /// The same rule that leaves an ordinary folder at 15 s holds this one to ~11 minutes.
    @Test("an expensive refresh backs itself off, with no backend named")
    func expensiveRefreshBacksOff() throws {
        let interval = try #require(
            RemoteRefreshPolicy.interval(afterRefreshTaking: 32, floor: 15, backend: s3)
        )
        #expect(interval == 640)
        // The claim is the ratio, not the number: whatever the floor and the duration, a pane never
        // spends more than the stated share of its wall time re-listing.
        #expect(32 / interval <= RemoteRefreshPolicy.dutyCycle)
    }

    /// Zero is the honest off switch on a metered link, and it has to reach the timer as "never
    /// arm" rather than as a very short gap — the direction that would bill hardest.
    @Test("a floor of zero turns polling off entirely")
    func zeroFloorNeverPolls() {
        #expect(
            RemoteRefreshPolicy.interval(afterRefreshTaking: 0.65, floor: 0, backend: s3) == nil
        )
    }

    /// Not having measured is not evidence of expense. The first poll of a pane has no previous
    /// refresh to time, and a rule that treated "unknown" as "back off" would make it the rarest.
    @Test("an unmeasured, negative or non-finite duration falls back to the floor")
    func unknownDurationUsesFloor() {
        for duration: TimeInterval? in [nil, -1, 0, .infinity, .nan] {
            #expect(
                RemoteRefreshPolicy.interval(afterRefreshTaking: duration, floor: 15, backend: s3)
                    == 15,
                "duration \(String(describing: duration)) should fall back to the floor"
            )
        }
    }

    /// A floor from a hand-edited defaults domain, or one carried over from an older build, is
    /// brought inside the band at the one place — so Settings' own range and the timer's cannot
    /// disagree about what is allowed.
    @Test("a floor outside the band is clamped rather than honoured")
    func floorIsClamped() {
        #expect(RemoteRefreshPolicy.clampedFloor(-30) == RemoteRefreshPolicy.floorRange.lowerBound)
        #expect(RemoteRefreshPolicy.clampedFloor(99999) == RemoteRefreshPolicy.floorRange.upperBound)
        #expect(RemoteRefreshPolicy.clampedFloor(.nan) == RemoteRefreshPolicy.defaultFloor)
        #expect(RemoteRefreshPolicy.clampedFloor(15) == 15)
    }

    /// The default the app ships with has to be inside the band Settings offers, or the field opens
    /// showing a value it would immediately take back.
    @Test("the shipped default sits inside the settable band")
    func defaultIsSettable() {
        #expect(RemoteRefreshPolicy.floorRange.contains(RemoteRefreshPolicy.defaultFloor))
        #expect(RemoteRefreshPolicy.defaultFloor > 0)
    }
}

@Suite("Remote refresh — is anybody looking")
struct RemoteRefreshPolicyVisibilityTests {
    private let s3 = VFSBackendID.s3(
        S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")
    )

    @Test("a remote pane on screen with a floor set polls")
    func visibleRemotePolls() {
        #expect(RemoteRefreshPolicy.shouldPoll(backend: s3, floor: 15, isOnScreen: true))
    }

    /// The gate the whole feature rests on. `occlusionState` was probed to go false for a window
    /// that is miniaturized, hidden, ordered out **or covered by another window**, so this one
    /// input stands for all four — and it is what stops a pane nobody is reading from billing.
    @Test("nothing is asked of a server nobody is looking at")
    func offScreenRemoteDoesNotPoll() {
        #expect(!RemoteRefreshPolicy.shouldPoll(backend: s3, floor: 15, isOnScreen: false))
    }

    /// The narrowness control on the other side, and the one that keeps "poll what nothing reports"
    /// from becoming "poll everything": being on screen is necessary, never sufficient.
    @Test("a local pane on screen still never polls")
    func visibleLocalDoesNotPoll() {
        #expect(!RemoteRefreshPolicy.shouldPoll(backend: .local, floor: 15, isOnScreen: true))
    }

    /// Zero has to reach every gate, not only the timer — otherwise "never contact my server"
    /// would be honoured in one place and not the other.
    @Test("a floor of zero refuses even a visible remote pane")
    func zeroFloorRefusesEverywhere() {
        #expect(!RemoteRefreshPolicy.shouldPoll(backend: s3, floor: 0, isOnScreen: true))
    }

    /// `shouldPoll` answers the backend-and-floor half by asking `interval`, so the two cannot
    /// drift. Asserted as an agreement rather than by restating either rule, which is the only
    /// form that fails when they diverge.
    @Test("shouldPoll and interval never disagree about who polls")
    func gatesAgree() {
        let backends: [VFSBackendID] = [
            .local,
            .search,
            .sftp(SFTPLocation(host: "h", username: "u")),
            .ftp(FTPLocation(host: "h", username: "u")),
            .s3(S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")),
            .s3Account(S3Account(host: "h", region: "r", accessKeyID: "k"))
        ]
        for backend in backends {
            for floor: TimeInterval in [0, 15, 600] {
                let hasInterval = RemoteRefreshPolicy.interval(
                    afterRefreshTaking: nil, floor: floor, backend: backend
                ) != nil
                #expect(
                    RemoteRefreshPolicy.shouldPoll(
                        backend: backend, floor: floor, isOnScreen: true
                    ) == hasInterval,
                    "\(backend) at floor \(floor) should answer both gates the same way"
                )
            }
        }
    }
}

@Suite("Remote refresh — coming back to a pane")
struct RemoteRefreshPolicyDelayTests {
    private let s3 = VFSBackendID.s3(
        S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")
    )

    /// The bug this suite exists for, in its own words: a pane that was stood down for longer than
    /// its interval is showing a listing that is certainly stale, and must catch up **at once**
    /// rather than wait out a fresh interval. Shipped the wrong way round and was caught only by
    /// watching the running app — `fire after 5.0s` where the log now reads `fire after 0.0s`.
    @Test("a pane uncovered after a long absence refreshes immediately")
    func longAbsenceCatchesUpAtOnce() throws {
        let delay = try #require(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: 0.08, finishedSecondsAgo: 25, floor: 15, backend: s3
            )
        )
        #expect(delay == 0)
    }

    /// The other half, and the one that keeps "catch up" from becoming "ask on every glance": a
    /// window flicked away and back inside a second has just been refreshed, so it waits out the
    /// remainder instead of spending a request on the gesture.
    @Test("a pane glanced away from and back waits out the remainder")
    func briefAbsenceWaitsOutTheRemainder() throws {
        let delay = try #require(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: 0.08, finishedSecondsAgo: 1, floor: 15, backend: s3
            )
        )
        #expect(delay == 14)
    }

    /// No previous refresh of this directory — a pane that has just arrived. It waits the full
    /// interval, which is honest: getting here *was* a listing.
    @Test("a pane that has never polled waits the whole interval")
    func noPreviousRefreshWaitsTheFullInterval() throws {
        let delay = try #require(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: nil, finishedSecondsAgo: nil, floor: 15, backend: s3
            )
        )
        #expect(delay == 15)
    }

    /// The backoff still governs what is being subtracted *from*, so an expensive folder does not
    /// become a cheap one by having been left alone for a while.
    @Test("the elapsed time is subtracted from the backed-off interval, not from the floor")
    func elapsedIsSubtractedFromTheBackedOffInterval() throws {
        let delay = try #require(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: 32, finishedSecondsAgo: 100, floor: 15, backend: s3
            )
        )
        #expect(delay == 540)
    }

    /// Never negative, and never an answer at all for a pane that must not poll — the two ways a
    /// delay could be read as "go now" when it means "never".
    @Test("a delay is never negative, and a non-polling pane gets none")
    func delayIsBoundedAndRefused() throws {
        let delay = try #require(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: 0.08, finishedSecondsAgo: 9999, floor: 15, backend: s3
            )
        )
        #expect(delay == 0)
        #expect(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: 0.08, finishedSecondsAgo: 25, floor: 15, backend: .local
            ) == nil
        )
        #expect(
            RemoteRefreshPolicy.delay(
                afterRefreshTaking: 0.08, finishedSecondsAgo: 25, floor: 0, backend: s3
            ) == nil
        )
    }
}
