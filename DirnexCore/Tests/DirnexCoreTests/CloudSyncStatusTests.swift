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

    @Test("an error outranks every transfer state")
    func errorWins() {
        let failed = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .notDownloaded,
            isDownloading: true,
            hasDownloadingError: true
        )
        #expect(failed.status == .failed)

        let failedUpload = CloudItemAttributes(
            isUbiquitous: true,
            downloadingStatus: .current,
            isUploaded: false,
            hasUploadingError: true
        )
        #expect(failedUpload.status == .failed)
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
            hasUploadingError: true
        )
        #expect(both.status == .failed)
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
