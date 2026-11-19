import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The sidebar's eject alert (2026-11-19): a volume in use names whatever is using it, as Finder
/// does, where the alert used to say "OSStatus error -47". The probe runs for real here, against
/// the volume this test host's own binary is on, which the host itself has mapped.
@Suite("Eject failure: who is using the volume")
struct EjectFailureTests {
    let busy = NSError(domain: NSOSStatusErrorDomain, code: -47)

    @Test("one name is in the sentence, and the status code is not")
    func oneName() {
        let detail = EjectFailure.inUse(by: ["VLC"]).detail
        #expect(detail.contains("VLC"))
        #expect(!detail.contains("-47"))
    }

    @Test("several names are all in the sentence")
    func severalNames() {
        let detail = EjectFailure.inUse(by: ["VLC", "Terminal"]).detail
        #expect(detail.contains("VLC"))
        #expect(detail.contains("Terminal"))
        #expect(detail != EjectFailure.inUse(by: ["VLC"]).detail)
    }

    @Test("in use with nobody to name still says it is in use, not the status")
    func noName() {
        let detail = EjectFailure.inUse(by: []).detail
        #expect(!detail.isEmpty)
        #expect(detail != busy.localizedDescription)
        #expect(!detail.contains("-47"))
    }

    @Test("any other failure is said in the error's own words, and nobody is asked")
    func otherFailure() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -36)
        let failure = EjectFailure.reading(error, volumeAt: Bundle.main.bundlePath)
        #expect(failure == .other(error.localizedDescription))
        #expect(failure.detail == error.localizedDescription)
    }

    @Test("the probe names this app on the volume its own binary is on")
    func probeNamesThisApp() throws {
        let me = try #require(NSRunningApplication.current.localizedName)
        let failure = EjectFailure.reading(busy, volumeAt: Bundle.main.bundlePath)
        guard case let .inUse(names) = failure else {
            Issue.record("a busy eject read as \(failure)")
            return
        }
        #expect(names.contains(me))
        #expect(Set(names).count == names.count, "each name once")
    }

    @Test("a path that is not there has nobody using it")
    func probeOnNothing() {
        #expect(VolumeUserProbe.names(usingVolumeAt: "/no/such/volume/\(UUID().uuidString)") == [])
    }
}
