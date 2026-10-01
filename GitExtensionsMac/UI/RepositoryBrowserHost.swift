import GitExtensionsCore
import GitCommands
import AppKit
import SwiftUI

enum RepositoryBrowserLaunch {
    case dashboard
    case mock
    case repository(URL, selection: [RevisionID] = [], fileHistory: FileHistoryBrowseRequest? = nil)
}


struct FileHistoryBrowseRequest: Equatable {
    let path: String
    var filterRevision: ObjectID?

    var arguments: [String] {
        ["--file-history-path", path] + (filterRevision.map { ["--file-history-revision", $0.string] } ?? [])
    }
    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--file-history-path"), !path.isEmpty else { return nil }
        return Self(path: path, filterRevision: value("--file-history-revision").flatMap { try? ObjectID.parse($0) })
    }
}

enum RepositoryOpeningSelection {
    static func arguments(_ ids: [RevisionID]) -> [String] {
        ids.flatMap { ["--select-revision", $0.description] }
    }
    static func parse(_ arguments: [String]) -> [RevisionID] {
        arguments.indices.compactMap { index in
            guard arguments[index] == "--select-revision", index + 1 < arguments.count else { return nil }
            switch arguments[index + 1] {
            case "WORKTREE": return .workingDirectory
            case "INDEX": return .index
            case let value: return (try? ObjectID.parse(value)).map(RevisionID.object)
            }
        }
    }
}

struct RepositoryBrowserHost: NSViewControllerRepresentable {
    let launch: RepositoryBrowserLaunch

    func makeNSViewController(context: Context) -> ApplicationHostViewController {
        ApplicationHostViewController(launch: launch, checksSettingsAtStartup: true)
    }

    func updateNSViewController(_ nsViewController: ApplicationHostViewController, context: Context) {}
}


@MainActor
enum ApplicationLifecycle {

    static var terminatesWithMainWindow = false
}

@MainActor
final class ApplicationHostViewController: NSViewController {
    private let launch: RepositoryBrowserLaunch
    private let store = AppSettingsStore.shared
    private let container = NSView()
    private(set) var activeController: NSViewController?
    private var commandObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private var openTask: Task<Void, Never>?
    private let checksSettingsAtStartup: Bool
    private var startupSettingsTask: Task<Void, Never>?
    private var didCheckStartupSettings = false

    init(launch: RepositoryBrowserLaunch, checksSettingsAtStartup: Bool = false) {
        self.launch = launch
        self.checksSettingsAtStartup = checksSettingsAtStartup
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        openTask?.cancel()
        startupSettingsTask?.cancel()
        if let commandObserver { NotificationCenter.default.removeObserver(commandObserver) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    override func loadView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        commandObserver = NotificationCenter.default.addObserver(
            forName: .browserCommand,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let command = BrowserCommandCenter.command(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, !(self.activeController is RepositoryBrowserViewController) else { return }
                self.performApplicationCommand(command)
            }
        }

        switch launch {
        case .dashboard:
            showDashboard()
        case .mock:
            showBrowser(repositoryModule: MockRepositoryDataSource())
        case .repository(let url, let selection, let fileHistory):
            showDashboard()
            openRepository(url, selection: selection, fileHistory: fileHistory)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if activeController is DashboardViewController {
            view.window?.title = "Git Extensions"
        }
        if windowCloseObserver == nil, let window = view.window {

            window.tabbingMode = .disallowed

            window.isRestorable = false
            window.setFrameAutosaveName("GitExtensionsMac.Browse")
            windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    if ApplicationLifecycle.terminatesWithMainWindow { NSApp.terminate(nil) }
                }
            }
        }
        if checksSettingsAtStartup, !didCheckStartupSettings, let window = view.window {
            didCheckStartupSettings = true
            startupSettingsTask = Task { @MainActor in
                await GitUICommands.checkStartupSettings(owner: window)
            }
        }
    }


    var dashboard: DashboardViewController? { activeController as? DashboardViewController }

    private var browser: RepositoryBrowserViewController? { activeController as? RepositoryBrowserViewController }


    private var toolsWorkingDirectory: URL {
        browser?.networkContext.map { URL(fileURLWithPath: $0.repository.path, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }


    private func performShellCommand(_ command: BrowserCommand) -> Bool {
        switch command {
        case .openRepository: presentOpenRepositoryDialog()
        case .closeToDashboard: showDashboard()
        case .cloneRepository: presentCloneShell()
        case .forkHostedRepository: presentForkAndClone()
        case .initializeRepository: presentInitializeRepository()
        case .clearRecentRepositories:
            store.clearRecentRepositories()
            dashboard?.refreshContent()
        case .openRecentRepository(let url): openRepository(url)
        case .openRepositoryAtRevisions(let url, let selection): openRepository(url, selection: selection)
        case .gitGui: GitUICommands.runGitGui(workingDirectory: toolsWorkingDirectory, owner: view.window)
        case .gitK: GitUICommands.runGitK(workingDirectory: toolsWorkingDirectory, owner: view.window)
        case .refreshDashboard: dashboard?.refreshContent()
        case .recentRepositoriesSettings:
            guard let window = view.window else { return true }
            RecentRepositoriesSettingsDialog.present(owner: window) { [weak self] saved in
                if saved { self?.dashboard?.refreshContent() }
            }
        default: return false
        }
        return true
    }

    private func performApplicationCommand(_ command: BrowserCommand) {
        if performShellCommand(command) { return }
        switch command {
        case .settings: presentSettings()
        case .plugins: GitUICommands.startPlugins(owner: view.window)
        case .viewPatch: GitUICommands.startPatchViewer(owner: view.window)
        case .openTerminal:

            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([FileManager.default.homeDirectoryForCurrentUser], withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        default: break
        }
    }

    private func showDashboard(error: Error? = nil) {
        openTask?.cancel()
        DispatchQueue.main.async {
            BrowserCommandAvailability.shared.canPatch = false
            BrowserCommandAvailability.shared.canArchive = false
            BrowserCommandAvailability.shared.gridMenuState = nil
            BrowserCommandAvailability.shared.isDashboard = true
        }
        let controller = DashboardViewController(store: store)
        controller.onOpenRepository = { [weak self] in self?.presentOpenRepositoryDialog() }
        controller.onOpenRecentRepository = { [weak self] url in self?.openRepository(url) }
        controller.onCloneRepository = { [weak self] in self?.presentCloneShell() }
        controller.onCloneHostedRepository = { [weak self] in self?.presentForkAndClone() }
        controller.onInitializeRepository = { [weak self] in self?.presentInitializeRepository() }
        install(controller)
        view.window?.title = "Git Extensions"
        if let error { controller.show(error: error) }
        RepositoryHistoryUIService.shared.triggerBranchNameCacheUpdate()
    }

    private func showBrowser(repositoryModule: any RepositoryBrowsingDataSource, selection: [RevisionID] = [], fileHistory: FileHistoryBrowseRequest? = nil) {
        let controller = RepositoryBrowserViewController(repositoryModule: repositoryModule, openingSelection: selection, fileHistory: fileHistory)
        controller.onApplicationCommand = { [weak self] command in
            guard let self else { return false }

            if case .settings = command { return false }
            return performShellCommand(command)
        }
        install(controller)
        BrowserCommandAvailability.shared.isDashboard = false
        RepositoryHistoryUIService.shared.triggerBranchNameCacheUpdate()
    }

    private func install(_ controller: NSViewController) {
        if let activeController {
            activeController.view.removeFromSuperview()
            activeController.removeFromParent()
        }
        activeController = controller
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }


    private func presentOpenRepositoryDialog() {
        guard let window = view.window else { return }
        let current = browser?.networkContext.map { URL(fileURLWithPath: $0.repository.path, isDirectory: true) }
        OpenLocalRepositoryDialog.present(owner: window, currentRepository: current) { [weak self] url in
            guard let url else { return }
            self?.openRepository(url)
        }
    }

    func openRepository(_ url: URL, selection: [RevisionID] = [], fileHistory: FileHistoryBrowseRequest? = nil) {
        openTask?.cancel()
        if !(activeController is DashboardViewController) { showDashboard() }
        let gitURL = URL(fileURLWithPath: store.preferences.gitExecutablePath)
        let repositoryModule = GitRepositoryModule(repositoryURL: url, git: GitProcess(executableURL: gitURL))
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await repositoryModule.loadRepositoryState()
                guard !Task.isCancelled else { return }
                store.recordOpenedRepository(url)
                showBrowser(repositoryModule: repositoryModule, selection: selection, fileHistory: fileHistory)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showDashboard(error: error)
            }
        }
    }
    private func presentSettings() {
        guard let window = view.window else { return }
        Task { await ApplicationShellDialogs.presentSettings(from: window) }
    }

    private func presentForkAndClone() {
        let recent = store.recentRepositories.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? ""
        let configured = store.repositoryCreationPreferences.cloneDestinationPath
        GitUICommands.startForkAndClone(
            owner: view.window, creator: repositoryCreator(),
            initialDestination: configured.isEmpty ? recent : configured,
            gitExecutable: URL(fileURLWithPath: store.preferences.gitExecutablePath)
        ) { [weak self] url in
            guard let self else { return }
            store.recordRecentRepository(url)
            openRepository(url)
        }
    }

    private func presentCloneShell() {
        guard let window = view.window else { return }
        let creator = repositoryCreator()
        let context = (activeController as? RepositoryBrowserViewController)?.networkContext
        let trackingRemote = context?.branches.first(where: { $0.isCurrent })?.remoteName
        let suggestedRemote = context?.remotes.first(where: { $0.name == trackingRemote })
            ?? context?.remotes.first(where: { $0.name.caseInsensitiveCompare("origin") == .orderedSame })
            ?? context?.remotes.first
        GitUICommands.startCloneRepository(
            source: creator,
            owner: window,
            initialSource: suggestedRemote?.fetchURL,
            initialDestination: context.map {
                URL(fileURLWithPath: $0.repository.path, isDirectory: true).deletingLastPathComponent()
            }
        ) { [weak self, weak window] result in
            guard let self else { return }
            store.recordRecentRepository(result.repositoryURL)
            dashboard?.refreshContent()
            let alert = NSAlert()
            alert.messageText = "Repository cloned successfully"
            alert.informativeText = "Do you want to open \(result.repositoryURL.path) now?"
            alert.addButton(withTitle: "Open repository")
            alert.addButton(withTitle: "Not now")
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.openRepository(result.repositoryURL)
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
            else { completion(alert.runModal()) }
        }
    }

    private func presentInitializeRepository() {
        guard let window = view.window else { return }
        let context = (activeController as? RepositoryBrowserViewController)?.networkContext
        GitUICommands.startInitializeRepository(
            source: repositoryCreator(),
            owner: window,
            initialDirectory: context.map {
                URL(fileURLWithPath: $0.repository.path, isDirectory: true).deletingLastPathComponent()
            }
        ) { [weak self] result in
            self?.openRepository(result.repositoryURL)
        }
    }

    private func repositoryCreator() -> GitRepositoryCreator {
        let gitURL = URL(fileURLWithPath: store.preferences.gitExecutablePath)
        return GitRepositoryCreator(git: GitProcess(executableURL: gitURL))
    }
}
