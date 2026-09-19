import Foundation

/// GoPro's General Purpose Raw (`.GPR`) — the one image format on this Mac that nothing in macOS
/// can decode, and what Dirnex has to know about it before spawning the helper that can.
///
/// ## Why a helper exists at all
///
/// Every other camera RAW reaches the image backend through Core Image (▸ `RAWImageDecoder`). A GPR
/// cannot, and it fails in a way that looks like support: probed 2026-09-20 against two HERO7 files,
/// ImageIO *identifies* the container as `com.adobe.raw-image`, reports `count = 1`, returns a
/// complete status and reads the **whole** EXIF/DNG/TIFF metadata block — and then answers `nil` to
/// `CGImageSourceCreateImageAtIndex`, `nil` to `CGImageSourceCreateThumbnailAtIndex`, and `nil` to
/// `CIRAWFilter.outputImage`. `NSImage` and `sips` both read `0x0`. Renaming the file to `.dng`
/// changes none of it, while a real `.dng` decodes to 6000x4000 through the identical call — so the
/// extension is not the blocker and the codec is.
///
/// The container says why: one IFD, 4000x3000, `Compression = 9` — GoPro's **VC-5 wavelet codec**,
/// which macOS ships no decoder for — with `PhotometricInterpretation = 32803` (a Bayer mosaic).
/// There is no `SubIFDs` tag and no `JPEGInterchangeFormat` tag, so unlike almost every other RAW
/// **a GPR embeds no preview at all**: there is nothing to fall back on. The only JPEG-looking byte
/// runs in the file are false positives inside compressed data, carrying no dimensions.
///
/// ## Why the file name is not enough to decide on
///
/// `.gpr` is not GoPro's alone — Gerber and other tools use it — and GoPro's own files are the ones
/// that must not reach Quick Look, so the test has to be cheap *and* has to be about the bytes. A
/// GPR is a DNG, so it opens with a TIFF header; anything that does not is left to Quick Look
/// exactly as before. The converter's exit status is the second, authoritative gate, which is why
/// this one only has to be cheap enough to run while the cursor moves.
public enum GoProRAW {
    /// The extension GoPro writes, matched case-insensitively — cameras write `.GPR`.
    public static let pathExtension = "gpr"

    /// How many leading bytes ``hasContainerHeader(_:)`` needs. Small enough to read while the
    /// cursor is moving, which is when this question gets asked.
    public static let headerLength = 4

    /// Whether `name` is spelled like a GoPro RAW. Necessary, never sufficient — pair it with
    /// ``hasContainerHeader(_:)``.
    public static func namesGoProRAW(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == pathExtension
    }

    /// Whether `prefix` opens with a TIFF header, which every DNG — and so every GPR — does.
    ///
    /// Both byte orders are accepted although GoPro writes little-endian (`II*\0`, measured on both
    /// fixtures): the DNG specification permits either, and refusing the one this camera happens not
    /// to use would be a rule about one model rather than about the format.
    public static func hasContainerHeader(_ prefix: Data) -> Bool {
        guard prefix.count >= headerLength else { return false }
        let bytes = [UInt8](prefix.prefix(headerLength))
        let littleEndian: [UInt8] = [0x49, 0x49, 0x2A, 0x00] // "II*\0"
        let bigEndian: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A] // "MM\0*"
        return bytes == littleEndian || bytes == bigEndian
    }

    /// The argv that turns a GPR into a DNG macOS can read.
    ///
    /// DNG is the output to ask for, and the alternatives were measured rather than assumed. The
    /// tool also writes PPM and JPG, both of which are **downsampled previews**: `-r 4:1` gives
    /// 1000x750 and `-r 2:1` gives 2000x1500, while `-r 1:1` — the spelling that looks like full
    /// resolution — writes an **11-byte 0x0 file and still exits 0**, which is the quiet direction
    /// and the reason nothing here trusts an exit status alone. Only the DNG carries the full
    /// 4000x3000 sensor image.
    ///
    /// Asking for a DNG is also what keeps a GPR looking like every other RAW in Dirnex: the file
    /// this produces is an ordinary `com.adobe.raw-image` that goes through the *existing*
    /// `RAWImageDecoder` unchanged, so the demosaic, the EXIF orientation and the Display P3 tagging
    /// are the same code every ARW, NEF and CR2 already takes, rather than a second rendering of the
    /// same photograph that would not match its neighbours.
    public static func conversionArguments(inputPath: String, outputPath: String) -> [String] {
        ["-i", inputPath, "-o", outputPath]
    }

    /// What the helper's exit told us. Three outcomes rather than a `Bool`, because the third one is
    /// the reason the decoder is a separate process at all.
    public enum Conversion: Equatable, Sendable {
        /// The helper exited cleanly. It says nothing about the file it wrote — the `-r 1:1` case
        /// above exits 0 having written nothing usable — so the caller still has to look.
        case converted
        /// The helper refused the file and said so (measured: exit 255 for a missing input and for a
        /// JPEG handed in as one). An ordinary answer about an unordinary file.
        case refused
        /// The helper **died on the file**, which is not hypothetical: measured 2026-09-20, a
        /// truncated GPR aborts it outright — `libc++abi: terminating due to uncaught exception of
        /// type dng_exception`, SIGABRT, exit 134.
        ///
        /// This case is the architecture's whole justification. The codec is 168k lines of vendored
        /// C++ that calls `abort()` on input it dislikes, and a partly-copied or corrupt GPR is
        /// exactly the kind of file a file manager puts the cursor on. In-process that is Dirnex
        /// gone; out of process it is this value.
        case crashed
    }

    /// Classify a finished helper run. `wasSignalled` is `Process.terminationReason == .uncaughtSignal`.
    public static func outcome(exitCode: Int32, wasSignalled: Bool) -> Conversion {
        if wasSignalled { return .crashed }
        return exitCode == 0 ? .converted : .refused
    }
}
