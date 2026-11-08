import Combine
import DirnexCore
import SwiftUI

/// What the Settings row knows about `git mergetool` (PLAN.md §M37 Slice 6), and its two actions.
@MainActor
final class GitMergeToolModel: ObservableObject {
    /// What the row shows.
    enum Shown: Equatable {
        /// Not read yet: no sentence and no button, rather than a wrong one.
        case reading
        case noGit
        case state(GitMergeToolSetup.State)
        /// git refused, in its own words.
        case readFailed(String)
    }

    @Published private(set) var shown = Shown.reading
    @Published private(set) var changeFailure: String?
    @Published private(set) var isChanging = false

    /// `nil` on a Mac with no real `git`.
    private let transport: (any GitTransport)?
    private let executablePath: String

    init(transport: (any GitTransport)?, executablePath: String) {
        self.transport = transport
        self.executablePath = executablePath
    }

    /// The real `git` and this copy's binary.
    static func forThisCopy() -> GitMergeToolModel {
        GitMergeToolModel(
            transport: GitProcessTransport.executablePath == nil ? nil : GitProcessTransport(),
            executablePath: Bundle.main.executablePath ?? ""
        )
    }

    /// Read what the global config says now, off the main thread.
    func refresh() async {
        guard let transport else {
            shown = .noGit
            return
        }
        let path = executablePath
        shown = await BlockingWork.run {
            do throws(GitRunFailure) {
                return try .state(GitMergeToolSetup.read(executablePath: path, transport: transport))
            } catch {
                return .readFailed(error.message)
            }
        }
    }

    /// Make this copy git's merge tool.
    func use() async {
        let path = executablePath
        await change { (transport: any GitTransport) throws(GitRunFailure) in
            try GitMergeToolSetup.apply(executablePath: path, transport: transport)
        }
    }

    /// Take Dirnex out of git's config.
    func stopUsing() async {
        await change { (transport: any GitTransport) throws(GitRunFailure) in
            try GitMergeToolSetup.remove(transport: transport)
        }
    }

    private func change(
        _ work: @escaping @Sendable (any GitTransport) throws(GitRunFailure) -> Void
    ) async {
        guard let transport, !isChanging else { return }
        isChanging = true
        let failure: GitRunFailure? = await BlockingWork.run {
            do throws(GitRunFailure) {
                try work(transport)
                return nil
            } catch {
                return error
            }
        }
        changeFailure = failure?.message
        await refresh()
        isChanging = false
    }

    /// The sentence under the row.
    var footer: String {
        if let changeFailure {
            return String(
                localized: "git couldn’t change its config. It said: \(changeFailure)",
                comment: "Settings, git merge tool: writing git's config failed; %@ is git's own message, in English."
            )
        }
        switch shown {
        case .reading:
            return ""
        case .noGit:
            return String(
                localized: "git wasn’t found on this Mac.",
                comment: "Settings, git merge tool: no git is installed. git is a program's name."
            )
        case let .readFailed(message):
            return String(
                localized: "git couldn’t read its config. It said: \(message)",
                comment: "Settings, git merge tool: reading git's config failed; %@ is git's own message, in English."
            )
        case let .state(state):
            return Self.sentence(for: state)
        }
    }

    private static func sentence(for state: GitMergeToolSetup.State) -> String {
        switch state {
        case .notSetUp(otherTool: nil):
            String(
                localized: """
                Makes git mergetool open each conflicted file in Dirnex’s merge window, by setting \
                merge.tool and mergetool.dirnex in your global git config.
                """,
                comment: """
                Settings, git merge tool. git mergetool, merge.tool and mergetool.dirnex are not to be \
                translated.
                """
            )
        case let .notSetUp(otherTool?):
            String(
                localized: "git mergetool now runs \(otherTool). Use Dirnex replaces it in your global git config.",
                comment: """
                Settings, git merge tool; %@ is the name of the tool git is set to. Use Dirnex is the \
                button beside it. git mergetool is not to be translated.
                """
            )
        case .active:
            String(
                localized: """
                git mergetool opens this copy of Dirnex. Save the merge and close its window, and git \
                stages the file.
                """,
                comment: "Settings, git merge tool, while it is set up. git mergetool is not to be translated."
            )
        case let .otherCopy(command):
            String(
                localized: "git mergetool runs another copy of Dirnex: \(command)",
                comment: "Settings, git merge tool; %@ is the command in git's config, a path and its arguments."
            )
        }
    }
}

/// Operations ▸ using Dirnex as `git mergetool`'s tool: a button that writes the three values to the
/// user's global git config, and takes them out again.
struct GitMergeToolSection: View {
    @StateObject private var model = GitMergeToolModel.forThisCopy()

    var body: some View {
        Section {
            HStack {
                Text("Merge tool for git")
                Spacer(minLength: 12)
                buttons.disabled(model.isChanging)
            }
        } footer: {
            Text(model.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .task { await model.refresh() }
    }

    @ViewBuilder private var buttons: some View {
        switch model.shown {
        case .state(.notSetUp):
            SettingsButton("Use Dirnex") { Task { await model.use() } }
        case .state(.active):
            SettingsButton("Stop Using") { Task { await model.stopUsing() } }
        case .state(.otherCopy):
            SettingsButton("Stop Using") { Task { await model.stopUsing() } }
            SettingsButton("Use This Copy") { Task { await model.use() } }
        case .reading, .noGit, .readFailed:
            EmptyView()
        }
    }
}
