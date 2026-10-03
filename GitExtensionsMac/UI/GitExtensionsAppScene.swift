import AppKit
import SwiftUI
import GitCommands
import Darwin


enum ApplicationShellLinks {

    static let documentationURL = URL(string: "https://git-extensions-documentation.readthedocs.org/en/main/")!
}


package final class GitExtensionsApplicationDelegate: NSObject, NSApplicationDelegate {
    override package init() {
        super.init()

        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    package func applicationShouldSaveApplicationState(_ app: NSApplication, coder: NSCoder) -> Bool { false }
    package func applicationShouldRestoreApplicationState(_ app: NSApplication, coder: NSCoder) -> Bool { false }

    package func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { ApplicationLifecycle.terminatesWithMainWindow = true }
    }

    package func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    package func applicationWillTerminate(_ notification: Notification) {
        if CommandLineSession.active { Darwin.exit(CommandLineSession.exitStatus) }
    }
}

package struct GitExtensionsAppScene: Scene {
    private let launch: RepositoryBrowserLaunch

    package init() {
        CommandLog.shared.capturesCallStacks = UserDefaults.standard.bool(forKey: "GitExtensionsMac.commandLog.captureCallStacks")
        CommandLog.shared.setOutputHistoryDepth(AppSettingsStore.shared.preferences.outputHistoryDepth)
        let arguments = CommandLine.arguments
        if arguments.contains("--dashboard") {
            launch = .dashboard
            return
        }
        if arguments.contains("--mock") {
            launch = .mock
            return
        }
        do {
            if let request = try CommandLineRequest.parse(arguments) {
                CommandLineSession.active = true
                launch = .commandLine(request)
                return
            }
        } catch {
            CommandLineSession.active = true
            launch = .commandLineError(error)
            return
        }

        if AppSettingsStore.shared.preferences.reopenLastRepository,
                  let path = AppSettingsStore.shared.lastRepositoryPath,
                  RepositoryHistory.isValidGitWorkingDir(path) {
            launch = .repository(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            launch = .dashboard
        }
    }

    package var body: some Scene {
        WindowGroup("Git Extensions", id: "repository-browser") {
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
    @ObservedObject private var history = RepositoryHistoryUIService.shared


    private func historyButton(_ item: RepositoryHistoryUIService.MenuItem) -> some View {
        Button {
            RepositoryHistoryUIService.shared.open(item.path, owner: NSApp.mainWindow)
        } label: {
            if item.anchored, let pin = AppKitFactory.resourceImage("Pin") { Image(nsImage: pin) }
            Text(item.title)
            if let branch = item.branch { Text(branch) }
        }
        .help(item.toolTip ?? "")
    }

    private func perform(_ command: BrowserCommand) {
        BrowserCommandCenter.perform(command)
    }



    @ViewBuilder
    private func revisionGridItems(_ commands: [RevisionGridMenuCommand]) -> some View {
        let available = availability.gridMenuState != nil
        ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
            switch command.kind {
            case .separator:
                Divider()
            case .header:
                Text(command.title)
            case .command:
                let action: BrowserCommand = command.id == "revision.view.tags" ? .toggleRevisionTags : .revisionGrid(command.id)
                if let checked = command.checked {
                    Toggle(command.title, isOn: Binding(get: { checked }, set: { _ in perform(action) }))
                        .keyboardShortcut(command.id == "revision.view.tags" ? hotkeys.shortcut("toggleRevisionTags") : nil)
                        .disabled(!available || !command.enabled)
                } else {
                    Button(command.title) { perform(action) }
                        .disabled(!available || !command.enabled)
                }
            }
        }
    }

    var body: some Commands {

        CommandGroup(replacing: .newItem) {
            Button("Create new repository…") { perform(.initializeRepository) }
                .keyboardShortcut(hotkeys.shortcut("initializeRepository"))
            Button("Open…") { perform(.openRepository) }
                .keyboardShortcut(hotkeys.shortcut("openRepository"))
            Menu("Favorite repositories") {
                ForEach(history.favourites) { category in
                    Menu(category.id) {
                        ForEach(category.items) { historyButton($0) }
                    }
                }
            }
            .disabled(history.favourites.isEmpty)
            Menu("Recent repositories") {
                ForEach(history.pinned) { historyButton($0) }
                if !history.pinned.isEmpty && !history.recent.isEmpty { Divider() }
                ForEach(history.recent) { historyButton($0) }
                if !history.pinned.isEmpty || !history.recent.isEmpty {
                    Divider()
                    Button("Clear list") { perform(.clearRecentRepositories) }
                }
            }
            .disabled(history.pinned.isEmpty && history.recent.isEmpty)
            Divider()
            Button("Clone repository…") { perform(.cloneRepository) }
                .keyboardShortcut(hotkeys.shortcut("cloneRepository"))
        }


        CommandMenu("Dashboard") {
            Button("Refresh") { perform(.refreshDashboard) }
                .keyboardShortcut(availability.isDashboard ? hotkeys.shortcut("refresh") : nil)
                .disabled(!availability.isDashboard)
            Divider()
            Button("Recent repositories settings") { perform(.recentRepositoriesSettings) }
                .disabled(!availability.isDashboard)
        }


        CommandMenu("Repository") {
            let repository = availability.hasRepository
            let bare = availability.isBareRepository
            Button("Refresh") { perform(.refresh) }
                .keyboardShortcut(repository ? hotkeys.shortcut("refresh") : nil)
                .disabled(!repository)
            Button("File Explorer") { perform(.openFileExplorer) }
                .disabled(!repository)
            Divider()
            Button("Remote repositories…") { perform(.remoteRepositories) }
                .keyboardShortcut(hotkeys.shortcut("remoteRepositories"))
                .disabled(!repository)
            Divider()
            Button("Manage submodules…") { perform(.manageSubmodules) }
                .keyboardShortcut(hotkeys.shortcut("manageSubmodules"))
                .disabled(!repository || bare || !availability.canManageSubmodules)
            Button("Update all submodules") { perform(.updateSubmodules) }
                .disabled(!repository || bare || !availability.canManageSubmodules)
            Button("Synchronize all submodules") { perform(.synchronizeSubmodules) }
                .disabled(!repository || bare || !availability.canManageSubmodules)
            Divider()
            Button("Manage worktrees…") { perform(.manageWorktrees) }
                .keyboardShortcut(hotkeys.shortcut("manageWorktrees"))
                .disabled(!repository || !availability.canManageWorktrees)
            Divider()


            Button("Edit .gitignore") { perform(.editGitIgnore) }
                .disabled(!repository || bare)
            Button("Edit .git/info/exclude") { perform(.editGitInfoExclude) }
                .disabled(!repository)
            Button("Edit .gitattributes") { perform(.editGitAttributes) }
                .disabled(!repository || bare)
            Button("Edit .mailmap") { perform(.editMailMap) }
                .disabled(!repository || bare)

            Button("Sparse Working Copy") { perform(.sparseWorkingCopy) }
                .disabled(!repository)
            Divider()
            Menu("Git maintenance") {
                Button("Compress git database") { perform(.compressGitDatabase) }
                Button("Recover lost objects…") { perform(.recoverLostObjects) }
                Button("Delete index.lock") { perform(.deleteIndexLock) }
                Button("Edit .git/config") { perform(.editGitConfig) }
            }
            .disabled(!repository)
            Button("Repository settings…") { perform(.repositorySettings) }.disabled(!repository)
            Divider()
            Button("Close (go to Dashboard)") { perform(.closeToDashboard) }
                .keyboardShortcut(hotkeys.shortcut("closeToDashboard"))
                .disabled(!repository)
        }


        CommandGroup(after: .sidebar) {
            Button("Output history") { perform(.outputHistory) }
                .keyboardShortcut(hotkeys.shortcut("focus.output"))
                .disabled(!availability.hasRepository || AppSettingsStore.shared.preferences.outputHistoryDepth <= 0)
            revisionGridItems(RevisionGridMenuModel.view(availability.gridMenuState ?? .init()))

            if !availability.toolbars.isEmpty {
                Divider()
                Menu("Toolbars") {
                    ForEach(availability.toolbars) { toolbar in
                        Menu(toolbar.id) {
                            Toggle("Show \(toolbar.id) toolbar", isOn: Binding(get: { toolbar.isVisible },
                                                                              set: { _ in perform(.toolbarVisibility(toolbar.id)) }))
                            Divider()
                            ForEach(toolbar.items) { item in
                                Toggle(item.title, isOn: Binding(get: { item.isVisible },
                                                                set: { _ in perform(.toolbarItemVisibility(item.id)) }))
                            }
                        }
                    }
                }
            }
        }
        CommandMenu("Navigate") {
            revisionGridItems(RevisionGridMenuModel.navigate(availability.gridMenuState ?? .init()))
        }


        CommandMenu("Commands") {
            let repository = availability.hasRepository
            let eligible = availability.selectionEligibility
            Button("Commit…") { perform(.commit) }
                .keyboardShortcut(hotkeys.shortcut("commit"))
                .disabled(!repository || !eligible.notBare)
            Button("Undo last commit…") { perform(.undoLastCommit) }
                .disabled(!repository || !eligible.notBare)
            Button("Pull/Fetch…") { perform(.pullFetch) }
                .keyboardShortcut(hotkeys.shortcut("pullFetch"))
                .disabled(!repository)
            Button("Push…") { perform(.push) }
                .keyboardShortcut(hotkeys.shortcut("push"))
                .disabled(!repository)
            Divider()
            Button("Manage stashes…") { perform(.manageStashes) }
                .keyboardShortcut(hotkeys.shortcut("manageStashes"))
                .disabled(!repository || !eligible.notBare)
            Button("Reset changes…") { perform(.resetChanges) }
                .keyboardShortcut(hotkeys.shortcut("resetChanges"))
                .disabled(!repository || !eligible.notBare || !availability.canReset)
            Button("Clean working directory…") { perform(.cleanRepository) }
                .keyboardShortcut(hotkeys.shortcut("cleanRepository"))
                .disabled(!repository || !eligible.notBare || !availability.canClean)
            Divider()
            Button("Create branch…") { perform(.createBranch) }
                .keyboardShortcut(hotkeys.shortcut("createBranch"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare || !availability.canCreateBranch)
            Button("Delete branch…") { perform(.deleteBranch) }
                .keyboardShortcut(hotkeys.shortcut("deleteBranch"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare || !availability.canDeleteBranch)
            Button("Checkout branch…") { perform(.checkoutBranch) }
                .keyboardShortcut(hotkeys.shortcut("checkoutBranch"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare || !availability.canCheckoutBranch)
            Button("Merge branches…") { perform(.mergeBranches) }
                .keyboardShortcut(hotkeys.shortcut("mergeBranches"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare)
            Button("Rebase…") { perform(.rebase) }
                .keyboardShortcut(hotkeys.shortcut("rebase"))
                .disabled(!repository || !eligible.rebase)
            Button("Solve merge conflicts…") { perform(.solveMergeConflicts) }
                .keyboardShortcut(hotkeys.shortcut("solveMergeConflicts"))
                .disabled(!repository || !eligible.notBare)
            Divider()
            Button("Create tag…") { perform(.createTag) }
                .keyboardShortcut(hotkeys.shortcut("createTag"))
                .disabled(!repository || !eligible.singleNormalCommit || !availability.canCreateTag)
            Button("Delete tag…") { perform(.deleteTag) }
                .keyboardShortcut(hotkeys.shortcut("deleteTag"))
                .disabled(!repository || !eligible.singleNormalCommit || !availability.canDeleteTag)
            Divider()
            Button("Cherry pick…") { perform(.cherryPick) }
                .keyboardShortcut(hotkeys.shortcut("cherryPick"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare)
            Button("Archive revision…") { perform(.archiveRevision) }
                .keyboardShortcut(hotkeys.shortcut("archiveRevision"))
                .disabled(!repository || !eligible.singleNormalCommit || !availability.canArchive)
            Button("Checkout revision…") { perform(.checkoutRevision) }
                .keyboardShortcut(hotkeys.shortcut("checkoutRevision"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare)
            Button("Bisect…") { perform(.bisect) }
                .keyboardShortcut(hotkeys.shortcut("bisect"))
                .disabled(!repository || !eligible.singleNormalCommitNotBare)
            Button("Show reflog…") { perform(.reflog) }
                .keyboardShortcut(hotkeys.shortcut("reflog"))
                .disabled(!repository || !eligible.notBare || !availability.canReflog)
            Divider()
            Button("Format patch…") { perform(.formatPatch) }
                .keyboardShortcut(hotkeys.shortcut("formatPatch"))
                .disabled(!repository)
            Button("Apply patch…") { perform(.applyPatch) }
                .keyboardShortcut(hotkeys.shortcut("applyPatch"))
                .disabled(!repository || !eligible.notBare || !availability.canPatch)
            Button("View patch file…") { perform(.viewPatch) }
                .keyboardShortcut(hotkeys.shortcut("viewPatch"))
        }

        CommandMenu("GitHub") {
            Button("Fork/Clone repository…") { perform(.forkHostedRepository) }

            Button("View pull requests…") { perform(.viewHostedPullRequests) }
                .disabled(!availability.hasRepository)
            Button("Create pull requests…") { perform(.createHostedPullRequest) }
                .disabled(!availability.hasRepository)
            Button("Add upstream remote") { perform(.addHostedUpstream) }
                .disabled(!availability.hasRepository)
        }

        CommandMenu("Plugins") {
            ForEach(availability.plugins) { plugin in
                Button { perform(.executePlugin(plugin.id)) } label: {
                    if let icon = plugin.icon { Image(nsImage: icon) }
                    Text(plugin.title)
                }
            }
            if !availability.plugins.isEmpty { Divider() }
            Button("Installed plugins…") { perform(.plugins) }
        }


        CommandMenu("Tools") {
            Button("Git bash") { perform(.openTerminal) }
                .keyboardShortcut(hotkeys.shortcut("gitBash"))
            Button("Git GUI") { perform(.gitGui) }
                .keyboardShortcut(hotkeys.shortcut("gitGui"))
                .disabled(availability.hasRepository && availability.isBareRepository)
            Button("GitK") { perform(.gitK) }
                .keyboardShortcut(hotkeys.shortcut("gitK"))
            Divider()
            Button("Git command log") { GitUICommands.startCommandLog() }
                .keyboardShortcut(KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: []))
            Button("Scripts…") { perform(.scripts) }
            Divider()
            Button("Settings…") { perform(.settings) }
                .keyboardShortcut(hotkeys.shortcut("settings"))
        }


        CommandGroup(replacing: .help) {
            Button("User manual") { NSWorkspace.shared.open(ApplicationShellLinks.documentationURL) }
            Divider()
            Button("Translate") { NSWorkspace.shared.open(DashboardViewController.translateURL) }
            Divider()
            Button("Donate") { DonateWindowController.show() }
            Button("Report an issue") { UserEnvironmentInformation.copyInformationAndOpenIssues() }
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Git Extensions") { AboutWindowController.show() }
        }
    }
}
