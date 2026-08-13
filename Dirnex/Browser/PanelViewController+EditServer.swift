import AppKit
import DirnexCore

/// The sidebar's **Edit…** — the same Connect sheet, prefilled, whose Connect button is also the
/// button that saves.
///
/// Split from `PanelViewController+Connect` when that file reached SwiftLint's `file_length`, and it
/// is the concept boundary anyway: everything there is about *reaching* a server, everything here is
/// about the saved record — which is a different question, asked by a different gesture, and the one
/// the connect path deliberately treats as a side effect.
///
/// **There is no update path and there must not be one.** The record is written from
/// `form.endpoint`, which is the very `ServerEndpoint` the store holds, so every field of every
/// protocol is covered by construction and a protocol added later arrives covered. A hand-written
/// per-protocol commit would be the same question with five answers — this project's most repeated
/// finding — and the fields it forgot would be exactly the ones with no control behind them, the way
/// FTPS's certificate pin was dropped by a `_` in a pattern match for the whole life of the feature.
extension PanelViewController {
    /// Re-open the connect sheet prefilled from a saved server (the sidebar's "Edit…").
    ///
    /// **Connect is this sheet's OK button, so it commits the edit before it attempts anything.**
    /// The record is written from `form.endpoint`, which is the same `ServerEndpoint` the store
    /// holds — so every field of every protocol is covered by construction, and a protocol added
    /// later arrives covered rather than needing a line here.
    ///
    /// It used to save only on a *successful* connection, which is what made the button a liar:
    /// changing a port on a server that is down, fixing a typo in a host that no longer answers, or
    /// correcting a password on a machine that is asleep were all edits the app took, used once and
    /// discarded. Nothing on screen said so — the sheet stays open on a failure, so the fields still
    /// show what was typed, and the loss only shows up at the next launch. The old rule survives
    /// where it belongs: a **new** connection still records nothing until it works, so a first
    /// attempt that fails does not litter the sidebar with a row that has never connected.
    func editServer(_ server: ServerConnection) {
        guard let window = view.window else { return }
        ConnectServerPrompt.present(
            over: window,
            prefill: server,
            attempt: { [weak self] form in
                guard let self else { return .failed(Self.genericConnectError) }
                if let refusal = commitEdit(form, replacing: server) { return .failed(refusal) }
                return await apply(form)
            },
            onSucceeded: { [weak self] in self?.focusTable() }
        )
    }

    /// Write the edited record, or answer with the sentence that says why not.
    ///
    /// The secret goes with it, which is the one place this departs from "only persist a password
    /// once it has authenticated". That rule is right for a new connection, where an unverified
    /// secret is filed against coordinates nothing else refers to; here the record is being
    /// rewritten in the same breath, so holding the secret back produces a *split* state — a row
    /// pointing at the newly typed host with the old host's password — which fails later, from the
    /// sidebar, with nothing to connect it to the edit that caused it.
    private func commitEdit(
        _ form: ConnectServerPrompt.Form,
        replacing previous: ServerConnection
    ) -> String? {
        // A cleared "Save as" is a request to connect *without* a bookmark, not a request to delete
        // one: removing a saved server is its own confirmed gesture, and it must not be reachable by
        // emptying a text field.
        guard let name = form.saveName else { return nil }
        var store = ServerConnectionStore.load()
        let edited = ServerConnection(name: name, endpoint: form.endpoint)
        switch store.commitEdit(of: previous.name, as: edited) {
        case .committed:
            ServerConnectionStore.save(store)
            storeSecret(of: form)
            return nil
        case let .nameTaken(taken):
            return String(
                localized: """
                Another saved server is already called “\(taken)”. \
                Give this one a different name to keep both.
                """,
                comment: "Connect-sheet failure when an edit renames a server onto an existing name."
            )
        }
    }

    /// File the typed secret under the edited coordinates. A form that carries none — key-file SFTP,
    /// anonymous FTP, a guest share — has nothing to store, and `SecretKeychain` declines the ones
    /// whose location says it keeps no secret.
    private func storeSecret(of form: ConnectServerPrompt.Form) {
        guard let password = form.password, !password.isEmpty else { return }
        switch form.endpoint {
        case let .sftp(location, _): _ = SecretKeychain.store(password: password, for: location)
        case let .ftp(location, _, _): _ = SecretKeychain.store(password: password, for: location)
        case let .smb(location): _ = SecretKeychain.store(password: password, for: location)
        case let .s3(location): _ = SecretKeychain.store(password: password, for: location)
        case let .s3Account(account): _ = SecretKeychain.store(password: password, for: account)
        }
    }
}
