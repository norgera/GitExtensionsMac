import SwiftUI
import GitCommands

package struct GitExtensionsAppScene: Scene {
    private let launch: RepositoryBrowserLaunch

    package init() {
        CommandLog.shared.capturesCallStacks = UserDefaults.standard.bool(forKey: "GitExtensionsMac.commandLog.captureCallStacks")
        let arguments = CommandLine.arguments
        if arguments.contains("--dashboard") {
            launch = .dashboard
            return
        }
        if arguments.contains("--mock") {
            launch = .mock
            return
        }

        let explicitPath: String? = arguments.firstIndex(of: "--repository").flatMap { index in
            let valueIndex = arguments.index(after: index)
            return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
        }
        if let explicitPath {
            launch = .repository(URL(fileURLWithPath: explicitPath, isDirectory: true), selection: RepositoryOpeningSelection.parse(arguments))
        } else if AppSettingsStore.shared.preferences.reopenLastRepository,
                  let path = AppSettingsStore.shared.lastRepositoryPath,
                  FileManager.default.fileExists(atPath: path) {
            launch = .repository(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            launch = .dashboard
        }
    }

    package var body: some Scene {
        WindowGroup("gitextensions — Git Extensions", id: "repository-browser") {
            RepositoryBrowserHost(launch: launch)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            GitExtensionsMenuCommands()
        }
    }
}

private struct GitExtensionsMenuCommands: Commands {
    @ObservedObject private var availability = BrowserCommandAvailability.shared
    @ObservedObject private var hotkeys = ApplicationHotkeys.shared

    private func perform(_ command: BrowserCommand) {
        BrowserCommandCenter.perform(command)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New repository…") { perform(.initializeRepository) }
                .keyboardShortcut(hotkeys.shortcut("initializeRepository"))
            Button("Open repository…") { perform(.openRepository) }
                .keyboardShortcut(hotkeys.shortcut("openRepository"))
            Button("Clone repository…") { perform(.cloneRepository) }
                .keyboardShortcut(hotkeys.shortcut("cloneRepository"))

            Menu("Recent repositories") {
                ForEach(AppSettingsStore.shared.recentRepositories.prefix(10), id: \.path) { repository in
                    Button(URL(fileURLWithPath: repository.path).lastPathComponent) {
                        perform(.openRecentRepository(URL(fileURLWithPath: repository.path, isDirectory: true)))
                    }
                }
                Divider()
                Button("Clear recent repositories") { perform(.clearRecentRepositories) }
            }

            Divider()
            Button("Close (go to Dashboard)") { perform(.closeToDashboard) }
                .keyboardShortcut(hotkeys.shortcut("closeToDashboard"))
        }

        CommandMenu("Dashboard") {
            Button("Refresh") { perform(.unavailable("Refresh Dashboard")) }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandMenu("Repository") {
            Button("Refresh") { perform(.refresh) }
                .keyboardShortcut(hotkeys.shortcut("refresh"))
            Button("File Explorer") { perform(.unavailable("File Explorer")) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Remote repositories…") { perform(.remoteRepositories) }
                .keyboardShortcut(hotkeys.shortcut("remoteRepositories"))
            Divider()
            Button("Manage submodules…") { perform(.manageSubmodules) }
                .keyboardShortcut(hotkeys.shortcut("manageSubmodules"))
                .disabled(!availability.canManageSubmodules)
            Button("Update all submodules") { perform(.updateSubmodules) }
                .disabled(!availability.canManageSubmodules)
            Button("Synchronize all submodules") { perform(.synchronizeSubmodules) }
                .disabled(!availability.canManageSubmodules)
            Divider()
            Button("Manage worktrees…") { perform(.manageWorktrees) }
                .keyboardShortcut(hotkeys.shortcut("manageWorktrees"))
                .disabled(!availability.canManageWorktrees)
            Divider()
            Button("Edit .gitignore") { perform(.unavailable("Edit .gitignore")) }
            Button("Edit .git/info/exclude") { perform(.unavailable("Edit .git/info/exclude")) }
            Button("Edit .gitattributes") { perform(.unavailable("Edit .gitattributes")) }
            Button("Edit .mailmap") { perform(.unavailable("Edit .mailmap")) }
            Button("Sparse Working Copy") { perform(.unavailable("Sparse Working Copy")) }
            Divider()
            Menu("Git maintenance") {
                Button("Compress git database") { perform(.unavailable("Compress git database")) }
                Button("Recover lost objects…") { perform(.unavailable("Recover lost objects")) }
                Button("Delete index.lock") { perform(.unavailable("Delete index.lock")) }
                Button("Edit .git/config") { perform(.unavailable("Edit .git/config")) }
            }
            Button("Repository settings…") { perform(.unavailable("Repository settings")) }
        }

        CommandGroup(after: .sidebar) {
            Button("Show/hide tags in revision grid") { perform(.toggleRevisionTags) }
                .keyboardShortcut(hotkeys.shortcut("toggleRevisionTags"))
        }

        CommandMenu("Commands") {
            Button("Commit…") { perform(.commit) }
                .keyboardShortcut(hotkeys.shortcut("commit"))
            Button("Undo last commit…") { perform(.unavailable("Undo last commit")) }
            Button("Pull/Fetch…") { perform(.pullFetch) }
                .keyboardShortcut(hotkeys.shortcut("pullFetch"))
            Button("Push…") { perform(.push) }
                .keyboardShortcut(hotkeys.shortcut("push"))
            Divider()
            Button("Manage stashes…") { perform(.manageStashes) }
                .keyboardShortcut(hotkeys.shortcut("manageStashes"))
            Button("Reset changes…") { perform(.resetChanges) }
                .keyboardShortcut(hotkeys.shortcut("resetChanges"))
                .disabled(!availability.canReset)
            Button("Clean working directory…") { perform(.cleanRepository) }
                .keyboardShortcut(hotkeys.shortcut("cleanRepository"))
                .disabled(!availability.canClean)
            Divider()
            Button("Create branch…") { perform(.createBranch) }
                .keyboardShortcut(hotkeys.shortcut("createBranch"))
                .disabled(!availability.canCreateBranch)
            Button("Delete branch…") { perform(.deleteBranch) }
                .keyboardShortcut(hotkeys.shortcut("deleteBranch"))
                .disabled(!availability.canDeleteBranch)
            Button("Checkout branch…") { perform(.checkoutBranch) }
                .keyboardShortcut(hotkeys.shortcut("checkoutBranch"))
                .disabled(!availability.canCheckoutBranch)
            Button("Merge branches…") { perform(.mergeBranches) }
                .keyboardShortcut(hotkeys.shortcut("mergeBranches"))
                .disabled(!availability.canMerge)
            Button("Rebase…") { perform(.rebase) }
                .keyboardShortcut(hotkeys.shortcut("rebase"))
            Button("Solve merge conflicts…") { perform(.solveMergeConflicts) }
                .keyboardShortcut(hotkeys.shortcut("solveMergeConflicts"))
            Divider()
            Button("Create tag…") { perform(.createTag) }
                .keyboardShortcut(hotkeys.shortcut("createTag"))
                .disabled(!availability.canCreateTag)
            Button("Delete tag…") { perform(.deleteTag) }
                .keyboardShortcut(hotkeys.shortcut("deleteTag"))
                .disabled(!availability.canDeleteTag)
            Divider()
            Button("Cherry pick…") { perform(.cherryPick) }
                .keyboardShortcut(hotkeys.shortcut("cherryPick"))
            Button("Archive revision…") { perform(.archiveRevision) }
                .keyboardShortcut(hotkeys.shortcut("archiveRevision"))
                .disabled(!availability.canArchive)
            Button("Checkout revision…") { perform(.checkoutRevision) }
                .keyboardShortcut(hotkeys.shortcut("checkoutRevision"))
                .disabled(!availability.canCheckoutRevision)
            Button("Bisect…") { perform(.bisect) }
                .keyboardShortcut(hotkeys.shortcut("bisect"))
                .disabled(!availability.canBisect)
            Button("Show reflog…") { perform(.reflog) }
                .keyboardShortcut(hotkeys.shortcut("reflog"))
                .disabled(!availability.canReflog)
            Divider()
            Button("Format patch…") { perform(.formatPatch) }
                .keyboardShortcut(hotkeys.shortcut("formatPatch"))
                .disabled(!availability.canPatch)
            Button("Apply patch…") { perform(.applyPatch) }
                .keyboardShortcut(hotkeys.shortcut("applyPatch"))
                .disabled(!availability.canPatch)
            Button("View patch file…") { perform(.viewPatch) }
                .keyboardShortcut(hotkeys.shortcut("viewPatch"))
        }

        CommandMenu("Repository hosts") {
            Button("Fork/Clone repository…") { perform(.unavailable("Fork/Clone repository")) }
            Button("View pull requests…") { perform(.unavailable("View pull requests")) }
            Button("Create pull request…") { perform(.unavailable("Create pull request")) }
            Button("Add upstream remote") { perform(.unavailable("Add upstream remote")) }
        }

        CommandMenu("Plugins") {
            Button("Plugin manager…") { perform(.unavailable("Plugin manager")) }
            Button("Plugin settings…") { perform(.unavailable("Plugin settings")) }
        }

        CommandMenu("Tools") {
            Button("Git command log") { GitUICommands.startCommandLog() }
            Button("Settings…") { perform(.settings) }
                .keyboardShortcut(hotkeys.shortcut("settings"))
            Divider()
            Button("Translation") { perform(.unavailable("Translation")) }
            Button("Check for updates") { perform(.unavailable("Check for updates")) }
        }

        CommandGroup(replacing: .help) {
            Button("Git Extensions manual") { perform(.unavailable("Git Extensions manual")) }
            Button("Keyboard shortcuts") { perform(.unavailable("Keyboard shortcuts")) }
            Button("Report an issue") { perform(.unavailable("Report an issue")) }
        }
    }
}
