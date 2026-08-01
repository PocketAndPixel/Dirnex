import AppKit
import DirnexCore

/// The editable half of the Permissions tab (PLAN.md §M14 Slice 4): mode bits and BSD flags, applied
/// on **Save** as one undoable gesture, discarded on Cancel.
///
/// Every byte-touching decision is already in the tested core — ``AttributeDiff`` says what changed,
/// ``AttributePrivilege`` says whether it needs root, ``AttributeChangePlan`` orders the syscalls
/// (the immutable unlock/relock included), and ``FileAttributeIO`` runs them. This file is the thin
/// AppKit shell: it turns the live checkboxes into a ``working`` copy, echoes the mode, and commits.
extension AttributesController {
    // MARK: - Live editing

    /// Any checkbox changed: rebuild ``working`` from *all* of them at once, then refresh the Mode
    /// echo and Save's enablement together, so the three never disagree.
    @objc func editChanged(_ sender: Any?) {
        rebuildWorkingFromControls()
        refreshModeEcho()
        refreshSaveEnabled()
    }

    private func rebuildWorkingFromControls() {
        var permissions = POSIXPermissions(rawValue: 0)
        for entry in modeBoxes {
            permissions[entry.cls, entry.access] = entry.box.state == .on
        }
        permissions.setUserID = setUserIDBox?.state == .on
        permissions.setGroupID = setGroupIDBox?.state == .on
        permissions.sticky = stickyBox?.state == .on
        working.permissions = permissions

        // Start from what was read so the bits with no checkbox — the `SF_*` flags and `SF_DATALESS`
        // — are preserved rather than dropped; only the offered `UF_*` bits are toggled.
        var flags = snapshot.attributes.flags
        for entry in flagBoxes {
            if entry.box.state == .on { flags.insert(entry.flag) } else { flags.remove(entry.flag) }
        }
        working.flags = flags

        if let tag = groupPopup?.selectedItem?.tag { working.groupID = UInt32(tag) }

        for field in dateFields {
            // An untouched picker hands back the *original* value, not its own — see `DateField`.
            // Without this the sub-second remainder every real timestamp carries would show up as an
            // edit on all three dates the moment the sheet opened.
            let edited = field.picker.dateValue != field.initial
            switch field.kind {
            case .access:
                working.accessDate = edited ? field.picker.dateValue : snapshot.attributes.accessDate
            case .modification:
                working.modificationDate = edited
                    ? field.picker.dateValue : snapshot.attributes.modificationDate
            case .creation:
                working.creationDate = edited
                    ? field.picker.dateValue : snapshot.attributes.creationDate
            }
        }
    }

    func refreshModeEcho() {
        modeValueField?.stringValue = AttributeFormatting.modeDescription(working.permissions)
    }

    /// Save is live when something changed **and** the change is one the panel can write.
    ///
    /// The validity half is the ACL's: an entry carrying no rights is a state the OS stores happily
    /// and that decides nothing (probed), so the panel refuses to write one rather than saving a row
    /// that does nothing. Gating Save is the honest place for that — the alternative is an alert at
    /// commit time about a row the user can already see.
    func refreshSaveEnabled() {
        let changed = !AttributeDiff(from: snapshot.attributes, to: working).isEmpty
            || accessControlListChanged
        saveButton?.isEnabled = changed && accessControlTable?.isValid != false
    }

    // MARK: - Recursion

    /// The recursive job this sheet's edits describe, or `nil` when the box is unticked or there is
    /// nothing to force.
    ///
    /// The translation from a whole-value edit to a patch is ``AttributePatch/init(from:to:)``'s, and
    /// it is a core decision rather than a detail of this file: a changed mode travels whole because
    /// a mode is a shape, while flags travel bit by bit so a `UF_HIDDEN` on one file inside the
    /// folder survives ticking Locked on the folder.
    ///
    /// The ACL travels as a **whole list** when it was edited, adjusted to each item's kind by the
    /// runner — a file cannot carry `delete_child` or an inheritance flag meaningfully, and the
    /// kernel will store one anyway if nobody stops it (probed).
    func recursiveJob() -> AttributeApplyJob? {
        guard let options = recursiveOptions, options.isRecursive else { return nil }
        let job = AttributeApplyJob(
            patch: AttributePatch(from: snapshot.attributes, to: working),
            accessControlList: accessControlListChanged ? workingAccessControlList : nil,
            target: options.target
        )
        return job.isEmpty ? nil : job
    }

    // MARK: - Commit

    /// Apply the diff between what was read and what the boxes now say, as one operation: check it
    /// does not need root, run the ordered plan, journal it for ⌘Z, re-list the pane, and close. An
    /// empty diff just closes; a root-only change (a system-immutable file) is refused with an
    /// explanation rather than the bare `EPERM` it would otherwise hit.
    @objc func saveAttributes(_ sender: Any?) {
        let old = snapshot.attributes
        let diff = AttributeDiff(from: old, to: working)
        // The ACL rides beside the diff rather than inside it: it is an ordered list, not a field,
        // so "changed" is a whole-value comparison and the change is a whole-list replacement.
        let aclChanged = accessControlListChanged
        let newList = workingAccessControlList
        guard !diff.isEmpty || aclChanged else { dismiss(sender); return }

        // "Apply to enclosed items" replaces the flat write rather than running beside it, so the
        // item on screen and everything under it are one operation with one undo record. Doing the
        // root here and the tree there would take two Cmd+Z to reverse one gesture.
        if let job = recursiveJob() {
            confirmRecursive(job, sender)
            return
        }

        let reasons = AttributePrivilege.reasons(
            for: diff, current: old, actor: actor, changesAccessControlList: aclChanged
        )
        // A change that needs root — a file the user does not own, or a system-immutable one they do
        // — is offered the escalation instead of refused (Slice 5): the same edit, run as an
        // administrator. The dialog builds the elevated command from this exact diff and ACL.
        guard reasons.isEmpty else {
            presentEscalation(
                diff: diff,
                old: old,
                aclChanged: aclChanged,
                newList: newList,
                sender: sender
            )
            return
        }

        do {
            // One plan for both halves, so a locked item unlocks once and relocks once — `acl_set` is
            // EPERM under UF_IMMUTABLE exactly as `chmod` is (probed), and two separate writes would
            // either surface that EPERM or unlock the file twice.
            let plan = AttributeChangePlan(
                diff: diff,
                current: old,
                actsOnLink: snapshot.isSymlink,
                accessControlList: aclChanged ? newList : nil
            )
            try FileAttributeIO.apply(plan, to: snapshot.entry.path)
            if let record = UndoRecord.attributeChange(
                at: snapshot.entry.path,
                actsOnLink: snapshot.isSymlink,
                from: old,
                to: working,
                accessControlList: aclChanged
                    ? (old: snapshot.accessControlList, new: newList)
                    : nil
            ) {
                recordUndo?(record)
            }
            onApplied?()
            dismiss(sender)
        } catch {
            presentApplyFailure(error)
        }
    }

    /// Count the tree, ask, and hand the job to the queue. The sheet closes as soon as the job is
    /// accepted: it is queued work now, with its own bar and cancel button, and a sheet left sitting
    /// over a running operation would only be describing a state that no longer exists.
    private func confirmRecursive(_ job: AttributeApplyJob, _ sender: Any?) {
        RecursiveApplyConfirmation.ask(
            over: [snapshot.entry],
            job: job,
            using: LocalBackend(),
            in: view.window
        ) { [weak self] confirmed in
            guard let self else { return }
            enqueueRecursive?(confirmed, [snapshot.entry])
            dismiss(sender)
        }
    }

    // MARK: - Alerts

    func presentApplyFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn’t change “\(snapshot.entry.name)”",
            comment: "Attributes save failure title; %@ is the item name."
        )
        alert.informativeText = VFSErrorText.sentence(for: error)
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        present(alert)
    }

    func present(_ alert: NSAlert) {
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
