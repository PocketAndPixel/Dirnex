import AppKit
import DirnexCore

/// Getting the passphrase an encrypted archive needs, once, for every gesture that reads its bytes
/// (PLAN.md §M19).
///
/// Four gestures reach into a browsed archive's data — Quick Look / Quick View, opening a member,
/// entering a nested archive, and F5 copy-out — and each of them needs the same three things: ask
/// only when the archive is actually encrypted, ask only once per archive, and ask *again* saying so
/// when the answer was a typo. Written four times that is four places for the retry to be forgotten;
/// `withArchivePassphrase` is the one place it lives.
///
/// **The passive paths must not call it.** A preview follows the *cursor*, so a sheet raised from
/// there is a question the user never asked — the same separation docs/NOTES.md draws for Quick
/// View's JavaScript switch between "is this safe" and "should this happen unasked". Those paths
/// read ``PanelViewController/rememberedPassphrase(forArchiveAt:)`` and stay quiet when it is `nil`.
extension PanelViewController {
    /// The passphrase already given for `archivePath` this session, if any.
    func rememberedPassphrase(forArchiveAt archivePath: String) -> ArchivePassphrase? {
        host?.archivePassphrases.passphrase(forArchiveAt: archivePath)
    }

    /// Run `work` with whatever passphrase `archivePath` needs, asking for one when the archive is
    /// encrypted and none has been given this session, and asking again — saying so — when the one
    /// given is refused.
    ///
    /// `work` runs on the main actor and does its own detaching. It throws
    /// ``EncryptedArchiveError/incorrectPassphrase`` to re-raise the prompt; everything else reaches
    /// `onFailure`. Canceling the prompt calls neither closure — the user withdrew the request, and
    /// an alert saying so would be the app arguing with them.
    ///
    /// The passphrase is remembered only once `work` has returned, so a wrong one is never filed for
    /// the next gesture to inherit.
    func withArchivePassphrase<T>(
        forArchiveAt archivePath: String,
        doing work: @escaping @MainActor (ArchivePassphrase?) async throws -> T,
        onSuccess: @escaping @MainActor (T) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let attempt = ArchivePassphraseAttempt(
            archivePath: archivePath, work: work, onSuccess: onSuccess, onFailure: onFailure
        )
        // The encryption question costs one header read — measured at 3–4 ms for a 600 MB archive
        // (see `ArchiveExtractor.needsPassphrase`), which is what lets every gesture ask it outright.
        guard ArchiveExtractor.needsPassphrase(
            forArchiveAt: archivePath,
            nameEncoding: declaredNameEncoding(forArchiveAt: archivePath)
        ) else {
            run(attempt, with: nil)
            return
        }
        if let remembered = rememberedPassphrase(forArchiveAt: archivePath) {
            run(attempt, with: remembered)
        } else {
            ask(attempt, retrying: false)
        }
    }

    private func ask<T>(_ attempt: ArchivePassphraseAttempt<T>, retrying: Bool) {
        PassphrasePrompt.ask(
            forItemNamed: (attempt.archivePath as NSString).lastPathComponent,
            retrying: retrying,
            over: view.window
        ) { [weak self] passphrase in
            guard let self, let passphrase else { return }
            run(attempt, with: passphrase)
        }
    }

    private func run<T>(_ attempt: ArchivePassphraseAttempt<T>, with passphrase: ArchivePassphrase?) {
        Task {
            do {
                let result = try await attempt.work(passphrase)
                if let passphrase {
                    host?.archivePassphrases.remember(passphrase, forArchiveAt: attempt.archivePath)
                }
                attempt.onSuccess(result)
            } catch EncryptedArchiveError.incorrectPassphrase {
                // A typo, not a failure worth an alert of its own — ask again, saying so.
                ask(attempt, retrying: true)
            } catch {
                attempt.onFailure(error)
            }
        }
    }
}

/// One in-flight `withArchivePassphrase` call, bundled so the ask/run pair can hand it back and
/// forth across a retry without six parameters travelling with it (SwiftLint's parameter count is
/// the smaller reason; the larger one is that a retry must carry *exactly* what the first attempt
/// had).
@MainActor
struct ArchivePassphraseAttempt<T> {
    let archivePath: String
    let work: @MainActor (ArchivePassphrase?) async throws -> T
    let onSuccess: @MainActor (T) -> Void
    let onFailure: @MainActor (Error) -> Void
}
