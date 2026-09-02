import GitExtensionsCore
import GitCommands
import AppKit
import SwiftUI

enum RepositoryBrowserLaunch {
    case dashboard
    case mock
    case repository(URL)
}

struct RepositoryBrowserHost: NSViewControllerRepresentable {
    let launch: RepositoryBrowserLaunch

    func makeNSViewController(context: Context) -> ApplicationHostViewController {
        ApplicationHostViewController(launch: launch)
    }

    func updateNSViewController(_ nsViewController: ApplicationHostViewController, context: Context) {}
}

@MainActor
final class ApplicationHostViewController: NSViewController {
    private let launch: RepositoryBrowserLaunch
    private let store = AppSettingsStore.shared
    private let container = NSView()
    private var activeController: NSViewController?
    private var commandObserver: NSObjectProtocol?
    private var openTask: Task<Void, Never>?

    init(launch: RepositoryBrowserLaunch) {
        self.launch = launch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        openTask?.cancel()
        if let commandObserver { NotificationCenter.default.removeObserver(commandObserver) }
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
        case .repository(let url):
            showDashboard()
            openRepository(url)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if activeController is RepositoryStartupViewController {
            view.window?.title = "Git Extensions"
        }
    }

    private func performApplicationCommand(_ command: BrowserCommand) {
        switch command {
        case .openRepository: presentOpenRepositoryPanel()
        case .closeToDashboard: showDashboard()
        case .cloneRepository: presentCloneShell()
        case .initializeRepository: presentInitializeRepository()
        case .settings: presentSettings()
        case .clearRecentRepositories:
            store.clearRecentRepositories()
            (activeController as? RepositoryStartupViewController)?.reloadRecents()
        case .openRecentRepository(let url):
            openRepository(url)
        default: break
        }
    }

    private func showDashboard(error: Error? = nil) {
        openTask?.cancel()
        let controller = RepositoryStartupViewController(store: store)
        controller.onOpenRepository = { [weak self] in self?.presentOpenRepositoryPanel() }
        controller.onOpenRecentRepository = { [weak self] url in self?.openRepository(url) }
        controller.onCloneRepository = { [weak self] in self?.presentCloneShell() }
        controller.onInitializeRepository = { [weak self] in self?.presentInitializeRepository() }
        controller.onSettings = { [weak self] in self?.presentSettings() }
        install(controller)
        view.window?.title = "Git Extensions"
        if let error { controller.show(error: error) }
    }

    private func showBrowser(repositoryModule: any RepositoryBrowsingDataSource) {
        let controller = RepositoryBrowserViewController(repositoryModule: repositoryModule)
        controller.onApplicationCommand = { [weak self] command in
            guard let self else { return false }
            switch command {
            case .openRepository: self.presentOpenRepositoryPanel()
            case .closeToDashboard: self.showDashboard()
            case .cloneRepository: self.presentCloneShell()
            case .initializeRepository: self.presentInitializeRepository()
            case .settings: self.presentSettings()
            case .clearRecentRepositories:
                self.store.clearRecentRepositories()
            case .openRecentRepository(let url):
                self.openRepository(url)
            default: return false
            }
            return true
        }
        install(controller)
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

    private func presentOpenRepositoryPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open repository"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openRepository(url)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func openRepository(_ url: URL) {
        openTask?.cancel()
        if !(activeController is RepositoryStartupViewController) { showDashboard() }
        let gitURL = URL(fileURLWithPath: store.preferences.gitExecutablePath)
        let repositoryModule = GitRepositoryModule(repositoryURL: url, git: GitProcess(executableURL: gitURL))
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await repositoryModule.loadRepositoryState()
                guard !Task.isCancelled else { return }
                store.recordOpenedRepository(url)
                showBrowser(repositoryModule: repositoryModule)
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
            (activeController as? RepositoryStartupViewController)?.reloadRecents()
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
