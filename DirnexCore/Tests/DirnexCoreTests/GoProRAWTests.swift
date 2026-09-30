import Foundation
import Testing

@testable import DirnexCore

/// The pure half of GoPro RAW support: which files are offered to the helper, what it is asked, and
/// what its exit meant (PLAN.md §2 — the spawn itself lives in the app).
@Suite("GoPro RAW")
struct GoProRAWTests {
    // MARK: - Naming

    @Test("the extension is matched however the camera spelled it")
    func nameIsCaseInsensitive() {
        // GoPro writes `.GPR`; a copy made on another machine may not have kept the case.
        #expect(GoProRAW.namesGoProRAW("GOPR4581.GPR"))
        #expect(GoProRAW.namesGoProRAW("GOPR4581.gpr"))
        #expect(GoProRAW.namesGoProRAW("GOPR4581.Gpr"))
    }

    @Test("a name that merely contains the letters is not a GoPro RAW")
    func nameIsNotASubstringMatch() {
        #expect(!GoProRAW.namesGoProRAW("gpr"))
        #expect(!GoProRAW.namesGoProRAW("GOPR4581.GPR.txt"))
        #expect(!GoProRAW.namesGoProRAW("report.gprx"))
        #expect(!GoProRAW.namesGoProRAW("GOPR4581.JPG"))
    }

    // MARK: - Header

    /// The bytes these fixtures carry are the ones the real files open with: measured 2026-09-20,
    /// both HERO7 fixtures begin `49 49 2A 00`.
    @Test("a TIFF header in either byte order is a container we can offer the helper")
    func headerAcceptsBothByteOrders() {
        #expect(GoProRAW.hasContainerHeader(Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00])))
        #expect(GoProRAW.hasContainerHeader(Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x08])))
    }

    @Test("anything else keeps whatever Quick Look does with it")
    func headerRefusesOtherFormats() {
        // `.gpr` is not GoPro's alone, and a file that is not a DNG container must not be handed to
        // a decoder that aborts on input it dislikes.
        #expect(!GoProRAW.hasContainerHeader(Data([0xFF, 0xD8, 0xFF, 0xE0]))) // JPEG
        #expect(!GoProRAW.hasContainerHeader(Data("G04*".utf8))) // Gerber-ish text
        #expect(!GoProRAW.hasContainerHeader(Data([0x49, 0x49, 0x2B, 0x00]))) // BigTIFF, not DNG
    }

    @Test("a file too short to carry a header is refused rather than read past")
    func headerRefusesShortFiles() {
        #expect(!GoProRAW.hasContainerHeader(Data()))
        #expect(!GoProRAW.hasContainerHeader(Data([0x49, 0x49, 0x2A])))
    }

    // MARK: - Arguments

    @Test("the helper is asked for a DNG, which is the only full-resolution output it has")
    func argumentsRequestTheInputAndOutput() {
        let arguments = GoProRAW.conversionArguments(
            inputPath: "/in/GOPR.GPR",
            outputPath: "/out/x.dng"
        )

        #expect(arguments == ["-i", "/in/GOPR.GPR", "-o", "/out/x.dng"])
    }

    /// The narrowness half of the argument test: nothing may reach the helper that selects a
    /// *reduced* output. `-r` is the flag that does, and `-r 1:1` is the one that exits 0 having
    /// written an 11-byte file — so a caller that grew a resolution argument would get a preview
    /// that silently became empty rather than one that failed.
    @Test("no resolution flag is passed, so the output cannot be a downsampled preview")
    func argumentsCarryNoResolutionFlag() {
        let arguments = GoProRAW.conversionArguments(
            inputPath: "/in/a.GPR",
            outputPath: "/out/b.dng"
        )

        #expect(!arguments.contains("-r"))
        #expect(!arguments.contains { $0.contains(":") })
    }

    @Test("a path is passed as one argument, so spaces and non-ASCII need no quoting")
    func argumentsPassPathsWhole() {
        let input = "/Volumes/My Card/DCIM/Панорама.GPR"
        let arguments = GoProRAW.conversionArguments(inputPath: input, outputPath: "/tmp/o.dng")

        #expect(arguments.contains(input))
    }

    // MARK: - Outcome

    @Test("a clean exit is a conversion")
    func cleanExitConverts() {
        #expect(GoProRAW.outcome(exitCode: 0, wasSignalled: false) == .converted)
    }

    @Test("the refusal the helper reports for a file it will not read is not a crash")
    func nonZeroExitIsARefusal() {
        // Measured: 255 for a missing input and for a JPEG handed in as one.
        #expect(GoProRAW.outcome(exitCode: 255, wasSignalled: false) == .refused)
        #expect(GoProRAW.outcome(exitCode: 1, wasSignalled: false) == .refused)
    }

    /// The case the separate process exists for. A truncated GPR aborts the decoder, and a signalled
    /// death must never be read as an ordinary refusal — it is the evidence that the codec cannot be
    /// trusted in-process.
    @Test("a signalled death is a crash, whatever exit code came with it")
    func signalledExitIsACrash() {
        #expect(GoProRAW.outcome(exitCode: 134, wasSignalled: true) == .crashed)
        #expect(GoProRAW.outcome(exitCode: 0, wasSignalled: true) == .crashed)
    }
}
