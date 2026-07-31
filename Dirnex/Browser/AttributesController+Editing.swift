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

        let reasons = AttributePrivilege.reasons(
            for: diff, current: old, actor: actor, changesAccessControlList: aclChanged
        )
        guard reasons.isEmpty else { presentNeedsAdministrator(reasons); return }

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

    // MARK: - Alerts

    /// The narrow root-only cases an owner can still reach, until Slice 5 adds the escalation. Stated
    /// rather than papered over: an `SF_*` `EPERM` is indistinguishable from the "you need root" one,
    /// so the panel says which it is instead of showing a raw error.
    ///
    /// The sentence is built from the reasons the core actually gave rather than assuming the
    /// system-flag case, which is the only one the controls could reach before dates and the group
    /// picker existed. That is also the seam Slice 5 slots into: it escalates exactly these reasons.
    private func presentNeedsAdministrator(_ reasons: [AttributePrivilege.Reason]) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "This change needs an administrator",
            comment: "Attributes save alert title: the change requires root privileges."
        )
        alert.informativeText = AttributeFormatting.privilegeExplanation(
            reasons.first, name: snapshot.entry.name
        )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        present(alert)
    }

    private func presentApplyFailure(_ error: Error) {
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

    private func present(_ alert: NSAlert) {
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
