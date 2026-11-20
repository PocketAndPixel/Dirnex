import Foundation

/// Gives pictures read in decoding order the ticks they are shown at (PLAN.md §M42 ▸ Slice 5), for a
/// container that times its frames as they are decoded, and hands them on still in decoding order,
/// which is the order a decoder takes them in.
///
/// Over a run of pictures the ticks they are shown at are the ticks they are decoded at, handed out in
/// another order: an AVI's B-frames are stored after the frame they are shown before, and each keeps a
/// tick. So a window holds `depth + 1` pictures, and when it is full the one with the lowest key (its
/// place in showing order) takes the lowest tick held. FFmpeg's decoders give out timestamps the same
/// way. A depth at least the stream's reorder depth is right; more only waits longer. Measured over the
/// AVI sample's 1 344 frames: depth 2, its encoder's, and depth 16 gave the same ticks as sorting each
/// closed group of pictures whole.
///
/// A picture leaves once it and every picture decoded before it have their ticks, so an anchor waits
/// for the B-frames shown before it.
struct PresentationReorder<Payload: Sendable>: Sendable {
    let depth: Int
    /// Pictures in decoding order, each with its tick once the window has given it one.
    private var queue: [(payload: Payload, tick: Int64?)] = []
    /// The window: each picture's key and its place in `queue`, counted from `base`.
    private var waiting: [(key: Int64, sequence: Int)] = []
    private var base = 0
    private var ticks: [Int64] = []

    init(depth: Int) {
        self.depth = max(0, depth)
    }

    /// Take a picture; out come the pictures now ready, in decoding order, each with its tick.
    mutating func push(key: Int64, tick: Int64, payload: Payload) -> [
        (payload: Payload, tick: Int64)
    ] {
        waiting.append((key, base + queue.count))
        queue.append((payload, nil))
        if let last = ticks.last, tick < last {
            ticks.insert(tick, at: ticks.firstIndex { $0 > tick } ?? ticks.count)
        } else {
            ticks.append(tick)
        }
        while waiting.count > depth {
            assignLowest()
        }
        return drain()
    }

    /// Every picture still held: at the end of the stream, or before a picture that starts the count
    /// again.
    mutating func flush() -> [(payload: Payload, tick: Int64)] {
        while !waiting.isEmpty {
            assignLowest()
        }
        return drain()
    }

    /// Drop everything held, as after a seek.
    mutating func reset() {
        queue = []
        waiting = []
        ticks = []
        base = 0
    }

    var isEmpty: Bool { queue.isEmpty }

    private mutating func assignLowest() {
        var lowest = 0
        for index in waiting.indices.dropFirst() where waiting[index].key < waiting[lowest].key {
            lowest = index
        }
        let picture = waiting.remove(at: lowest)
        queue[picture.sequence - base].tick = ticks.removeFirst()
    }

    private mutating func drain() -> [(payload: Payload, tick: Int64)] {
        var ready: [(Payload, Int64)] = []
        while let first = queue.first, let tick = first.tick {
            ready.append((first.payload, tick))
            queue.removeFirst()
            base += 1
        }
        return ready
    }
}
