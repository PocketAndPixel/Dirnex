import Foundation
import Testing

@testable import DirnexCore

/// The truth table behind the sync badge. Every case here is a shape a **real** iCloud file was
/// observed in while building this (see `CloudItemAttributes.status`) — an evicted placeholder, a
/// download sampled every 20 ms, a 60 MB upload, and the `.DS_Store` that sits inside iCloud Drive
/// without being a cloud file at all.
@Suite("CloudSyncStatus")
struct CloudSyncStatusTests {
    // MARK: - The system's own spellings

    @Test("the three downloading statuses map from the strings the system actually reports")
    func downloadingStatusRawValues() {
        // Probed off live files, not recalled: these are what `URLUbiquitousItemDownloadingStatus`
        // hands back on macOS. A typo here would silently make every row "unknown".
        #expect(
            CloudDownloadingStatus(rawValue: "NSURLUbiquitousItemDownloadingStatusCurrent")
                == .current
        )
        #expect(
            CloudDownloadingStatus(rawValue: "NSURLUbiquitousItemDownloadingStatusNotDownloaded")
                == .notDownloaded
        )
        #expect(
            CloudDownloadingStatus(rawValue: "NSURLUbiquitousItemDownloadingStatusDownloaded")
                == .downloaded
        )
        #expect(CloudDownloadingStatus(rawValue: "something else") == nil)
    }

    @Test("the transfer errors map from the codes the system actually reports")
    func transferErrorCodes() {
        // Probed off live files too: 4355 is what a real iCloud upload reports, every time, and the
        // numbers are pinned here rather than left implicit in the Cocoa constants because that
        // reading is the whole reason this type exists.
        #expect(CloudTransferError(domain: NSCocoaErrorDomain, code: 4355) == .serverUnavailable)
        #expect(CloudTransferError(domain: NSCocoaErrorDomain, code: 4354) == .quotaExceeded)
        #expect(CloudTransferError(domain: NSCocoaErrorDomain, code: 4353) == .itemUnavailable)
        #expect(CloudTransferError(domain: NSCocoaErrorDomain, code: 999_999) == .other)
        // The same number in someone else's domain is someone else's meaning.
        #expect(CloudTransferError(domain: NSURLErrorDomain, code: 4355) == .other)
    }

    @Test("only an unreachable server is not a verdict on the file")
    func onlyServerUnavailableIsNoise() {
        for error in CloudTransferError.allCases {
            #expect(error.isVerdict == (error != .serverUnavailable))
        }
    }

    // MARK: - Is this a cloud row at all?

    @Test("a file outside any cloud container has no status")
    func nonCloudFileHasNoStatus() {
        // Every ubiquity attribute reads `nil` out there, which the reader defaults to `false`.
        #expect(CloudItemAttributes().status == nil)
    }

    @Test("a local-only file inside a cloud folder has no status, even though it claims .current")
    func localFileInsideCloudFolderHasNoStatus() {
        // THE discriminator case: `.DS_Store` inside iCloud Drive really does report
        // `isUbiquitous == false` **and** `.current`. Keying off the status would badge it as synced.
        let dsStore = CloudItemAttributes(isUbiquitous: false, downloadingStatus: .current)
        #expect(dsStore.status == nil)
    }

    // MARK: - The states

    @Test("an evicted placeholder reads as not downloaded")
    func evictedFileIsNotDownloaded() {
        let evicted = CloudItemAttributes(isUbiquitous: true, downloadingStatus: .notDownloaded)
        #expect(evicted.status == .notDownloaded)
        #expect(evicted.status?.isNoteworthy == true)
    }

    @Test("a fully synced file is up to date, and draws nothing")
    func syncedFileIsUpToDate() {
        let synced = CloudItemAttributes(isUbiquitous: true, downloadingStatus: .current)
        #expect(synced.status == .upToDate)
        #expect(synced.status?.isNoteworthy == false)
    }

    @Test("a stale-but-local file counts as up to date — its bytes are here")
    func downloadedStatusIsUpToDate() {
        let stale = CloudItemAttributes(isUbiquitous: true, downloadingStatus: .downloaded)
        #expect(stale.status == .upToDate)
    }

    @Test("a download in flight beats the status still saying NotDownloaded")
    func downloadingBeatsNotDownloadedStatus() {
        // Sampled at 2.29 s of a real `brctl download`: the flag is already true while the status
        // has not caught up. Consulting the status first would paint "in the cloud" over a file
        // that is actively arriving.
        let arriving = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .notDownloaded,
            isDownloading: true
        )
        #expect(arriving.status == .downloading)
    }

    @Test("a file with local changes not yet in the cloud reads as uploading")
    func pendingUploadIsUploading() {
        // The 60 MB probe: `isUploading` stayed false the whole way up while `isUploaded` was false
        // throughout — so the pending flag, not the active one, is what actually reports an upload.
        let pending = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false
        )
        #expect(pending.status == .uploading)

        let active = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploading: true
        )
        #expect(active.status == .uploading)
    }

    @Test("an unanswered isUploaded is not read as a pending upload")
    func unknownUploadStateIsNotPending() {
        // The default is `true` on purpose: a provider that declines to answer must not have every
        // one of its rows badged as forever uploading.
        #expect(
            CloudItemAttributes(isUbiquitous: true, downloadingStatus: .current).status == .upToDate
        )
    }

    // MARK: - Precedence

    @Test("a real error outranks every transfer state")
    func errorWins() {
        let failed = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .notDownloaded,
            isDownloading: true,
            downloadingError: .itemUnavailable
        )
        #expect(failed.status == .failed)

        let failedUpload = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false,
            uploadingError: .quotaExceeded
        )
        #expect(failedUpload.status == .failed)
    }

    @Test("the error iCloud reports on every healthy upload does not read as a failure")
    func serverUnavailableDoesNotFail() {
        // THE regression, live-reported and then reproduced: applying a Finder tag red-crossed the
        // row for the couple of seconds the upload took. This is that exact sample — iCloud reports
        // `isUploading` **and** "server not available" together, on a sync that completes fine.
        let taggedAndUploading = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploading: true,
            isUploaded: false,
            uploadingError: .serverUnavailable
        )
        #expect(taggedAndUploading.status == .uploading)

        // And the 60 MB sample, where the error was there before `isUploading` had caught up: still
        // an upload, still not a failure.
        let pending = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false,
            uploadingError: .serverUnavailable
        )
        #expect(pending.status == .uploading)
    }

    @Test("an unreachable server does not suppress a real error alongside it")
    func serverUnavailableDoesNotMaskAVerdict() {
        // The suppression is per-error, not "any noise means no failure": a download that genuinely
        // has nowhere to come from still fails while the server is also unreachable.
        let both = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .notDownloaded,
            downloadingError: .itemUnavailable,
            uploadingError: .serverUnavailable
        )
        #expect(both.status == .failed)
    }

    @Test("a conflict outranks a transfer, and yields only to an error")
    func conflictPrecedence() {
        let conflicted = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false,
            hasUnresolvedConflicts: true
        )
        #expect(conflicted.status == .conflicted)

        let both = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            hasUnresolvedConflicts: true,
            uploadingError: .quotaExceeded
        )
        #expect(both.status == .failed)

        // A conflict still wins over the routine upload noise, rather than being hidden by it.
        let conflictedMidUpload = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false,
            hasUnresolvedConflicts: true,
            uploadingError: .serverUnavailable
        )
        #expect(conflictedMidUpload.status == .conflicted)
    }

    @Test("an excluded file is excluded, not eternally uploading")
    func excludedOutranksPendingUpload() {
        // An excluded file never uploads, so `isUploaded` is false on it forever. Asking about
        // uploads first would badge it as pending for the rest of its life.
        let excluded = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false,
            isExcludedFromSync: true
        )
        #expect(excluded.status == .excluded)
    }

    @Test("exactly the two transfers are transfers")
    func onlyTransfersAreTransient() {
        // What this drives: a resting state is announced by the filesystem, a transfer *ends*
        // without an event, so the provider has to look again while one is showing. A live run
        // caught the badge stuck on "downloading" for precisely this reason.
        for status in CloudSyncStatus.allCases {
            #expect(status.isTransfer == (status == .downloading || status == .uploading))
        }
    }

    @Test("only up-to-date is unworthy of a badge")
    func onlyUpToDateDrawsNothing() {
        for status in CloudSyncStatus.allCases {
            #expect(status.isNoteworthy == (status != .upToDate))
        }
    }
}
