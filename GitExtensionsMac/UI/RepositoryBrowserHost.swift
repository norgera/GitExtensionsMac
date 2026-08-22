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
            showBrowser(dataSource: MockRepositoryDataSource())
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
        controller.onSettings = { [weak self] in self?.presentSettings() }
        install(controller)
        view.window?.title = "Git Extensions"
        if let error { controller.show(error: error) }
    }

    private func showBrowser(dataSource: any RepositoryBrowsingDataSource) {
        let controller = RepositoryBrowserViewController(dataSource: dataSource)
        controller.onApplicationCommand = { [weak self] command in
            guard let self else { return false }
            switch command {
            case .openRepository: self.presentOpenRepositoryPanel()
            case .closeToDashboard: self.showDashboard()
            case .cloneRepository: self.presentCloneShell()
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
        let source = GitRepositoryBrowsingDataSource(repositoryURL: url, git: GitProcess(executableURL: gitURL))
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await source.loadSnapshot()
                guard !Task.isCancelled else { return }
                store.recordOpenedRepository(url)
                showBrowser(dataSource: source)
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
        Task { await ApplicationShellDialogs.cloneShell(from: window) }
    }
}
