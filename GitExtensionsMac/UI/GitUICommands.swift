import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
final class GitUICommands {
    private static var commandLogWindow: CommandLogWindowController?
    private static let globalPluginRegistry = ApplicationPluginRegistry()
    private static var globalPluginWindows: [NSWindowController] = []
    private var scriptsWindow: ScriptsWindowController?
    private var hostingWindows: [NSWindowController] = []
    private static var forkCloneWindow: ForkAndCloneWindowController?
    private var scriptTask: Task<Void, Never>?
    private let pluginRegistry = ApplicationPluginRegistry()
    private let pluginSession = ApplicationPluginSession()
    private var pluginWindows: [NSWindowController] = []
    private var pluginsInitialized = false
    private var pluginLoadTask: Task<Void, Never>?
    private var pluginCloseObserver: NSObjectProtocol?
    private var pluginMainObserver: NSObjectProtocol?
    private let repositoryModule: any RepositoryBrowsingDataSource
    private weak var browser: RepositoryBrowserViewController?
    let repositoryChangedNotifier: RepositoryChangedNotifier
    private var remoteWindowController: NSWindowController?
    private var reflogWindowController: NSWindowController?
    private var worktreeWindowController: NSWindowController?
    private var submoduleWindowController: NSWindowController?
    private var submodulePullWindowController: NSWindowController?
    private var submoduleRemoteWindowController: NSWindowController?
    private var submoduleCommitWindowController: NSWindowController?
    private var pendingSubmoduleCommits: [any RepositoryBrowsingDataSource] = []
    private var submoduleSources: [String: any RepositoryBrowsingDataSource] = [:]
    private var reflogBranchWorkflowCoordinator: CheckoutBranchWorkflowCoordinator?
    private var archiveWindows: [UUID: ArchiveWindowController] = [:]
    private var patchWindows: [UUID: PatchWindowController] = [:]
    private var blameWindows: [UUID: NSWindowController] = [:]
    private var fileHistoryWindows: [UUID: FileHistoryWindowController] = [:]
    private var comparisonWindows: [UUID: RevisionComparisonWindowController] = [:]

    private(set) var fileEditorWindows: [String: NSWindowController] = [:]
    private static var standalonePatchWindows: [UUID: PatchWindowController] = [:]
    private var commandLineWindows: [NSWindowController] = []
    private static var applicationCommandLineWindows: [NSWindowController] = []

    init(
        repositoryModule: any RepositoryBrowsingDataSource,
        browser: RepositoryBrowserViewController
    ) {
        self.repositoryModule = repositoryModule
        self.browser = browser
        repositoryChangedNotifier = RepositoryChangedNotifier {}
    }

    func perform(
        changesRepositoryState: Bool,
        action: @MainActor () async throws -> Bool
    ) async throws -> Bool {
        repositoryChangedNotifier.lock()
        defer { repositoryChangedNotifier.unlock(requestNotify: false) }
        let succeeded = try await OutputHistoryRecording.perform { try await action() }
        if succeeded && changesRepositoryState {
            repositoryChangedNotifier.notify()
        }
        return succeeded
    }

    func notifyRepositoryChanged(preferredCommitID: RevisionID? = nil) {
        browser?.prepareNotifierRefresh(preferredCommitID: preferredCommitID)
        repositoryChangedNotifier.notify()
    }

    func stopPlugins() {
        if let pluginCloseObserver { NotificationCenter.default.removeObserver(pluginCloseObserver) }
        if let pluginMainObserver { NotificationCenter.default.removeObserver(pluginMainObserver) }
        pluginCloseObserver = nil
        pluginMainObserver = nil
        pluginLoadTask?.cancel(); pluginLoadTask = nil
        pluginSession.close()
        pluginWindows.forEach { $0.close() }
        pluginWindows.removeAll()
        pluginsInitialized = false
        if NSApp.mainWindow == nil || NSApp.mainWindow === browser?.view.window {
            BrowserCommandAvailability.shared.plugins = []
        }
    }

    static func runApplicationCommandLine(_ request: CommandLineRequest, owner: NSWindow,
                                         openRepository: @escaping (URL) -> Void) async throws -> CommandLineDispatch {
        let executable = URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath)
        switch request.verb {
        case .help:
            FileHandle.standardOutput.write(Data((CommandLineSession.usage + "\n").utf8))
            let controller = CommandLineHelpWindow()
            applicationCommandLineWindows.append(controller)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        case .about: AboutWindowController.show()
        case .clone:
            startCloneRepository(source: GitRepositoryCreator(git: GitProcess(executableURL: executable)), owner: owner,
                                 initialSource: request.arguments.first, initialDestination: request.currentDirectory) { result in
                AppSettingsStore.shared.recordRecentRepository(result.repositoryURL)
                openRepository(result.repositoryURL)
            }
        case .initialize:
            startInitializeRepository(source: GitRepositoryCreator(git: GitProcess(executableURL: executable)), owner: owner,
                                      initialDirectory: request.arguments.first.map(request.path) ?? request.currentDirectory) { result in openRepository(result.repositoryURL) }
        case .viewpatch:
            startPatchViewer(owner: owner, file: request.arguments.count == 1 ? request.arguments.first.map(request.path) : nil)
        case .settings:
            return .completed(await ApplicationShellDialogs.presentSettings(from: owner))
        case .fileeditor:
            guard let name = request.arguments.first else { throw CLIError.invalid("No file selected.") }
            return .completed(try await withCheckedThrowingContinuation { continuation in
                var controller: FileEditorWindowController!
                controller = FileEditorWindowController(fileURL: request.path(name), source: StandaloneFileEditingDataSource(), showWarning: false, onClose: {
                    continuation.resume(returning: controller.acceptedClose)
                    applicationCommandLineWindows.removeAll { $0 === controller }
                    controller = nil
                })
                Task { @MainActor in
                    do {
                        try await controller.load()
                        applicationCommandLineWindows.append(controller)
                        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                    } catch { continuation.resume(throwing: error); controller = nil }
                }
            })
        case .uninstall:
            try await CommandLineRepository.removeOwnEditor(applicationPath: Bundle.main.bundlePath,
                git: GitProcess(executableURL: executable), directory: request.currentDirectory)
            return .completed(true)
        default: throw CLIError.invalid("\(request.verb.rawValue) requires a repository.")
        }
        return .presentation
    }

    func runCommandLine(_ request: CommandLineRequest) async throws -> CommandLineDispatch {
        guard let browser, let owner = browser.view.window, let identity = browser.repositoryIdentity else {
            throw CLIError.invalid("No repository is open.")
        }
        if identity.currentRepository.isBare,
           [.add, .addfiles, .branch, .commit, .checkout, .checkoutbranch, .checkoutrevision, .cherry, .cleanup,
            .merge, .rebase, .revert, .reset, .stash, .synchronize].contains(request.verb) {
            throw RepositoryMutationError.bareRepository
        }
        let root = URL(fileURLWithPath: identity.currentRepository.path, isDirectory: true)
        try await initializePlugins()
        func revision(_ expression: String? = nil) async throws -> Commit {
            guard let source = repositoryModule as? any RepositoryRevisionComparingDataSource else { throw RepositoryDataSourceError.unavailable }
            return try await source.comparisonTarget(expression ?? "HEAD")
        }
        switch request.verb {
        case .add, .addfiles:
            guard let source = repositoryModule as? any RepositoryAddingFilesDataSource else { throw RepositoryDataSourceError.unavailable }
            let controller = CommandLineAddFilesWindow(source: source, paths: request.arguments) { [weak self] in self?.notifyRepositoryChanged() }
            commandLineWindows.append(controller)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        case .apply, .applypatch:
            startPatch(.apply, file: request.arguments.count == 1 ? request.arguments.first.map(request.path) : nil)
        case .blame:
            startBlame(file: request.relativeFile(request.arguments[0], root: root), initialLine: request.arguments.count > 1 ? Int(request.arguments[1]) : nil)
        case .blamehistory, .filehistory:
            let commit = request.arguments.count > 1 ? try await revision(request.arguments[1]) : nil
            if AppSettingsStore.shared.revisionGridPreferences.useBrowseForFileHistory {
                Self.launchBrowse(root, selection: commit.map { [$0.id] } ?? [], fileHistory: .init(path: request.relativeFile(request.arguments[0], root: root), filterRevision: request.has("filter-by-revision") ? commit?.objectID : nil))
                return .completed(true)
            }
            startFileHistory(file: request.relativeFile(request.arguments[0], root: root), revision: commit,
                filterByRevision: request.has("filter-by-revision"), showBlame: request.verb == .blamehistory)
        case .branch:
            guard let coordinator = makeCheckoutWorkflowCoordinator() else { throw RepositoryDataSourceError.unavailable }
            return .completed(await withCheckedContinuation { continuation in
                coordinator.createBranch(sourceRevision: nil, onFinished: { continuation.resume(returning: $0) })
            })
        case .checkout, .checkoutbranch:
            guard let coordinator = makeCheckoutWorkflowCoordinator() else { throw RepositoryDataSourceError.unavailable }
            return .completed(await withCheckedContinuation { continuation in
                coordinator.checkoutBranch(initialTarget: nil, onFinished: { continuation.resume(returning: $0) })
            })
        case .checkoutrevision:
            guard let coordinator = makeCheckoutWorkflowCoordinator() else { throw RepositoryDataSourceError.unavailable }
            let target = try await revision()
            return .completed(await withCheckedContinuation { continuation in
                coordinator.checkoutRevision(target, onFinished: { continuation.resume(returning: $0) })
            })
        case .cherry:
            let target = try await revision()
            return .completed(await withCheckedContinuation { continuation in
                startCherryPick([target], onFinished: { continuation.resume(returning: $0) })
            })
        case .cleanup: startCleanRepository()
        case .commit:
            if request.has("quiet"), let source = repositoryModule as? any RepositoryCommitWorkflowDataSource,
               !(try await source.loadMutationState()).isDirty { return .completed(true) }
            startCommit(initialMessage: request.value("message"))
        case .difftool:
            guard let source = repositoryModule as? any RepositoryFileStatusDataSource else { throw RepositoryDataSourceError.unavailable }
            let tool = AppSettingsStore.shared.preferences.externalDiffToolPath
            try await source.openDifftool(first: nil, second: nil, path: request.relativeFile(request.arguments[0], root: root), oldPath: nil,
                                         isTracked: true, customTool: nil, externalCommand: tool.isEmpty ? nil : tool)
            return .completed(true)
        case .fileeditor:
            return .completed(await withCheckedContinuation { continuation in
                startFileEditor(request.path(request.arguments[0]), onFinished: { continuation.resume(returning: $0) })
            })
        case .formatpatch: startPatch(.format, selected: identity.headID.map { id in browser.revisions.filter { $0.id == .object(id) } } ?? [])
        case .gitignore: startEditGitIgnore(localExclude: false)
        case .merge: startMergeBranches(initialTarget: request.value("branch"))
        case .mergeconflicts, .mergetool:
            if request.has("quiet"), let source = repositoryModule as? any RepositoryConflictResolutionDataSource {
                let state = try await source.loadMutationState()
                if state.conflictedPaths.isEmpty { return .completed(true) }
            }
            startConflictResolution()
        case .pull:
            var preferences = AppSettingsStore.shared.pullPreferences
            if request.has("merge") { preferences.formAction = .merge; preferences.defaultAction = .merge }
            if request.has("rebase") { preferences.formAction = .rebase; preferences.defaultAction = .rebase }
            if request.has("fetch") { preferences.formAction = .fetch; preferences.defaultAction = .fetch }
            if request.has("autostash") { preferences.autoStash = true }
            AppSettingsStore.shared.savePullPreferences(preferences)
            return .completed(await withCheckedContinuation { continuation in
                startPull(action: .openDialog, immediately: request.has("quiet"), initialRemoteBranch: request.value("remotebranch"), onCompletion: { continuation.resume(returning: $0) })
            })
        case .push:
            return .completed(await withCheckedContinuation { continuation in
                startPush(immediately: request.has("quiet"), onCompletion: { continuation.resume(returning: $0) })
            })
        case .rebase:
            guard let source = repositoryModule as? any RepositoryRebaseDataSource else { throw RepositoryDataSourceError.unavailable }
            if await WorkflowManagementDialogs.startRebase(source: source, target: nil, interactive: false,
                initialActions: [:], advancedFrom: nil, showAdvancedOptions: false, window: owner,
                initialOnto: request.value("branch"), startImmediately: false, scriptHooks: scriptHooks) { notifyRepositoryChanged() }
            return .completed(true)
        case .remotes: startRemoteManagement()
        case .revert, .reset:
            if request.arguments.isEmpty {
                return .completed(await withCheckedContinuation { continuation in startResetChanges(onFinished: { continuation.resume(returning: $0) }) })
            }
            else {
                guard let source = repositoryModule as? any RepositoryFileStatusDataSource else { throw RepositoryDataSourceError.unavailable }
                guard let resetSource = repositoryModule as? any RepositoryAddingFilesDataSource else { throw RepositoryDataSourceError.unavailable }
                let target = RevisionID.object(try await resetSource.commandLineResetTarget())
                let artificial = RevisionCommitBuilder.artificialRevisions(headID: identity.headID)
                let groups = try await source.calculateFileStatus(.init(revisions: artificial, headID: identity.headID, allowMultiDiff: false), describe: { $0.shortString })
                var files = groups.flatMap(\.files)
                let names = request.arguments.map { request.relativeFile($0, root: root).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                var seen = Set<String>()
                files = files.filter { file in !file.isStatusOnly && names.contains { $0 == "." || file.path == $0 || file.path.hasPrefix($0 + "/") } && seen.insert(file.id).inserted }
                let group = FileStatusGroup(first: target, second: .workingDirectory, summary: "HEAD", files: files)
                guard !files.isEmpty else { return .completed(false) }
                return .completed(await withCheckedContinuation { continuation in
                    resetFileStatusItems(files.map { .init(group: group, file: $0) }, toFirst: true, source: source, owner: owner, onFinished: { continuation.resume(returning: $0) })
                })
            }
        case .searchfile:
            let entries = try await repositoryModule.loadRepositoryFiles(for: revision())
            var chosen = false
            let result = await withCheckedContinuation { continuation in
                FileSearchWindow.present(owner: owner, standalone: true, candidates: { pattern in
                    let predicate = FileSearchWindow.predicate(pattern, workingDirectory: root.path)
                    return entries.filter { predicate($0.path) }.map {
                        ChangedFile(id: $0.path, path: $0.path, oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
                    }
                }, selected: { file in
                    chosen = true
                    FileHandle.standardOutput.write(Data((root.appendingPathComponent(file.path).path + "\n").utf8))
                }, onClose: { continuation.resume(returning: chosen) })
            }
            return .completed(result)
        case .settings:
            return .completed(await ApplicationShellDialogs.presentSettings(from: owner, source: repositoryModule as? any RepositorySettingsDataSource,
                repositoryChanged: { [weak self] in self?.notifyRepositoryChanged() }))
        case .stash: startStashManagement()
        case .synchronize:
            var allSucceeded = true
            for verb in [CommandLineRequest.Verb.commit, .pull, .push] {
                var next = request; next.verb = verb
                let presentation = CommandLinePresentation(owner: owner, notifier: repositoryChangedNotifier)
                presentation.successfulRead = next.succeedsOnClose
                switch try await runCommandLine(next) {
                case .completed(let succeeded): presentation.finish(); allSucceeded = allSucceeded && succeeded
                case .presentation:
                    let succeeded = try await presentation.wait()
                    allSucceeded = allSucceeded && succeeded
                }
            }
            return .completed(allSucceeded)
        case .tag:
            return .completed(await withCheckedContinuation { continuation in startCreateTag(onFinished: { continuation.resume(returning: $0) }) })
        case .viewdiff: _ = startCompareRevisions()
        default: return try await Self.runApplicationCommandLine(request, owner: owner) { Self.launchBrowse($0) }
        }
        return .presentation
    }

    @discardableResult
    func pluginEvent(_ event: String, succeeded: Bool? = nil) -> Bool {
        for (_, host) in pluginSession.registered {
            var context = host.context
            if let browser {
                for key in Array(context.keys) where key.hasPrefix("s") { context[key] = nil }
                let selected = browser.workflowRevisionSelection.compactMap { id in browser.revisions.first { $0.id == id } }
                context.merge(ScriptExecution.selectedRevisionOptions(selected), uniquingKeysWith: { _, new in new })
                context.merge(browser.scriptFileContext, uniquingKeysWith: { _, new in new })
            }
            host.update(context: context, owner: browser?.view.window)
            host.updateSelection(browser?.workflowRevisionSelection ?? [])
        }
        let previousFailures = pluginSession.failures.count
        let result = pluginSession.dispatch(event, succeeded: succeeded)
        if pluginSession.failures.count > previousFailures {
            let alert = NSAlert(); alert.messageText = "Plugin event failed"
            alert.informativeText = pluginSession.failures.dropFirst(previousFailures).joined(separator: "\n")
            alert.runModal()
        }
        return result
    }

    func pluginsRepositoryLoaded() {
        pluginLoadTask?.cancel()
        pluginLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let initial = !pluginsInitialized
                try await initializePlugins()
                let context = try await scriptOptions(for: ScriptDefinition())
                try Task.checkCancellation()
                for (_, host) in pluginSession.registered {
                    host.update(context: context, owner: browser?.view.window)
                    host.updateSelection(browser?.workflowRevisionSelection ?? [])
                }
                _ = pluginSession.dispatch(initial ? "PostBrowseInitialize" : "PostRepositoryChanged")
            } catch is CancellationError { }
            catch { NSAlert(error: error).runModal() }
        }
    }

    func startPlugins() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await initializePlugins()
                let alert = NSAlert()
                alert.messageText = "Plugins"
                let entries = pluginSession.registered
                let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
                list.addItems(withTitles: entries.map { $0.0.name })
                alert.accessoryView = list
                alert.informativeText = (pluginRegistry.failures + pluginSession.failures).joined(separator: "\n")
                if entries.isEmpty {
                    alert.informativeText += "\nNo compatible native plugins are installed. Install trusted GitExtensions.*.bundle plugins in \(ApplicationPluginRegistry.userDirectory.path), then reopen the repository."
                    alert.addButton(withTitle: "Close")
                    alert.runModal(); return
                }
                alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Settings…"); alert.addButton(withTitle: "Cancel")
                let action = alert.runModal()
                guard list.indexOfSelectedItem >= 0 else { return }
                let (plugin, host) = entries[list.indexOfSelectedItem]
                host.update(context: try await scriptOptions(for: ScriptDefinition()), owner: browser?.view.window)
                host.updateSelection(browser?.workflowRevisionSelection ?? [])
                if action == .alertFirstButtonReturn {
                    repositoryChangedNotifier.lock()
                    defer { repositoryChangedNotifier.unlock(requestNotify: false) }
                    if try await plugin.execute(in: host) { notifyRepositoryChanged() }
                } else if action == .alertSecondButtonReturn {
                    if let view = try plugin.settingsController(in: host) {
                        let window = NSWindow(contentViewController: view)
                        window.title = "Settings — \(plugin.name)"; window.isReleasedWhenClosed = false
                        let controller = NSWindowController(window: window)
                        pluginWindows.append(controller); controller.showWindow(nil)
                    } else {
                        let message = NSAlert(); message.messageText = "\(plugin.name) has no settings."; message.runModal()
                    }
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func gitHubContext() async -> GitHubHostingContext? {
        guard let manager = repositoryModule as? any RepositoryRemoteManagingDataSource,
              let remotes = try? await manager.loadRemoteConfigurations() else { return nil }
        let hosted = HostedRemote.gitHubRemotes(remotes)
        guard !hosted.isEmpty else { return nil }
        let current = browser?.networkContext?.branches.first(where: \.isCurrent)?.remoteName
        let active = remotes.filter { !$0.isDisabled }
        let protocolRemote = active.first { current == nil || current == "" || $0.name == current } ?? active.first
        return GitHubHostingContext(
            remotes: hosted, currentRemote: current, protocolRemoteURL: protocolRemote?.fetchURL,
            source: repositoryModule as? any RepositoryHostingDataSource, saveRemote: { try await manager.saveRemote($0) },
            client: { RepositoryHostClient(identity: $0, token: GitHubRepositoryPlugin.token) },
            lockNotifier: { [weak self] in self?.repositoryChangedNotifier.lock() },
            unlockNotifier: { [weak self] in self?.repositoryChangedNotifier.unlock(requestNotify: false) },
            changed: { [weak self] in self?.notifyRepositoryChanged(preferredCommitID: self?.browser?.selectedCommitID) })
    }

    private func withRepositoryHost(_ action: @escaping @MainActor (GitHubHostingContext) -> Void, noHost: String) {
        let owner = browser?.view.window
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let context = await gitHubContext() else { HostingMessages.error(noHost); return }
            let host = pluginSession.registered.first { $0.0 is GitHubRepositoryPlugin }?.1
            guard await GitHubRepositoryPlugin.ensureConfigured(owner: owner, host: host) else { return }
            action(context)
        }
    }

    func startPullRequests() {
        withRepositoryHost({ [weak self] context in
            let controller = PullRequestsWindowController(context: context)
            self?.hostingWindows.append(controller); controller.showWindow(nil)
        }, noHost: "Could not find any relevant repository hosts for the currently open repository.")
    }

    func startCreatePullRequest(fromPush: Bool = false, chooseRemote: String? = nil) {
        withRepositoryHost({ [weak self] context in
            let controller = CreateHostedPullRequestWindowController(context: context, chooseRemote: chooseRemote)
            self?.hostingWindows.append(controller); controller.showWindow(nil)
        }, noHost: fromPush ? "Could not find any repo hosts for current working directory"
            : "Could not find any relevant repository hosts for the currently open repository.")
    }

    func startForkHostedRepository() {
        _ = browser?.onApplicationCommand?(.forkHostedRepository)
    }

    func startAddHostedUpstream() {
        withRepositoryHost({ [weak self] context in
            Task { @MainActor [weak self] in
                guard let self, let manager = repositoryModule as? any RepositoryRemoteManagingDataSource else { return }
                do {
                    guard let first = context.remotes.first else { return }
                    let login = try await context.client(first.identity).currentUser()
                    guard let mine = context.remotes.first(where: { $0.identity.owner == login }) else { return }
                    let repository = try await context.client(mine.identity).repository()
                    guard repository.fork, let parent = repository.parent else { return }
                    let url = mine.usesHTTPS ? parent.clone_url.absoluteString : parent.ssh_url
                    let remotes = try await manager.loadRemoteConfigurations()
                    guard !remotes.contains(where: { $0.name == "upstream" || $0.fetchURL == url }) else { return }
                    try await manager.saveRemote(.init(originalName: nil, name: "upstream", fetchURL: url,
                        pushURL: nil, puttyKeyFile: nil, color: nil, prefix: nil))
                    notifyRepositoryChanged()
                    fetchRemote(named: "upstream", prune: false)
                } catch {
                    HostingMessages.error("ERROR: Add upstream remote failed. Message: \(error.localizedDescription)", "Error! :(")
                }
            }
        }, noHost: "Could not find any relevant repository hosts for the currently open repository.")
    }

    static func startForkAndClone(owner: NSWindow?, creator: any RepositoryCreating, initialDestination: String,
                                  gitExecutable: URL, opened: @escaping (URL) -> Void) {
        Task { @MainActor in
            guard await GitHubRepositoryPlugin.ensureConfigured(owner: owner) else { return }
            let environment = ForkAndCloneWindowController.Environment(
                creator: creator,
                addRemote: { directory, name, url in
                    let module = GitRepositoryModule(repositoryURL: directory, git: GitProcess(executableURL: gitExecutable))
                    _ = try await module.loadRepositoryState()
                    try await module.saveRemote(.init(originalName: nil, name: name, fetchURL: url, pushURL: nil,
                                                      puttyKeyFile: nil, color: nil, prefix: nil))
                },
                opened: opened, initialDestination: initialDestination)
            let controller = ForkAndCloneWindowController(environment: environment)
            forkCloneWindow = controller
            controller.showWindow(nil)
        }
    }

    func startPlugin(_ id: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await initializePlugins()
                guard let entry = pluginSession.registered.first(where: { $0.0.identifier == id }) else {
                    throw PluginError.invalid("This plugin is no longer available.")
                }
                let context = try await scriptOptions(for: ScriptDefinition())
                entry.1.update(context: context, owner: browser?.view.window)
                entry.1.updateSelection(browser?.workflowRevisionSelection ?? [])
                repositoryChangedNotifier.lock()
                defer { repositoryChangedNotifier.unlock(requestNotify: false) }
                if try await entry.0.execute(in: entry.1) { notifyRepositoryChanged() }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    static func startPlugins(owner: NSWindow?) {
        globalPluginRegistry.load()
        let entries = globalPluginRegistry.entries.sorted {
            $0.plugin.name.localizedCaseInsensitiveCompare($1.plugin.name) == .orderedAscending
        }
        let alert = NSAlert(); alert.messageText = "Plugins"
        alert.informativeText = globalPluginRegistry.failures.joined(separator: "\n")
        guard !entries.isEmpty else {
            alert.informativeText += "\nNo compatible native plugins are installed in \(ApplicationPluginRegistry.userDirectory.path)."
            alert.runModal(); return
        }
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        choices.addItems(withTitles: entries.map { $0.plugin.name })
        alert.accessoryView = choices
        alert.addButton(withTitle: "Settings…"); alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
        let target = PluginSelectionTarget { alert.buttons[1].isEnabled = !entries[choices.indexOfSelectedItem].plugin.requiresRepository }
        choices.target = target; choices.action = #selector(PluginSelectionTarget.changed)
        target.changed()
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let plugin = entries[choices.indexOfSelectedItem].plugin
        let settings = ApplicationPluginSettings(identifier: plugin.identifier, legacyName: plugin.pluginDescription,
            locations: nil, defaults: .standard)
        let host = GitExtensionPluginHost(refresh: {}, navigate: { _ in throw PluginError.invalid("Open a repository first.") },
            readSetting: { try settings.value($0, scope: DistributedSettingsScope(rawValue: $1.rawValue)!) },
            writeSetting: { try settings.set($0, value: $1, scope: DistributedSettingsScope(rawValue: $2.rawValue)!) })
        host.update(context: [:], owner: owner)
        Task { @MainActor in
            do {
                if response == .alertFirstButtonReturn {
                    if let controller = try plugin.settingsController(in: host) {
                        let window = NSWindow(contentViewController: controller)
                        window.title = "Settings — \(plugin.name)"; window.isReleasedWhenClosed = false
                        let presentation = NSWindowController(window: window)
                        globalPluginWindows.append(presentation); presentation.showWindow(nil)
                    } else {
                        let message = NSAlert(); message.messageText = "\(plugin.name) has no settings."; message.runModal()
                    }
                } else if !plugin.requiresRepository {
                    defer { plugin.unregister(from: host) }
                    try plugin.register(with: host)
                    _ = try await plugin.execute(in: host)
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func executePlugin(named name: String, context: [String: [String]], module: (any RepositoryBrowsingDataSource)? = nil) async throws {
        try await initializePlugins()
        guard let (plugin, host) = pluginSession.registered.first(where: {
            $0.0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw PluginError.invalid("Plugin is not installed or failed registration: \(name)") }
        if let module {
            let child = type(of: plugin).init()
            let locations: DistributedSettings?
            if let source = module as? any RepositorySettingsDataSource {
                locations = try await DistributedSettings.loadLocations(from: source)
            } else { locations = nil }
            let settings = ApplicationPluginSettings(identifier: child.identifier,
                legacyName: child.pluginDescription, locations: locations, defaults: .standard)
            let childHost = GitExtensionPluginHost(refresh: { [weak self] in self?.notifyRepositoryChanged() },
                navigate: { _ in throw PluginError.invalid("Revision navigation is unavailable in a child-repository workflow.") },
                readSetting: { try settings.value($0, scope: DistributedSettingsScope(rawValue: $1.rawValue)!) },
                writeSetting: { try settings.set($0, value: $1, scope: DistributedSettingsScope(rawValue: $2.rawValue)!) },
                executeCommand: { arguments, remote, mutation, input in
                    guard let source = module as? any RepositoryPluginDataSource else {
                        throw PluginError.invalid("Repository command execution is unavailable.")
                    }
                    let result = try await source.executePluginCommand(
                        GitCommand(arguments: arguments, accessesRemote: remote, changesRepositoryState: mutation), standardInput: input)
                    return (result.exitStatus, result.standardOutput, result.standardError)
                })
            childHost.update(context: context, owner: browser?.view.window)
            childHost.builtInRepository = module as? any RepositoryBuiltInPluginDataSource
            childHost.builtInSettings = module as? any RepositorySettingsDataSource
            repositoryChangedNotifier.lock()
            defer { child.unregister(from: childHost); repositoryChangedNotifier.unlock(requestNotify: false) }
            try child.register(with: childHost)
            if try await child.execute(in: childHost) { notifyRepositoryChanged() }
            return
        }
        host.update(context: context, owner: browser?.view.window)
        host.updateSelection(browser?.workflowRevisionSelection ?? [])
        repositoryChangedNotifier.lock()
        defer { repositoryChangedNotifier.unlock(requestNotify: false) }
        if try await plugin.execute(in: host) { notifyRepositoryChanged() }
    }

    private func initializePlugins() async throws {
        guard !pluginsInitialized else { return }
        pluginRegistry.load()
        let locations: DistributedSettings?
        if let source = repositoryModule as? any RepositorySettingsDataSource {
            locations = try await DistributedSettings.loadLocations(from: source)
        } else { locations = nil }
        let context = try await scriptOptions(for: ScriptDefinition())
        try Task.checkCancellation()
        guard !pluginsInitialized else { return }
        for entry in pluginRegistry.entries {
            if entry.plugin.requiresRepository && context["WorkingDir"] == nil { continue }
            let settings = ApplicationPluginSettings(identifier: entry.plugin.identifier,
                legacyName: entry.plugin.pluginDescription, locations: locations, defaults: .standard)
            let host = GitExtensionPluginHost(refresh: { [weak self] in self?.notifyRepositoryChanged() },
                navigate: { [weak self] expression in
                    guard let self, let source = repositoryModule as? any RepositoryScriptContextDataSource else { return }
                    browser?.selectScriptRevision(try await source.scriptRevision(expression))
                }, readSetting: { try settings.value($0, scope: DistributedSettingsScope(rawValue: $1.rawValue)!) },
                writeSetting: { try settings.set($0, value: $1, scope: DistributedSettingsScope(rawValue: $2.rawValue)!) },
                settingsChanged: { [weak self] in self?.pluginEvent("PostSettings", succeeded: true) },
                launchWorkflow: { [weak self] workflow in
                    guard let self else { throw PluginError.invalid("The repository window has closed.") }
                    switch workflow {
                    case .commit: startCommit()
                    case .checkoutBranch: startCheckoutBranch(initialTarget: nil)
                    case .pull: startPull(action: .openDialog, immediately: false)
                    case .push: startPush()
                    case .fetch: startPull(action: .fetch, immediately: false)
                    case .merge: startMergeBranches(initialTarget: nil)
                    case .stashes: startStashManagement()
                    case .settings: startSettings()
                    case .remoteManagement: startRemoteManagement()
                    case .repositoryHosting: startPullRequests()
                    case .reflog: startReflog()
                    case .worktrees: startCreateWorktree()
                    case .submodules: startSubmoduleManagement()
                    case .clean: startCleanRepository()
                    case .bisect: startBisect(browser?.workflowRevisionSelection.compactMap { id in self.browser?.revisions.first { $0.id == id } } ?? [])
                    case .openRepository(let url): BrowserCommandCenter.perform(.openRecentRepository(url))
                    }
                },
                executeCommand: { [weak self] arguments, remote, mutation, input in
                    guard let source = self?.repositoryModule as? any RepositoryPluginDataSource else {
                        throw PluginError.invalid("Repository command execution is unavailable.")
                    }
                    let result = try await source.executePluginCommand(
                        GitCommand(arguments: arguments, accessesRemote: remote, changesRepositoryState: mutation),
                        standardInput: input)
                    return (result.exitStatus, result.standardOutput, result.standardError)
                })
            host.update(context: context, owner: browser?.view.window)
            host.builtInRepository = repositoryModule as? any RepositoryBuiltInPluginDataSource
            host.builtInSettings = repositoryModule as? any RepositorySettingsDataSource
            host.updateSelection(browser?.workflowRevisionSelection ?? [])
            pluginSession.register(entry.plugin, host: host)
        }
        pluginsInitialized = true
        if let owner = browser?.view.window, pluginCloseObserver == nil {
            let session = pluginSession
            pluginCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: owner, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        if let self { self.stopPlugins() } else { session.close() }
                    }
                }
            pluginMainObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification,
                object: owner, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.publishPluginMenu() }
                }
        }
        publishPluginMenu()
        _ = pluginSession.dispatch("PostRegisterPlugin")
    }

    private func publishPluginMenu() {
        guard browser?.view.window?.isMainWindow == true else { return }
        BrowserCommandAvailability.shared.plugins = pluginSession.registered
            .sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
            .map { .init(id: $0.0.identifier, title: $0.0.name, icon: $0.0.icon) }
    }

    func startArchive(selected: [Commit]) {
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryArchivingDataSource else { return }
        guard (1...2).contains(selected.count), selected.allSatisfy({ !$0.isArtificial }) else {
            Task { await MutationDialogs.showInformation("Select only one or two real revisions.", title: "Archive", window: owner) }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try await repositoryModule.revisionReadRequest()
                var history: [Commit] = []
                for try await batch in await request.reader.read(request.context) { history += batch }
                let id = UUID()
                let controller = ArchiveWindowController(source: source,
                    repositoryName: browser.repositoryIdentity?.currentRepository.name ?? "repository",
                    history: history, selected: selected, closed: { [weak self] in self?.archiveWindows[id] = nil })
                archiveWindows[id] = controller
                controller.window?.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30))
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            } catch { await MutationDialogs.showError(error, title: "Archive", window: owner) }
        }
    }

    func startScripts() {
        guard let browser, let identity = browser.repositoryIdentity else { return }
        if let scriptsWindow { scriptsWindow.showWindow(nil); scriptsWindow.window?.makeKeyAndOrderFront(nil); return }
        let directory = URL(fileURLWithPath: identity.currentRepository.path, isDirectory: true)
        do {
            let controller = try ScriptsWindowController(execute: { [weak self] script, completion in
                guard let self else { return }
                scriptTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let options = try await scriptOptions(for: script)
                        try ScriptExecution.validateContext(script.arguments, options: options, beforePrompts: true)
                        guard let script = await ScriptPrompts.resolve(script, options: options) else {
                            completion(.failure(CancellationError())); scriptTask = nil; return
                        }
                        if !script.isPowerShell, let name = ApplicationPluginRegistry.scriptPluginName(script.command) {
                            try await executePlugin(named: name, context: options)
                            completion(.success(.pluginCompleted)); scriptTask = nil; return
                        }
                        let invocation = try ScriptExecution.invocation(script, directory: directory, options: options,
                            gitExecutable: URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath),
                            applicationExecutable: Bundle.main.executableURL)
                        if script.isPowerShell || (script.runInBackground && !script.command.hasPrefix("navigateTo:")) {
                            completion(.success(try await ScriptExecution.startBackground(invocation)))
                        } else {
                            let result = try await ScriptExecution.run(invocation, output: { _ in })
                            try await finishScript(script, result: result)
                            completion(.success(.completed(result)))
                        }
                    } catch { completion(.failure(error)) }
                    scriptTask = nil
                }
            }, cancel: { [weak self] in self?.scriptTask?.cancel() })
            scriptsWindow = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { NSAlert(error: error).runModal() }
    }

    private func scriptOptions(for script: ScriptDefinition, module: (any RepositoryBrowsingDataSource)? = nil, context: [String: [String]] = [:]) async throws -> [String: [String]] {
        guard let source = (module ?? repositoryModule) as? any RepositoryScriptContextDataSource else { return [:] }
        let selected = module == nil ? browser?.workflowRevisionSelection.compactMap(\.objectID) ?? [] : []
        var options = try await source.scriptContext(selected: selected, arguments: script.arguments)
        if module == nil, let browser {
            let revisions = browser.workflowRevisionSelection.compactMap { id in browser.revisions.first { $0.id == id } }
            options.merge(ScriptExecution.selectedRevisionOptions(revisions)) { _, value in value }
        }
        let fileContext = module == nil ? browser?.scriptFileContext : nil
        options.merge(fileContext ?? ["SelectedRelativePaths": [], "LineNumber": ["1"], "ColumnNumber": ["1"]]) { _, value in value }
        options.merge(context) { _, value in value }
        for key in options.keys.sorted() where key != "sHashes" && script.arguments.contains("{\(key)}") {
            guard let values = options[key], values.count > 1 else { continue }
            let alert = NSAlert(); alert.messageText = "Select \(key)"
            let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
            choices.addItems(withTitles: values); alert.accessoryView = choices
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
            options[key] = [values[choices.indexOfSelectedItem]]
        }
        return options
    }

    func startScript(_ script: ScriptDefinition) {
        Task { @MainActor in
            var script = script
            script.enabled = true
            _ = await runScriptEvent(script.onEvent, definitions: [script])
        }
    }

    func runScriptEvent(_ event: ScriptEvent, module: (any RepositoryBrowsingDataSource)? = nil, definitions: [ScriptDefinition]? = nil, context: [String: [String]] = [:]) async -> Bool {
        do {
            return try await ApplicationScriptEvents.run(event, scripts: definitions ?? ApplicationScriptsStore.shared.load()) { [self] script in
                guard !script.command.isEmpty else { return false }
                if script.askConfirmation {
                    let alert = NSAlert(); alert.messageText = "Execute script ‘\(script.displayName)’?"
                    alert.addButton(withTitle: "Execute"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return false }
                }
                let options = try await scriptOptions(for: script, module: module, context: context)
                try ScriptExecution.validateContext(script.arguments, options: options, beforePrompts: true)
                guard let prepared = await ScriptPrompts.resolve(script, options: options) else { return false }
                if !script.isPowerShell, let name = ApplicationPluginRegistry.scriptPluginName(script.command) {
                    try await executePlugin(named: name, context: options, module: module)
                    return true
                }
                guard let directory = options["WorkingDir"]?.first else { return false }
                let invocation = try ScriptExecution.invocation(prepared,
                    directory: URL(fileURLWithPath: directory), options: options,
                    gitExecutable: URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath),
                    applicationExecutable: Bundle.main.executableURL)
                if script.isPowerShell || (script.runInBackground && !script.command.hasPrefix("navigateTo:")) {
                    _ = try await ScriptExecution.startBackground(invocation)
                    return true
                }
                let result = try await ScriptProcessWindow.run(invocation, title: script.displayName, owner: browser?.view.window)
                try await finishScript(script, result: result, module: module)
                if script.command.hasPrefix("navigateTo:") || result.succeeded { return true }
                let alert = NSAlert(); alert.messageText = "Script failed: \(script.displayName)"
                alert.informativeText = "Exit code: \(result.exitStatus)\n" + result.standardErrorString
                alert.runModal(); return false
            }
        } catch is CancellationError { return false }
        catch { NSAlert(error: error).runModal(); return false }
    }

    private func finishScript(_ script: ScriptDefinition, result: GitCommandResult, module: (any RepositoryBrowsingDataSource)? = nil) async throws {
        if script.command.hasPrefix("navigateTo:") {
            if let expression = result.standardOutputString.components(separatedBy: "\n").first, !expression.isEmpty,
               let source = (module ?? repositoryModule) as? any RepositoryScriptContextDataSource {
                let id = try await source.scriptRevision(expression.trimmingCharacters(in: .whitespacesAndNewlines))
                if module == nil { browser?.selectScriptRevision(id) }
            }
        } else if result.succeeded { notifyRepositoryChanged() }
    }

    var scriptHooks: ApplicationScriptHooks {
        scriptHooks(for: nil)
    }

    private func scriptHooks(for module: (any RepositoryBrowsingDataSource)?) -> ApplicationScriptHooks {
        let notifier = repositoryChangedNotifier
        return ApplicationScriptHooks(begin: { notifier.lock() },
            end: { notifier.unlock(requestNotify: false) },
            run: { [weak self] event in await self?.runScriptEvent(event, module: module) ?? false },
            contextualRun: { [weak self] event, context in
                await self?.runScriptEvent(event, module: module, context: context) ?? false
            },
            manualRun: { [weak self] script, context in
                var script = script; script.enabled = true
                return await self?.runScriptEvent(script.onEvent, module: module, definitions: [script], context: context) ?? false
            }, childHooks: { [weak self] module in
                self?.scriptHooks(for: module) ?? ApplicationScriptHooks(begin: {}, end: {}, run: { _ in false })
            })
    }


    static func launchBrowse(_ url: URL, selection: [RevisionID] = [], fileHistory: FileHistoryBrowseRequest? = nil, onError: @escaping @MainActor (Error) -> Void = { _ in }) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--repository", url.path] + RepositoryOpeningSelection.arguments(selection) + (fileHistory?.arguments ?? [])
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Task { @MainActor in onError(error) } }
        }
    }


    static func runGitGui(workingDirectory: URL, owner: NSWindow?) {
        let git = GitProcess(executableURL: URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath))
        runExternalTool("Git GUI", git: git, arguments: ["gui"], workingDirectory: workingDirectory, owner: owner)
    }


    static func runGitK(workingDirectory: URL, owner: NSWindow?) {
        let gitDirectory = URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath).deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let candidates = [gitDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + path
        guard let gitk = candidates.map({ URL(fileURLWithPath: $0).appendingPathComponent("gitk") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            if let owner { Task { await MutationDialogs.showError(GitError.executableUnavailable("gitk"), title: "GitK", window: owner) } }
            return
        }
        runExternalTool("GitK", git: GitProcess(executableURL: gitk), arguments: [], workingDirectory: workingDirectory, owner: owner)
    }

    private static func runExternalTool(_ title: String, git: GitProcess, arguments: [String], workingDirectory: URL, owner: NSWindow?) {
        Task { @MainActor in
            do {
                let result = try await git.run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false),
                                               in: workingDirectory)
                guard !result.succeeded else { return }
                throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
            } catch {
                if let owner { await MutationDialogs.showError(error, title: title, window: owner) }
            }
        }
    }

    static func startCommandLog() {
        if commandLogWindow == nil {
            let controller = CommandLogWindowController()
            controller.onClose = { commandLogWindow = nil }
            commandLogWindow = controller
        }
        commandLogWindow?.showWindow(nil)
        commandLogWindow?.window?.deminiaturize(nil)
        commandLogWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func startOutputHistory() { browser?.focusOutputHistory() }

    func startSettings(initialPage: String? = nil, initialScope: DistributedSettingsScope = .effective) {
        guard let owner = browser?.view.window else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let accepted = await ApplicationShellDialogs.presentSettings(from: owner, source: repositoryModule as? any RepositorySettingsDataSource,
                initialPage: initialPage, initialScope: initialScope,
                repositoryChanged: { [weak self] in self?.notifyRepositoryChanged() })
            pluginEvent("PostSettings", succeeded: accepted)
        }
    }



    static func checkStartupSettings(owner: NSWindow, store: AppSettingsStore = .shared) async {
        guard store.checkSettingsAtStartup else { return }
        var executable = URL(fileURLWithPath: (store.preferences.gitExecutablePath as NSString).expandingTildeInPath)
        var checks = (try? await GitSettingsChecklist.load(executableURL: executable)) ?? []
        guard !Task.isCancelled else { return }
        if checks.first?.status == .invalid, let located = await GitSettingsChecklist.locateGit(), located != executable {
            executable = located
            var preferences = store.preferences
            preferences.gitExecutablePath = located.path
            store.save(preferences)
            checks = (try? await GitSettingsChecklist.load(executableURL: executable)) ?? []
        }
        guard !Task.isCancelled else { return }
        if !checks.isEmpty && checks.allSatisfy({ $0.status == .valid }) {
            store.recordSettingsCheck(allValid: true)
        } else if owner.isVisible, owner.attachedSheet == nil {
            _ = await ApplicationShellDialogs.presentSettings(from: owner, initialPage: "application")
        }
    }

    static func startPatchViewer(owner: NSWindow?, file: URL? = nil) {
        let id = UUID()
        let controller = PatchWindowController(mode: .view, source: nil, revisions: [], selected: [], initialFile: file,
            viewPatch: { file in startPatchViewer(owner: owner, file: file) }, changed: {}, conflicts: { _ in false },
            closed: { standalonePatchWindows[id] = nil })
        standalonePatchWindows[id] = controller
        if let owner { controller.window?.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30)) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func startPatch(_ mode: PatchDialogMode, selected: [Commit] = [], history: [Commit]? = nil, file: URL? = nil) {
        if mode == .view { Self.startPatchViewer(owner: browser?.view.window, file: file); return }
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryPatchingDataSource,
              browser.repositoryIdentity?.currentRepository.isBare == false else { return }
        if mode == .format && history == nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let request = try await repositoryModule.revisionReadRequest()
                    var commits: [Commit] = []
                    for try await batch in await request.reader.read(request.context) { commits += batch }
                    startPatch(mode, selected: selected, history: commits)
                } catch { await MutationDialogs.showError(error, title: "Load patch revisions", window: owner) }
            }
            return
        }
        let id = UUID()
        let controller = PatchWindowController(
            mode: mode, source: source, revisions: history ?? browser.revisions, selected: selected.map(\.id),
            currentBranch: browser.repositoryReferences?.branches.first(where: \.isCurrent)?.name,
            initialFile: file, viewPatch: { [weak self] file in self?.startPatch(.view, file: file) },
            changed: { [weak self, weak browser] in self?.notifyRepositoryChanged(preferredCommitID: browser?.selectedCommitID) },
            conflicts: { [weak self] window in await WorkflowManagementDialogs.resolveConflicts(source: source, window: window, offerCommit: false, scriptHooks: self?.scriptHooks) },
            closed: { [weak self] in self?.patchWindows[id] = nil })
        controller.onViewRevisions = { [weak self, weak controller] in self?.startViewRevisions($0, owner: controller?.window) }
        patchWindows[id] = controller
        controller.window?.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30))
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func startWorktreeManagement() {
        if let worktreeWindowController { worktreeWindowController.showWindow(nil); worktreeWindowController.window?.makeKeyAndOrderFront(nil); return }
        guard let owner = browser?.view.window, let source = repositoryModule as? any RepositoryWorktreeManagingDataSource else { return }
        worktreeWindowController = WorktreeDialogs.manage(
            source: source, owner: owner,
            create: { [weak self] in await self?.createWorktree(owner: $0) },
            delete: { [weak self] in await self?.deleteWorktree($0, owner: $1) },
            prune: { [weak self] in await self?.pruneWorktrees(owner: $0) },
            open: { [weak self] in self?.openWorktree($0, owner: $1) ?? false },
            closed: { [weak self] in self?.worktreeWindowController = nil }
        )
    }

    func startSubmoduleManagement() {
        if let submoduleWindowController { submoduleWindowController.showWindow(nil); submoduleWindowController.window?.makeKeyAndOrderFront(nil); return }
        guard let owner = browser?.view.window, browser?.repositoryIdentity?.currentRepository.isBare == false,
              let source = repositoryModule as? any RepositorySubmoduleManagingDataSource else { return }
        submoduleWindowController = SubmoduleDialogs.manage(source: source, owner: owner,
            changed: { [weak self] in self?.notifyRepositoryChanged() },
            open: { [weak self] submodule, pull in
                if pull { self?.startSubmodulePull(path: submodule.path) }
                else { self?.startOpenSubmodule(submodule) }
            }, closed: { [weak self] in self?.submoduleWindowController = nil })
    }

    static func resolveSubmoduleConflict(source: any RepositorySubmoduleManagingDataSource, path: String, owner: NSWindow,
                                        scriptHooks: ((any RepositoryBrowsingDataSource) -> ApplicationScriptHooks)? = nil) async -> Bool {
        await SubmoduleDialogs.resolveConflict(source: source, path: path, owner: owner,
            scriptHooks: scriptHooks)
    }

    func startSubmoduleAction(_ action: RepositorySubmoduleAction) {
        guard let source = repositoryModule as? any RepositorySubmoduleManagingDataSource,
              let owner = browser?.view.window, browser?.repositoryIdentity?.currentRepository.isBare == false else { return }
        Task { @MainActor in
            let result = await SubmoduleDialogs.run(title: "Submodules", owner: owner) { output in try await source.performSubmoduleAction(action, output: output) }
            completeSubmoduleOperation(result)
            if case .update = action { pluginEvent("PostUpdateSubmodules", succeeded: result.succeeded) }
        }
    }

    func completeSubmoduleOperation(_ result: RepositorySubmoduleResult) {
        if result.changed { notifyRepositoryChanged() }
        browser?.showPlaceholderStatus(result.output.isEmpty ? "Submodules refreshed." : result.output)
    }

    func startOpenSubmodule(_ submodule: Submodule, newWindow: Bool = false) {
        guard let repository = browser?.repositoryIdentity?.currentRepository else { return }
        let url = URL(fileURLWithPath: repository.path).appendingPathComponent(submodule.path)
        openSubmoduleURL(url, newWindow: newWindow)
    }

    func startOpenSubmodule(_ item: SubmoduleTreeItem, newWindow: Bool = false) {
        guard let source = repositoryModule as? any RepositorySubmoduleManagingDataSource else { return }
        Task { @MainActor in
            do {
                let url = try await source.submoduleTreeLocation(item)
                let selection: [RevisionID]
                if item.isCurrent { selection = browser?.workflowRevisionSelection ?? [] }
                else if newWindow || (!item.isTop && (item.isDirty || item.commitID != item.recordedID)) {
                    selection = [.workingDirectory] + (item.commitID != item.recordedID ? item.recordedID.map { [.object($0)] } ?? [] : [])
                } else { selection = [] }
                openSubmoduleURL(url, newWindow: newWindow, validated: true, selection: selection)
            } catch {
                if let owner = browser?.view.window { worktreeError(error.localizedDescription, owner: owner) }
                else { browser?.showPlaceholderStatus(error.localizedDescription) }
            }
        }
    }

    private func openSubmoduleURL(_ url: URL, newWindow: Bool, validated: Bool = false, selection: [RevisionID] = []) {
        guard validated || FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            browser?.showPlaceholderStatus("Initialize the submodule before opening it."); return
        }
        if newWindow {
            Self.launchBrowse(url, selection: selection) { [weak self] error in self?.browser?.showPlaceholderStatus(error.localizedDescription) }
        } else if selection.isEmpty { _ = browser?.onApplicationCommand?(.openRecentRepository(url)) }
        else { _ = browser?.onApplicationCommand?(.openRepositoryAtRevisions(url, selection)) }
    }

    func startSubmoduleTreeUpdate(_ item: SubmoduleTreeItem) {
        guard let source = repositoryModule as? any RepositorySubmoduleManagingDataSource, let owner = browser?.view.window else { return }
        Task { @MainActor in
            let result = await SubmoduleDialogs.run(title: "Submodules", owner: owner) { output in
                try await source.updateSubmoduleTreeItem(item, output: output)
            }
            completeSubmoduleOperation(result)
            pluginEvent("PostUpdateSubmodules", succeeded: result.succeeded)
        }
    }

    private func submoduleSource(path: String) async throws -> any RepositoryBrowsingDataSource {
        if let existing = submoduleSources[path] { return existing }
        guard let parent = repositoryModule as? any RepositorySubmoduleManagingDataSource else { throw RepositorySubmoduleError.missingSubmodule }
        let child = try await parent.submoduleRepository(path: path)
        submoduleSources[path] = child
        return child
    }

    private func startSubmodulePull(path: String) {
        if let submodulePullWindowController { submodulePullWindowController.window?.makeKeyAndOrderFront(nil); return }
        Task { @MainActor in
            do {
                let child = try await submoduleSource(path: path)
                guard let pullSource = child as? any RepositoryPullingDataSource else { return }
                let state = try await child.loadRepositoryState()
                let context = RepositoryNetworkContext(repository: state.identity.currentRepository, headID: state.identity.headID,
                    branches: state.references.branches, remotes: state.navigation.remotes,
                    references: state.references.references, submodules: state.navigation.submodules)
                submodulePullWindowController = ApplicationShellDialogs.presentPullWindow(initialAction: .merge, executeImmediately: false,
                    context: context, source: pullSource,
                    onManageRemotes: { [weak self] remote, branch in
                        guard let self, let remotes = child as? any RepositoryRemoteManagingDataSource else { return }
                        self.submoduleRemoteWindowController = RemoteManagementDialog.present(source: remotes, selectedRemote: remote, selectedLocalBranch: branch,
                            onFetchRemote: { name, owner in
                                _ = await PullProcessDialog.run(request: RepositoryPullRequest(source: .remote(name), mode: .fetch), source: pullSource, parent: owner, scriptHooks: self.scriptHooks(for: child))
                            }, onRepositoryChanged: { [weak self] in self?.notifyRepositoryChanged() },
                            onClose: { [weak self] in self?.submoduleRemoteWindowController = nil })
                    }, scriptHooks: scriptHooks(for: child), onRepositoryChanged: { [weak self] _ in self?.notifyRepositoryChanged() },
                    onClose: { [weak self] in self?.submodulePullWindowController = nil })
            } catch { if let owner = browser?.view.window { worktreeError(error.localizedDescription, owner: owner) } }
        }
    }

    enum SubmoduleChildAction { case reset, stash, commit }
    func startSubmoduleChildAction(_ action: SubmoduleChildAction, submodule: SubmoduleTreeItem) {
        guard let owner = browser?.view.window else { return }
        Task { @MainActor in
            do {
                guard let parent = repositoryModule as? any RepositorySubmoduleManagingDataSource else { return }
                let child: any RepositoryBrowsingDataSource
                if let cached = submoduleSources[submodule.id] { child = cached }
                else { child = try await parent.submoduleTreeRepository(submodule); submoduleSources[submodule.id] = child }
                switch action {
                case .commit:
                    presentSubmoduleCommit(child, owner: owner)
                case .stash:
                    guard let stash = child as? any RepositoryStashDataSource else { return }
                    let before = try await child.loadRepositoryState().navigation.stashes
                    let result = try await stash.createStash(.init(message: "", includeUntracked: AppSettingsStore.shared.stashPreferences.includeUntracked, keepIndex: false, stagedOnly: false))
                    if try await child.loadRepositoryState().navigation.stashes != before { notifyRepositoryChanged() }
                    browser?.showPlaceholderStatus(result.message)
                case .reset:
                    guard let reset = child as? any RepositoryResettingDataSource else { return }
                    let state = try await reset.loadMutationState()
                    let tracked = state.hasStagedChanges || state.hasUnstagedChanges || !state.conflictedPaths.isEmpty
                    guard tracked || state.hasUntrackedFiles else { browser?.showPlaceholderStatus("There are no changes to reset."); return }
                    guard let clean = await ResetDialogs.confirmResetChanges(hasTrackedChanges: tracked, hasUntrackedFiles: state.hasUntrackedFiles, owner: owner) else { return }
                    let result = try await reset.resetChanges(.init(scope: .all, deleteUntracked: clean))
                    notifyRepositoryChanged(); browser?.showPlaceholderStatus(result.message)
                }
            } catch { worktreeError(error.localizedDescription, owner: owner) }
        }
    }

    func startCreateWorktree() { Task { @MainActor in if let owner = browser?.view.window { await createWorktree(owner: owner) } } }
    func startDeleteWorktree(_ worktree: Worktree) { Task { @MainActor in if let owner = browser?.view.window { await deleteWorktree(worktree, owner: owner) } } }
    func startPruneWorktrees() { Task { @MainActor in if let owner = browser?.view.window { await pruneWorktrees(owner: owner) } } }
    func startOpenWorktree(_ worktree: Worktree, confirm: Bool = true) { if let owner = browser?.view.window { _ = openWorktree(worktree, owner: owner, confirm: confirm) } }

    private func reportWorktreeResult(_ result: RepositoryWorktreeResult) {
        if result.changed { notifyRepositoryChanged() }
        browser?.showPlaceholderStatus(result.output.isEmpty ? "Worktrees refreshed." : result.output)
    }

    private func createWorktree(owner: NSWindow) async {
        guard let source = repositoryModule as? any RepositoryWorktreeManagingDataSource else { return }
        do {
            let context = try await source.loadWorktreeContext()
            let path = await WorktreeDialogs.create(context: context, owner: owner) { [weak self] request, output in
                let result = try await source.createWorktree(request, output: output)
                self?.reportWorktreeResult(result)
                return result
            }
            if let path, let worktree = try await source.loadWorktreeContext().worktrees.first(where: { $0.path == URL(fileURLWithPath: path).standardizedFileURL.path }) {
                _ = openWorktree(worktree, owner: owner)
            }
        } catch { worktreeError(error.localizedDescription, owner: owner) }
    }

    private func deleteWorktree(_ worktree: Worktree, owner: NSWindow) async {
        guard worktree.canDelete, let source = repositoryModule as? any RepositoryWorktreeManagingDataSource else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "This cannot be undone"
        confirmation.informativeText = "Delete worktree ‘\(worktree.path)’?\nThe directory and all its contents, including uncommitted and untracked files, will be permanently deleted."
        confirmation.addButton(withTitle: "Cancel"); confirmation.addButton(withTitle: "Delete worktree")
        guard await confirmation.beginSheetModal(for: owner) == .alertSecondButtonReturn else { return }
        do {
            let result = try await source.deleteWorktree(path: worktree.path)
            reportWorktreeResult(result)
            if !result.succeeded { worktreeError(result.output, owner: owner) }
        } catch { worktreeError(error.localizedDescription, owner: owner) }
    }

    private func pruneWorktrees(owner: NSWindow) async {
        guard let source = repositoryModule as? any RepositoryWorktreeManagingDataSource else { return }
        do {
            let result = try await source.pruneWorktrees(); reportWorktreeResult(result)
            if !result.succeeded { worktreeError(result.output, owner: owner) }
        } catch { worktreeError(error.localizedDescription, owner: owner) }
    }

    private func openWorktree(_ worktree: Worktree, owner: NSWindow, confirm: Bool = true) -> Bool {
        guard worktree.canOpen else { return false }
        guard FileManager.default.fileExists(atPath: worktree.path) else { worktreeError("The worktree directory no longer exists: \(worktree.path)", owner: owner); return false }
        if confirm && !UserDefaults.standard.bool(forKey: "GitExtensionsMac.DontConfirmSwitchWorktree") {
            let alert = NSAlert(); alert.messageText = "Switch worktree?"
            alert.informativeText = "Open ‘\(worktree.path)’ in Git Extensions?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            alert.showsSuppressionButton = true
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "GitExtensionsMac.DontConfirmSwitchWorktree") }
        }
        worktreeWindowController?.close()
        return browser?.onApplicationCommand?(.openRecentRepository(URL(fileURLWithPath: worktree.path))) ?? false
    }



    static let dontConfirmUndoLastCommitKey = "GitExtensionsMac.DontConfirmUndoLastCommit"


    func startUndoLastCommit() {
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryBrowserMaintenanceDataSource else { return }
        if !UserDefaults.standard.bool(forKey: Self.dontConfirmUndoLastCommitKey) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Undo last commit"
            alert.informativeText = "You will still be able to find all the commit's changes in the staging area\n\nDo you want to continue?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            alert.showsSuppressionButton = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Self.dontConfirmUndoLastCommitKey) }
        }
        Task { @MainActor [weak self] in
            do {
                let result = try await source.undoLastCommit()
                self?.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
            } catch {
                await MutationDialogs.showError(error, title: "Undo last commit", window: owner)
            }
        }
    }


    func openFileExplorer() {
        guard let path = browser?.repositoryIdentity?.currentRepository.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }


    func openTerminal() {
        guard let path = browser?.repositoryIdentity?.currentRepository.path,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }


    func deleteIndexLock() {
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryBrowserMaintenanceDataSource else { return }
        Task { @MainActor in
            do { _ = try await source.deleteIndexLocks() }
            catch { await MutationDialogs.showError(error, title: "Delete index.lock", window: owner) }
        }
    }


    func compressGitDatabase() {
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryBrowserMaintenanceDataSource else { return }
        Task { @MainActor [weak self] in
            _ = await HostingProcessDialog.run("Compress git database", owner) { output in
                let result = try await source.compressGitDatabase(output: output)
                guard result.succeeded else {
                    throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
                }
                return true
            }
            self?.notifyRepositoryChanged(preferredCommitID: nil)
        }
    }




    func startEditGitIgnore(localExclude: Bool, owner: NSWindow? = nil, onClosed: (() -> Void)? = nil) {
        startRepositoryFileEditor(localExclude ? .localExclude : .gitIgnore, owner: owner) { [weak self] in
            self?.pluginEvent("PostEditGitIgnore", succeeded: true)
            onClosed?()
        }
    }


    func startEditGitAttributes() { startRepositoryFileEditor(.gitAttributes, owner: nil, onClosed: nil) }


    func startEditMailMap() { startRepositoryFileEditor(.mailMap, owner: nil, onClosed: nil) }

    private func startRepositoryFileEditor(_ kind: RepositoryFileEditorWindowController.Kind, owner: NSWindow?, onClosed: (() -> Void)?) {
        let key = "repository:\(kind.fileName)"
        if focusFileEditor(key) { return }
        guard let browser, let owner = owner ?? browser.view.window,
              let source = repositoryModule as? any RepositoryFileEditingDataSource else { return }

        if browser.repositoryIdentity?.currentRepository.isBare == true {
            Task { @MainActor in
                await RepositoryFileEditorDialogs.message(kind.noWorkingDirectory, caption: RepositoryFileEditorWindowController.Kind.noWorkingDirectoryCaption, window: owner)
                onClosed?()
            }
            return
        }
        let controller = RepositoryFileEditorWindowController(
            kind: kind, source: source,
            addPattern: { [weak self] window in
                await self?.startAddToGitIgnore(localExclude: kind == .localExclude, patterns: ["*.dll"], owner: window)
            },

            onSaved: { [weak self] in self?.notifyRepositoryChanged(preferredCommitID: self?.browser?.selectedCommitID) },
            onClose: { [weak self] in
                self?.fileEditorWindows[key] = nil
                onClosed?()
            })
        fileEditorWindows[key] = controller
        Task { @MainActor [weak self] in
            await controller.load()
            self?.showFileEditor(controller, owner: owner)
        }
    }


    @discardableResult
    func startAddToGitIgnore(localExclude: Bool, patterns: [String], owner: NSWindow) async -> Bool {
        guard let source = repositoryModule as? any RepositoryFileEditingDataSource else { return false }
        let controller = AddToGitIgnoreWindowController(source: source, localExclude: localExclude, patterns: patterns)
        await controller.run(parent: owner)
        pluginEvent("PostEditGitIgnore", succeeded: true)
        return true
    }


    func startFileEditor(_ url: URL, showWarning: Bool = false, lineNumber: Int? = nil, owner: NSWindow? = nil, onClosed: (() -> Void)? = nil, onFinished: ((Bool) -> Void)? = nil) {
        let key = "file:" + url.standardizedFileURL.path
        if focusFileEditor(key) { return }
        guard let browser, let owner = owner ?? browser.view.window,
              let source = repositoryModule as? any RepositoryFileEditingDataSource else { onFinished?(false); return }
        let controller = FileEditorWindowController(fileURL: url, source: source, showWarning: showWarning, lineNumber: lineNumber) { [weak self] in
            let accepted = (self?.fileEditorWindows[key] as? FileEditorWindowController)?.acceptedClose ?? false
            self?.fileEditorWindows[key] = nil
            onClosed?()
            onFinished?(accepted)
        }
        fileEditorWindows[key] = controller
        Task { @MainActor [weak self] in
            do { try await controller.load() } catch {
                self?.fileEditorWindows[key] = nil
                await RepositoryFileEditorDialogs.message("Cannot open file:\n\(error.localizedDescription)", caption: "Error", window: owner)
                onClosed?()
                onFinished?(false)
                return
            }
            self?.showFileEditor(controller, owner: owner)
        }
    }


    func startEditGitConfig() {
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryFileEditingDataSource else { return }
        Task { @MainActor [weak self] in
            do { self?.startFileEditor(try await source.editableFileURL(.gitConfig), showWarning: true, owner: owner) }
            catch { await MutationDialogs.showError(error, title: "Edit .git/config", window: owner) }
        }
    }



    func startSparseWorkingCopy() {
        let key = "sparse-working-copy"
        if focusFileEditor(key) { return }
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? SparseWorkingCopyWindowController.Source else { return }
        let path = browser.repositoryIdentity?.currentRepository.path ?? ""
        let controller = SparseWorkingCopyWindowController(
            source: source, processTitle: path.isEmpty ? "Process" : "Process (\(path))",
            onSaved: { [weak self] in self?.notifyRepositoryChanged(preferredCommitID: self?.browser?.selectedCommitID) },
            onClose: { [weak self] in self?.fileEditorWindows[key] = nil })
        fileEditorWindows[key] = controller
        Task { @MainActor [weak self] in
            await controller.load()
            self?.showFileEditor(controller, owner: owner)
        }
    }


    func startRecoverLostObjects() {
        let key = "recover-lost-objects"
        if focusFileEditor(key) { return }
        guard let browser, let owner = browser.view.window,
              let source = repositoryModule as? any RepositoryLostObjectsDataSource,
              let tagSource = repositoryModule as? any RepositoryTagManagingDataSource else { return }
        let path = browser.repositoryIdentity?.currentRepository.path ?? ""
        let title = path.isEmpty ? "Process" : "Process (\(path))"
        let actions = RecoverLostObjectsWindowController.Actions(
            runProcess: { window, operation in await HostingProcessDialog.run(title, window, operation) },
            createTag: { [weak self] id, window, finished in
                self?.startCreateTag(initialTarget: id, owner: window, onFinished: finished)
            },
            createBranch: { [weak self] id, window, finished in
                guard let coordinator = self?.makeCheckoutWorkflowCoordinator(owner: window) else { finished(false); return }
                coordinator.createBranch(sourceRevision: RevisionCommitBuilder.placeholderRevision(id: id),
                                         allowsBareRepository: true, onFinished: finished)
            },
            createLightweightTag: { name, id in
                _ = try await tagSource.createTag(RepositoryCreateTagRequest(name: name, target: id))
            },
            deleteTag: { name in _ = try await tagSource.deleteTag(named: name) })
        let controller = RecoverLostObjectsWindowController(
            source: source, actions: actions,
            workingDirectory: path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true),
            onClose: { [weak self] in
                self?.fileEditorWindows[key] = nil
                self?.notifyRepositoryChanged(preferredCommitID: self?.browser?.selectedCommitID)
            })
        fileEditorWindows[key] = controller
        showFileEditor(controller, owner: owner)
        Task { await controller.updateLostObjects() }
    }

    private func focusFileEditor(_ key: String) -> Bool {
        guard let controller = fileEditorWindows[key] else { return false }
        if controller.window?.isVisible == true {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func showFileEditor(_ controller: NSWindowController, owner: NSWindow) {
        guard let window = controller.window else { return }

        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: owner.frame.midX - frame.width / 2, y: owner.frame.midY - frame.height / 2))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func worktreeError(_ message: String, owner: NSWindow) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Worktree operation failed"; alert.informativeText = message
        alert.beginSheetModal(for: owner)
    }

    func startDifftool(commit: Commit, file: ChangedFile) {
        guard let browser else { return }
        browser.statusLabel.stringValue = "Opening \(file.path) with the configured difftool…"
        Task { @MainActor [weak browser, repositoryModule] in
            do {
                let customTool = AppSettingsStore.shared.preferences.externalDiffToolPath
                try await repositoryModule.openWithDifftool(
                    for: commit,
                    file: file,
                    customToolPath: customTool.isEmpty ? nil : customTool
                )
                browser?.statusLabel.stringValue = "Opened \(file.path) with difftool."
            } catch {
                browser?.statusLabel.stringValue = "Difftool failed: \(error.localizedDescription)"
            }
        }
    }




    func startBlame(file: String, revision: ObjectID? = nil, initialLine: Int? = nil, owner: NSWindow? = nil) {
        guard let source = repositoryModule as? any RepositoryBlameDataSource,
              let owner = owner ?? browser?.view.window else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let commit = try await source.loadBlameRevision(revision)
                let manager = repositoryModule as? any RepositoryRemoteManagingDataSource
                let controller = BlameWindowController(source: source,
                    infoSource: repositoryModule as? any RepositoryCommitInfoDataSource,
                    revision: commit, file: file, initialLine: initialLine,
                    hostedRemotes: { HostedRemote.gitHubRemotes((try? await manager?.loadRemoteConfigurations()) ?? []) },
                    showChanges: { [weak self] in self?.startBlameCommitDiff($0) })
                controller.infoController.onGoToRevision = { [weak self] id in
                    if let object = id.objectID { self?.browser?.selectScriptRevision(object) }
                }
                retainBlameWindow(controller, owner: owner)
            } catch { await MutationDialogs.showError(error, title: "Blame", window: owner) }
        }
    }


    func startViewRevisions(_ selected: [Commit], owner: NSWindow? = nil) {
        if let first = selected.first {
            if let object = first.objectID { startBlameCommitDiff(object, owner: owner) }
        } else { startCompareRevisions(owner: owner) }
    }

    func startRevisionComparison(_ action: String, selected: [Commit], base: Commit?, owner: NSWindow? = nil) {
        guard let source = repositoryModule as? any RepositoryRevisionComparingDataSource,
              let owner = owner ?? browser?.view.window, let latest = selected.first else { return }
        Task { @MainActor [weak self, weak owner] in
            guard let self, let owner else { return }
            do {
                let request = try await source.comparisonReadRequest()
                let head = request.context.headID
                var first = latest
                var second = latest
                var firstLabel: String?
                var secondLabel: String?
                switch action {
                case "revision.compare.branch":
                    guard let expression = await pickComparisonBranch(selected: latest.id, request: request, owner: owner) else { return }
                    first = try await source.comparisonTarget(expression); firstLabel = expression
                case "revision.compare.current":
                    guard let head, let branch = request.references.branches.first(where: \.isCurrent) else {
                        throw RevisionComparisonError.noCurrentBranch
                    }
                    second = try await source.comparisonRevision(.object(head), headID: head); secondLabel = branch.name
                case "revision.compare.base":
                    guard let base else { throw RevisionComparisonError.noBase }
                    first = base
                case "revision.compare.worktree":
                    guard !request.identity.currentRepository.isBare, latest.id != .workingDirectory else { return }
                    second = try await source.comparisonRevision(.workingDirectory, headID: head)
                case "revision.compare.selected":

                    let actual = try await source.comparisonRevision(latest.id, headID: head)
                    guard let id = RevisionComparison.firstID(in: selected.count == 1 ? [actual] : selected) else { return }
                    first = try await source.comparisonRevision(id, headID: head)
                default: return
                }
                _ = try await showRevisionComparison(first: first, second: second, firstLabel: firstLabel,
                    secondLabel: secondLabel, request: request, owner: owner)
            } catch { await MutationDialogs.showError(error, title: "Compare revisions", window: owner) }
        }
    }

    @discardableResult
    func showRevisionComparison(first: Commit, second: Commit, firstLabel: String? = nil, secondLabel: String? = nil,
                                request: RevisionComparisonReadRequest, owner: NSWindow) async throws -> RevisionComparisonWindowController {
        guard let source = repositoryModule as? any RepositoryRevisionComparingDataSource else { throw RepositoryDataSourceError.unavailable }
        let baseID = try await source.comparisonMergeBase(first: first.id, second: second.id, headID: request.context.headID)
        let base: Commit?
        if let baseID { base = try await source.comparisonRevision(.object(baseID), headID: request.context.headID) }
        else { base = nil }
        let content = RevisionPairViewController(first: first, second: second, firstLabel: firstLabel, secondLabel: secondLabel,
                                                 headID: request.context.headID, mergeBase: base)
        let controller = RevisionComparisonWindowController(content: content, title: "Diff", size: NSSize(width: 1042, height: 685), autosave: "GitExtensionsMac.RevisionDiff")
        configureComparisonDiff(content.diff, owner: controller.window)
        content.diff.repositoryURL = URL(fileURLWithPath: request.identity.currentRepository.path)
        content.diff.isBareRepository = request.identity.currentRepository.isBare


        content.populate()
        content.onPickBranch = { [weak self, weak controller, weak content] first in
            guard let self, let content, let window = controller?.window else { return }
            Task { @MainActor in
                guard let expression = await self.pickComparisonBranch(selected: (first ? content.first : content.second).id, request: request, owner: window) else { return }
                do { content.replaceEndpoint(first: first, revision: try await source.comparisonTarget(expression), label: expression) }
                catch { await MutationDialogs.showError(error, title: "Compare to branch", window: window) }
            }
        }
        content.onPickCommit = { [weak self, weak controller, weak content] first in
            guard let self, let content, let window = controller?.window else { return }
            Task { @MainActor in
                if let revision = await self.pickComparisonCommit(preselect: (first ? content.first : content.second).id, owner: window) {
                    content.replaceEndpoint(first: first, revision: revision)
                }
            }
        }
        content.onDirectoryDiff = { [weak self, weak controller] a, b in
            guard let source = self?.repositoryModule as? any RepositoryRevisionGridDataSource else { return }
            Task { @MainActor in
                do { try await source.openDirDiffWithDifftool(first: a, second: b) }
                catch { if let window = controller?.window { await MutationDialogs.showError(error, title: "Directory diff tool", window: window) } }
            }
        }
        let subscription = repositoryChangedNotifier.subscribe { [weak content] _, _ in content?.populate() }
        retainComparison(controller, owner: owner) { [weak content] in subscription.cancel(); content?.diff.cancelLoads() }
        return controller
    }

    @discardableResult
    func startCompareRevisions(owner: NSWindow? = nil) -> RevisionComparisonWindowController? {
        guard let source = repositoryModule as? any RepositoryRevisionComparingDataSource, let owner = owner ?? browser?.view.window else { return nil }
        let content = RevisionComparisonGridController(source: source)
        content.grid.dataSource = repositoryModule as? any RepositoryRevisionGridDataSource
        let controller = RevisionComparisonWindowController(content: content, title: "Diff", size: NSSize(width: 900, height: 650), autosave: "GitExtensionsMac.CompareRevisions")
        configureComparisonDiff(content.diff, owner: controller.window)
        content.grid.onViewSelected = { [weak self, weak controller] in self?.startViewRevisions($0, owner: controller?.window) }
        configureComparisonGrid(content, controller: controller)
        let subscription = repositoryChangedNotifier.subscribe { [weak content] _, _ in content?.reload() }
        retainComparison(controller, owner: owner) { [weak content] in subscription.cancel(); content?.cancel() }
        return controller
    }

    private func configureComparisonGrid(_ content: RevisionComparisonGridController, controller: RevisionComparisonWindowController) {
        content.grid.onCommand = { [weak self, weak content, weak controller] id, selected, focused in
            if id.hasPrefix("revision.compare.") {
                self?.startRevisionComparison(id, selected: selected, base: content?.grid.comparisonBase, owner: controller?.window)
            } else { self?.browser?.performRevisionCommand(id, selected: selected, focused: focused) }
        }
        content.grid.onDeleteBranch = { [weak self] in self?.deleteBranches(initiallySelected: [$0]) }
        content.grid.onApplyPatch = { [weak self] in self?.startPatch(.apply, file: $0) }
        content.grid.onScript = { [weak self, weak content] script in
            guard let self, let content else { return }
            let ids = content.grid.selectedRevisionIDsBySelectionOrder
            let selected = ids.compactMap { id in content.revisions.first { $0.id == id } }
            var script = script; script.enabled = true
            Task { @MainActor in
                var context = (try? await (self.repositoryModule as? any RepositoryScriptContextDataSource)?.scriptContext(selected: ids.compactMap(\.objectID), arguments: script.arguments)) ?? [:]
                context.merge(ScriptExecution.selectedRevisionOptions(selected)) { _, value in value }
                context.merge(content.diff.scriptFileContext) { _, value in value }
                _ = await self.runScriptEvent(script.onEvent, definitions: [script], context: context)
            }
        }
    }

    private func retainComparison(_ controller: RevisionComparisonWindowController, owner: NSWindow, cancel: @escaping () -> Void) {
        let id = UUID()
        controller.onClose = { [weak self] in cancel(); self?.comparisonWindows[id] = nil }
        comparisonWindows[id] = controller
        controller.window?.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30))
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private func pickComparisonBranch(selected: RevisionID, request: RevisionComparisonReadRequest, owner: NSWindow) async -> String? {
        guard let source = repositoryModule as? any RepositoryRevisionComparingDataSource else { return nil }
        let content = ComparisonBranchPicker(branches: request.branches, selected: selected, headID: request.context.headID, source: source)
        let window = NSWindow(contentViewController: content); window.title = "Compare to branch"
        window.styleMask = [.titled]; window.setContentSize(NSSize(width: 434, height: 140))
        return await withCheckedContinuation { continuation in
            content.completion = { value in content.cancel(); owner.endSheet(window); window.orderOut(nil); continuation.resume(returning: value); content.completion = nil }
            owner.beginSheet(window)
        }
    }

    private func pickComparisonCommit(preselect: RevisionID, owner: NSWindow) async -> Commit? {
        guard let source = repositoryModule as? any RepositoryRevisionComparingDataSource else { return nil }
        let content = RevisionComparisonGridController(source: source, choosing: true, preselect: preselect)
        content.grid.dataSource = repositoryModule as? any RepositoryRevisionGridDataSource
        let controller = RevisionComparisonWindowController(content: content, title: "Choose commit", size: NSSize(width: 900, height: 550), autosave: "GitExtensionsMac.ChooseCommit")
        configureComparisonGrid(content, controller: controller)
        guard let window = controller.window else { return nil }
        let subscription = repositoryChangedNotifier.subscribe { [weak content] _, _ in content?.reload() }
        return await withCheckedContinuation { continuation in
            var completed = false
            let finish: (Commit?) -> Void = { value in
                guard !completed else { return }; completed = true
                subscription.cancel(); content.cancel(); content.onChoose = nil; controller.onClose = nil
                owner.endSheet(window); window.orderOut(nil); continuation.resume(returning: value)
            }
            controller.onClose = { finish(nil) }
            content.onChoose = finish
            owner.beginSheet(window)

            content.onChoose = { [controller] value in finish(value); _ = controller }
        }
    }

    private func configureComparisonDiff(_ diff: RevisionDiffViewController, owner: NSWindow?) {
        diff.supportsContinuousFileNavigation = true
        diff.fileStatusSource = repositoryModule as? any RepositoryFileStatusDataSource
        diff.blameSource = repositoryModule as? any RepositoryBlameDataSource
        let manager = repositoryModule as? any RepositoryRemoteManagingDataSource
        diff.blameContext = .init(revisionInGrid: { _ in nil }, selectFileInRevision: { _, _ in false },
            hostedRemotes: { HostedRemote.gitHubRemotes((try? await manager?.loadRemoteConfigurations()) ?? []) })
        diff.blameController.onShowChanges = { [weak self, weak owner] in self?.startBlameCommitDiff($0, owner: owner) }
        diff.filesController.canShowInFileTree = false; diff.filesController.canFilterInGrid = false
        diff.onCommand = { [weak self, weak owner] in self?.performFileStatusCommand($0, owner: owner) }
        diff.onLinePatch = { [weak self, weak owner] kind, file, patch, ids in
            guard let owner else { return }
            self?.applyLinePatch(kind, file: file, diff: patch, lineIDs: ids, owner: owner)
        }
        diff.onFileCommand = { [weak self, weak owner] id, item in
            self?.performFileStatusCommand(.init(identifier: id, items: [item], folder: nil, tool: nil, focused: item, remembered: nil), owner: owner)
        }
        diff.onFileHistory = { [weak self, weak owner] path, revision in
            guard let self else { return }
            Task { @MainActor in
                let commit = try? await (self.repositoryModule as? any RepositoryRevisionComparingDataSource)?.comparisonRevision(revision ?? .workingDirectory, headID: self.browser?.repositoryIdentity?.headID)
                self.startFileHistory(file: path, revision: commit, owner: owner)
            }
        }
        Task { @MainActor [weak diff] in diff?.diffTools = (try? await (repositoryModule as? any RepositoryFileStatusDataSource)?.loadDiffTools()) ?? [] }
    }

    func startBlameCommitDiff(_ revision: ObjectID, comparedRevisions: [Commit]? = nil, owner: NSWindow? = nil) {
        guard let source = repositoryModule as? any RepositoryBlameDataSource,
              let files = repositoryModule as? any RepositoryFileStatusDataSource,
              let owner = owner ?? browser?.view.window else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let commit = try await source.loadBlameRevision(revision)
                let path = browser?.repositoryIdentity?.currentRepository.path
                let controller = CommitDiffWindowController(revision: commit, source: files,
                    infoSource: repositoryModule as? any RepositoryCommitInfoDataSource,
                    repositoryURL: path.map { URL(fileURLWithPath: $0) },
                    comparedRevisions: comparedRevisions,
                    command: { [weak self] in self?.performFileStatusCommand($0) })
                configureComparisonDiff(controller.diffController, owner: controller.window)
                controller.diffController.isBareRepository = browser?.repositoryIdentity?.currentRepository.isBare ?? false
                controller.infoController.onGoToRevision = { [weak self] id in
                    if let object = id.objectID { self?.browser?.selectScriptRevision(object) }
                }
                retainBlameWindow(controller, owner: owner)
            } catch { await MutationDialogs.showError(error, title: "Show changes", window: owner) }
        }
    }

    private func retainBlameWindow(_ controller: NSWindowController, owner: NSWindow) {
        let id = UUID()
        let closed: () -> Void = { [weak self] in self?.blameWindows[id] = nil }
        (controller as? BlameWindowController)?.onClose = closed
        (controller as? CommitDiffWindowController)?.onClose = closed
        blameWindows[id] = controller
        controller.window?.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30))
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func startFileHistory(file: String, revision: Commit? = nil, filterByRevision: Bool = false,
                          showBlame: Bool = false, owner: NSWindow? = nil) -> FileHistoryWindowController? {
        guard !file.isEmpty, let history = repositoryModule as? any RepositoryFileHistoryDataSource,
              let owner = owner ?? browser?.view.window else { return nil }
        if AppSettingsStore.shared.revisionGridPreferences.useBrowseForFileHistory,
           let repository = browser?.repositoryIdentity?.currentRepository {
            Self.launchBrowse(URL(fileURLWithPath: repository.path), selection: revision.map { [$0.id] } ?? [],
                fileHistory: FileHistoryBrowseRequest(path: file, filterRevision: filterByRevision ? revision?.objectID : nil)) { error in
                    Task { await MutationDialogs.showError(error, title: "File History", window: owner) }
                }
            return nil
        }
        weak var historyWindow: NSWindow?
        let controller = FileHistoryWindowController(source: repositoryModule, history: history,
            file: file, revision: revision, filterByRevision: filterByRevision, showBlame: showBlame) { [weak self] id, selected, item in
                guard let self else { return }
                switch id {
                case "revert", "cherryPick":
                    guard let source = repositoryModule as? any RepositoryBlameDataSource else { return }
                    Task { @MainActor [weak self, weak historyWindow] in
                        guard let self, let historyWindow else { return }
                        do {
                            var resolved: [Commit] = []
                            for commit in selected {
                                if let object = commit.objectID { resolved.append(try await source.loadBlameRevision(object)) }
                            }
                            guard historyWindow.isVisible else { return }
                            if id == "revert" { startRevert(resolved, owner: historyWindow) }
                            else { startCherryPick(resolved, owner: historyWindow) }
                        } catch { await MutationDialogs.showError(error, title: "File History", window: historyWindow) }
                    }
                case "commandLog": Self.startCommandLog()
                case "settings": startSettings()
                case "showChanges": if let id = selected.first?.objectID { startBlameCommitDiff(id, comparedRevisions: selected.count > 1 ? selected : nil, owner: historyWindow) }
                default:
                    if let item {
                        let local = id.hasPrefix("difftool.local.")
                        let prefix = local ? "difftool.local." : "difftool.named."
                        let tool = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
                        performFileStatusCommand(.init(identifier: tool == nil ? id : local ? "file.difftool.selectedToLocal" : "file.difftool", items: [item], folder: nil, tool: tool, focused: item, remembered: nil), owner: historyWindow)
                    }
                }
            }
        historyWindow = controller.window
        controller.controller.onShowChanges = { [weak self, weak controller] id in self?.startBlameCommitDiff(id, owner: controller?.window) }
        controller.controller.onFileStatusCommand = { [weak self, weak controller] command in self?.performFileStatusCommand(command, owner: controller?.window) }
        controller.controller.onLinePatch = { [weak self, weak controller] kind, file, diff, ids in
            guard let owner = controller?.window else { return }
            self?.applyLinePatch(kind, file: file, diff: diff, lineIDs: ids, owner: owner)
        }
        let id = UUID()
        let subscription = repositoryChangedNotifier.subscribe { [weak controller] _, _ in controller?.controller.reload() }
        controller.onClose = { [weak self] in subscription.cancel(); self?.fileHistoryWindows[id] = nil }
        fileHistoryWindows[id] = controller
        controller.window?.setFrameOrigin(NSPoint(x: owner.frame.minX + 30, y: owner.frame.minY + 30))
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    func applyLinePatch(_ kind: FileStatusLinePatchKind, file: ChangedFile, diff: FileDiff, lineIDs: Set<String>, owner: NSWindow) {
        guard let source = repositoryModule as? any RepositoryFileStatusDataSource else { return }
        Task { @MainActor [weak self] in
            do {
                let result = try await source.applyLinePatch(kind, file: file, diff: diff, lineIDs: lineIDs)
                self?.notifyRepositoryChanged()
                guard !result.succeeded else { return }
                if kind == .applyToWorkTree || kind == .revertToWorkTree {
                    let conflicts = (try? await (self?.repositoryModule as? any RepositoryConflictDataSource)?.loadConflicts()) ?? []
                    if !conflicts.isEmpty {
                        if await Self.confirm("There are unresolved merge conflicts, solve conflicts now?", title: "Merge conflicts", owner: owner) {
                            self?.startConflictResolution(offerCommit: false)
                        }
                        return
                    }
                }
                await Self.showMessage("\(result.output)\n\n\(result.patch)", title: "Error", owner: owner)
            } catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
        }
    }

    func performFileStatusCommand(_ command: FileStatusListCommand, owner: NSWindow? = nil) {
        guard let browser, let owner = owner ?? browser.view.window,
              let source = repositoryModule as? any RepositoryFileStatusDataSource,
              let repository = browser.repositoryIdentity?.currentRepository else { return }
        let root = URL(fileURLWithPath: repository.path, isDirectory: true)
        let items = command.items
        let externalCommand = AppSettingsStore.shared.preferences.externalDiffToolPath
        switch command.identifier {
        case "file.history":
            if let path = command.folder ?? items.first?.file.path {
                let id = items.first?.second
                if let object = id?.objectID, !browser.revisions.contains(where: { $0.id == id }),
                   let revisions = repositoryModule as? any RepositoryBlameDataSource {
                    Task { @MainActor [weak self] in
                        do { self?.startFileHistory(file: path, revision: try await revisions.loadBlameRevision(object), owner: owner) }
                        catch { await MutationDialogs.showError(error, title: "File History", window: owner) }
                    }
                } else { startFileHistory(file: path, revision: browser.revisions.first { $0.id == id }, owner: owner) }
            }
        case "file.reset", "file.reset.first": resetFileStatusItems(items, toFirst: true, source: source, owner: owner)
        case "file.reset.second": resetFileStatusItems(items, toFirst: false, source: source, owner: owner)
        case "file.resetChunk", "file.interactiveAdd":
            guard let item = items.first else { return }

            let gitCommand = FileStatusCommands.interactivePatch(path: item.file.path, stage: command.identifier == "file.interactiveAdd")
            startInteractiveGit(gitCommand, root: root, owner: owner)
        case "file.cherryPick":
            guard let item = items.first else { return }
            Task { @MainActor [weak self] in
                do {
                    let result = try await source.cherryPickChanges(group: item.group, file: item.file)
                    self?.notifyRepositoryChanged()
                    if !result.succeeded {
                        let conflicts = (try? await (self?.repositoryModule as? any RepositoryConflictDataSource)?.loadConflicts()) ?? []
                        if !conflicts.isEmpty, await Self.confirm("There are unresolved merge conflicts, solve conflicts now?", title: "Merge conflicts", owner: owner) {
                            self?.startConflictResolution(offerCommit: false)
                        } else if conflicts.isEmpty {
                            await Self.showMessage("\(result.output)\n\n\(result.patch)", title: "Error", owner: owner)
                        }
                    }
                } catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
            }
        case "file.difftool", "file.difftool.selectedToLocal", "file.difftool.firstToLocal":
            Task { @MainActor in
                for item in items where item.group.kind != .combined {
                    let (first, second): (RevisionID?, RevisionID?) = switch command.identifier {
                    case "file.difftool": (item.first, item.second)
                    case "file.difftool.selectedToLocal": (item.second, .workingDirectory)
                    default: (item.first, .workingDirectory)
                    }
                    do {
                        try await source.openDifftool(first: first, second: second, path: item.file.path, oldPath: item.file.oldPath,
                                                      isTracked: item.file.isTracked, customTool: command.tool,
                                                      externalCommand: externalCommand.isEmpty ? nil : externalCommand)
                    } catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner); return }
                }
            }
        case "file.difftool.twoSelected", "file.difftool.remembered":
            startBlobDifftool(command, source: source, externalCommand: externalCommand, owner: owner)
        case "file.open.local", "file.open.localWith":
            guard let item = items.first else { return }
            let url = root.appendingPathComponent(item.file.path)
            if command.identifier == "file.open.local" { NSWorkspace.shared.open(url) } else { Self.openWith(url, owner: owner) }
        case "file.open.revision", "file.open.revisionWith":
            guard let item = items.first else { return }
            Task { @MainActor in
                do {
                    let data = try await source.loadFileData(path: item.file.path, at: item.second)
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Revision-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent(URL(fileURLWithPath: item.file.path).lastPathComponent)
                    try data.write(to: file, options: .atomic)
                    if command.identifier == "file.open.revision" { NSWorkspace.shared.open(file) } else { Self.openWith(file, owner: owner) }
                } catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
            }
        case "file.save": saveFileStatusItems(items, root: root, source: source, owner: owner)
        case "file.move": moveFileStatusItem(command, source: source, owner: owner)
        case "file.delete": deleteFileStatusItems(items, source: source, owner: owner)
        case "file.showFinder":

            let urls = items.map { root.appendingPathComponent($0.file.path) }
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
            else if let parent = urls.map({ $0.deletingLastPathComponent() }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                NSWorkspace.shared.open(parent)
            }
        case "file.skipWorktree", "file.assumeUnchanged", "file.stopTracking":
            Task { @MainActor [weak self] in
                do {
                    switch command.identifier {
                    case "file.skipWorktree": try await source.setSkipWorktree(items.map(\.file.path), !items.contains(where: \.file.isSkipWorktree))
                    case "file.assumeUnchanged": try await source.setAssumeUnchanged(items.map(\.file.path), !items.contains(where: \.file.isAssumeUnchanged))
                    default:
                        guard let path = items.first?.file.path else { return }
                        do { try await source.stopTracking(path) } catch {
                            await Self.showMessage("Fail to stop tracking the file '\(path)'.", title: "Error", owner: owner)
                            return
                        }
                    }
                    self?.notifyRepositoryChanged()
                } catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
            }
        case "file.submodule.update", "file.submodule.reset", "file.submodule.stash", "file.submodule.commit":
            startFileStatusSubmoduleAction(command.identifier, paths: Array(NSOrderedSet(array: items.filter(\.file.isSubmodule).map(\.file.path))) as? [String] ?? [], owner: owner)
        case "file.openSubmodule":
            guard let item = items.first else { return }
            let url = root.appendingPathComponent(item.file.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Task { await Self.showMessage("The submodule directory \(url.path) does not exist for \(item.file.path).", title: "Error", owner: owner) }
                return
            }
            Task { @MainActor in
                let selected: RevisionID? = item.second == .workingDirectory ? .workingDirectory
                    : (try? await source.submoduleCommit(path: item.file.path, at: item.second)).flatMap { $0.map(RevisionID.object) }
                let first = (try? await source.submoduleCommit(path: item.file.path, at: item.first)).flatMap { $0.map(RevisionID.object) }
                Self.launchBrowse(url, selection: [selected, first].compactMap { $0 })
            }
        case "file.edit.local":

            guard let item = items.first else { return }
            startFileEditor(root.appendingPathComponent(item.file.path), lineNumber: command.lineNumber, owner: owner) { [weak self] in
                self?.notifyRepositoryChanged()
            }
        case "file.ignore.gitignore", "file.ignore.exclude":

            let folder = command.folder.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            let patterns = folder.map { $0.isEmpty ? [] : ["/\($0)/"] } ?? items.map { "/" + $0.file.path }
            guard !patterns.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard await self?.startAddToGitIgnore(localExclude: command.identifier == "file.ignore.exclude", patterns: patterns, owner: owner) == true else { return }
                self?.notifyRepositoryChanged()
            }
        case "file.editGitIgnore", "file.editLocallyIgnored":

            startEditGitIgnore(localExclude: command.identifier == "file.editLocallyIgnored", owner: owner) { [weak self] in
                self?.notifyRepositoryChanged()
            }
        default:
            break
        }
    }


    private func resetFileStatusItems(_ items: [FileStatusListItem], toFirst: Bool, source: any RepositoryFileStatusDataSource, owner: NSWindow, onFinished: ((Bool) -> Void)? = nil) {
        guard !items.isEmpty else { onFinished?(false); return }
        func isNew(_ file: ChangedFile) -> Bool { file.changeType == .added || file.changeType == .copied || !file.isTracked }
        let hasNewFiles = !items.allSatisfy { $0.file.changeType == .modified && $0.file.isTracked }
        let hasExistingFiles = items.contains { !((isNew($0.file) && $0.file.staged != .none) || ($0.file.changeType == .renamed && $0.file.staged == .index)) }
        func describeAll(_ revisions: [RevisionID?]) -> String {
            var seen: [RevisionID?] = []
            for revision in revisions where !seen.contains(revision) { seen.append(revision) }
            guard seen.count == 1 else { return seen.isEmpty ? "" : "<multiple>" }
            return browser?.describeRevision(seen[0]) ?? ""
        }
        let description = toFirst ? "First: A \(describeAll(items.map(\.first)))" : "Second: B \(describeAll(items.map { $0.second }))"
        Task { @MainActor [weak self] in
            var finished = false
            defer { onFinished?(finished) }
            guard let deleteNew = await ResetDialogs.confirmResetChanges(
                hasTrackedChanges: hasExistingFiles, hasUntrackedFiles: hasNewFiles,
                message: "Are you sure you want to reset all selected files to \(description)?", owner: owner) else { return }
            var output = ""
            let targets = toFirst ? items.map(\.first) : items.map { Optional($0.second) }
            var seen: [RevisionID] = []
            for case let target? in targets where !seen.contains(target) {
                seen.append(target)

                if toFirst {
                    guard target.objectID != nil || (target == .index && items.allSatisfy { $0.second == .workingDirectory }) else { continue }
                } else {
                    guard target.objectID != nil else { continue }
                }

                let resetItems = items.map { item -> ChangedFile in
                    guard !toFirst else { return item.file }
                    var file = item.file
                    if file.changeType == .added { file.changeType = .deleted } else if file.changeType == .deleted { file.changeType = .added }
                    return file
                }
                do { output += try await source.resetFiles(to: target, items: resetItems, resetAndDelete: deleteNew) }
                catch { output += error.localizedDescription }
            }
            self?.notifyRepositoryChanged()
            finished = true
            if !output.isEmpty { await Self.showMessage(output, title: "Reset changes", owner: owner) }
        }
    }


    private func startBlobDifftool(_ command: FileStatusListCommand, source: any RepositoryFileStatusDataSource, externalCommand: String, owner: NSWindow) {
        let items = command.items
        func specifier(_ side: (revision: RevisionID?, path: String)) async -> String? {
            guard let revision = side.revision else { return nil }
            return try? await source.blobSpecifier(path: side.path, at: revision)
        }
        Task { @MainActor in
            var pair: (String?, String?)
            if command.identifier == "file.difftool.twoSelected" {
                guard items.count == 2 else { return }

                let firstIndex = command.focused == items[0] ? 1 : 0
                let firstFile = RememberedDiffFile(item: items[firstIndex]), secondFile = RememberedDiffFile(item: items[1 - firstIndex])
                pair.0 = await specifier(firstFile.side(secondRevision: firstFile.canUseAsFirst(secondRevision: true)))
                pair.1 = await specifier(secondFile.side(secondRevision: secondFile.canUseAsSecond(secondRevision: true)))
            } else {
                guard let remembered = command.remembered, let item = items.first else { return }
                let selected = RememberedDiffFile(item: item)
                pair.0 = await specifier(remembered.side(secondRevision: true))
                pair.1 = await specifier(selected.side(secondRevision: selected.canUseAsSecond(secondRevision: true)))
            }
            guard let first = pair.0, !first.isEmpty, let second = pair.1, !second.isEmpty else { return }
            do { try await source.openDifftool(firstBlob: first, secondBlob: second, customTool: command.tool, externalCommand: externalCommand.isEmpty ? nil : externalCommand) }
            catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
        }
    }


    private func saveFileStatusItems(_ items: [FileStatusListItem], root: URL, source: any RepositoryFileStatusDataSource, owner: NSWindow) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            let item = items[0]
            let full = root.appendingPathComponent(item.file.path)
            let panel = NSSavePanel()
            panel.directoryURL = full.deletingLastPathComponent()
            panel.nameFieldStringValue = full.lastPathComponent
            panel.beginSheetModal(for: owner) { response in
                guard response == .OK, let destination = panel.url else { return }
                Task { @MainActor in
                    do { try await source.loadFileData(path: item.file.path, at: item.second).write(to: destination, options: .atomic) }
                    catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
                }
            }
            return
        }

        let directories = items.map { ($0.file.path as NSString).deletingLastPathComponent }
        var common = directories[0].split(separator: "/").map(String.init)
        for directory in directories.dropFirst() {
            let parts = directory.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        let base = common.joined(separator: "/")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = base.isEmpty ? root : root.appendingPathComponent(base, isDirectory: true)
        panel.prompt = "Save"
        panel.beginSheetModal(for: owner) { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    for item in items {
                        let relative = String((item.file.path as NSString).deletingLastPathComponent.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let directory = relative.isEmpty ? destination : destination.appendingPathComponent(relative, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let data = try await source.loadFileData(path: item.file.path, at: item.second)
                        try data.write(to: directory.appendingPathComponent((item.file.path as NSString).lastPathComponent), options: .atomic)
                    }
                } catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
            }
        }
    }


    private func moveFileStatusItem(_ command: FileStatusListCommand, source: any RepositoryFileStatusDataSource, owner: NSWindow) {
        let isFolder = command.items.count != 1 && command.folder != nil
        guard let oldName = isFolder ? command.folder : command.items.first?.file.path ?? command.folder else { return }
        Task { @MainActor [weak self] in
            var proposal = oldName
            while true {
                let alert = NSAlert()
                alert.messageText = "Rename / move"
                alert.informativeText = "New name"
                let field = NSTextField(string: proposal)
                field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
                alert.accessoryView = field
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                alert.window.initialFirstResponder = field
                guard await alert.beginSheetModal(for: owner) == .alertFirstButtonReturn else { return }
                proposal = field.stringValue
                guard FileStatusCommands.validateMove(oldName: oldName, newName: proposal) else { continue }
                do {
                    try await source.move(from: oldName, to: proposal, isFolder: isFolder)
                    self?.notifyRepositoryChanged()
                    return
                } catch {
                    self?.notifyRepositoryChanged()
                    await Self.showMessage(error.localizedDescription, title: "Rename / move", owner: owner)
                }
            }
        }
    }


    private func deleteFileStatusItems(_ items: [FileStatusListItem], source: any RepositoryFileStatusDataSource, owner: NSWindow) {
        guard let first = items.first, first.second.objectID == nil else { return }
        Task { @MainActor [weak self] in
            guard await Self.confirm("Are you sure you want to delete the selected file(s)?", title: "Delete", owner: owner) else { return }
            do {
                if try await source.deleteFiles(items.map(\.file)) { self?.notifyRepositoryChanged() }
            } catch {
                if error is FileStatusPartialMutationError { self?.notifyRepositoryChanged() }
                await Self.showMessage("Delete file failed\n" + error.localizedDescription, title: "Error", owner: owner)
            }
        }
    }


    private func startFileStatusSubmoduleAction(_ identifier: String, paths: [String], owner: NSWindow) {
        guard !paths.isEmpty, let parent = repositoryModule as? any RepositorySubmoduleManagingDataSource else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch identifier {
            case "file.submodule.update":
                let result = await SubmoduleDialogs.run(title: "Submodules", owner: owner) { output in
                    var combined: RepositorySubmoduleResult?
                    for path in paths {
                        let result = try await parent.performSubmoduleAction(.update(path: path), output: output)
                        combined = RepositorySubmoduleResult(succeeded: (combined?.succeeded ?? true) && result.succeeded,
                                                             changed: (combined?.changed ?? false) || result.changed,
                                                             output: [combined?.output, result.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                    return combined ?? RepositorySubmoduleResult(succeeded: true, changed: false, output: "")
                }
                completeSubmoduleOperation(result)
                pluginEvent("PostUpdateSubmodules", succeeded: result.succeeded)
            case "file.submodule.reset":
                guard let clean = await ResetDialogs.confirmResetChanges(hasTrackedChanges: true, hasUntrackedFiles: true, owner: owner) else { return }
                do {
                    for path in paths {
                        guard let reset = try await submoduleSource(path: path) as? any RepositoryResettingDataSource else { continue }
                        _ = try await reset.resetChanges(.init(scope: .all, deleteUntracked: clean))
                    }
                } catch { worktreeError(error.localizedDescription, owner: owner) }
                notifyRepositoryChanged()
            case "file.submodule.stash":
                do {
                    for path in paths {
                        guard let stash = try await submoduleSource(path: path) as? any RepositoryStashDataSource else { continue }
                        _ = try await stash.createStash(.init(message: "", includeUntracked: AppSettingsStore.shared.stashPreferences.includeUntracked, keepIndex: false, stagedOnly: false))
                    }
                } catch { worktreeError(error.localizedDescription, owner: owner) }
                notifyRepositoryChanged()
            default:
                for path in paths {
                    guard let child = try? await submoduleSource(path: path) else { continue }
                    pendingSubmoduleCommits.append(child)
                }
                presentNextSubmoduleCommit(owner: owner)
            }
        }
    }



    private func presentNextSubmoduleCommit(owner: NSWindow) {
        if let submoduleCommitWindowController { submoduleCommitWindowController.window?.makeKeyAndOrderFront(nil); return }
        guard !pendingSubmoduleCommits.isEmpty else { return }
        let child = pendingSubmoduleCommits.removeFirst()
        presentSubmoduleCommit(child, owner: owner)
    }


    private func presentSubmoduleCommit(_ child: any RepositoryBrowsingDataSource, owner: NSWindow) {
        if let submoduleCommitWindowController { submoduleCommitWindowController.window?.makeKeyAndOrderFront(nil); return }
        guard let commitSource = child as? any RepositoryCommitWorkflowDataSource else { return }
        submoduleCommitWindowController = CommitWorkflowDialog.present(source: commitSource,
            pushSource: child as? any RepositoryPushingDataSource, initialMode: .normal, head: nil, draft: nil, owner: owner,
            onManageRemotes: { [weak self] remote, branch in
                guard let self, let remotes = child as? any RepositoryRemoteManagingDataSource else { return }
                self.submoduleRemoteWindowController = RemoteManagementDialog.present(source: remotes, selectedRemote: remote, selectedLocalBranch: branch,
                    onFetchRemote: { name, window in
                        if let pull = child as? any RepositoryPullingDataSource { _ = await PullProcessDialog.run(request: .init(source: .remote(name), mode: .fetch), source: pull, parent: window, scriptHooks: self.scriptHooks(for: child)) }
                    }, onRepositoryChanged: { [weak self] in self?.notifyRepositoryChanged() }, onClose: { [weak self] in self?.submoduleRemoteWindowController = nil })
            }, scriptHooks: scriptHooks(for: child), onRepositoryChanged: { [weak self] _ in self?.notifyRepositoryChanged() },
            onClose: { [weak self, weak owner] in
                self?.submoduleCommitWindowController = nil
                if let owner { self?.presentNextSubmoduleCommit(owner: owner) }
            })
    }


    private func startInteractiveGit(_ command: GitCommand, root: URL, owner: NSWindow) {
        do {
            let invocation = try ScriptExecution.terminalInvocation(
                executable: URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath), arguments: command.arguments, directory: root)
            Task { @MainActor [weak self] in
                do { _ = try await ScriptExecution.run(invocation) { _ in } }
                catch { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner); return }
                self?.refreshOnNextActivation()
            }
        } catch {
            Task { await Self.showMessage(error.localizedDescription, title: "Error", owner: owner) }
        }
    }

    private var activationRefreshObserver: NSObjectProtocol?
    private func refreshOnNextActivation() {
        if let activationRefreshObserver { NotificationCenter.default.removeObserver(activationRefreshObserver) }
        activationRefreshObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let observer = self.activationRefreshObserver { NotificationCenter.default.removeObserver(observer) }
                self.activationRefreshObserver = nil
                self.notifyRepositoryChanged()
            }
        }
    }


    private static func openWith(_ url: URL, owner: NSWindow) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(url.lastPathComponent)"
        panel.beginSheetModal(for: owner) { response in
            guard response == .OK, let application = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func showMessage(_ message: String, title: String, owner: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        _ = await alert.beginSheetModal(for: owner)
    }

    private static func confirm(_ message: String, title: String, owner: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return await alert.beginSheetModal(for: owner) == .alertFirstButtonReturn
    }

    func startCommit(
        initialMode: RepositoryCommitMode = .normal,
        specialKind: CommitWorkflowSpecialKind? = nil,
        initialMessage: String? = nil
    ) {
        guard let browser,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCommitWorkflowDataSource else {
            browser?.showPlaceholderStatus("Commit is unavailable for mock data")
            return
        }

        if let existing = browser.commitWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let head = browser.revisions.first(where: \.isHEAD)
            ?? browser.revisions.first(where: { !$0.isArtificial })
        guard pluginEvent("PreCommit") else { return }
        browser.commitWindowController = browser.presentCommitDialog(
            source: source,
            pushSource: repositoryModule as? any RepositoryPushingDataSource,
            initialMode: initialMode,
            specialKind: specialKind,
            head: head,
            draft: browser.commitDraft,
            owner: window,
            initialMessage: initialMessage,
            previousSelection: browser.selectedCommitID
        )
    }

    func startPull(action: PullActionPreference, immediately: Bool, initialRemoteBranch: String? = nil, onCompletion: ((Bool) -> Void)? = nil) {
        guard let browser, let context = browser.networkContext else { return }
        let effectiveAction = action == .openDialog ? AppSettingsStore.shared.pullPreferences.formAction : action
        let initialAction: NetworkDialogInitialAction = switch effectiveAction {
        case .rebase: .rebase
        case .fetch: .fetch
        case .fetchAll: .fetchAll
        case .fetchPruneAll: .fetchPruneAll
        case .merge, .openDialog: .merge
        }
        let isFetch = initialAction == .fetch || initialAction == .fetchAll || initialAction == .fetchPruneAll
        if let existing = browser.pullWindowController ?? browser.fetchWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard browser.view.window != nil,
              let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        let controller = ApplicationShellDialogs.presentPullWindow(
            initialAction: initialAction,
            executeImmediately: immediately,
            initialRemoteBranch: initialRemoteBranch,
            context: context,
            source: source,
            onManageRemotes: { [weak self] remote, localBranch in
                self?.startRemoteManagement(selectedRemote: remote, selectedLocalBranch: localBranch)
            },
            scriptHooks: scriptHooks,
            onRepositoryChanged: { [weak self, weak browser] selected in
                self?.notifyRepositoryChanged(preferredCommitID: selected ?? browser?.selectedCommitID)
            },
            onClose: { [weak browser] in
                browser?.pullWindowController = nil
                browser?.fetchWindowController = nil
            }, onCompletion: onCompletion
        )
        if isFetch {
            browser.fetchWindowController = controller
        } else {
            browser.pullWindowController = controller
        }
    }

    func startFetchAll(prune: Bool) {
        startPull(action: prune ? .fetchPruneAll : .fetchAll, immediately: true)
    }

    func fetchRemote(named remote: String, prune: Bool) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            scriptHooks.begin()
            defer { scriptHooks.end() }
            let processResult = await PullProcessDialog.run(
                request: RepositoryPullRequest(source: .remote(remote), mode: .fetch, prune: prune),
                source: source,
                parent: window,
                scriptHooks: scriptHooks
            )
            switch processResult {
            case .success(let result):
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            case .failure(let error):
                browser.statusLabel.stringValue = error.localizedDescription
            case nil:
                break
            }
        }
    }

    func setRemote(named remote: String, disabled: Bool, fetchAfterEnabling: Bool) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryRemoteManagingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            scriptHooks.begin()
            defer { scriptHooks.end() }
            do {
                try await source.setRemote(named: remote, disabled: disabled)
                if fetchAfterEnabling,
                   let pullSource = repositoryModule as? any RepositoryPullingDataSource {
                    let result = await PullProcessDialog.run(
                        request: RepositoryPullRequest(source: .remote(remote), mode: .fetch),
                        source: pullSource,
                        parent: window,
                        scriptHooks: scriptHooks
                    )
                    if case .success(let fetched) = result {
                        browser.statusLabel.stringValue = fetched.message
                    } else if case .failure(let error) = result {
                        browser.statusLabel.stringValue = error.localizedDescription
                    }
                }
                notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
            } catch {
                browser.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    func startRemoteManagement(selectedRemote: String? = nil, selectedLocalBranch: String? = nil) {
        if let remoteWindowController {
            RemoteManagementDialog.focus(
                remoteWindowController,
                selectedRemote: selectedRemote,
                selectedLocalBranch: selectedLocalBranch
            )
            return
        }
        guard let browser,
              let source = repositoryModule as? any RepositoryRemoteManagingDataSource else {
            browser?.showPlaceholderStatus("Remote management is unavailable for this data source.")
            return
        }

        remoteWindowController = RemoteManagementDialog.present(
            source: source,
            selectedRemote: selectedRemote,
            selectedLocalBranch: selectedLocalBranch,
            onFetchRemote: { [weak self] remote, window in
                await self?.fetchAfterSavingRemote(named: remote, parent: window)
            },
            onRepositoryChanged: { [weak self, weak browser] in
                self?.notifyRepositoryChanged(preferredCommitID: browser?.selectedCommitID)
            },
            onClose: { [weak self] in
                self?.remoteWindowController = nil
            }
        )
    }

    private func fetchAfterSavingRemote(named remote: String, parent: NSWindow) async {
        guard let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        scriptHooks.begin()
        defer { scriptHooks.end() }
        let request = RepositoryPullRequest(source: .remote(remote), mode: .fetch)
        guard let processResult = await PullProcessDialog.run(
            request: request,
            source: source,
            parent: parent,
            scriptHooks: scriptHooks
        ) else { return }
        switch processResult {
        case .success(let result):
            browser?.statusLabel.stringValue = result.message
        case .failure(let error):
            browser?.statusLabel.stringValue = error.localizedDescription
        }
    }

    func startPush(
        immediately: Bool = false,
        initialBranch: String? = nil,
        forceWithLease: Bool = false,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        guard let browser,
              let context = browser.networkContext,
              browser.view.window != nil,
              let source = repositoryModule as? any RepositoryPushingDataSource else { return }

        if let existing = browser.pushWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        browser.pushWindowController = PushDialog.present(
            source: source,
            context: context,
            initialBranch: initialBranch,
            executeImmediately: immediately,
            initialForceWithLease: forceWithLease,
            onManageRemotes: { [weak self] remote, localBranch in
                self?.startRemoteManagement(selectedRemote: remote, selectedLocalBranch: localBranch)
            },
            scriptHooks: scriptHooks,
            onRepositoryChanged: { [weak self, weak browser] preferredCommitID in
                self?.notifyRepositoryChanged(preferredCommitID: preferredCommitID ?? browser?.selectedCommitID)
            },
            onCompletion: onCompletion,
            onCreatePullRequest: { [weak self] in self?.startCreatePullRequest(fromPush: true) },
            onClose: { [weak browser] in
                browser?.pushWindowController = nil
            }
        )
    }

    func startMergeBranches(initialTarget: String?) {
        guard let browser,
              let context = browser.mergeContext,
              !context.repository.isBare else {
            browser?.showPlaceholderStatus("Merge is unavailable for this repository")
            return
        }
        if let existing = browser.mergeWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = browser.view.window,
              let source = repositoryModule as? any RepositoryMergingDataSource else { return }
        Task { @MainActor [weak browser] in
            guard let browser else { return }
            do {
                var distributed: DistributedSettings?
                if let settingsSource = source as? any RepositorySettingsDataSource {
                    distributed = try await DistributedSettings.loadLocations(from: settingsSource)
                    _ = try distributed?.mergePreferences(AppSettingsStore.shared)
                }
                if let existing = browser.mergeWindowController {
                    existing.window?.makeKeyAndOrderFront(nil)
                    return
                }
                browser.mergeWindowController = browser.presentMergeDialog(
                    source: source, context: context, initialTarget: initialTarget,
                    distributedSettings: distributed,
                    previousSelection: browser.selectedCommitID, owner: window
                )
            } catch { await MutationDialogs.showError(error, title: "Merge settings", window: window) }
        }
    }

    func startCherryPick(_ selectedCommits: [Commit], owner: NSWindow? = nil, onFinished: ((Bool) -> Void)? = nil) {
        guard let browser,
              browser.repositoryIdentity != nil,
              let window = owner ?? browser.view.window,
              let source = repositoryModule as? any RepositoryCherryPickDataSource else {
            browser?.showPlaceholderStatus("Cherry-pick is unavailable for mock data")
            return
        }

        let historyIndex = Dictionary(uniqueKeysWithValues: browser.revisions.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = selectedCommits
            .filter { !$0.isArtificial }
            .sorted { (historyIndex[$0.id] ?? 0) > (historyIndex[$1.id] ?? 0) }
        guard !ordered.isEmpty else { return }

        browser.startCherryPickWorkflow(
            orderedRevisions: ordered,
            history: browser.revisions,
            mutationSource: source,
            window: window,
            previousSelection: browser.selectedCommitID,
            onFinished: onFinished
        )
    }

    func startRevert(_ selectedCommits: [Commit], owner: NSWindow? = nil) {
        guard let browser,
              browser.repositoryIdentity?.currentRepository.isBare == false,
              let window = owner ?? browser.view.window,
              let source = repositoryModule as? any RepositoryRevertingDataSource else {
            browser?.showPlaceholderStatus("Revert is unavailable for this repository")
            return
        }

        let history = browser.revisions
        let ordered = RevertWorkflowOrdering.ordered(selectedCommits, in: history)
        guard !ordered.isEmpty else { return }
        let previousSelection = browser.selectedCommitID

        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            var completedCount = 0
            var preferredCommitID = previousSelection

            for commit in ordered {
                guard let commitID = commit.objectID else { continue }
                guard let selection = await RevertDialog.present(
                    commit: commit,
                    history: history,
                    owner: window
                ) else {
                    browser.statusLabel.stringValue = completedCount == 0
                        ? "Revert cancelled."
                        : "Reverted \(completedCount) commit(s); remaining revisions were cancelled."
                    return
                }

                do {
                    browser.statusLabel.stringValue = "Reverting \(commit.shortID)…"
                    let result = try await source.revert(RepositoryRevertRequest(
                        commitID: commitID,
                        automaticallyCommit: selection.automaticallyCommit,
                        mainlineParent: selection.mainlineParent
                    ))
                    preferredCommitID = result.selectedCommitID ?? preferredCommitID
                    notifyRepositoryChanged(preferredCommitID: preferredCommitID)

                    switch result.outcome {
                    case .completed:
                        completedCount += 1
                        browser.statusLabel.stringValue = result.message
                    case .conflicts(let paths):
                        browser.statusLabel.stringValue = result.message
                        guard await MutationDialogs.confirmResolveRevertConflicts(paths: paths, window: window) else {
                            return
                        }
                        let resolution = await WorkflowManagementDialogs.resolveRevertConflicts(
                            source: source,
                            window: window, scriptHooks: scriptHooks
                        )
                        if resolution.repositoryChanged {
                            notifyRepositoryChanged(preferredCommitID: preferredCommitID)
                        }
                        switch resolution.sequencerAction {
                        case .continued:
                            completedCount += 1
                            browser.statusLabel.stringValue = "Revert continued."
                        case .aborted:
                            browser.statusLabel.stringValue = completedCount == 0
                                ? "Revert aborted."
                                : "Revert aborted after \(completedCount) completed commit(s)."
                            return
                        case .none:
                            browser.statusLabel.stringValue = "Revert remains paused. Resolve all conflicts, then Continue or Abort."
                            return
                        }
                    case .paused(let reason):
                        browser.statusLabel.stringValue = reason
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    browser.statusLabel.stringValue = error.localizedDescription
                    await MutationDialogs.showError(error, title: "Revert failed", window: window)
                    return
                }
            }
        }
    }

    func startBisect(_ selectedCommits: [Commit]) {
        guard let browser,
              browser.repositoryIdentity?.currentRepository.isBare == false,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryBisectingDataSource else {
            browser?.showPlaceholderStatus("Bisect is unavailable for this repository")
            return
        }
        let revisions = selectedCommits.filter { !$0.isArtificial && $0.objectID != nil }
        guard !revisions.isEmpty else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            let result = await BisectDialog.present(
                source: source,
                selectedRevisions: revisions,
                owner: window,
                statusChanged: { [weak browser] in browser?.statusLabel.stringValue = $0 }
            )
            if result.repositoryChanged {
                notifyRepositoryChanged(
                    preferredCommitID: result.preferredCommitID ?? browser.selectedCommitID
                )
            }
        }
    }

    func markBisect(_ mark: RepositoryBisectMark, revision: Commit) {
        guard let browser,
              let window = browser.view.window,
              let objectID = revision.objectID,
              let source = repositoryModule as? any RepositoryBisectingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            do {
                let result = try await source.markBisect(mark, revisions: [objectID])
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                browser.statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Bisect failed", window: window)
            }
        }
    }

    func stopBisect() {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryBisectingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            do {
                let result = try await source.resetBisect()
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                browser.statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Stop bisect failed", window: window)
            }
        }
    }

    func startRebase(on target: Commit, interactive: Bool, showAdvancedOptions: Bool) {
        startRebase(
            on: target,
            interactive: interactive,
            initialActions: [:],
            advancedFrom: nil,
            showAdvancedOptions: showAdvancedOptions
        )
    }

    func startRebase(
        on target: Commit,
        interactive: Bool,
        initialActions: [ObjectID: RepositoryRebaseTodoAction] = [:],
        advancedFrom: String? = nil,
        showAdvancedOptions: Bool = false
    ) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryRebaseDataSource else {
            browser?.showPlaceholderStatus("Rebase is unavailable for mock data")
            return
        }
        browser.startRebaseWorkflow(
            on: target,
            interactive: interactive,
            initialActions: initialActions,
            advancedFrom: advancedFrom,
            showAdvancedOptions: showAdvancedOptions,
            mutationSource: source,
            window: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startCheckoutBranch(initialTarget: CheckoutDialogTarget?, confirmDirectCheckout: Bool = false) {
        makeCheckoutWorkflowCoordinator()?.checkoutBranch(
            initialTarget: initialTarget,
            confirmDirectCheckout: confirmDirectCheckout
        )
    }

    func startCheckoutRevision(_ commit: Commit) {
        makeCheckoutWorkflowCoordinator()?.checkoutRevision(commit)
    }

    func startResetCurrentBranch(
        to target: Commit,
        owner overrideOwner: NSWindow? = nil,
        initialMode: RepositoryResetMode = .soft,
        confirmDirtyWorkingTree: Bool = false
    ) {
        let owner = overrideOwner ?? browser?.view.window
        guard let browser,
              let owner,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let targetID = target.objectID,
              let source = repositoryModule as? any RepositoryResettingDataSource else {
            browser?.showPlaceholderStatus("Reset is unavailable for this repository")
            return
        }
        let currentBranch = browser.repositoryReferences?.branches.first(where: \.isCurrent)?.name
        Task { @MainActor [weak self, weak browser, weak owner] in
            guard let self, let browser, let owner else { return }
            if confirmDirtyWorkingTree {
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = "Changes not committed…"
                warning.informativeText = "You have changes in your working directory that could be lost.\n\nDo you want to continue?"
                warning.addButton(withTitle: "Continue")
                warning.addButton(withTitle: "Cancel")
                warning.buttons[1].keyEquivalent = "\r"
                warning.buttons[0].keyEquivalent = ""
                guard await warning.beginSheetModal(for: owner) == .alertFirstButtonReturn else {
                    browser.statusLabel.stringValue = "Reset cancelled"
                    return
                }
            }
            guard let mode = await ResetDialogs.resetCurrentBranch(
                branchName: currentBranch,
                target: target,
                initialMode: initialMode,
                owner: owner
            ) else {
                browser.statusLabel.stringValue = "Reset cancelled"
                return
            }
            await Task.yield()
            if mode == .hard, !(await ResetDialogs.confirmHardReset(owner: owner)) {
                browser.statusLabel.stringValue = "Reset cancelled"
                return
            }
            do {
                let hasChangedTarget = identity.headID != targetID
                let hasSubmodules = !(browser.repositoryNavigation?.submodules.isEmpty ?? true)
                let updateSubmodules: Bool
                if hasChangedTarget, hasSubmodules {
                    if let preference = AppSettingsStore.shared.checkoutBranchPreferences.updateSubmodulesOnCheckout {
                        updateSubmodules = preference
                    } else if mode == .hard {
                        updateSubmodules = await ResetDialogs.confirmUpdateSubmodules(owner: owner)
                    } else {
                        updateSubmodules = false
                    }
                } else {
                    updateSubmodules = false
                }
                let result = try await source.resetCurrentBranch(RepositoryResetCurrentBranchRequest(
                    target: targetID,
                    mode: mode,
                    updateSubmodules: updateSubmodules
                ))
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                browser.statusLabel.stringValue = result.message
                if case .completedWithSubmoduleUpdateFailure(let detail) = result.outcome {
                    await ResetDialogs.showError(
                        RepositoryResetFollowUpError(detail: detail),
                        title: "Reset completed; submodule update failed",
                        owner: owner
                    )
                }
            } catch {
                await ResetDialogs.showError(error, title: "Reset failed", owner: owner)
            }
        }
    }

    func startResetCurrentBranch(to targetID: ObjectID, label: String) {
        guard let browser else { return }
        let target = browser.revisions.first(where: { $0.objectID == targetID })
            ?? RevisionCommitBuilder.placeholderRevision(id: targetID, subject: label)
        startResetCurrentBranch(to: target)
    }

    func startReflog() {
        if let reflogWindowController {
            ReflogDialog.focus(reflogWindowController)
            return
        }
        guard let browser,
              let owner = browser.view.window,
              browser.repositoryIdentity?.currentRepository.isBare == false,
              let source = repositoryModule as? any RepositoryReflogDataSource else {
            browser?.showPlaceholderStatus("Reflog is unavailable for this repository")
            return
        }
        reflogWindowController = ReflogDialog.present(
            source: source,
            owner: owner,
            createBranch: { [weak self] objectID, selector, actionOwner in
                Task { @MainActor [weak self] in
                    guard let self, let browser = self.browser else { return }
                    let revision: Commit
                    if let existing = browser.revisions.first(where: { $0.objectID == objectID }) {
                        revision = existing
                    } else if let loaded = try? await source.loadReflogRevision(objectID) {
                        revision = loaded
                    } else {
                        revision = RevisionCommitBuilder.placeholderRevision(id: objectID, subject: selector)
                    }
                    self.reflogBranchWorkflowCoordinator = self.makeCheckoutWorkflowCoordinator(
                        owner: actionOwner,
                        retainOnBrowser: false
                    )
                    self.reflogBranchWorkflowCoordinator?.createBranch(
                        sourceRevision: revision,
                        checkoutAfterCreation: false,
                        userCanChangeRevision: false,
                        couldBeOrphan: false
                    )
                }
            },
            resetCurrentBranch: { [weak self] objectID, selector, isDirty, actionOwner in
                Task { @MainActor [weak self] in
                    guard let self, let browser = self.browser else { return }
                    let revision: Commit
                    if let existing = browser.revisions.first(where: { $0.objectID == objectID }) {
                        revision = existing
                    } else if let loaded = try? await source.loadReflogRevision(objectID) {
                        revision = loaded
                    } else {
                        revision = RevisionCommitBuilder.placeholderRevision(id: objectID, subject: selector)
                    }
                    self.startResetCurrentBranch(
                        to: revision,
                        owner: actionOwner,
                        initialMode: isDirty ? .soft : .hard,
                        confirmDirtyWorkingTree: isDirty
                    )
                }
            },
            onClose: { [weak self] in
                self?.reflogWindowController = nil
                self?.reflogBranchWorkflowCoordinator = nil
            }
        )
    }

    func startResetAnotherBranch(to target: Commit) {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let targetID = target.objectID,
              let references = browser.repositoryReferences,
              let source = repositoryModule as? any RepositoryResettingDataSource else {
            browser?.showPlaceholderStatus("Reset is unavailable for this repository")
            return
        }
        let currentBranch = references.branches.first(where: \.isCurrent)?.name
        Task { @MainActor [weak self, weak browser, weak owner] in
            guard let self, let browser, let owner else { return }
            guard let value = await ResetDialogs.resetAnotherBranch(
                source: source,
                branches: references.branches,
                localReferences: references.references,
                currentBranchName: currentBranch,
                target: target,
                owner: owner
            ) else {
                browser.statusLabel.stringValue = "Reset cancelled"
                return
            }
            do {
                let result = try await source.resetAnotherBranch(RepositoryResetAnotherBranchRequest(
                    branch: value.branch.name,
                    target: targetID,
                    force: value.force
                ))
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                browser.statusLabel.stringValue = result.message
                if value.checkoutAfterReset {
                    startCheckoutBranch(initialTarget: .local(value.branch))
                }
            } catch {
                await ResetDialogs.showError(error, title: "Reset branch failed", owner: owner)
            }
        }
    }


    func startResetChanges(onlyWorkTree: Bool = false, onFinished: ((Bool) -> Void)? = nil) {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let source = repositoryModule as? any RepositoryResettingDataSource else {
            browser?.showPlaceholderStatus("Reset changes is unavailable for this repository")
            return
        }
        Task { @MainActor [weak self, weak browser, weak owner] in
            var finished = false
            defer { onFinished?(finished) }
            guard let self, let browser, let owner else { return }
            do {
                let state = try await source.loadMutationState()
                let hasTracked = state.hasStagedChanges || state.hasUnstagedChanges || !state.conflictedPaths.isEmpty
                guard hasTracked || state.hasUntrackedFiles else {
                    browser.statusLabel.stringValue = "There are no changes to reset."
                    return
                }
                guard let deleteUntracked = await ResetDialogs.confirmResetChanges(
                    hasTrackedChanges: hasTracked,
                    hasUntrackedFiles: state.hasUntrackedFiles,
                    owner: owner
                ) else {
                    browser.statusLabel.stringValue = "Reset cancelled"
                    return
                }
                let result = try await source.resetChanges(RepositoryResetChangesRequest(
                    scope: onlyWorkTree ? .worktree : .all,
                    deleteUntracked: deleteUntracked
                ))
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                browser.statusLabel.stringValue = result.message
                finished = true
            } catch {
                await ResetDialogs.showError(error, title: "Reset changes failed", owner: owner)
            }
        }
    }

    func startCleanRepository(initialPath: String? = nil) {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let source = repositoryModule as? any RepositoryCleaningDataSource else {
            browser?.showPlaceholderStatus("Clean is unavailable for this repository")
            return
        }
        CleanDialog.present(
            source: source,
            repositoryURL: URL(fileURLWithPath: identity.currentRepository.path, isDirectory: true),
            initialPath: initialPath,
            owner: owner,
            repositoryChanged: { [weak self] in
                self?.notifyRepositoryChanged(preferredCommitID: .workingDirectory)
            },
            statusChanged: { [weak browser] status in
                browser?.statusLabel.stringValue = status
            }
        )
    }

    func checkout(_ target: CheckoutDialogTarget, confirmDirectCheckout: Bool = false) {
        makeCheckoutWorkflowCoordinator()?.checkout(
            target,
            confirmDirectCheckout: confirmDirectCheckout
        )
    }

    func fetchRemoteBranch(
        _ branch: Branch,
        then followUp: CheckoutBranchFetchFollowUp
    ) {
        makeCheckoutWorkflowCoordinator()?.fetchRemoteBranch(branch, then: followUp)
    }

    func createBranch(sourceRevision: Commit?, suggestedPrefix: String? = nil) {
        makeCheckoutWorkflowCoordinator()?.createBranch(
            sourceRevision: sourceRevision,
            suggestedPrefix: suggestedPrefix
        )
    }

    func deleteBranches(initiallySelected: [String]) {
        makeCheckoutWorkflowCoordinator()?.deleteBranches(initiallySelected: initiallySelected)
    }

    func renameBranch(_ name: String) {
        makeCheckoutWorkflowCoordinator()?.renameBranch(name)
    }


    func startCreateTag(initialTarget: ObjectID? = nil, owner: NSWindow? = nil, onFinished: ((Bool) -> Void)? = nil) {
        guard let browser,
              let window = owner ?? browser.view.window,
              let identity = browser.repositoryIdentity,
              let source = repositoryModule as? any RepositoryTagManagingDataSource else {
            browser?.showPlaceholderStatus("Tag creation is unavailable for this data source")
            return
        }
        let remote = preferredTagRemote(browser: browser)
        let defaultTarget = initialTarget ?? identity.headID
        var initial = CreateTagDialogValue(target: defaultTarget?.string ?? "")
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            while let value = await TagDialogs.createTag(
                initial: initial,
                revisions: browser.revisions,
                remote: remote,
                window: window
            ) {
                initial = value
                do {
                    let target = try await source.resolveTagTarget(value.target)
                    scriptHooks.begin()
                    defer { scriptHooks.end() }
                    let result = try await source.createTag(RepositoryCreateTagRequest(
                        name: value.name,
                        target: target,
                        operation: value.operation,
                        message: value.message,
                        signingKey: value.signingKey,
                        force: value.force
                    ))
                    if value.pushToRemote, let remote,
                       let pushSource = repositoryModule as? any RepositoryPushingDataSource {
                        let processResult = await PushProcessDialog.run(
                            request: RepositoryPushRequest(destination: .remote(remote), operation: .tag(value.name)),
                            source: pushSource,
                            parent: window,
                            scriptHooks: scriptHooks
                        )
                        self.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                        if case .success(let pushed)? = processResult {
                            browser.statusLabel.stringValue = pushed.message
                        } else if case .failure(let error)? = processResult {
                            await TagDialogs.showError(
                                error,
                                title: "Push tag failed",
                                window: window
                            )
                        }
                    } else {
                        self.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                        browser.statusLabel.stringValue = result.message
                    }
                    onFinished?(true)
                    return
                } catch {
                    await TagDialogs.showError(error, title: "Create tag failed", window: window)
                }
            }
            onFinished?(false)
        }
    }

    func startDeleteTag(initialName: String? = nil) {
        guard let browser,
              let window = browser.view.window,
              let references = browser.repositoryReferences,
              let navigation = browser.repositoryNavigation,
              let source = repositoryModule as? any RepositoryTagManagingDataSource else {
            browser?.showPlaceholderStatus("Tag deletion is unavailable for this data source")
            return
        }
        guard !references.tags.isEmpty else {
            browser.showPlaceholderStatus("There are no tags to delete")
            return
        }
        let activeRemotes = navigation.remotes.filter { !$0.isDisabled }
        let preferredRemote = preferredTagRemote(browser: browser) ?? activeRemotes.first?.name ?? ""
        var initial = DeleteTagDialogValue(
            name: initialName ?? references.tags.first?.name ?? "",
            remote: preferredRemote
        )
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            while let value = await TagDialogs.deleteTag(
                initial: initial,
                tags: references.tags,
                remotes: activeRemotes,
                window: window
            ) {
                initial = value
                do {
                    scriptHooks.begin()
                    defer { scriptHooks.end() }
                    let result = try await source.deleteTag(named: value.name)
                    if value.deleteFromRemote,
                       !value.remote.isEmpty,
                       let pushSource = repositoryModule as? any RepositoryPushingDataSource {
                        let processResult = await PushProcessDialog.run(
                            request: RepositoryPushRequest(
                                destination: .remote(value.remote),
                                operation: .deleteTag(value.name)
                            ),
                            source: pushSource,
                            parent: window,
                            scriptHooks: scriptHooks
                        )
                        self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
                        if case .success(let pushed)? = processResult {
                            browser.statusLabel.stringValue = pushed.message
                        } else if case .failure(let error)? = processResult {
                            await TagDialogs.showError(
                                error,
                                title: "Delete remote tag failed",
                                window: window
                            )
                        }
                    } else {
                        self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
                        browser.statusLabel.stringValue = result.message
                    }
                    return
                } catch {
                    await TagDialogs.showError(error, title: "Delete tag failed", window: window)
                }
            }
        }
    }

    private func preferredTagRemote(browser: RepositoryBrowserViewController) -> String? {
        guard let references = browser.repositoryReferences,
              let navigation = browser.repositoryNavigation else { return nil }
        let activeRemotes = navigation.remotes.filter { !$0.isDisabled }
        if let current = references.branches.first(where: \.isCurrent),
           let remote = current.remoteName,
           activeRemotes.contains(where: { $0.name == remote }) {
            return remote
        }
        if activeRemotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return activeRemotes.first?.name
    }

    private func makeCheckoutWorkflowCoordinator(
        owner overrideOwner: NSWindow? = nil,
        retainOnBrowser: Bool = true
    ) -> CheckoutBranchWorkflowCoordinator? {
        let owner = overrideOwner ?? browser?.view.window
        guard let browser,
              let context = browser.branchContext,
              let owner,
              let source = repositoryModule as? any RepositoryCheckoutBranchDataSource else {
            return nil
        }
        let coordinator = CheckoutBranchWorkflowCoordinator(
            source: source,
            stashSource: repositoryModule as? any RepositoryStashDataSource,
            pullSource: repositoryModule as? any RepositoryPullingDataSource,
            context: context,
            revisions: browser.revisions,
            owner: owner,
            onRepositoryChanged: { [weak self, weak browser] selectedCommitID in
                self?.notifyRepositoryChanged(preferredCommitID: selectedCommitID ?? browser?.selectedCommitID)
            },
            onStatus: { [weak browser] message in
                browser?.statusLabel.stringValue = message
            },
            onConflicts: { [weak self] in
                self?.startConflictResolution()
            },
            onMerge: { [weak self] target in
                self?.startMergeBranches(initialTarget: target)
            },
            onRebase: { [weak self] commit in
                self?.startRebase(on: commit, interactive: false)
            }
        )
        coordinator.scriptHooks = scriptHooks
        coordinator.pluginEvent = { [weak self] event, succeeded in self?.pluginEvent(event, succeeded: succeeded) ?? true }
        if retainOnBrowser { browser.checkoutBranchWorkflowCoordinator = coordinator }
        return coordinator
    }

    func startConflictResolution(offerCommit: Bool = true) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryConflictResolutionDataSource else {
            browser?.showPlaceholderStatus("Conflict resolver is unavailable for mock data")
            return
        }

        Task { @MainActor [weak browser] in
            guard let browser else { return }
            let refreshed = await WorkflowManagementDialogs.resolveConflicts(
                source: source,
                window: window,
                offerCommit: offerCommit, scriptHooks: scriptHooks
            )
            if refreshed {
                self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
            }
        }
    }

    func startStashManagement(manageStashes: Bool = true, initialStash: String? = nil) {
        guard let browser,
              let context = browser.stashContext,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryStashWorkflowDataSource else {
            browser?.showPlaceholderStatus("Stash manager is unavailable for mock data")
            return
        }

        Task { @MainActor [weak browser] in
            guard let browser else { return }
            let result = await WorkflowManagementDialogs.manageStashes(
                source: source,
                context: context,
                window: window,
                manageStashes: manageStashes,
                initialStash: initialStash,
                openWithDifftool: { [weak self] commit, file in
                    self?.startDifftool(commit: commit, file: file)
                }, scriptHooks: scriptHooks
            )
            if result.repositoryChanged {
                self.notifyRepositoryChanged(
                    preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID
                )
            }
        }
    }

}
