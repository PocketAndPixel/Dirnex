import AVFoundation
import DirnexCore
import Testing

@testable import Dirnex

/// The core's player's feed, apart from the player (PLAN.md §M42 ▸ Slice 4).
@Suite("Sample-buffer feed")
@MainActor
struct SampleBufferFeedTests {
    /// A renderer asks for data until it is told to stop, and `AVQueuedSampleBufferRendering.h` says
    /// releasing one without that stop "will result in undefined behavior". What happened (CI,
    /// 2026-11-22): a feed let go without `stop()`, by a test dropping its surface with the player up,
    /// left its sound renderer calling a block whose feed was gone, millions of times a second for the
    /// life of the process. Seven of them on an eight-core runner left GCD no thread for an
    /// `AVAssetReader`, and a later test waited 22 minutes. The asking keeps the renderer alive, so
    /// the renderers going away is the witness that it stopped.
    ///
    /// Played, then paused, as `QuickViewAVITests.playAndPause` left one: paused from the start, the
    /// sound renderer took the whole file in one call and stopped asking by itself.
    @Test("a feed let go without stop() ends its renderers' asking, and lets them go")
    func releaseStopsTheRequests() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.avi")
        _ = try AVIFixtures.writeMovie(to: url, seconds: 20)
        let file = try AVIFile(source: FileByteSource(url: url))
        let preparation = try #require(SampleBufferPreparation.prepare(file, language: nil))
        weak var video: AVSampleBufferVideoRenderer?
        weak var audio: AVSampleBufferAudioRenderer?
        do {
            let feed = SampleBufferFeed(preparation, videoRenderer: AVSampleBufferVideoRenderer())
            let renderers = feed.synchronizer.renderers
            video = renderers.lazy.compactMap { $0 as? AVSampleBufferVideoRenderer }.first
            audio = renderers.lazy.compactMap { $0 as? AVSampleBufferAudioRenderer }.first
            #expect(video != nil && audio != nil)
            feed.start()
            feed.setRate(1)
            try await settleUntil(within: .seconds(60)) {
                feed.synchronizer.currentTime().seconds > 0.5
            }
            feed.setRate(0)
        }
        try await settleUntil(within: .seconds(10)) { video == nil && audio == nil }
    }
}
