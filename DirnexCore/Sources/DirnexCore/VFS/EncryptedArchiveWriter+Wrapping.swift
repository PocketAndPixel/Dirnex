import Foundation

/// The "hide file names" half of the writer: pack everything into one inner tar, then encrypt that
/// single entry into the outer zip.
///
/// Kept beside the main writer rather than inside it because it is a *composition* of the ordinary
/// path rather than a variant of it — both passes are the same `writeArchive`, and neither knows it
/// is part of a pair. See ``ArchiveNamePrivacy`` for why the inner container is a tar.
extension EncryptedArchiveWriter {
    /// Two passes: an unencrypted tar of the real selection, then an encrypted zip holding it.
    ///
    /// The cost is honest and worth stating, because a caller sizing a temporary volume needs it:
    /// this needs scratch space for a full uncompressed copy of the selection, and it reads those
    /// bytes twice. Streaming the tar straight into the outer entry would avoid both, and it is not
    /// available — a zip entry's size has to be declared before its data, and the tar's size is not
    /// known until it has been written.
    /// `outerPath` is the temporary the finished archive is built at; the inner tar is created beside
    /// it, which is also where the final rename lands — so one path answers both and there is no
    /// second destination to keep in step.
    static func writeWrapped(
        items: [ArchiveSourceItem],
        atPath outerPath: String,
        settings: Settings,
        onProgress: @escaping (Progress) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        let destinationPath = outerPath
        let dataBytes = ArchiveSourceEnumerator.totalByteSize(of: items)
        // Both passes move roughly the same bytes, so the bar is scaled to twice the data and each
        // pass fills half of it. The second half is the encrypt pass over what the first wrote —
        // clamped, since a tar is fractionally larger than its contents and a progress bar must
        // never report more than its own total.
        let scaledTotal = dataBytes * 2

        let innerPath = temporaryPath(besideArchiveAt: destinationPath)
        defer { try? FileManager.default.removeItem(atPath: innerPath) }

        try writeArchive(
            items: items,
            atPath: innerPath,
            settings: Settings(encryption: .none, passphrase: nil, level: .normal, container: .tar),
            onProgress: { inner in
                onProgress(Progress(
                    bytesWritten: min(inner.bytesWritten, dataBytes),
                    totalBytes: scaledTotal,
                    itemsWritten: inner.itemsWritten,
                    totalItems: inner.totalItems,
                    currentName: inner.currentName
                ))
            },
            isCancelled: isCancelled
        )

        var status = stat()
        guard stat(innerPath, &status) == 0 else {
            throw EncryptedArchiveError.archiveNotWritable
        }

        let wrapped = ArchiveSourceItem(
            onDiskPath: innerPath,
            archivePath: ArchiveNamePrivacy.wrappedEntryName,
            kind: .regularFile,
            byteSize: Int64(status.st_size),
            // A fixed, unremarkable mode and the current time: the wrapper is Dirnex's own container,
            // not one of the user's files, and giving it a real file's mode or mtime would leak a
            // fact about the contents into the plaintext part of the archive — which is the exact
            // thing this mode exists to prevent.
            permissions: 0o644,
            modificationDate: Date(),
            isDataless: false
        )

        try writeArchive(
            items: [wrapped],
            atPath: outerPath,
            settings: settings,
            onProgress: { outer in
                onProgress(Progress(
                    bytesWritten: dataBytes + min(outer.bytesWritten, dataBytes),
                    totalBytes: scaledTotal,
                    itemsWritten: outer.itemsWritten,
                    totalItems: 1,
                    currentName: ArchiveNamePrivacy.wrappedEntryName
                ))
            },
            isCancelled: isCancelled
        )
    }
}
