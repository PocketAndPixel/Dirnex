import Foundation

/// Uploading a file too big for one `PUT` (PLAN.md §M21).
///
/// S3 refuses a single `PUT` above 5 GiB, so without this a file manager simply cannot put a large
/// file in a bucket — the operation fails at the end of however long it took to offer the whole
/// thing. A multipart upload opens an id, sends the file in numbered parts, and closes with a
/// manifest naming each part's ETag; the object appears only when the manifest is accepted.
///
/// Three properties this orchestration has to hold, none of them free:
///
/// - **Flat memory.** Each part is cut to a temp file and streamed by `curl -T`, so the resident
///   cost is a 1 MiB copy buffer whatever the file's size (``S3PartSlice``, which argues why a part
///   is a file on disk and what the alternatives measured).
/// - **An abort on every failing exit.** S3 stores the parts of an unfinished upload and **bills
///   for them**, invisibly to an ordinary listing — so a cancelled or failed upload that just
///   returns leaves the user paying for bytes they cannot see. Every exit but the successful one
///   goes through ``abort(key:uploadID:)``.
/// - **Progress that moves.** The single-`PUT` path can only report its bytes once, at the end,
///   because the whole object is one `curl` invocation; here each part reports as it lands, which
///   is what makes a determinate bar honest on a file that takes an hour.
///
/// The parts go **several at a time** (docs/HISTORY.md ▸ After M19). One part is one connection,
/// and one connection is not what a link gives — measured on this project's own account, one
/// stream carried 0.98 MB/s where four carried 3.13 aggregate — so a loop that sends one 16 MiB
/// part and waits leaves most of the link idle. How many go at once is the plan's
/// (``S3MultipartPlan/partsInFlight``), because the bound that decides it is the *disk*: every
/// part in flight is a slice cut to a temp file first.
/// What one multipart upload is about: the local bytes, where they are going, and how they are cut.
///
/// Bundled rather than passed as four parameters because every step of the upload needs the same
/// four and none of them varies between steps — which is also what keeps the orchestration's own
/// signatures readable once `progress` and `isCancelled` are added to them.
struct S3MultipartRequest {
    let localPath: String
    let key: String
    let destination: VFSPath
    let plan: S3MultipartPlan
}

/// One part as the *plan* describes it — which number it is and which bytes it covers — before
/// anything has been cut or sent. Paired for the reason the request above is: the two always travel
/// together, and separately they push the sending step past the parameter-count ceiling.
private struct PlannedPart {
    let number: Int
    let range: Range<Int64>
}

extension S3Backend {
    /// Upload a file in parts, reporting bytes as they move.
    ///
    /// `progress` is called with a **delta**, matching `VFSBackend.copyFile`'s contract and what
    /// `CopyEngine` expects — never the running total, which would make the engine's bar count every
    /// byte twice over. Each part reports as it goes and is then topped up to its exact length once
    /// it lands, so what the caller adds up is the plan's own arithmetic however coarse the
    /// in-flight estimate was (``S3Transport/uploadPart(localPath:to:uploadID:partNumber:progress:isCancelled:)``).
    ///
    /// `condition` is evaluated by the server at the **completion**, which is the request that
    /// publishes the object (PLAN.md §M21 Slice 19). It therefore protects the object without
    /// protecting the transfer: measured, every part is already sent and paid for by the time the
    /// refusal arrives, where a conditional single `PUT` is ended before its body moves. A refused
    /// completion leaves the upload open — the probe endpoint still held it — so the abort below is
    /// what stops the parts being billed, and that it already runs on every failing exit is the
    /// reason this cost nothing structurally.
    func uploadInParts(
        _ request: S3MultipartRequest,
        condition: S3WriteCondition = .unconditional,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let plan = request.plan
        let destination = request.destination
        let uploadID = try openUpload(key: request.key, at: destination)

        var parts: [S3UploadedPart] = []
        var moved: Int64 = 0
        do {
            for numbers in plan.batches {
                if isCancelled() { throw CancellationError() }
                var streamed: Int64 = 0
                parts += try sendBatch(
                    numbers,
                    of: request,
                    uploadID: uploadID,
                    progress: { delta in
                        streamed += delta
                        progress(delta)
                    },
                    isCancelled: isCancelled
                )
                let length = numbers.reduce(0) { $0 + plan.length(ofPart: $1) }
                moved += length
                reportRemainder(of: length, streamed: streamed, to: progress)
            }
            if isCancelled() { throw CancellationError() }
            try closeUpload(
                key: request.key,
                uploadID: uploadID,
                parts: parts,
                at: destination,
                condition: condition
            )
        } catch {
            // Best effort by construction: the upload has already failed, and a failing abort must
            // not replace the reason it failed with a second, less useful one.
            abort(key: request.key, uploadID: uploadID)
            throw error
        }
        return moved
    }

    /// Open the upload and read back the id everything else quotes.
    ///
    /// A 2xx with no readable id is treated as a failure rather than pressed on with: without an id
    /// there is nothing to upload parts against and — the half that matters — nothing to abort, so
    /// continuing would create parts that this code could never clean up.
    private func openUpload(key: String, at destination: VFSPath) throws -> String {
        let response = try write(at: destination) { try transport.createMultipartUpload(key: key) }
        guard let uploadID = S3MultipartDocument.uploadID(from: response.body) else {
            throw VFSError.io(path: destination, code: EIO)
        }
        return uploadID
    }

    /// Cut this batch's parts out of the file, send them **together**, and return what the server
    /// called each one.
    ///
    /// Every slice is removed on every exit path including the throwing ones, so a failed upload of
    /// a 100 GB file leaves nothing behind in the temp directory. They are cut before the batch
    /// rather than during it because `curl` reads each one as a file: what is on disk at once is
    /// ``S3MultipartPlan/partsInFlight`` slices, which is the bound that number exists to keep.
    ///
    /// A batch answers **per part**, and the first failing part in *number* order is the one
    /// reported — not the first to answer, which is whichever section the network happened to
    /// finish first and would make one failure name a different part on each run.
    private func sendBatch(
        _ numbers: [Int],
        of request: S3MultipartRequest,
        uploadID: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> [S3UploadedPart] {
        let destination = request.destination
        let planned = try numbers.map { number -> PlannedPart in
            guard let range = request.plan.range(ofPart: number) else {
                throw VFSError.io(path: destination, code: EIO)
            }
            return PlannedPart(number: number, range: range)
        }
        let slices = planned.map { part in
            (
                part: part,
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("dirnex-s3-part-\(UUID().uuidString)")
            )
        }
        defer { slices.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        try cut(slices, of: request)

        let responses = try mapping(destination) {
            try transport.uploadParts(
                slices.map {
                    S3PartRequest(
                        localPath: $0.url.path,
                        key: request.key,
                        uploadID: uploadID,
                        number: $0.part.number
                    )
                },
                progress: progress,
                isCancelled: isCancelled
            )
        }
        guard responses.count == slices.count else {
            // A transport that answered for a different set of parts cannot be reconciled with the
            // manifest, and pressing on would complete an upload naming parts nobody sent.
            throw VFSError.io(path: destination, code: EIO)
        }
        return try zip(slices, responses).map { slice, response in
            if let service = Self.serviceError(from: response) {
                throw service.vfsError(for: destination)
            }
            guard let etag = response.etag, !etag.isEmpty else {
                // A part with no ETag cannot be named in the manifest, so the upload can never be
                // completed — fail here, where the abort still runs, rather than at the completion.
                throw VFSError.io(path: destination, code: EIO)
            }
            return S3UploadedPart(number: slice.part.number, etag: etag)
        }
    }

    /// Write each planned part's bytes into its own temp file.
    ///
    /// A slice failure is about **this machine** — its disk, or the file changing underneath the
    /// upload — and never about S3, which is why it is mapped here rather than left to look like a
    /// transfer error.
    private func cut(
        _ slices: [(part: PlannedPart, url: URL)],
        of request: S3MultipartRequest
    ) throws {
        for slice in slices {
            do {
                _ = try S3PartSlice.write(
                    from: request.localPath,
                    range: slice.part.range,
                    to: slice.url.path
                )
            } catch {
                throw VFSError.io(path: request.destination, code: EIO)
            }
        }
    }

    /// Hand over the manifest, and read the **body** as well as the status.
    ///
    /// A completion can answer 200 carrying an `<Error>` document, so a status-only reading would
    /// report an object that does not exist as uploaded — the quiet direction, on the one request
    /// whose entire job is to say the file arrived
    /// (``S3MultipartDocument/completionFailure(from:status:)``).
    ///
    /// **That is also why a refusal is read twice here**, and the two readings are not redundant
    /// (PLAN.md §M21 Slice 19). `conditionallyWrite` classifies a refusal that arrives as a
    /// *status* — measured, `HTTP=412` — and cannot see one that arrives under a status the server
    /// already committed to; the body reading below is the only thing that can, and it was measured
    /// in the same shape (`HTTP=200` carrying `<Code>PreconditionFailed</Code>`). Both end at
    /// ``S3Backend/refusalError(_:or:at:)`` so the sentence has one definition.
    private func closeUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart],
        at destination: VFSPath,
        condition: S3WriteCondition
    ) throws {
        let response = try conditionallyWrite(at: destination, condition: condition) {
            try transport.completeMultipartUpload(
                key: key,
                uploadID: uploadID,
                parts: parts,
                condition: condition
            )
        }
        if let failure = S3MultipartDocument.completionFailure(
            from: response.body,
            status: response.status
        ) {
            throw Self.refusalError(condition.refusal(for: failure), or: failure, at: destination)
        }
    }

    /// Release the parts of an upload that will never be completed.
    ///
    /// Deliberately swallows its own failure: it runs on a path where something has already gone
    /// wrong, and the error the caller is carrying is the one worth reporting. What is lost when the
    /// abort itself fails is storage the user pays for, which a bucket lifecycle rule is the proper
    /// remedy for — not a second error message on top of the first.
    private func abort(key: String, uploadID: String) {
        _ = try? transport.abortMultipartUpload(key: key, uploadID: uploadID)
    }
}
