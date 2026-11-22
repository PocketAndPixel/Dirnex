import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// AVI files for Quick View's player tests (PLAN.md §M42 ▸ Slice 5), made of packets the system's own
/// encoders wrote: H.264 with B-frames from VideoToolbox, AAC from AudioToolbox, JPEG from ImageIO.
/// Nothing binary is checked in, and the encoder's own presentation times are the witness the reader's
/// display order is held to, since an AVI keeps none.
enum AVIFixtures {
    /// One H.264 picture as the encoder handed it out, in decoding order: length-prefixed units and
    /// the time the encoder means it to be shown at, in frames.
    struct Picture {
        let data: Data
        let frame: Int
        let isKeyframe: Bool
    }

    /// What the encoder wrote: the pictures in decoding order and the `avcC` record.
    struct H264 {
        let pictures: [Picture]
        let record: Data
    }

    static let size = 64

    /// `frames` pictures at 25 a second, each a background a step brighter than the last, with a
    /// square moving across it so that the encoder has motion to predict, encoded at High profile with
    /// frame reordering, which is what makes the encoder write B-frames.
    nonisolated static func encodeH264(frames: Int) throws -> H264 {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(size),
            height: Int32(size),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw CocoaError(.featureUnsupported) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanTrue
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_High_AutoLevel
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: 25 as CFNumber
        )
        let collected = Collected()
        for frame in 0..<frames {
            let buffer = try picture(frame)
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: buffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 25),
                duration: CMTime(value: 1, timescale: 25),
                frameProperties: nil,
                infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample else { return }
                collected.add(sample)
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return try collected.result()
    }

    /// The encoder's samples, which its callback hands over on its own thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var pictures: [Picture] = []
        private var record: Data?

        func add(_ sample: CMSampleBuffer) {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            guard let pointer else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let atoms = CMSampleBufferGetFormatDescription(sample).flatMap {
                CMFormatDescriptionGetExtension(
                    $0,
                    extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                )
            } as? [String: Any]
            lock.withLock {
                pictures.append(Picture(
                    data: Data(bytes: pointer, count: length),
                    frame: Int((time.seconds * 25).rounded()),
                    isKeyframe: !notSync
                ))
                if record == nil { record = atoms?["avcC"] as? Data }
            }
        }

        func result() throws -> H264 {
            try lock.withLock {
                guard let record else { throw CocoaError(.fileReadCorruptFile) }
                return H264(pictures: pictures, record: record)
            }
        }
    }

    /// Frame `index`: its background `20 + 3 × index` grey, and a white square stepping right.
    nonisolated static func picture(_ index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let grey = UInt8(min(235, 20 + 3 * index))
        let left = (index * 2) % (size - 16)
        for y in 0..<size {
            for x in 0..<size {
                let inSquare = (24..<40).contains(y) && (left..<left + 16).contains(x)
                let value = inSquare ? 255 : grey
                let pixel = base + y * row + x * 4
                pixel[0] = value
                pixel[1] = value
                pixel[2] = value
                pixel[3] = 255
            }
        }
        return buffer
    }

    /// The units of a length-prefixed picture behind start codes, as an AVI chunk holds H.264, with
    /// `record`'s parameter sets before the first.
    nonisolated static func annexB(_ picture: Data, parameterSetsFrom record: Data?) -> Data {
        var out = Data()
        if let record {
            let bytes = [UInt8](record)
            var index = 6
            for count in [Int(bytes[5] & 0x1F), -1] {
                let sets = count >= 0 ? count : Int(bytes[index])
                if count < 0 { index += 1 }
                for _ in 0..<sets {
                    let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                    out += [0, 0, 0, 1] + bytes[index + 2..<index + 2 + length]
                    index += 2 + length
                }
            }
        }
        let bytes = [UInt8](picture)
        var index = 0
        while index + 4 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            out += [0, 0, 0, 1] + bytes[index + 4..<min(bytes.count, index + 4 + length)]
            index += 4 + length
        }
        return out
    }
}

/// JPEG frames, and the AVI writer.
extension AVIFixtures {
    /// A JPEG as ImageIO writes one, with its Huffman tables: blocks of colour that change with
    /// `seed`. A busy picture, since a flat one decodes alike with the wrong tables (measured
    /// 2026-11-20: a grey frame's corner came out the same whichever tables it had).
    nonisolated static func jpeg(_ seed: Int) throws -> Data {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        for y in stride(from: 0, to: size, by: 8) {
            for x in stride(from: 0, to: size, by: 8) {
                context?.setFillColor(CGColor(
                    red: CGFloat((x * 7 + seed * 13) % 255) / 255,
                    green: CGFloat((y * 3 + seed * 5) % 255) / 255,
                    blue: CGFloat((x + y + seed) % 255) / 255,
                    alpha: 1
                ))
                context?.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        guard let image = context?.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// `jpeg` without its `DHT` segments, as a camera's `AVI1` frame comes.
    nonisolated static func withoutTables(_ jpeg: Data) -> Data {
        let bytes = [UInt8](jpeg)
        var out = Data(bytes[0..<2])
        var index = 2
        while index + 4 <= bytes.count {
            let marker = bytes[index + 1]
            if marker == 0xDA {
                out.append(contentsOf: bytes[index...])
                break
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker != 0xC4 { out.append(contentsOf: bytes[index..<index + 2 + length]) }
            index += 2 + length
        }
        return out
    }

    // MARK: - Writing

    /// A stream to write: its type and handler, its clock, its format, and its chunks.
    struct Stream {
        var type = "vids"
        var handler = "H264"
        var scale: UInt32 = 1
        var rate: UInt32 = 25
        var format: [UInt8]
        var chunks: [Chunk]
    }

    /// One chunk: its bytes, whether it is a key frame, and when it is decoded, which orders the file.
    struct Chunk {
        var data: Data
        var isKey = true
        var seconds: Double
    }

    static func videoFormat(compression: String) -> [UInt8] {
        le32(40) + le32(size) + le32(size) + le16(1) + le16(24) + Array(compression.utf8)
            + le32(size * size * 3) + [UInt8](repeating: 0, count: 16)
    }

    static func aacFormat(config: Data) -> [UInt8] {
        le16(0xFF) + le16(2) + le32(48000) + le32(16000) + le16(1) + le16(16) + le16(config.count) + [
            UInt8
        ](config)
    }

    /// The H.264 movie, `seconds` long, with AAC silence beside it when `sound` is set.
    nonisolated static func writeMovie(to url: URL, seconds: Int = 1, sound: Bool = true) throws -> H264 {
        let h264 = try encodeH264(frames: seconds * 25)
        var streams = [Stream(
            format: videoFormat(compression: "H264"),
            chunks: h264.pictures.enumerated().map { index, picture in
                Chunk(
                    data: annexB(picture.data, parameterSetsFrom: index == 0 ? h264.record : nil),
                    isKey: picture.isKeyframe,
                    seconds: Double(index) / 25
                )
            }
        )]
        if sound {
            let aac = try MatroskaFixtures.encode(
                kAudioFormatMPEG4AAC,
                seconds: Double(seconds),
                amplitude: 0
            )
            streams.append(Stream(
                type: "auds",
                handler: "\0\0\0\0",
                scale: 1024,
                rate: 48000,
                format: aacFormat(
                    config: try MatroskaFixtures.audioSpecificConfig(fromCookie: aac.cookie)
                ),
                chunks: aac.packets.map { Chunk(
                    data: $0.data,
                    seconds: Double($0.milliseconds) / 1000
                ) }
            ))
        }
        try write(streams, to: url)
        return h264
    }

    /// An AVI of `streams`, their chunks interleaved by time, with an `idx1`.
    nonisolated static func write(_ streams: [Stream], to url: URL) throws {
        var header = Array("hdrl".utf8)
        let frames = streams.first?.chunks.count ?? 0
        header += chunk(
            "avih",
            le32(40000) + le32(0) + le32(0) + le32(0x10) + le32(frames) + le32(0)
                + le32(streams.count) + le32(0) + le32(size) + le32(size) + [UInt8](
                    repeating: 0,
                    count: 16
                )
        )
        for stream in streams {
            var strh = Array(stream.type.utf8) + Array(stream.handler.utf8) + le32(0) + le32(0) + le32(
                0
            )
            strh += le32(stream.scale) + le32(stream.rate) + le32(0) + le32(stream.chunks.count)
            strh += le32(0) + le32(UInt32.max) + le32(0) + [UInt8](repeating: 0, count: 8)
            header += chunk(
                "LIST",
                Array("strl".utf8) + chunk("strh", strh) + chunk("strf", stream.format)
            )
        }
        var out = Array("RIFF".utf8) + le32(0) + Array("AVI ".utf8) + chunk("LIST", header)
        let moviStart = out.count
        out += Array("LIST".utf8) + le32(0) + Array("movi".utf8)
        let order = streams.enumerated().flatMap { number, stream in
            stream.chunks.enumerated().map { (seconds: $1.seconds, stream: number, index: $0) }
        }.sorted { ($0.seconds, $0.stream) < ($1.seconds, $1.stream) }
        var index = [UInt8]()
        for item in order {
            let piece = streams[item.stream].chunks[item.index]
            let code = String(
                format: "%02d%@",
                item.stream,
                streams[item.stream].type == "vids" ? "dc" : "wb"
            )
            index += Array(code.utf8) + le32(piece.isKey ? 0x10 : 0) + le32(
                out.count - moviStart - 8
            ) + le32(piece.data.count)
            out += chunk(code, [UInt8](piece.data))
        }
        out.replaceSubrange(moviStart + 4..<moviStart + 8, with: le32(out.count - moviStart - 8))
        out += chunk("idx1", index)
        out.replaceSubrange(4..<8, with: le32(out.count - 8))
        try Data(out).write(to: url)
    }

    static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(body.count) + body + (body.count & 1 == 1 ? [0] : [])
    }

    static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    static func le32<T: BinaryInteger>(_ value: T) -> [UInt8] {
        let bits = UInt32(truncatingIfNeeded: value)
        return [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) }
    }
}
