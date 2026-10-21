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
    }

    @Test("a dataless entry starts evicted and asks for a download")
    func datalessStartsEvicted() {
        let tracker = CloudDownloadTracker(isDataless: true)
        #expect(tracker.phase == .evicted)
    }

    // MARK: - The happy path

    @Test("evicted → downloading → ready")
    func fullDownloadSequence() {
        var tracker = CloudDownloadTracker(isDataless: true)
        tracker.requestSent()

        tracker.observe(
            CloudItemReading(isDataless: true, status: .notDownloaded, isDownloading: true)
        )
        #expect(tracker.phase == .downloading)

        tracker.observe(CloudItemReading(isDataless: false, status: .current))
        #expect(tracker.phase == .ready)
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
