import AVFoundation
import DirnexCore

/// The half of the core's player that runs on its own queue (PLAN.md §M42 ▸ Slices 4 and 5): it reads
/// packets from the demuxer as each renderer asks for more, and seeks.
///
/// Everything here is touched on `queue` alone, apart from the synchronizer's clock, which the player
/// reads from the main actor and Core Media keeps safe to read from anywhere. That confinement is
/// what `@unchecked Sendable` stands for: the renderers ask for data on `queue`, and every call that
/// changes them or the demuxer is sent there.
final class SampleBufferFeed: @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer: AVSampleBufferAudioRenderer?
    private let preparation: SampleBufferPreparation
    private let queue = DispatchQueue(
        label: "app.dirnex.quickview.samplebuffers",
        qos: .userInitiated
    )
    private var demuxer: any MediaDemuxing
    private var isStopped = false
    private let progress = NSLock()
    /// The tracks that have run out since the last seek, and where the last packet seen ended, in
    /// seconds; behind `progress`, since the player reads them from the main actor.
    private var finishedTracks: Set<UInt64> = []
    private var lastEnd: Double = 0
    /// The sound being played, which a switch changes; behind `progress` with the two above.
    private var audioTrack: SampleBufferPreparation.Track?

    /// How far before a seek's target pictures start to be shown. A seek to a file's very end would
    /// otherwise make every picture preroll and show none; with this the last frame before the target
    /// is the one on screen, as a seek in AVKit leaves it.
    static let displayLead: Int64 = 100_000_000

    init(_ preparation: SampleBufferPreparation, videoRenderer: AVSampleBufferVideoRenderer?) {
        self.preparation = preparation
        self.videoRenderer = preparation.video == nil ? nil : videoRenderer
        audioRenderer = preparation.audio == nil ? nil : AVSampleBufferAudioRenderer()
        audioTrack = preparation.audio
        demuxer = preparation.demuxer
        if let renderer = self.videoRenderer { synchronizer.addRenderer(renderer) }
        if let audioRenderer { synchronizer.addRenderer(audioRenderer) }
    }

    /// A feed let go without `stop()` ends its renderers' requests itself. Each request needs its stop
    /// (`AVQueuedSampleBufferRendering.h`: releasing a renderer without one "will result in undefined
    /// behavior"), and here the request keeps the renderer alive and calls its block, whose `self` is
    /// gone, as fast as a core runs, for the life of the process (CI, 2026-11-22). The path seen was a
    /// surface dropped with its player up, played and then paused, as several tests leave one.
    deinit {
        videoRenderer?.stopRequestingMediaData()
        audioRenderer?.stopRequestingMediaData()
    }

    /// Start reading from the start of the file, paused there.
    func start() {
        queue.async { [self] in
            synchronizer.setRate(0, time: .zero)
            requestData()
        }
    }

    func setRate(_ rate: Float) {
        queue.async { [self] in
            guard !isStopped else { return }
            synchronizer.rate = rate
        }
    }

    /// Go to `seconds` and carry on at `rate`; `done` runs on the main queue once the clock is there.
    func seek(to seconds: Double, rate: Float, done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !isStopped else { return }
            reposition(to: seconds, rate: rate)
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Play the sound numbered `number` in place of the one playing, from `seconds` on at `rate`; `done`
    /// runs on the main queue once it is there (PLAN.md §M42 ▸ Sound tracks).
    ///
    /// A seek to where the player already is, with a demuxer made again for the picture and the new
    /// sound: the one reading the old sound is at its own place in the file, and the renderers hold
    /// what it handed them. The picture starts again from the key frame before, as after any seek, and
    /// the sound renderer takes the new format after its flush.
    func switchSound(
        to number: UInt64,
        at seconds: Double,
        rate: Float,
        done: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            guard !isStopped, audioRenderer != nil,
                  let track = preparation.audioTracks[number],
                  let fresh = preparation.makeDemuxer(number)
            else { return }
            demuxer = fresh
            progress.withLock { audioTrack = track }
            reposition(to: seconds, rate: rate)
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Stop for good: nothing plays or is read after this.
    func stop() {
        queue.async { [self] in
            isStopped = true
            synchronizer.rate = 0
            videoRenderer?.stopRequestingMediaData()
            audioRenderer?.stopRequestingMediaData()
            videoRenderer?.flush()
            audioRenderer?.flush()
        }
    }

    /// Where the file's last packet ends, in seconds, once every track being played has run out.
    var endOfData: Double? {
        progress.withLock {
            let tracks = Set([preparation.video?.number, audioTrack?.number].compactMap(\.self))
            return finishedTracks.isSuperset(of: tracks) ? lastEnd : nil
        }
    }

    /// Whether the sound renderer refused what it was given, which is the one failure that shows
    /// nowhere else: the picture plays on in silence.
    var audioError: Error? { audioRenderer?.error }

    // MARK: - On the queue

    /// Start the demuxer and both renderers again at `seconds`, and the clock there at `rate`.
    private func reposition(to seconds: Double, rate: Float) {
        videoRenderer?.stopRequestingMediaData()
        audioRenderer?.stopRequestingMediaData()
        let target = Int64((seconds * 1_000_000_000).rounded())
        try? demuxer.seek(
            to: max(0, target - Self.displayLead),
            keyTrack: preparation.video?.number
        )
        progress.withLock {
            finishedTracks = []
            lastEnd = seconds
        }
        videoRenderer?.flush()
        audioRenderer?.flush()
        synchronizer.setRate(rate, time: CMTime(value: target, timescale: 1_000_000_000))
        requestData()
    }

    private func requestData() {
        if let videoRenderer {
            videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo() }
        }
        if let audioRenderer {
            audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio() }
        }
    }

    private func feedVideo() {
        guard let renderer = videoRenderer, let track = preparation.video else { return }
        feed(renderer, track: track)
    }

    private func feedAudio() {
        guard let renderer = audioRenderer, let track = progress.withLock({ audioTrack }) else { return }
        feed(renderer, track: track)
    }

    /// Hand `renderer` packets of `track` while it has room, and tell it when the track has run out.
    private func feed(
        _ renderer: any AVQueuedSampleBufferRendering,
        track: SampleBufferPreparation.Track
    ) {
        while !isStopped, renderer.isReadyForMoreMediaData {
            guard let packet = try? demuxer.next(track: track.number) else {
                renderer.stopRequestingMediaData()
                progress.withLock { _ = finishedTracks.insert(track.number) }
                return
            }
            let end = Double(packet.time + (packet.duration ?? 0)) / 1_000_000_000
            progress.withLock { lastEnd = max(lastEnd, end) }
            if let sample = MediaSampleBridge.sampleBuffer(
                packet,
                description: track.description,
                audio: track.audio
            ) {
                renderer.enqueue(sample)
            }
        }
    }
}

/// Quick View's player for a Matroska, WebM or AVI file (PLAN.md §M42 ▸ Slices 4 and 5): AVFoundation
/// refuses the container, so the core reads it and the system's decoders play what it hands over,
/// through a display layer, a sound renderer and a synchronizer that keeps the two together.
///
/// It answers what `QuickViewMediaView` asks of AVPlayer: whether it plays, where it is, play and
/// pause, and seek. Nothing plays until it is asked to, and `stop()` ends it for good.
@MainActor
final class SampleBufferPlayer {
    /// The picture, or `nil` for a sound alone.
    let displayLayer: AVSampleBufferDisplayLayer?
    let preparation: SampleBufferPreparation
    private let feed: SampleBufferFeed
    private(set) var isPlaying = false
    /// Where a seek is going while the feed's queue gets there, so the readout does not show the old
    /// place in between.
    private var pendingTarget: Double?
    private var timeObserver: Any?
    /// Told whenever the readout may have moved: a quarter-second of playback, a start or a stop, a seek.
    var onChange: (() -> Void)?
    /// The number of the sound playing, which `selectSound` changes, or `nil` with none.
    private(set) var playingSound: UInt64?

    init(_ preparation: SampleBufferPreparation) {
        self.preparation = preparation
        playingSound = preparation.audio?.number
        let layer = preparation.video == nil ? nil : AVSampleBufferDisplayLayer()
        layer?.videoGravity = .resizeAspect
        displayLayer = layer
        feed = SampleBufferFeed(preparation, videoRenderer: layer?.sampleBufferRenderer)
        timeObserver = feed.synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        feed.start()
    }

    /// The length the file states, or where its data was seen to end once it has all been read.
    var duration: Double? {
        preparation.statedDuration ?? feed.endOfData
    }

    /// Where playback stops: the stated length, or where the data ran out when that comes first.
    ///
    /// The two differ by a packet as often as not: the Steam clip states 4.008 s and its last Opus
    /// packet ends at 4.021 s. Waiting for the clock to pass the later one, with the clock held at the
    /// earlier, left the player saying it played forever (seen live 2026-11-20).
    private var endSeconds: Double? {
        switch (preparation.statedDuration, feed.endOfData) {
        case let (stated?, data?): min(stated, data)
        case let (stated?, nil): stated
        case let (nil, data): data
        }
    }

    /// The place on the timeline, in seconds.
    var currentSeconds: Double {
        if let pendingTarget { return pendingTarget }
        let seconds = feed.synchronizer.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return duration.map { min(seconds, $0) } ?? seconds
    }

    /// ⌘P. At the end it starts again from the start, as the AVPlayer path does.
    func togglePlayback() {
        defer { onChange?() }
        if isPlaying {
            isPlaying = false
            feed.setRate(0)
            return
        }
        isPlaying = true
        if let end = endSeconds, currentSeconds >= end - 0.05 {
            seek(to: 0)
        } else {
            feed.setRate(1)
        }
    }

    /// One of the ⇧-keys, as a move along the timeline.
    func seek(_ move: QuickViewScroll) {
        seek(to: move.timelineTarget(from: currentSeconds, duration: duration))
    }

    /// Go to `seconds`, held inside the file, carrying on playing or paused as before.
    func seek(to seconds: Double) {
        let target = max(0, duration.map { min(seconds, $0) } ?? seconds)
        pendingTarget = target
        feed.seek(to: target, rate: isPlaying ? 1 : 0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingTarget == target else { return }
                self.pendingTarget = nil
                self.onChange?()
            }
        }
        onChange?()
    }

    /// The file's sounds, for the header's menu and tooltip.
    var sounds: [QuickViewSoundTrack] { preparation.sounds }

    /// Whether another sound can be played in place of this one: there is a sound renderer, and more
    /// than one sound decodes.
    var canSwitchSound: Bool { preparation.audio != nil && preparation.audioTracks.count > 1 }

    /// Play the sound numbered `number` from where the player is, playing on or paused as before
    /// (PLAN.md §M42 ▸ Sound tracks). Nothing for the one playing or one that does not decode.
    func selectSound(_ number: UInt64) {
        guard canSwitchSound, number != playingSound, preparation.audioTracks[number] != nil else { return }
        playingSound = number
        let target = currentSeconds
        pendingTarget = target
        feed.switchSound(to: number, at: target, rate: isPlaying ? 1 : 0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingTarget == target else { return }
                self.pendingTarget = nil
                self.onChange?()
            }
        }
        onChange?()
    }

    func stop() {
        isPlaying = false
        if let timeObserver { feed.synchronizer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        feed.stop()
        onChange = nil
    }

    /// Whether the sound renderer refused the sound it was given.
    var audioError: Error? { feed.audioError }

    /// The periodic report: pause at the end, as AVPlayer's `actionAtItemEnd = .pause` does, and tell
    /// the readout.
    private func tick() {
        if isPlaying, let end = endSeconds, currentSeconds >= end {
            isPlaying = false
            feed.setRate(0)
        }
        onChange?()
    }
}
