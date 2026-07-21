import Foundation
import Testing

@testable import DirnexCore

@Suite("CloudDownloadTracker")
struct CloudDownloadTests {
    // MARK: - Where it starts

    @Test("a materialized entry starts ready and needs no download")
    func materializedStartsReady() {
        let tracker = CloudDownloadTracker(isDataless: false)
        #expect(tracker.phase == .ready)
        #expect(!tracker.needsDownload)
        #expect(tracker.phase.isSettled)
    }

    @Test("a dataless entry starts evicted and asks for a download")
    func datalessStartsEvicted() {
        let tracker = CloudDownloadTracker(isDataless: true)
        #expect(tracker.phase == .evicted)
        #expect(tracker.needsDownload)
        #expect(!tracker.phase.isSettled)
    }

    // MARK: - The happy path

    @Test("evicted → downloading → ready")
    func fullDownloadSequence() {
        var tracker = CloudDownloadTracker(isDataless: true)
        tracker.requestSent()

        tracker.observe(
            CloudItemReading(isDataless: true, status: .notDownloaded, isDownloading: true)
        )
        #expect(tracker.phase == .downloading(fraction: nil))

        tracker.observe(percentDownloaded: 40)
        #expect(tracker.phase == .downloading(fraction: 0.4))

        tracker.observe(CloudItemReading(isDataless: false, status: .current))
        #expect(tracker.phase == .ready)
        #expect(tracker.phase.isSettled)
    }

    @Test("the dataless flag alone settles the wait, even while the status key still lags")
    func datalessClearedWins() {
        // Probed shape: the bytes land before every key catches up. `isDataless` is what
        // decides whether a read would block, so it is what ends the wait.
        var tracker = CloudDownloadTracker(isDataless: true)
        tracker.requestSent()
        let phase = tracker.observe(
            CloudItemReading(isDataless: false, status: .notDownloaded, isDownloading: true)
        )
        #expect(phase == .ready)
    }

    @Test("a status with local bytes settles the wait too")
    func downloadedStatusIsReady() {
        var tracker = CloudDownloadTracker(isDataless: true)
        for status in [CloudDownloadStatus.downloaded, .current] {
            #expect(status.hasLocalBytes)
            tracker.observe(CloudItemReading(isDataless: true, status: status))
            #expect(tracker.phase == .ready)
        }
        #expect(!CloudDownloadStatus.notDownloaded.hasLocalBytes)
    }

    // MARK: - Not settling

    @Test("a request that has not visibly started yet is not a failure")
    func earlyPollIsNotAStall() {
        // The whole reason the tracker holds a clock: a caller polling every 200 ms must not
        // declare a stall before the provider has had a chance to react.
        var tracker = CloudDownloadTracker(isDataless: true, stallTimeout: 30)
        let start = Date()
        tracker.requestSent(at: start)
        let phase = tracker.observe(
            CloudItemReading(isDataless: true, status: .notDownloaded),
            at: start.addingTimeInterval(0.2)
        )
        #expect(phase == .evicted)
        #expect(!phase.isSettled)
    }

    @Test("a download that never starts stalls once the deadline passes")
    func stallsAfterTimeout() {
        var tracker = CloudDownloadTracker(isDataless: true, stallTimeout: 30)
        let start = Date()
        tracker.requestSent(at: start)
        let phase = tracker.observe(
            CloudItemReading(isDataless: true, status: .notDownloaded),
            at: start.addingTimeInterval(31)
        )
        #expect(phase == .failed(reason: .stalled))
        #expect(phase.isSettled)
    }

    @Test("without a request there is no clock, so an evicted item never stalls on its own")
    func noRequestNeverStalls() {
        // A row simply being listed for an hour is not a failed download.
        var tracker = CloudDownloadTracker(isDataless: true, stallTimeout: 1)
        let phase = tracker.observe(
            CloudItemReading(isDataless: true, status: .notDownloaded),
            at: Date().addingTimeInterval(3600)
        )
        #expect(phase == .evicted)
    }

    @Test("a provider error settles as a failure and outranks every other signal")
    func providerErrorWins() {
        var tracker = CloudDownloadTracker(isDataless: true)
        tracker.requestSent()
        let phase = tracker.observe(
            CloudItemReading(
                isDataless: false,
                status: .current,
                isDownloading: true,
                downloadingError: "The Internet connection appears to be offline."
            )
        )
        #expect(
            phase == .failed(reason: .provider("The Internet connection appears to be offline."))
        )
    }

    // MARK: - Progress

    @Test("a percentage is ignored unless a download is actually running")
    func percentIgnoredOutsideDownloading() {
        // A late progress report must not resurrect a finished transfer.
        var tracker = CloudDownloadTracker(isDataless: false)
        tracker.observe(percentDownloaded: 50)
        #expect(tracker.phase == .ready)

        var evicted = CloudDownloadTracker(isDataless: true)
        evicted.observe(percentDownloaded: 50)
        #expect(evicted.phase == .evicted)
    }

    @Test("a percentage outside 0…100 is clamped rather than rendered as a broken bar")
    func percentIsClamped() {
        var tracker = CloudDownloadTracker(isDataless: true)
        tracker.requestSent()
        tracker.observe(
            CloudItemReading(isDataless: true, status: .notDownloaded, isDownloading: true)
        )

        tracker.observe(percentDownloaded: 140)
        #expect(tracker.phase == .downloading(fraction: 1))
        tracker.observe(percentDownloaded: -5)
        #expect(tracker.phase == .downloading(fraction: 0))
    }

    // MARK: - The status key's spelling

    @Test("the downloading-status raw values match Foundation's constants")
    func statusRawValuesMatchFoundation() throws {
        // These strings are the API contract; a typo would silently read as "not ubiquitous"
        // and every evicted file would look materialized.
        #expect(
            CloudDownloadStatus.notDownloaded.rawValue == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue
        )
        #expect(
            CloudDownloadStatus.downloaded.rawValue == URLUbiquitousItemDownloadingStatus.downloaded.rawValue
        )
        #expect(
            CloudDownloadStatus.current.rawValue == URLUbiquitousItemDownloadingStatus.current.rawValue
        )
    }
}
