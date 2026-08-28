import AppKit
import DirnexCore

/// Running the Synchronize sheet's comparison, and reporting on it — the scan itself, the summary
/// under the table, and the sentence a failed scan shows.
///
/// Split from ``SyncDirectoriesController`` at M25 Slice 5c along with the layout, when the class
/// body crossed SwiftLint's 250-line ceiling. What is left in the class is the *model*: which rows
/// exist, what action each carries, and which of them the user has checked.
extension SyncDirectoriesController {
    // MARK: - Scan

    /// Run the comparison off the main thread (content mode reads bytes), then rebuild the rows.
    /// Called on load and whenever the comparison method changes; a direction change only
    /// re-derives actions in memory (`recomputeActions`) without re-reading the folders.
    func startScan() {
        isScanning = true
        scanError = nil
        spinner.startAnimation(nil)
        updateChrome()
        let backend = backend
        let left = leftDir
        let right = rightDir
        let comparison = comparison
        Task {
            let outcome = await BlockingWork.run { () -> Result<
                [SyncEntry],
                any Error
            > in
                do {
                    return .success(try DirectorySync.compare(
                        left: left, right: right,
                        leftBackend: backend, rightBackend: backend,
                        comparison: comparison
                    ))
                } catch {
                    return .failure(error)
                }
            }
            finishScan(outcome)
        }
    }

    func finishScan(_ outcome: Result<[SyncEntry], any Error>) {
        isScanning = false
        spinner.stopAnimation(nil)
        switch outcome {
        case let .success(entries):
            rows = entries.map { entry in
                let action = DirectorySync.defaultAction(for: entry.status, direction: direction)
                return Row(entry: entry, action: action, included: isActionable(action))
            }
        case let .failure(error):
            rows = []
            scanError = (error as? VFSError).map(describe) ?? String(
                localized: "The folders couldn’t be compared.",
                comment: "Sync error: the comparison failed for an unspecified reason."
            )
        }
        tableView.reloadData()
        updateChrome()
    }

    // MARK: - Chrome

    func updateChrome() {
        directionControl.isEnabled = !isScanning
        comparisonControl.isEnabled = !isScanning
        if isScanning {
            setStatus(String(
                localized: "Comparing folders…",
                comment: "Sync status shown while the two folders are being compared."
            ), isError: false)
            syncButton.isEnabled = false
            return
        }
        if let scanError {
            setStatus(scanError, isError: true)
            syncButton.isEnabled = false
            return
        }
        if rows.isEmpty {
            setStatus(String(
                localized: "The folders are already in sync.",
                comment: "Sync status: no differences were found."
            ), isError: false)
            syncButton.isEnabled = false
            return
        }
        let checked = rows.filter { $0.included && isActionable($0.action) }
        let copies = checked.count { isCopy($0.action) }
        let deletes = checked.count - copies
        let conflicts = rows.count { $0.action == .conflict }
        var text = String(
            localized: "\(copies) to copy, \(deletes) to delete",
            comment: "Sync status summary; %1$lld files to copy, %2$lld to delete."
        )
        if conflicts > 0 {
            text += " · " + String(
                localized: "\(conflicts) conflicts skipped",
                comment: "Sync status suffix; %lld conflicting items left unchanged. Plural."
            )
        }
        setStatus(text, isError: false)
        syncButton.isEnabled = !checked.isEmpty
    }

    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func describe(_ error: VFSError) -> String {
        switch error {
        case .notFound:
            return String(
                localized: "One of the folders no longer exists.",
                comment: "Sync error: a compared folder was removed."
            )
        case .permissionDenied:
            return String(
                localized: "Permission was denied reading one of the folders.",
                comment: "Sync error: no read permission on a compared folder."
            )
        default:
            return String(
                localized: "The folders couldn’t be compared.",
                comment: "Sync error: the comparison failed for an unspecified reason."
            )
        }
    }
}
