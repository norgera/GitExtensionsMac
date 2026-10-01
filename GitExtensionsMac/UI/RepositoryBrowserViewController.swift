import Combine
import GitExtensionsCore
import GitCommands
import AppKit

private final class BrowserShortcutRootView: NSView {
    var onFocusPane: ((String) -> Void)?
    var onScript: ((String) -> Void)?

    var onBrowseCommand: ((String) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.attachedSheet == nil, let command = ApplicationHotkeys.shared.matching(event, category: "Scripts") {
            onScript?(command); return true
        }
        if window?.attachedSheet == nil, let command = ApplicationHotkeys.shared.matching(event, category: "Browse"),
           ApplicationHotkeys.browseWindowCommands.contains(command), onBrowseCommand?(command) == true {
            return true
        }
        guard window?.attachedSheet == nil,
              let command = ApplicationHotkeys.shared.matching(event, category: "Browse panes") else {
            return super.performKeyEquivalent(with: event)
        }
        onFocusPane?(command)
        return true
    }
}

final class RepositoryBrowserViewController: NSViewController, NSTextFieldDelegate {
    var onApplicationCommand: ((BrowserCommand) -> Bool)?
    private static let collapsedPaneThickness: CGFloat = 1
    private static let collapsedMainContentThickness: CGFloat = 1
    private static let minimumWindowWidth: CGFloat = 120
    private static let minimumWindowHeight: CGFloat = 120

    private let repositoryModule: any RepositoryBrowsingDataSource
    private(set) var uiCommands: GitUICommands!

    private let outlineController = RepositoryOutlineViewController()
    private let revisionGridController = RevisionGridViewController()
    private let commitDetailController = CommitDetailViewController()
    private var revisionLinksTask: Task<Void, Never>?
    private let revisionDiffController = RevisionDiffViewController()

    private let fileTreeController = RevisionDiffViewController(mode: .fileTree)
    private var activationObserver: NSObjectProtocol?
    private let gpgController = GPGInfoViewController()
    private let detailTabs = DetailTabsViewController()
    let outputHistoryController = OutputHistoryViewController()
    private let leftPanelSplitController = RetainingSplitViewController(resizeBehavior: .fixedTrailingPane)
    private lazy var outlineSplitItem = NSSplitViewItem(viewController: outlineController)
    private let outputPanelPlaceholder = NSViewController()
    private lazy var outputSplitItem = NSSplitViewItem(viewController: outputPanelPlaceholder)
    private var outputLayoutObserver: NSObjectProtocol?
    private var outputTabEnabled = AppSettingsStore.shared.preferences.showOutputHistoryAsTab
    private var outputHistoryEnabled = AppSettingsStore.shared.preferences.outputHistoryDepth > 0
    private let buildReportController = BuildReportViewController()
    private var showsBuildReportTab = false
    private var showBuildResultPage = false
    private let buildServerWatcher = BuildServerWatcher()
    private var buildServerLaunchTask: Task<Void, Never>?



    private let mainSplitController = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
    private let rightSplitController = RetainingSplitViewController(resizeBehavior: .proportional)
    private let revisionsSplitController = RetainingSplitViewController(resizeBehavior: .fixedTrailingPane)
    private lazy var leftSplitItem = NSSplitViewItem(viewController: leftPanelSplitController)
    private lazy var gridSplitItem = NSSplitViewItem(viewController: revisionGridController)
    private lazy var commitInfoSplitItem = NSSplitViewItem(viewController: commitDetailController)
    private lazy var revisionsSplitItem = NSSplitViewItem(viewController: revisionsSplitController)
    private lazy var detailsSplitItem = NSSplitViewItem(viewController: detailTabs)
    private var layout = AppSettingsStore.shared.browserLayoutPreferences
    private let toggleLeftPanelButton = AppKitFactory.resourceButton("LayoutSidebarLeft", tooltip: "Toggle left panel", target: nil, action: nil)
    private let toggleSplitViewButton = AppKitFactory.resourceButton("LayoutFooter", tooltip: "Toggle split view layout", target: nil, action: nil)
    private let commitPositionButton = AppKitFactory.resourceButton("LayoutFooterTab", tooltip: "Commit info below graph", target: nil, action: nil)
    private static let commitPositionItems: [(title: String, image: String)] = [
        ("Commit info below graph", "LayoutFooterTab"),
        ("Commit info left of graph", "LayoutSidebarTopLeft"),
        ("Commit info right of graph", "LayoutSidebarTopRight")
    ]

    let statusLabel = NSTextField(labelWithString: "Loading repository…")
    private let repositoryStateLabel = NSTextField(labelWithString: "")
    let filterToolbar = RevisionFilterToolbar()
    private let workingDirectoryPopUp = NSPopUpButton()
    private let branchPopUp = NSPopUpButton()
    private let pullPopUp = NSPopUpButton()
    private let stashSplitButton = NSSegmentedControl()
    private let stashMenu = NSMenu(title: "Stash")
    private let pushButton = NSButton()
    private let levelUpButton = AppKitFactory.resourceButton("SubmodulesManage", tooltip: "Submodules", width: 32, target: nil, action: nil)
    private let worktreeButton = AppKitFactory.resourceButton("WorkTree", tooltip: "Worktrees", width: 32, target: nil, action: nil)
    private let worktreeDropdownButton = NSButton(title: "⌄", target: nil, action: nil)
    private let commitButton = NSButton()
    private var workingDirectoryWidthConstraint: NSLayoutConstraint?
    private var branchWidthConstraint: NSLayoutConstraint?
    private(set) var repositoryIdentity: RepositoryIdentityState?
    private(set) var repositoryReferences: RepositoryReferenceState?
    private(set) var repositoryNavigation: RepositoryNavigationState?
    private(set) var repositoryStatus: RepositoryStatusSummary?
    var networkContext: RepositoryNetworkContext? {
        guard let repositoryIdentity, let repositoryReferences, let repositoryNavigation else { return nil }
        return RepositoryNetworkContext(
            repository: repositoryIdentity.currentRepository,
            headID: repositoryIdentity.headID,
            branches: repositoryReferences.branches,
            remotes: repositoryNavigation.remotes.filter { !$0.isDisabled },
            references: repositoryReferences.references,
            submodules: repositoryNavigation.submodules
        )
    }
    var branchContext: RepositoryBranchContext? {
        guard let repositoryIdentity, let repositoryReferences, let repositoryNavigation else { return nil }
        return RepositoryBranchContext(
            repository: repositoryIdentity.currentRepository,
            headID: repositoryIdentity.headID,
            branches: repositoryReferences.branches,
            remotes: repositoryNavigation.remotes.filter { !$0.isDisabled },
            referencesByCommit: repositoryReferences.referencesByCommit,
            submodules: repositoryNavigation.submodules
        )
    }
    var mergeContext: RepositoryMergeContext? {
        guard let repositoryIdentity, let repositoryReferences, let repositoryNavigation else { return nil }
        return RepositoryMergeContext(
            repository: repositoryIdentity.currentRepository,
            branches: repositoryReferences.branches,
            tags: repositoryReferences.tags,
            referencesByCommit: repositoryReferences.referencesByCommit,
            submodules: repositoryNavigation.submodules
        )
    }
    var commitContext: RepositoryCommitContext? {
        guard let repositoryIdentity, let repositoryReferences else { return nil }
        return RepositoryCommitContext(
            repository: repositoryIdentity.currentRepository,
            headID: repositoryIdentity.headID,
            branches: repositoryReferences.branches,
            submodules: repositoryNavigation?.submodules ?? []
        )
    }
    var stashContext: RepositoryStashContext? {
        guard let repositoryIdentity, let repositoryNavigation else { return nil }
        return RepositoryStashContext(headID: repositoryIdentity.headID, stashes: repositoryNavigation.stashes)
    }
    var rebaseContext: RepositoryRebaseContext? {
        guard let repositoryReferences else { return nil }
        return RepositoryRebaseContext(branches: repositoryReferences.branches, tags: repositoryReferences.tags)
    }
    private var placeholderObserver: NSObjectProtocol?
    private var commitInfoChildren: [ObjectID] = []
    private var commitInfoFilledFor: RevisionID?
    private var historyMenuObserver: AnyCancellable?
    private var annotatedTagsObserver: NSObjectProtocol?
    private var windowScreenObserver: NSObjectProtocol?
    private weak var configuredWindow: NSWindow?
    private var didSetInitialDividerPositions = false
    private var repositoryStateLoadTask: Task<Void, Never>?
    private var activeRevisionReader: RevisionReader?
    private var revisionReadTask: Task<Void, Never>?
    private var labelContextTask: Task<Void, Never>?
    private var appliedMaximumRevisionCount = AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount
    private(set) var revisions: [Commit] = []
    var revisionDetailsTask: Task<Void, Never>?
    var mutationTask: Task<Void, Never>?
    var commitWindowController: NSWindowController?
    var pullWindowController: NSWindowController?
    var pushWindowController: NSWindowController?
    var mergeWindowController: NSWindowController?
    var fetchWindowController: NSWindowController?
    private var remoteBranchDeleteWindowController: NSWindowController?
    var checkoutBranchWorkflowCoordinator: CheckoutBranchWorkflowCoordinator?
    private var operationStateTask: Task<Void, Never>?
    private let bisectBanner = NSView()
    private let bisectBannerLabel = NSTextField(labelWithString: "")
    private var bisectBannerHeightConstraint: NSLayoutConstraint?
    private let rebaseBanner = NSView()
    private let rebaseBannerLabel = NSTextField(labelWithString: "")
    private let rebaseResolveButton = NSButton(title: "Resolve…", target: nil, action: nil)
    private let gitActionAbortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let gitActionMoreButton = NSButton(title: "More…", target: nil, action: nil)
    private let gitActionIcon = NSImageView()
    private var gitAction = BrowserGitAction.none
    private let rebaseContinueButton = NSButton(title: "Continue", target: nil, action: nil)
    private var rebaseBannerHeightConstraint: NSLayoutConstraint?
    private var preferencesObserver: NSObjectProtocol?
    private var pullPreferencesObserver: NSObjectProtocol?
    private var repositoryChangeSubscription: RepositoryChangedSubscription?
    private var notifierPreferredCommitID: RevisionID?
    var selectedCommitID: RevisionID?
    var commitDraft: CommitDialogDraft?
    private var openingSelection: [RevisionID]
    private let fileHistory: FileHistoryBrowseRequest?
    private var fileHistoryLeftPanelStartupState: Bool?
    var workflowRevisionSelection: [RevisionID] { revisionGridController.selectedRevisionIDs }
    var scriptFileContext: [String: [String]] {
        (selectedDetailController === fileTreeController ? fileTreeController : revisionDiffController).scriptFileContext
    }
    func selectScriptRevision(_ id: ObjectID) { revisionGridController.selectCommit(id: .object(id)) }

    init(repositoryModule: any RepositoryBrowsingDataSource, openingSelection: [RevisionID] = [], fileHistory: FileHistoryBrowseRequest? = nil) {
        self.repositoryModule = repositoryModule
        self.openingSelection = openingSelection
        self.fileHistory = fileHistory
        super.init(nibName: nil, bundle: nil)
        if let fileHistory {
            revisionGridController.updateFilter(refresh: false) {
                $0.byPathFilter = true
                $0.pathFilter = "\"" + fileHistory.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                if let revision = fileHistory.filterRevision { $0.byBranchFilter = true; $0.branchFilter = revision.string }
            }
            fileTreeController.requestsBlameForFollowedFile = true
        }
        uiCommands = GitUICommands(repositoryModule: repositoryModule, browser: self)
        repositoryChangeSubscription = uiCommands.repositoryChangedNotifier.subscribe { [weak self] _, _ in
            guard let self else { return }
            let preferredCommitID = self.notifierPreferredCommitID
            self.notifierPreferredCommitID = nil
            self.reloadRepositoryState(preferredCommitID: preferredCommitID)
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        repositoryStateLoadTask?.cancel()
        revisionReadTask?.cancel()
        revisionDetailsTask?.cancel()
        mutationTask?.cancel()
        operationStateTask?.cancel()
        if let placeholderObserver {
            NotificationCenter.default.removeObserver(placeholderObserver)
        }
        if let windowScreenObserver {
            NotificationCenter.default.removeObserver(windowScreenObserver)
        }
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        if let pullPreferencesObserver {
            NotificationCenter.default.removeObserver(pullPreferencesObserver)
        }
        repositoryChangeSubscription?.cancel()
        if let outputLayoutObserver { NotificationCenter.default.removeObserver(outputLayoutObserver) }
        layoutSaveObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        outputPanelPlaceholder.view = NSView()
        configureDetailTabs(selecting: layout.commitInfoPosition == .belowList ? commitDetailController : revisionDiffController)
        configureSplitHierarchy()

        let root = BrowserShortcutRootView()
        root.onFocusPane = { [weak self] in self?.focusPane($0) }
        root.onBrowseCommand = { [weak self] identifier in
            guard let self, repositoryIdentity != nil, let command = BrowserCommand.browseHotkey(identifier) else { return false }
            performTopLevelCommand(command)
            return true
        }
        root.onScript = { [weak self] identifier in
            guard let script = try? ApplicationScriptsStore.shared.load().first(where: { "script.\($0.hotkeyCommandIdentifier)" == identifier }) else { return }
            self?.uiCommands.startScript(script)
        }
        revisionGridController.onScript = { [weak self] in self?.uiCommands.startScript($0) }
        revisionDiffController.onScript = { [weak self] in self?.uiCommands.startScript($0) }
        fileTreeController.onScript = { [weak self] in self?.uiCommands.startScript($0) }
        let browserToolbar = makeBrowserToolbar()
        let bisectBanner = makeBisectBanner()
        let rebaseBanner = makeRebaseBanner()
        let statusBar = makeStatusBar()

        addChild(mainSplitController)
        let contentView = mainSplitController.view
        [browserToolbar, bisectBanner, rebaseBanner, contentView, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        let toolbarHeight = browserToolbar.heightAnchor.constraint(equalToConstant: BrowserMetrics.primaryToolbarHeight)
        toolbarHeight.priority = .defaultHigh
        let statusHeight = statusBar.heightAnchor.constraint(equalToConstant: BrowserMetrics.statusHeight)
        statusHeight.priority = .defaultHigh
        let bisectHeight = bisectBanner.heightAnchor.constraint(equalToConstant: 0)
        bisectBannerHeightConstraint = bisectHeight
        let rebaseHeight = rebaseBanner.heightAnchor.constraint(equalToConstant: 0)
        rebaseBannerHeightConstraint = rebaseHeight
        NSLayoutConstraint.activate([
            browserToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            browserToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarHeight,

            bisectBanner.topAnchor.constraint(equalTo: browserToolbar.bottomAnchor),
            bisectBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bisectBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bisectHeight,

            rebaseBanner.topAnchor.constraint(equalTo: bisectBanner.bottomAnchor),
            rebaseBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rebaseBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rebaseHeight,

            contentView.topAnchor.constraint(equalTo: rebaseBanner.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusHeight
        ])

        view = root
        if !outputTabEnabled && outputHistoryEnabled { attachOutputPanel() }
        outputLayoutObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOutputPanelLayout() }
        }
        bindInteractions()
        observePlaceholderActions()
        applyPreferences()
        preferencesObserver = NotificationCenter.default.addObserver(forName: .appPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyPreferences()
        }
        pullPreferencesObserver = NotificationCenter.default.addObserver(forName: .pullPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildPullMenu()
        }
        reloadRepositoryState()
    }

    private func makeRebaseBanner() -> NSView {
        rebaseBanner.wantsLayer = true
        rebaseBanner.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Rebase in progress") ?? NSImage())
        rebaseBannerLabel.font = AppSettingsStore.shared.applicationFont(size: 12)
        gitActionAbortButton.target = self; gitActionAbortButton.action = #selector(abortGitActionFromBanner)
        gitActionMoreButton.target = self; gitActionMoreButton.action = #selector(showGitActionMore)
        rebaseContinueButton.target = self; rebaseContinueButton.action = #selector(continueGitActionFromBanner)
        rebaseResolveButton.target = self; rebaseResolveButton.action = #selector(resolveGitActionFromBanner)
        gitActionIcon.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Git action in progress")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [gitActionIcon, rebaseBannerLabel, spacer, rebaseResolveButton, rebaseContinueButton, gitActionAbortButton, gitActionMoreButton])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        rebaseBanner.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rebaseBanner.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: rebaseBanner.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: rebaseBanner.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: rebaseBanner.bottomAnchor, constant: -3),
            gitActionIcon.widthAnchor.constraint(equalToConstant: 22)
        ])
        rebaseBanner.isHidden = true
        return rebaseBanner
    }

    private func makeBisectBanner() -> NSView {
        bisectBanner.wantsLayer = true
        bisectBanner.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "info.circle.fill",
            accessibilityDescription: "Bisect in progress"
        ) ?? NSImage())
        bisectBannerLabel.font = AppSettingsStore.shared.applicationFont(size: 12)
        let more = NSButton(title: "More…", target: self, action: #selector(showBisectManager))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, bisectBannerLabel, spacer, more])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        bisectBanner.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bisectBanner.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bisectBanner.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bisectBanner.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bisectBanner.bottomAnchor, constant: -3),
            icon.widthAnchor.constraint(equalToConstant: 22)
        ])
        bisectBanner.isHidden = true
        return bisectBanner
    }

    private func applyPreferences() {
        let settings = AppSettingsStore.shared.preferences
        CommandLog.shared.setOutputHistoryDepth(settings.outputHistoryDepth)
        let outputChanged = outputTabEnabled != settings.showOutputHistoryAsTab || outputHistoryEnabled != (settings.outputHistoryDepth > 0)
        if outputChanged {

            if leftPanelSplitController.splitViewItems.contains(where: { $0 === outputSplitItem }) {
                leftPanelSplitController.removeSplitViewItem(outputSplitItem)
            }
            if outputHistoryController.parent === self {
                outputHistoryController.view.removeFromSuperview()
                outputHistoryController.removeFromParent()
            }
            outputTabEnabled = settings.showOutputHistoryAsTab
            outputHistoryEnabled = settings.outputHistoryDepth > 0
            outputHistoryController.view.isHidden = false
            configureDetailTabs()
            configureOutputPanel()
            if !outputTabEnabled && outputHistoryEnabled { attachOutputPanel() }
        }
        updateOutputPanelLayout()
        let maximum = AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount
        if maximum != appliedMaximumRevisionCount {
            appliedMaximumRevisionCount = maximum
            if repositoryIdentity != nil { restartRevisionReadForFilterChange() }
        }
        revisionGridController.setGraphConfiguration(
            mergeCommonParentLanes: settings.mergeCommonParentLanes,
            straightenDiagonals: settings.straightenGraphDiagonals,
            renderWithDiagonals: settings.renderGraphWithDiagonals
        )
        revisionGridController.setShowsTagReferences(AppSettingsStore.shared.tagPreferences.showTagsInRevisionGrid)
        revisionGridController.reloadAppearance()
        if let repositoryIdentity, let repositoryReferences, let repositoryNavigation {
            outlineController.apply(identity: repositoryIdentity, references: repositoryReferences, navigation: repositoryNavigation)
        }
        updateToolbarRepositoryState()
        if let selectedCommitID, let commit = revisions.first(where: { $0.id == selectedCommitID }) {
            loadRevisionLinks(for: commit)
        }
        updateRevisionCount()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowTitle()
        configureWindowSizing()
        setInitialDividerPositionsIfNeeded()
        refreshLayoutToggleButtonStates()
        if layoutSaveObservers.isEmpty {

            layoutSaveObservers = [NSWindow.willCloseNotification, NSApplication.willTerminateNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: name == NSWindow.willCloseNotification ? view.window : nil,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.saveLayout() }
                }
            }
        }
    }
    private var layoutSaveObservers: [NSObjectProtocol] = []

    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveLayout()
        BrowserCommandAvailability.shared.hasRepository = false
        uiCommands.stopPlugins()
        buildServerLaunchTask?.cancel()
        buildServerWatcher.repositoryChanged()
        buildServerWatcher.cancel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialDividerPositions {
            setInitialDividerPositionsIfNeeded()
        }
        updateOutputPanelLayout()
    }


    private func configureDetailTabs(selecting controller: NSViewController? = nil) {
        let selected = controller ?? selectedDetailController ?? revisionDiffController
        var items: [(String, String, NSViewController)] = layout.commitInfoPosition == .belowList
            ? [("Commit", "CommitSummary", commitDetailController)] : []
        items += [
            ("Diff", "Diff", revisionDiffController),
            ("File tree", "FileTree", fileTreeController),
            ("GPG", "Key", gpgController)
        ]
        if showsBuildReportTab { items.append(("Build Report", "", buildReportController)) }
        if outputHistoryEnabled && outputTabEnabled { items.append(("Output", "GitCommandLog", outputHistoryController)) }
        detailTabControllers = items.map(\.2)
        detailTabs.configure(items: items, selectedIndex: detailTabControllers.firstIndex { $0 === selected } ?? 0)
    }

    private var detailTabControllers: [NSViewController] = []
    private var selectedDetailController: NSViewController? {
        detailTabControllers.indices.contains(detailTabs.selectedTabIndex) ? detailTabControllers[detailTabs.selectedTabIndex] : nil
    }
    private func selectDetailTab(_ controller: NSViewController) {
        guard let index = detailTabControllers.firstIndex(where: { $0 === controller }) else { return }
        detailTabs.selectTab(at: index)
    }

    private func updateBuildReportTab() {
        let url = revisionGridController.buildStatus(for: selectedCommitID)?.url
        buildReportController.url = url
        let show = showBuildResultPage && url != nil
        guard show != showsBuildReportTab else { return }
        showsBuildReportTab = show
        configureDetailTabs()
    }

    private func launchBuildServerWatcher() {
        buildServerLaunchTask?.cancel()
        buildServerWatcher.cancel()
        guard let manager = repositoryModule as? any RepositoryRemoteManagingDataSource,
              let settingsSource = repositoryModule as? any RepositorySettingsDataSource else { return }
        let hosting = repositoryModule as? any RepositoryHostingDataSource
        let current = repositoryReferences?.branches.first(where: \.isCurrent)?.remoteName
        buildServerLaunchTask = Task { @MainActor [weak self] in
            let remotes = (try? await manager.loadRemoteConfigurations()) ?? []
            let locations = try? await DistributedSettings.loadLocations(from: settingsSource)
            let settings = (try? BuildServerSettingsStore(locations: locations).values(.effective)) ?? [:]
            let resolution = await BuildServerAdapterResolver.resolve(settings: settings, remotes: remotes, currentRemote: current,
                credential: { url in await hosting?.hostCredentialPassword(for: url) })
            guard let self, !Task.isCancelled else { return }
            showBuildResultPage = BuildServerSettingsStore.bool(settings[BuildServerSettingKeys.showBuildResultPage]) ?? false
            revisionGridController.setBuildStatusColumn(enabled: resolution.adapter != nil || resolution.explicitlyEnabled)
            buildServerWatcher.onUpdate = { [weak self] infos in
                self?.revisionGridController.applyBuildInfos(infos)
                self?.updateBuildReportTab()
            }
            buildServerWatcher.onInitializationError = { [weak self] error in
                BuildServerErrorPresenter.present(error, window: self?.view.window) { self?.uiCommands.startSettings() }
            }
            buildServerWatcher.launch(resolution.adapter)
            updateBuildReportTab()
        }
    }

    private func focusPane(_ command: String) {
        if command == "focus.output" { uiCommands.startOutputHistory(); return }
        let target: NSView
        switch command {
        case "focus.tree":

            guard !mainSplitController.isCollapsed(leftSplitItem) else { return }
            target = outlineController.view
        case "focus.grid":
            target = revisionGridController.view
        case "focus.details" where layout.commitInfoPosition != .belowList:
            target = commitDetailController.view
        default:
            let controller: NSViewController
            switch command {
            case "focus.details": controller = commitDetailController
            case "focus.diff": controller = revisionDiffController
            case "focus.files": controller = fileTreeController
            case "focus.gpg": controller = gpgController
            case "focus.build":
                guard showsBuildReportTab else { return }
                controller = buildReportController
            default: return
            }
            target = controller.view
            if !layout.showSplitViewLayout { setShowSplitViewLayout(true) }
            selectDetailTab(controller)
        }
        func focusable(_ node: NSView) -> NSView? {
            guard !node.isHidden else { return nil }
            if node is NSTableView || node is NSTextView, node.acceptsFirstResponder { return node }
            if let field = node as? NSTextField, field.isSelectable, field.acceptsFirstResponder { return field }
            for child in node.subviews { if let found = focusable(child) { return found } }
            return nil
        }
        if let responder = focusable(target) { view.window?.makeFirstResponder(responder) }
    }

    private func configureSplitHierarchy() {
        leftPanelSplitController.splitView.isVertical = false
        leftPanelSplitController.splitView.dividerStyle = .paneSplitter
        outlineSplitItem.minimumThickness = Self.collapsedPaneThickness
        outputSplitItem.minimumThickness = Self.collapsedPaneThickness
        leftPanelSplitController.addSplitViewItem(outlineSplitItem)
        configureOutputPanel()
        mainSplitController.splitView.isVertical = true
        mainSplitController.splitView.dividerStyle = .paneSplitter
        leftSplitItem.minimumThickness = Self.collapsedPaneThickness
        leftSplitItem.canCollapse = false
        leftSplitItem.canCollapseFromWindowResize = false
        leftSplitItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        rightSplitController.splitView.isVertical = false
        rightSplitController.splitView.dividerStyle = .paneSplitter
        revisionsSplitItem.minimumThickness = Self.collapsedPaneThickness
        detailsSplitItem.minimumThickness = Self.collapsedPaneThickness
        revisionsSplitItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        detailsSplitItem.holdingPriority = .defaultLow
        rightSplitController.addSplitViewItem(revisionsSplitItem)
        rightSplitController.addSplitViewItem(detailsSplitItem)

        revisionsSplitController.splitView.isVertical = true
        revisionsSplitController.splitView.dividerStyle = .paneSplitter
        gridSplitItem.minimumThickness = Self.collapsedPaneThickness
        commitInfoSplitItem.minimumThickness = Self.collapsedPaneThickness
        layoutRevisionInfo()

        let browserItem = NSSplitViewItem(viewController: rightSplitController)
        browserItem.minimumThickness = Self.collapsedMainContentThickness
        browserItem.holdingPriority = .defaultLow
        mainSplitController.addSplitViewItem(leftSplitItem)
        mainSplitController.addSplitViewItem(browserItem)
        if layout.leftPanelCollapsed { mainSplitController.setCollapsed(true, for: leftSplitItem) }
        if !layout.showSplitViewLayout { rightSplitController.setCollapsed(true, for: detailsSplitItem) }
    }


    private func layoutRevisionInfo() {
        let selected = selectedDetailController
        revisionsSplitController.removeSplitViewItem(gridSplitItem)
        revisionsSplitController.removeSplitViewItem(commitInfoSplitItem)
        let sideWidth: CGFloat = 490 + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        switch layout.commitInfoPosition {
        case .belowList:
            configureDetailTabs(selecting: commitDetailController)
            revisionsSplitController.addSplitViewItem(gridSplitItem)
        case .rightwardFromList:
            configureDetailTabs(selecting: selected === commitDetailController ? revisionDiffController : selected)
            revisionsSplitController.resizeBehavior = .fixedTrailingPane
            revisionsSplitController.addSplitViewItem(gridSplitItem)
            revisionsSplitController.addSplitViewItem(commitInfoSplitItem)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                revisionsSplitController.setRetainedPosition(max(0, revisionsSplitController.primaryLength - sideWidth))
            }
        case .leftwardFromList:
            configureDetailTabs(selecting: selected === commitDetailController ? revisionDiffController : selected)
            revisionsSplitController.resizeBehavior = .fixedLeadingPane
            revisionsSplitController.addSplitViewItem(commitInfoSplitItem)
            revisionsSplitController.addSplitViewItem(gridSplitItem)
            DispatchQueue.main.async { [weak self] in self?.revisionsSplitController.setRetainedPosition(sideWidth) }
        }
        refreshLayoutToggleButtonStates()
        loadActiveDetailTab()
    }


    private func refreshLayoutToggleButtonStates() {
        toggleLeftPanelButton.state = mainSplitController.isCollapsed(leftSplitItem) ? .off : .on
        toggleSplitViewButton.state = layout.showSplitViewLayout ? .on : .off
        let item = Self.commitPositionItems[layout.commitInfoPosition.rawValue]
        commitPositionButton.image = AppKitFactory.resourceImage(item.image, accessibilityDescription: item.title)
        commitPositionButton.toolTip = item.title
        BrowserCommandAvailability.shared.layout = layout
    }


    var layoutSnapshot: (leftPanelCollapsed: Bool, detailsCollapsed: Bool, commitTabShown: Bool, commitInfoBesideGraph: Bool,
                         visibleToolbarItems: Set<String>) {
        (mainSplitController.isCollapsed(leftSplitItem), rightSplitController.isCollapsed(detailsSplitItem),
         detailTabControllers.contains { $0 === commitDetailController },
         revisionsSplitController.splitViewItems.contains { $0 === commitInfoSplitItem },
         Set(toolbarItems.filter { item in !item.views.isEmpty && item.views.allSatisfy { !$0.isHidden } }.map(\.key)))
    }


    private func updateWindowTitle() {
        guard let window = view.window else { return }
        let branch = repositoryReferences?.branches.first(where: \.isCurrent)?.name
        let path = repositoryIdentity.map { URL(fileURLWithPath: $0.currentRepository.path, isDirectory: true) }
        window.title = BrowserPresentation.windowTitle(repositoryURL: path, branch: branch,
                                                       pathFilter: revisionGridController.currentFilter.effectivePathFilter)
    }

    private func saveLayout() {
        layout.leftPanelCollapsed = fileHistoryLeftPanelStartupState ?? mainSplitController.isCollapsed(leftSplitItem)
        for (name, controller) in splitterControllers {
            guard let position = controller.dividerPosition else { continue }
            layout.splitters[name] = .init(distance: Double(position), size: Double(controller.primaryLength))
        }
        AppSettingsStore.shared.saveBrowserLayoutPreferences(layout)
    }

    private var splitterControllers: [(String, RetainingSplitViewController)] {
        [("MainSplitContainer", mainSplitController), ("RightSplitContainer", rightSplitController),
         ("OutputHistorySplitContainer", leftPanelSplitController),
         ("RevisionsSplitContainer.\(layout.commitInfoPosition.rawValue)", revisionsSplitController)]
    }

    private func configureOutputPanel() {
        guard outputHistoryEnabled && !outputTabEnabled else { return }
        leftPanelSplitController.addSplitViewItem(outputSplitItem)
        leftPanelSplitController.setCollapsed(!AppSettingsStore.shared.preferences.outputHistoryPanelVisible, for: outputSplitItem)
        if !restoreSplitter(("OutputHistorySplitContainer", leftPanelSplitController)) {
            leftPanelSplitController.setRetainedPosition(max(80, leftPanelSplitController.primaryLength - 160))
        }
    }

    private func attachOutputPanel() {
        addChild(outputHistoryController)
        outputHistoryController.view.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(outputHistoryController.view)
        updateOutputPanelLayout()
    }



    private func updateOutputPanelLayout() {
        guard isViewLoaded else { return }
        let shown = outputHistoryEnabled && !outputTabEnabled && !mainSplitController.isCollapsed(leftSplitItem)
            && !leftPanelSplitController.isCollapsed(outputSplitItem)
        if outputHistoryController.parent === self { outputHistoryController.view.isHidden = !shown }
        let height = shown ? outputPanelPlaceholder.view.bounds.height : 0
        let diffVisible = layout.showSplitViewLayout && selectedDetailController === revisionDiffController
        let treeVisible = layout.showSplitViewLayout && selectedDetailController === fileTreeController
        revisionDiffController.reserveOutputHistoryPanel(height: diffVisible ? height : 0)
        fileTreeController.reserveOutputHistoryPanel(height: treeVisible ? height : 0)
        guard shown, outputHistoryController.parent === self else { return }
        var frame = view.convert(outputPanelPlaceholder.view.bounds, from: outputPanelPlaceholder.view)
        let active = diffVisible ? revisionDiffController : treeVisible ? fileTreeController : nil
        if let active, active.isViewLoaded {
            let filesFrame = view.convert(active.filesController.view.bounds, from: active.filesController.view)
            frame.size.width = max(frame.width, filesFrame.maxX - frame.minX)
        }
        outputHistoryController.view.frame = frame
    }

    func focusOutputHistory() {
        guard outputHistoryEnabled else { return }
        if outputTabEnabled {
            if !layout.showSplitViewLayout { setShowSplitViewLayout(true) }
            selectDetailTab(outputHistoryController)
            outputHistoryController.focus()
        } else {
            let show = leftPanelSplitController.isCollapsed(outputSplitItem)
            leftPanelSplitController.setCollapsed(!show, for: outputSplitItem)
            if show && mainSplitController.isCollapsed(leftSplitItem) { toggleLeftPanel() }
            var settings = AppSettingsStore.shared.preferences
            settings.outputHistoryPanelVisible = show
            AppSettingsStore.shared.save(settings)
            updateOutputPanelLayout()
            if show { outputHistoryController.focus() }
        }
    }

    var outputHistoryPresentation: (enabled: Bool, tab: Bool, panelVisible: Bool) {
        (outputHistoryEnabled, outputTabEnabled, !outputTabEnabled && outputHistoryEnabled && !leftPanelSplitController.isCollapsed(outputSplitItem))
    }

    func setShowSplitViewLayout(_ show: Bool) {
        layout.showSplitViewLayout = show
        rightSplitController.setCollapsed(!show, for: detailsSplitItem)
        refreshLayoutToggleButtonStates()
        saveLayout()
    }

    func setCommitInfoPosition(_ position: BrowserLayoutPreferences.CommitInfoPosition) {
        saveLayout()
        layout.commitInfoPosition = position
        layoutRevisionInfo()
        restoreSplitter(("RevisionsSplitContainer.\(position.rawValue)", revisionsSplitController))
        saveLayout()
    }

    private func makeBrowserToolbar() -> NSView {
        let background = AppKitFactory.toolbarBackground()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(AppKitFactory.resourceButton("ReloadRevisions", tooltip: "Refresh", target: self, action: #selector(refresh)))
        stack.addArrangedSubview(AppKitFactory.separator())
        for (button, action) in [(toggleLeftPanelButton, #selector(toggleLeftPanel)), (toggleSplitViewButton, #selector(toggleSplitLayout))] {
            button.target = self
            button.action = action
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.isBordered = true
            stack.addArrangedSubview(button)
        }
        commitPositionButton.target = self
        commitPositionButton.action = #selector(cycleCommitInfoPosition)
        stack.addArrangedSubview(commitPositionButton)
        let commitPositionDropdown = NSButton(title: "⌄", target: self, action: #selector(showCommitInfoPositionMenu(_:)))
        commitPositionDropdown.isBordered = false
        commitPositionDropdown.toolTip = "Commit info position"
        commitPositionDropdown.translatesAutoresizingMaskIntoConstraints = false
        commitPositionDropdown.widthAnchor.constraint(equalToConstant: 12).isActive = true
        stack.addArrangedSubview(commitPositionDropdown)
        stack.addArrangedSubview(AppKitFactory.separator())

        levelUpButton.target = self
        levelUpButton.action = #selector(levelUpToolbar)
        stack.addArrangedSubview(levelUpButton)
        let submoduleDropdown = NSButton(title: "⌄", target: self, action: #selector(showSubmodulesMenu(_:)))
        submoduleDropdown.isBordered = false
        submoduleDropdown.toolTip = "Navigate submodules and superprojects"
        stack.addArrangedSubview(submoduleDropdown)
        worktreeButton.target = self
        worktreeButton.action = #selector(manageWorktreesToolbar(_:))
        stack.addArrangedSubview(worktreeButton)
        worktreeDropdownButton.target = self
        worktreeDropdownButton.action = #selector(showWorktreesMenu(_:))
        worktreeDropdownButton.isBordered = false
        worktreeDropdownButton.toolTip = "Switch worktree"
        worktreeDropdownButton.widthAnchor.constraint(equalToConstant: 12).isActive = true
        stack.addArrangedSubview(worktreeDropdownButton)

        workingDirectoryWidthConstraint = configureCompactPopUp(workingDirectoryPopUp, items: ["gitextensions"], width: 83, action: #selector(selectWorkingDirectory))
        workingDirectoryPopUp.pullsDown = true
        workingDirectoryPopUp.toolTip = "Change working directory"
        stack.addArrangedSubview(workingDirectoryPopUp)

        branchWidthConstraint = configureCompactPopUp(branchPopUp, items: ["main"], width: 60, action: #selector(selectBranch), imageName: "Branch")
        branchPopUp.toolTip = "Change current branch"
        stack.addArrangedSubview(branchPopUp)
        stack.addArrangedSubview(AppKitFactory.separator())

        configureImagePopUp(
            pullPopUp,
            imageName: "Pull",
            items: ["Pull"],
            width: 32,
            action: #selector(selectPullAction)
        )
        rebuildPullMenu()
        for (key, title, imageName, command) in Self.pullShortcutButtons {
            let button = AppKitFactory.resourceButton(imageName, tooltip: title, target: self, action: #selector(pullShortcutButton(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(key)
            pullShortcutViews[key] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(pullPopUp)
        configureDynamicToolbarButton(pushButton, imageName: "Push", tooltip: "Push", action: #selector(pushToolbarButton(_:)))
        stack.addArrangedSubview(pushButton)
        let pushCommitGap = NSView()
        pushCommitGap.translatesAutoresizingMaskIntoConstraints = false
        pushCommitGap.widthAnchor.constraint(equalToConstant: 3).isActive = true
        stack.addArrangedSubview(pushCommitGap)
        configureDynamicToolbarButton(commitButton, imageName: "RepoStateClean", tooltip: "Commit", action: #selector(commitToolbarButton(_:)))
        commitButton.title = "Commit (0)"
        stack.addArrangedSubview(commitButton)
        let commitStashGap = NSView()
        commitStashGap.translatesAutoresizingMaskIntoConstraints = false
        commitStashGap.widthAnchor.constraint(equalToConstant: 4).isActive = true
        stack.addArrangedSubview(commitStashGap)

        configureStashSplitButton()
        stack.addArrangedSubview(stashSplitButton)
        stack.addArrangedSubview(AppKitFactory.separator())
        stack.addArrangedSubview(AppKitFactory.resourceButton("BrowseFileExplorer", tooltip: "File Explorer (Finder)", target: self, action: #selector(fileExplorerToolbar(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("GitForWindows", tooltip: "Terminal", target: self, action: #selector(terminalToolbar(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("Settings", tooltip: "Settings", target: self, action: #selector(settingsToolbarButton(_:))))

        let toolbarGap = NSView()
        toolbarGap.translatesAutoresizingMaskIntoConstraints = false
        toolbarGap.widthAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(toolbarGap)

        standardToolbarViews = stack.arrangedSubviews
        filterToolbar.views.forEach(stack.addArrangedSubview)
        filtersToolbarViews = filterToolbar.views

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        let scripts = AppKitFactory.popUp("Scripts", width: 58)
        scripts.pullsDown = true
        scripts.menu = ApplicationScriptsMenu(placement: .toolbar,
            execute: { [weak self] in self?.uiCommands.startScript($0) },
            manage: { [weak self] in self?.uiCommands.startScripts() })
        stack.addArrangedSubview(scripts)
        scriptsToolbarViews = [scripts]
        registerToolbarItems(scripts: scripts)

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 3),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        return background
    }

    private func makeStatusBar() -> NSView {
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .active

        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = AppSettingsStore.shared.applicationFont(size: 10.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repositoryStateLabel.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedDigitSystemFont(ofSize: 10, weight: .regular))
        repositoryStateLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(repositoryStateLabel)
        background.addSubview(topBorder)
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: background.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        return background
    }

    @discardableResult
    private func configureCompactPopUp(
        _ button: NSPopUpButton,
        items: [String],
        width: CGFloat,
        action: Selector,
        imageName: String? = nil
    ) -> NSLayoutConstraint {
        button.removeAllItems()
        button.addItems(withTitles: items)
        button.controlSize = .small
        button.font = AppSettingsStore.shared.applicationFont(size: 11)
        button.bezelStyle = .texturedRounded
        if let imageName {
            let image = AppKitFactory.resourceImage(imageName, accessibilityDescription: items.first)
            button.image = image
            button.itemArray.forEach { $0.image = image }
            button.imagePosition = .imageLeading
        }
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([widthConstraint, button.heightAnchor.constraint(equalToConstant: 22)])
        return widthConstraint
    }

    @discardableResult
    private func configureImagePopUp(
        _ button: NSPopUpButton,
        imageName: String,
        items: [String],
        width: CGFloat,
        action: Selector
    ) -> NSLayoutConstraint {
        let widthConstraint = configureCompactPopUp(button, items: items, width: width, action: action)
        compactImagePopUp(button, imageName: imageName, width: width)
        return widthConstraint
    }

    private func configureDynamicToolbarButton(
        _ button: NSButton,
        imageName: String,
        tooltip: String,
        action: Selector
    ) {
        button.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: tooltip)
        button.title = ""
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.controlSize = .small
        button.font = AppSettingsStore.shared.applicationFont(size: 11)
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func configureStashSplitButton() {
        stashSplitButton.segmentCount = 2
        stashSplitButton.trackingMode = .momentary
        stashSplitButton.segmentStyle = .texturedRounded
        stashSplitButton.controlSize = .small
        stashSplitButton.target = self
        stashSplitButton.action = #selector(selectStashSegment(_:))
        stashSplitButton.setImage(AppKitFactory.resourceImage("stash", accessibilityDescription: "Manage stashes"), forSegment: 0)
        stashSplitButton.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Stash actions"), forSegment: 1)
        stashSplitButton.setWidth(23, forSegment: 0)
        stashSplitButton.setWidth(13, forSegment: 1)
        stashSplitButton.setToolTip("Manage stashes", forSegment: 0)
        stashSplitButton.setToolTip("Stash actions", forSegment: 1)
        stashSplitButton.translatesAutoresizingMaskIntoConstraints = false
        stashSplitButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let actions = ["Stash", "Stash staged", "Stash pop", "Manage stashes…", "Create a stash…"]
        for (index, title) in actions.enumerated() {
            if index == 3 { stashMenu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(stashMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = title
            stashMenu.addItem(item)
        }
    }

    private func repositoryDisplayTitle(_ repository: Repository) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard repository.path.hasPrefix(home) else { return repository.path }
        let suffix = repository.path.dropFirst(home.count)
        return suffix.isEmpty ? "~" : "~\(suffix)"
    }

    private func updatePopUpWidth(
        _ button: NSPopUpButton,
        constraint: NSLayoutConstraint?,
        title: String,
        minimum: CGFloat,
        includesLeadingImage: Bool
    ) {
        let measuringPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        measuringPopUp.controlSize = button.controlSize
        measuringPopUp.font = button.font
        measuringPopUp.bezelStyle = button.bezelStyle
        measuringPopUp.addItem(withTitle: title)
        if includesLeadingImage {
            measuringPopUp.image = button.image
            measuringPopUp.imagePosition = .imageLeading
        }
        measuringPopUp.sizeToFit()
        let imageGutter: CGFloat = includesLeadingImage ? 18 : 0
        constraint?.constant = max(minimum, ceil(measuringPopUp.frame.width) + imageGutter)
    }

    private func updateToolbarRepositoryState() {
        guard let repositoryIdentity, let repositoryReferences, let repositoryNavigation, let repositoryStatus else { return }
        let count = repositoryStatus.workingDirectoryChangeCount
        commitButton.title = AppSettingsStore.shared.browseDisplayPreferences.commitTitle(changedFiles: count)
        commitButton.image = AppKitFactory.resourceImage(
            "RepoStateClean",
            accessibilityDescription: commitButton.title
        )
        commitButton.toolTip = count == 1 ? "Commit — 1 changed file" : "Commit — \(count) changed files"

        let stashCount = repositoryNavigation.stashes.count
        let showStashCount = AppSettingsStore.shared.stashPreferences.showStashCount && !repositoryIdentity.currentRepository.isBare
        stashSplitButton.setLabel(showStashCount ? "(\(stashCount))" : "", forSegment: 0)
        stashSplitButton.setWidth(showStashCount ? CGFloat(41 + String(stashCount).count * 7) : 23, forSegment: 0)
        stashSplitButton.setToolTip(
            stashCount == 1 ? "Manage stashes — 1 stash" : "Manage stashes — \(stashCount) stashes",
            forSegment: 0
        )
        stashSplitButton.isEnabled = !repositoryIdentity.currentRepository.isBare

        guard let currentBranch = repositoryReferences.branches.first(where: \.isCurrent) else {
            pushButton.title = ""
            pushButton.image = AppKitFactory.resourceImage("Push", accessibilityDescription: "Push")
            pushButton.toolTip = "Push"
            return
        }

        pushButton.title = aheadBehindDisplay(ahead: currentBranch.ahead, behind: currentBranch.behind)
        pushButton.image = AppKitFactory.resourceImage("Push", accessibilityDescription: "Push")
        let aheadDescription = "\(currentBranch.ahead) new commit\(currentBranch.ahead == 1 ? "" : "s") will be pushed"
        let behindDescription = "\(currentBranch.behind) commit\(currentBranch.behind == 1 ? "" : "s") should be integrated"
        pushButton.toolTip = currentBranch.behind > 0 ? "\(aheadDescription)\n\(behindDescription)" : aheadDescription
    }

    private func aheadBehindDisplay(ahead: Int, behind: Int) -> String {
        if ahead == 0, behind == 0 { return "0↑↓" }
        var parts: [String] = []
        if ahead > 0 { parts.append("\(ahead)↑") }
        if behind > 0 { parts.append("\(behind)↓") }
        return parts.joined(separator: " ")
    }

    private func compactImagePopUp(_ button: NSPopUpButton, imageName: String, width: CGFloat) {
        button.controlSize = .small
        button.font = AppSettingsStore.shared.applicationFont(size: 11)
        button.bezelStyle = .texturedRounded
        let image = AppKitFactory.resourceImage(imageName, accessibilityDescription: button.titleOfSelectedItem)
        button.image = image
        button.itemArray.forEach { $0.image = image }
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        if !button.constraints.contains(where: { $0.firstAttribute == .width }) {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: width),
                button.heightAnchor.constraint(equalToConstant: 22)
            ])
        }
    }

    private func rebuildPullMenu() {
        guard isViewLoaded else { return }
        let preferences = AppSettingsStore.shared.pullPreferences
        let hasMultipleRemotes = (repositoryNavigation?.remotes.filter { !$0.isDisabled }.count ?? 0) > 1
        let menu = NSMenu(title: "Pull")

        let primary = NSMenuItem(title: "Pull", action: #selector(pullMenuCommand(_:)), keyEquivalent: "")
        primary.target = self
        BrowserCommandCenter.assign(.pull, to: primary)
        menu.addItem(primary)
        menu.addItem(.separator())

        let actions: [(String, PullActionPreference, String, BrowserCommand)] = [
            ("Open pull dialog…", .openDialog, "Pull", .openPullDialog),
            ("Pull - merge", .merge, "PullMerge", .pullMerge),
            ("Pull - rebase", .rebase, "PullRebase", .pullRebase),
            ("Fetch", .fetch, "PullFetch", .fetch),
            ("Fetch all", .fetchAll, "PullFetchAll", .fetchAll),
            ("Fetch and prune all", .fetchPruneAll, "PullFetchPruneAll", .fetchAndPruneAll)
        ]
        for (title, action, imageName, command) in actions where action != .fetchAll || hasMultipleRemotes {
            let item = NSMenuItem(title: title, action: #selector(pullMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            BrowserCommandCenter.assign(command, to: item)
            item.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: title)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let defaultItem = NSMenuItem(title: "Set default Pull button action", action: nil, keyEquivalent: "")
        let defaultMenu = NSMenu(title: defaultItem.title)
        for (title, action, imageName, _) in actions where action != .fetchAll || hasMultipleRemotes {
            let item = NSMenuItem(title: title.replacingOccurrences(of: "…", with: ""), action: #selector(setDefaultPullAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = action == preferences.defaultAction ? .on : .off
            item.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: title)
            defaultMenu.addItem(item)
        }
        defaultItem.submenu = defaultMenu
        menu.addItem(defaultItem)

        pullPopUp.menu = menu
        pullPopUp.selectItem(at: 0)
        let presentation = pullActionPresentation(preferences.defaultAction)
        let image = AppKitFactory.resourceImage(presentation.imageName, accessibilityDescription: presentation.tooltip)
        pullPopUp.image = image
        primary.image = image
        pullPopUp.imagePosition = .imageOnly
        pullPopUp.toolTip = presentation.tooltip
    }

    private func pullActionPresentation(_ action: PullActionPreference) -> (imageName: String, tooltip: String) {
        switch action {
        case .merge: return ("PullMerge", "Pull - merge")
        case .rebase: return ("PullRebase", "Pull - rebase")
        case .fetch: return ("PullFetch", "Fetch")
        case .fetchAll: return ("PullFetchAll", "Fetch all")
        case .fetchPruneAll: return ("PullFetchPruneAll", "Fetch and prune all")
        case .openDialog: return ("Pull", "Open pull dialog")
        }
    }

    private func configureFilterField(_ field: NSTextField, placeholder: String, width: CGFloat) {
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = AppSettingsStore.shared.applicationFont(size: 11)
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: width),
            field.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    private func bindInteractions() {
        revisionGridController.onRefreshRequested = { [weak self] in self?.restartRevisionReadForFilterChange() }
        revisionGridController.onFilterChanged = { [weak self] filter in
            self?.filterToolbar.filterChanged(filter)
            self?.updateWindowTitle()

            var path = filter.effectivePathFilter
            if path.count > 1, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
            if !path.trimmingCharacters(in: .whitespaces).isEmpty {
                self?.revisionDiffController.fallbackFollowedFile = path
                self?.fileTreeController.fallbackFollowedFile = path
            }
        }
        filterToolbar.grid = revisionGridController
        filterToolbar.references = { [weak self] in
            let branches = self?.repositoryReferences?.branches ?? []
            return .init(local: branches.filter { !$0.isRemote }.map(\.name),
                         remote: branches.filter(\.isRemote).map(\.name),
                         tags: self?.repositoryReferences?.tags.map(\.name) ?? [])
        }
        let gridSource = repositoryModule as? any RepositoryRevisionGridDataSource
        revisionGridController.dataSource = gridSource
        revisionGridController.referenceNames = { [weak self] in
            (self?.repositoryReferences?.branches.filter { !$0.isRemote }.map(\.name) ?? [],
             self?.repositoryReferences?.tags.map(\.name) ?? [])
        }
        filterToolbar.resolveRevision = { expression in await gridSource?.resolveRevision(expression) }
        filterToolbar.showAdvancedFilter = { [weak self] in self?.showRevisionFilterDialog() }
        filterToolbar.filterChanged(revisionGridController.currentFilter)
        revisionGridController.onSelection = { [weak self] commit in
            self?.select(commit: commit)
        }

        commitDetailController.onGoToRevision = { [weak self] id in self?.revisionGridController.goToRevision(id) }
        commitDetailController.onNavigate = { [weak self] backward in
            if backward { self?.revisionGridController.navigateBackward() } else { self?.revisionGridController.navigateForward() }
        }
        commitDetailController.source = repositoryModule as? any RepositoryCommitInfoDataSource
        outlineController.onSelection = { [weak self] node in
            self?.select(treeNode: node)
        }
        outlineController.onCommand = { [weak self] identifier, node in
            self?.performRepositoryCommand(identifier, node: node)
        }
        outlineController.selectedRevisions = { [weak self] in self?.revisionGridController.selectedCommits ?? [] }
        outlineController.onCopyRevisionValue = { [weak self] identifier in self?.revisionGridController.copyToClipboard(identifier) }
        outlineController.onScript = { [weak self] in self?.uiCommands.startScript($0) }
        outlineController.onFilterReferences = { [weak self] references in
            guard let self else { return }
            filterToolbar.setBranchFilter(references.joined(separator: " "))
        }
        revisionGridController.onCommand = { [weak self] identifier, selected, focused in
            self?.performRevisionCommand(identifier, selected: selected, focused: focused)
        }
        revisionGridController.onViewSelected = { [weak self] selected in self?.uiCommands.startViewRevisions(selected) }
        revisionGridController.onDeleteBranch = { [weak self] name in self?.uiCommands.deleteBranches(initiallySelected: [name]) }
        revisionGridController.onApplyPatch = { [weak self] url in self?.uiCommands.startPatch(.apply, file: url) }
        revisionGridController.onShowAdvancedFilter = { [weak self] in self?.showRevisionFilterDialog() }
        revisionGridController.onEmptyRepositoryCommit = { [weak self] in self?.uiCommands.startCommit() }
        revisionGridController.onEmptyRepositoryEditGitIgnore = { [weak self] in self?.uiCommands.startEditGitIgnore(localExclude: false) }
        revisionGridController.onMenuStateChanged = { [weak self] in self?.publishGridMenuState() }
        revisionDiffController.onHunkMutation = { [weak self] selection in
            self?.performHunkMutation(selection)
        }
        detailTabs.onSelectionChanged = { [weak self] _ in
            guard let self else { return }
            if let commit = revisions.first(where: { $0.id == self.selectedCommitID }) { fillCommitInfo(commit) }
            loadActiveDetailTab()
            updateOutputPanelLayout()
        }
        let source = repositoryModule
        for controller in [revisionDiffController, fileTreeController] {
            controller.fileStatusSource = source as? any RepositoryFileStatusDataSource
            controller.blameSource = source as? any RepositoryBlameDataSource
            controller.blameController.onShowChanges = { [weak self] in self?.uiCommands.startBlameCommitDiff($0) }
            controller.blameContext = .init(revisionInGrid: { [weak self] id in
                self?.revisionGridController.visibleRevision(id)
            }, selectFileInRevision: { [weak self, weak controller] id, path in
                guard let self, let controller, revisionGridController.visibleRevision(id) != nil else { return false }
                controller.selectFileOrFolder(path, requestBlame: true)
                revisionGridController.selectCommit(id: .object(id))
                return true
            }, hostedRemotes: {
                guard let manager = source as? any RepositoryRemoteManagingDataSource,
                      let remotes = try? await manager.loadRemoteConfigurations() else { return [] }
                return HostedRemote.gitHubRemotes(remotes)
            })
            controller.onBlameInFileTree = { [weak self] path, line in
                guard let self else { return }
                fileTreeController.selectFileOrFolder(path, requestBlame: true, line: line)
                if !layout.showSplitViewLayout { setShowSplitViewLayout(true) }
                selectDetailTab(fileTreeController)
            }
            controller.contentProvider = { commit, file, encoding in
                try await source.loadFilePresentation(for: commit, file: file, encoding: encoding)
            }
            controller.treeEntriesProvider = { commit in try await source.loadRepositoryFiles(for: commit) }
            controller.parentsOf = { [weak self] revision in self?.parents(of: revision) ?? [] }
            controller.onCommand = { [weak self, weak controller] command in
                guard let self, let controller else { return }
                performFileStatusCommand(command, from: controller)
            }
            controller.onFileCommand = { [weak self] identifier, item in
                self?.performFileViewerCommand(identifier, item: item)
            }
            controller.onFileHistory = { [weak self] path, revision in
                guard let self else { return }
                uiCommands.startFileHistory(file: path, revision: revisions.first { $0.id == revision })
            }
            controller.onRefreshArtificial = { [weak self] in self?.refreshArtificialRevisions() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applicationActivated() }
        }
    }

    private func observePlaceholderActions() {
        annotatedTagsObserver = NotificationCenter.default.addObserver(forName: .commitInfoAnnotatedTagsSettingChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.revisionGridController.reloadAppearance() }
        }
        historyMenuObserver = RepositoryHistoryUIService.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildWorkingDirectoryMenu() }
        }
        placeholderObserver = NotificationCenter.default.addObserver(
            forName: .browserCommand,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let command = BrowserCommandCenter.command(from: notification) else { return }
            guard let self else { return }
            if self.onApplicationCommand?(command) == true { return }
            self.performTopLevelCommand(command)
        }
    }

    func performTopLevelCommand(_ command: BrowserCommand) {
        guard view.window != nil else { return }
        switch command {
        case .openRepository: presentOpenRepositoryPanel()
        case .refresh: reloadRepositoryState()
        case .undoLastCommit: uiCommands.startUndoLastCommit()
        case .fileListCommand(let identifier):
            performFileListHotkey(identifier)
        case .addNotes:

            guard let commit = revisions.first(where: { $0.id == selectedCommitID }), !commit.isArtificial else { return }
            if commitDetailController.commit?.id != commit.id { commitDetailController.apply(commit: commit, children: commitInfoChildren) }
            commitDetailController.addNotes()
        case .openFileExplorer: uiCommands.openFileExplorer()
        case .openTerminal: uiCommands.openTerminal()
        case .deleteIndexLock: uiCommands.deleteIndexLock()
        case .compressGitDatabase: uiCommands.compressGitDatabase()
        case .editGitIgnore: uiCommands.startEditGitIgnore(localExclude: false)
        case .editGitInfoExclude: uiCommands.startEditGitIgnore(localExclude: true)
        case .editGitAttributes: uiCommands.startEditGitAttributes()
        case .editMailMap: uiCommands.startEditMailMap()
        case .editGitConfig: uiCommands.startEditGitConfig()
        case .sparseWorkingCopy: uiCommands.startSparseWorkingCopy()
        case .recoverLostObjects: uiCommands.startRecoverLostObjects()
        case .toggleLeftPanel: toggleLeftPanel()
        case .outputHistory: uiCommands.startOutputHistory()
        case .toggleSplitViewLayout: toggleSplitLayout()
        case .commitInfoPosition(let raw): setCommitInfoPosition(.init(rawValue: raw) ?? .belowList)
        case .toolbarVisibility(let name): toggleToolbar(name)
        case .toolbarItemVisibility(let key): toggleToolbarItem(key)
        case .stash: beginQuickStash()
        case .stashPop: performLatestStashPop()
        case .stashStaged: beginStashStaged()
        case .quickPull: uiCommands.startPull(action: .merge, immediately: true)
        case .quickFetch: uiCommands.startPull(action: .fetch, immediately: true)
        case .quickPullOrFetch:
            let action = AppSettingsStore.shared.pullPreferences.defaultAction
            uiCommands.startPull(action: action, immediately: action != .openDialog)
        case .quickPush: uiCommands.startPush(immediately: true)
        case .focusFilter: filterToolbar.focus(in: view.window)
        case .focusNextTab(let forward):
            let count = detailTabControllers.count
            guard count > 0 else { return }
            detailTabs.selectTab(at: (detailTabs.selectedTabIndex + (forward ? 1 : count - 1)) % count)
        case .goToSuperproject:
            if let superproject = superprojectURL { _ = onApplicationCommand?(.openRecentRepository(superproject)) }
        case .revisionGrid(let id):
            revisionGridController.performGridCommand(id)
        case .toggleRevisionTags:
            defer { publishGridMenuState() }
            var preferences = AppSettingsStore.shared.tagPreferences
            preferences.showTagsInRevisionGrid.toggle()
            AppSettingsStore.shared.saveTagPreferences(preferences)
            revisionGridController.setShowsTagReferences(preferences.showTagsInRevisionGrid)
            statusLabel.stringValue = preferences.showTagsInRevisionGrid
                ? "Showing tags in revision grid"
                : "Hiding tags in revision grid"
        case .toggleBuildStatusIcon, .toggleBuildStatusText:
            let store = AppSettingsStore.shared
            let icon = store.showBuildStatusIconColumn != (command == .toggleBuildStatusIcon)
            let text = store.showBuildStatusTextColumn != (command == .toggleBuildStatusText)
            store.saveShowBuildStatus(icon: icon, text: text)
            BrowserCommandAvailability.shared.showBuildStatusIcon = icon
            BrowserCommandAvailability.shared.showBuildStatusText = text
            revisionGridController.applyBuildStatusColumnSettings()
            publishGridMenuState()
        case .commit: uiCommands.startCommit()
        case .pullFetch: uiCommands.startPull(action: AppSettingsStore.shared.pullPreferences.formAction, immediately: false)
        case .pull: uiCommands.startPull(action: AppSettingsStore.shared.pullPreferences.defaultAction, immediately: AppSettingsStore.shared.pullPreferences.defaultAction != .openDialog)
        case .openPullDialog: uiCommands.startPull(action: AppSettingsStore.shared.pullPreferences.formAction, immediately: false)
        case .pullMerge: uiCommands.startPull(action: .merge, immediately: true)
        case .pullRebase: uiCommands.startPull(action: .rebase, immediately: true)
        case .push: uiCommands.startPush()
        case .fetch: uiCommands.startPull(action: .fetch, immediately: true)
        case .fetchAll: uiCommands.startFetchAll(prune: false)
        case .fetchAndPruneAll: uiCommands.startFetchAll(prune: true)
        case .remoteRepositories:
            uiCommands.startRemoteManagement()
        case .mergeBranches:
            guard let repositoryIdentity,
                  !repositoryIdentity.currentRepository.isBare,
                  revisionGridController.selectedCommitCount == 1,
                  let selectedCommitID,
                  revisions.contains(where: { $0.id == selectedCommitID && !$0.isArtificial })
            else {
                statusLabel.stringValue = "Select one revision before opening Merge."
                return
            }
            uiCommands.startMergeBranches(initialTarget: nil)
        case .createBranch:
            let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial })
            uiCommands.createBranch(sourceRevision: commit)
        case .deleteBranch:
            uiCommands.deleteBranches(initiallySelected: [])
        case .checkoutBranch:
            uiCommands.startCheckoutBranch(initialTarget: nil)
        case .checkoutRevision:
            guard let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial }) else { return }
            uiCommands.startCheckoutRevision(commit)
        case .createTag:
            uiCommands.startCreateTag(
                initialTarget: revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial })?.objectID
            )
        case .deleteTag:
            uiCommands.startDeleteTag()
        case .manageStashes: uiCommands.startStashManagement()
        case .resetChanges: uiCommands.startResetChanges()
        case .cleanRepository: uiCommands.startCleanRepository()
        case .bisect:
            guard repositoryIdentity?.currentRepository.isBare == false,
                  revisionGridController.selectedCommitCount == 1,
                  let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial })
            else {
                statusLabel.stringValue = "Select one revision before opening Bisect."
                return
            }
            uiCommands.startBisect([commit])
        case .reflog:
            uiCommands.startReflog()
        case .formatPatch:
            uiCommands.startPatch(.format, selected: revisions.filter { workflowRevisionSelection.contains($0.id) })
        case .archiveRevision:
            uiCommands.startArchive(selected: revisions.filter { workflowRevisionSelection.contains($0.id) })
        case .applyPatch: uiCommands.startPatch(.apply)
        case .viewPatch: uiCommands.startPatch(.view)
        case .manageWorktrees:
            uiCommands.startWorktreeManagement()
        case .manageSubmodules: uiCommands.startSubmoduleManagement()
        case .updateSubmodules: uiCommands.startSubmoduleAction(.update(path: nil))
        case .synchronizeSubmodules: uiCommands.startSubmoduleAction(.synchronize(path: nil))
        case .solveMergeConflicts: uiCommands.startConflictResolution()
        case .cherryPick:
            if let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial }) {
                uiCommands.startCherryPick([commit])
            }
        case .rebase:
            if let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial }) {
                uiCommands.startRebase(on: commit, interactive: false, showAdvancedOptions: true)
            }
        case .scripts:
            uiCommands.startScripts()
        case .plugins:
            uiCommands.startPlugins()
        case .viewHostedPullRequests:
            uiCommands.startPullRequests()
        case .createHostedPullRequest:
            uiCommands.startCreatePullRequest()
        case .addHostedUpstream:
            uiCommands.startAddHostedUpstream()
        case .executePlugin(let id):
            uiCommands.startPlugin(id)
        case .settings:
            uiCommands.startSettings()
        case .repositorySettings:
            uiCommands.startSettings(initialPage: "detailed", initialScope: .local)
        case .showStatus(let message):
            statusLabel.stringValue = message
        case .unavailable(let title):
            showPlaceholderStatus(for: title)
        default:
            break
        }
    }

    func prepareNotifierRefresh(preferredCommitID: RevisionID?) {
        notifierPreferredCommitID = preferredCommitID ?? notifierPreferredCommitID
    }

    private func reloadRepositoryState(preferredCommitID: RevisionID? = nil) {
        repositoryStateLoadTask?.cancel()
        revisionDetailsTask?.cancel()
        statusLabel.stringValue = "Loading repository…"
        repositoryStateLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await repositoryModule.loadRepositoryState()
                guard !Task.isCancelled else { return }
                apply(state: state, preferredCommitID: preferredCommitID)
            } catch is CancellationError {
                return
            } catch {
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func apply(state: RepositoryLoadState, preferredCommitID: RevisionID?) {
        commitDetailController.repositoryChanged()
        let previousRevisions = revisions
        let previousRepositoryID = repositoryIdentity?.currentRepository.id
        let sameRepository = previousRepositoryID == state.identity.currentRepository.id
        var requestedSelection = preferredCommitID ?? openingSelection.first ?? (sameRepository ? selectedCommitID : nil)

        if sameRepository, openingSelection.isEmpty, let head = state.identity.headID, head != repositoryIdentity?.headID {
            requestedSelection = .object(head)
        }
        if !sameRepository {

            revisionDiffController.repositoryChanged()
            fileTreeController.repositoryChanged()
        }
        applyRepositoryState(state)
        loadDiffTools()
        uiCommands.pluginsRepositoryLoaded()
        startRevisionRead(
            state.revisionReadRequest,
            preferredCommitID: requestedSelection,
            previousRevisions: sameRepository ? previousRevisions : []
        )
    }

    private func applyRepositoryState(_ state: RepositoryLoadState) {
        repositoryIdentity = state.identity
        repositoryReferences = state.references
        repositoryNavigation = state.navigation
        repositoryStatus = state.status
        revisionGridController.applyStatus(state.status)
        BrowserCommandAvailability.shared.canMerge = false
        BrowserCommandAvailability.shared.hasRepository = true
        BrowserCommandAvailability.shared.isBareRepository = state.identity.currentRepository.isBare
        let canManageBranches = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositoryCheckoutBranchDataSource
        BrowserCommandAvailability.shared.canCreateBranch = canManageBranches
        BrowserCommandAvailability.shared.canDeleteBranch = canManageBranches && !state.references.branches.isEmpty
        BrowserCommandAvailability.shared.canCheckoutBranch = canManageBranches
            && (!state.references.branches.isEmpty || state.navigation.remotes.contains { !$0.branches.isEmpty })
        BrowserCommandAvailability.shared.canCheckoutRevision = false
        BrowserCommandAvailability.shared.canCreateTag = repositoryModule is any RepositoryTagManagingDataSource
            && state.identity.headID != nil
        BrowserCommandAvailability.shared.canDeleteTag = repositoryModule is any RepositoryTagManagingDataSource
            && !state.references.tags.isEmpty
        BrowserCommandAvailability.shared.canReset = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositoryResettingDataSource
        BrowserCommandAvailability.shared.canClean = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositoryCleaningDataSource
        BrowserCommandAvailability.shared.canBisect = false
        BrowserCommandAvailability.shared.canReflog = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositoryReflogDataSource
        BrowserCommandAvailability.shared.canPatch = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositoryPatchingDataSource
        BrowserCommandAvailability.shared.canArchive = repositoryModule is any RepositoryArchivingDataSource
        BrowserCommandAvailability.shared.canManageWorktrees = repositoryModule is any RepositoryWorktreeManagingDataSource
        BrowserCommandAvailability.shared.canManageSubmodules = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositorySubmoduleManagingDataSource
        outlineController.apply(
            identity: state.identity,
            references: state.references,
            navigation: state.navigation
        )

        refreshToolbarNavigationState()

        branchPopUp.removeAllItems()
        branchPopUp.addItem(withTitle: "Checkout branch…")
        branchPopUp.menu?.addItem(.separator())
        state.references.branches.forEach { branchPopUp.addItem(withTitle: $0.name) }
        let branchImage = AppKitFactory.resourceImage("Branch", accessibilityDescription: "Branches")
        branchPopUp.itemArray.filter { !$0.isSeparatorItem }.forEach { $0.image = branchImage }
        if let current = state.references.branches.first(where: \.isCurrent) {
            branchPopUp.selectItem(withTitle: current.name)
        }
        updatePopUpWidth(
            branchPopUp,
            constraint: branchWidthConstraint,
            title: branchPopUp.titleOfSelectedItem ?? "Branch",
            minimum: 60,
            includesLeadingImage: true
        )
        updateToolbarRepositoryState()
        rebuildPullMenu()

        statusLabel.stringValue = "Ready"
        let revisionCount = revisions.filter { !$0.isArtificial }.count
        let branchState = state.references.branches.first(where: \.isCurrent).map { branch in
            let counts = AppSettingsStore.shared.browseDisplayPreferences.branchCounts(ahead: branch.ahead, behind: branch.behind)
            return "   \(branch.name)\(counts)"
        } ?? "   Detached HEAD"
        repositoryStateLabel.stringValue = "\(revisionCount) revisions\(branchState)"
        updateWindowTitle()
        refreshOperationIndicators()
        setInitialDividerPositionsIfNeeded()
    }

    private func startRevisionRead(
        _ request: RevisionReadRequest,
        preferredCommitID: RevisionID?,
        previousRevisions: [Commit]? = nil
    ) {
        revisionReadTask?.cancel()
        let oldRevisions = previousRevisions ?? revisions
        revisions = []
        revisionGridController.resetNavigationHistory()
        revisionGridController.beginIncrementalLoad(preferredCommitID: preferredCommitID)
        revisionGridController.showLoading(spinner: true)
        loadGridLabelContext()
        publishGridMenuState()
        activeRevisionReader = request.reader
        revisionReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await request.reader.cancel()
                var options = revisionGridController.readOptions
                if fileHistory != nil { options.followRenamesExactOnly = AppSettingsStore.shared.revisionGridPreferences.followRenamesInFileHistoryExactOnly }
                let context = request.context.with(options)
                let batches = await request.reader.read(context, maximumCount: AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount)
                for try await batch in batches {
                    guard !Task.isCancelled, activeRevisionReader === request.reader else { return }
                    revisions.append(contentsOf: batch)
                    revisionGridController.appendIncrementalBatch(batch)
                    outlineController.updateRevisionState(
                        revisions: revisions,
                        selectedRevisionID: selectedCommitID
                    )
                    updateRevisionCount()
                }
                guard !Task.isCancelled, activeRevisionReader === request.reader else { return }
                revisionGridController.finishLoading(isBareRepository: repositoryIdentity?.currentRepository.isBare ?? false)
                var restored = RevisionSelectionRestorer.restoredID(
                    requestedID: preferredCommitID,
                    previousCommits: oldRevisions,
                    refreshedCommits: revisions
                )

                if let requested = preferredCommitID?.objectID, !revisions.contains(where: { $0.id == preferredCommitID }),
                   let gridSource = repositoryModule as? any RepositoryRevisionGridDataSource {
                    let listed = Set(revisions.map(\.id))
                    let ancestors = await gridSource.ancestors(of: requested)
                    guard !Task.isCancelled, activeRevisionReader === request.reader else { return }
                    if let ancestor = ancestors.first(where: { listed.contains(.object($0)) }) { restored = .object(ancestor) }
                }
                if let restored, !revisionGridController.userSelectedDuringLoad { revisionGridController.selectCommit(id: restored) }
                if !openingSelection.isEmpty {
                    revisionGridController.selectCommits(ids: openingSelection)
                    openingSelection = []
                }
                launchBuildServerWatcher()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                revisionGridController.finishLoading(failed: true)
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func updateRevisionCount() {
        guard let repositoryReferences else { return }
        let revisionCount = revisions.filter { !$0.isArtificial }.count
        let branchState = repositoryReferences.branches.first(where: \.isCurrent).map { branch in
            let counts = AppSettingsStore.shared.browseDisplayPreferences.branchCounts(ahead: branch.ahead, behind: branch.behind)
            return "   \(branch.name)\(counts)"
        } ?? "   Detached HEAD"
        repositoryStateLabel.stringValue = "\(revisionCount) revisions\(branchState)"
    }

    private func select(commit: Commit) {
        guard let repositoryIdentity else { return }
        selectedCommitID = commit.id
        outlineController.updateRevisionState(revisions: revisions, selectedRevisionID: commit.id)
        BrowserCommandAvailability.shared.canMerge = !commit.isArtificial
            && !repositoryIdentity.currentRepository.isBare
            && revisionGridController.selectedCommitCount == 1
            && repositoryModule is any RepositoryMergingDataSource
        BrowserCommandAvailability.shared.canCheckoutRevision = !commit.isArtificial
            && !repositoryIdentity.currentRepository.isBare
            && revisionGridController.selectedCommitCount == 1
            && repositoryModule is any RepositoryCheckoutBranchDataSource
        BrowserCommandAvailability.shared.canBisect = !commit.isArtificial
            && !repositoryIdentity.currentRepository.isBare
            && revisionGridController.selectedCommitCount == 1
            && repositoryModule is any RepositoryBisectingDataSource
        BrowserCommandAvailability.shared.selectionEligibility = .make(
            selected: revisionGridController.selectedCommits.isEmpty ? [commit] : revisionGridController.selectedCommits,
            isBare: repositoryIdentity.currentRepository.isBare)
        revisionDetailsTask?.cancel()
        let relations = CommitRelationsResolver.resolve(commit: commit, history: revisions)
        commitInfoChildren = relations.childIDs
        commitInfoFilledFor = nil
        fillCommitInfo(commit)
        gpgController.apply(commit: commit, info: nil)
        statusLabel.stringValue = commit.isArtificial ? "Selected \(commit.subject)" : "Selected \(commit.shortID): \(commit.subject)"
        updateBuildReportTab()

        loadActiveDetailTab(commit: commit)
    }


    private func fillCommitInfo(_ commit: Commit) {
        guard layout.commitInfoPosition != .belowList || selectedDetailController === commitDetailController else { return }
        guard commitInfoFilledFor != commit.id else { return }
        commitInfoFilledFor = commit.id
        commitDetailController.apply(commit: commit, children: commitInfoChildren)
        loadRevisionLinks(for: commit)
    }

    private func loadRevisionLinks(for commit: Commit) {
        revisionLinksTask?.cancel()
        guard let objectID = commit.id.objectID else { return }
        revisionLinksTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var definitions = try RevisionLinkDefinition.decode(AppSettingsStore.shared.revisionLinksXML)
                var remotes: [RevisionLinkDefinition.RemoteInput] = []
                if let source = repositoryModule as? any RepositorySettingsDataSource {
                    let locations = try await DistributedSettings.loadLocations(from: source)
                    definitions = try RevisionLinkDefinition.decode(DistributedSettings.read(locations.localURL)[RevisionLinkDefinition.settingKey])
                        + RevisionLinkDefinition.decode(DistributedSettings.read(locations.distributedURL)[RevisionLinkDefinition.settingKey]) + definitions
                    if definitions.contains(where: { $0.enabled && !$0.remoteSearchPattern.isEmpty }) {
                        let config = try await source.loadGitSettings(.effective)
                        remotes = config.keys.filter { $0.hasPrefix("remote.") && $0.hasSuffix(".url") }.sorted().map { key in
                            let name = String(key.dropFirst(7).dropLast(4))
                            return .init(name: name, url: config[key]?.last ?? "", pushURL: config["remote.\(name).pushurl"]?.last ?? "")
                        }
                    }
                }
                try Task.checkCancellation()
                guard selectedCommitID == commit.id else { return }
                let links = definitions.flatMap {
                    $0.links(commitID: objectID, message: commit.subject + "\n\n" + commit.body,
                             localRefs: commit.references.filter { $0.kind != .remoteBranch }.map(\.localName),
                             remoteRefs: commit.references.filter { $0.kind == .remoteBranch }.map(\.localName), remotes: remotes)
                }
                commitDetailController.applyExternalLinks(links)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, selectedCommitID == commit.id else { return }
                commitDetailController.applyExternalLinks([], error: error.localizedDescription)
            }
        }
    }

    private func loadActiveDetailTab(commit: Commit? = nil) {
        guard repositoryIdentity != nil else { return }
        guard let activeCommit = commit ?? revisions.first(where: { $0.id == selectedCommitID }) else { return }

        revisionDetailsTask?.cancel()
        if fileHistory != nil, let reader = activeRevisionReader,
           let id = activeCommit.objectID ?? repositoryIdentity?.headID,
           !revisionGridController.currentFilter.effectivePathFilter.isEmpty {
            var path = revisionGridController.currentFilter.effectivePathFilter
            if path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            revisionDetailsTask = Task { @MainActor [weak self] in
                let historicalPath = await reader.fileName(at: id, path: path, exactOnly: AppSettingsStore.shared.revisionGridPreferences.followRenamesInFileHistoryExactOnly)
                guard let self, !Task.isCancelled, selectedCommitID == activeCommit.id, activeRevisionReader === reader else { return }
                revisionDiffController.fallbackFollowedFile = historicalPath
                fileTreeController.fallbackFollowedFile = historicalPath
                fillFileStatusTab(activeCommit)
            }
            return
        }
        fillFileStatusTab(activeCommit)
    }

    private func fillFileStatusTab(_ activeCommit: Commit) {
        switch selectedDetailController {
        case let controller? where controller === revisionDiffController:

            let selected = revisionGridController.selectedRevisionIDsBySelectionOrder.compactMap { id in revisions.first { $0.id == id } }
            let ordered = [activeCommit] + selected.filter { $0.id != activeCommit.id }
            configureFileStatusController(revisionDiffController)
            revisionDiffController.setDiffs(revisions: ordered, headID: repositoryIdentity?.headID)
        case let controller? where controller === fileTreeController:

            configureFileStatusController(fileTreeController)
            fileTreeController.setDiffs(revisions: [activeCommit], headID: repositoryIdentity?.headID)
        default:
            break
        }
    }

    private func select(treeNode node: RepositoryTreeNode) {
        switch node.kind {
        case .branch(let branch), .remoteBranch(let branch):
            revisionGridController.selectCommit(id: .object(branch.commitID))
            statusLabel.stringValue = "Selected \(branch.isRemote ? "remote " : "")branch \(branch.name)"
        case .tag(let tag):
            revisionGridController.selectCommit(id: .object(tag.commitID))
            statusLabel.stringValue = "Selected tag \(tag.name)"
        case .stash(let stash):
            revisionGridController.selectCommit(id: .object(stash.commitID))
            statusLabel.stringValue = "Selected \(stash.selector)"
        case .worktree(let worktree):
            statusLabel.stringValue = "Worktree: \(worktree.path)"
            if let id = worktree.headID { revisionGridController.selectCommit(id: .object(id)) }
        case .remote(let remote):
            statusLabel.stringValue = "Remote \(remote.name): \(remote.fetchURL)"
        case .submodule(let submodule):
            statusLabel.stringValue = SubmoduleTreePresentation.toolTip(submodule).components(separatedBy: "\n").first ?? submodule.path
        case .group, .folder, .tagFolder:
            statusLabel.stringValue = node.title
        }
    }

    private func presentOpenRepositoryPanel() {
        guard repositoryModule is any RepositoryOpeningDataSource else {
            showPlaceholderStatus(for: "Open repository is unavailable for mock data")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Open repository"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK,
                  let self,
                  let url = panel.url,
                  let openingSource = repositoryModule as? any RepositoryOpeningDataSource
            else { return }

            repositoryStateLoadTask?.cancel()
            revisionDetailsTask?.cancel()
            statusLabel.stringValue = "Opening \(url.path)…"
            repositoryStateLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let loaded = try await openingSource.openRepository(at: url)
                    guard !Task.isCancelled else { return }
                    apply(state: loaded, preferredCommitID: nil)
                } catch is CancellationError {
                    return
                } catch {
                    statusLabel.stringValue = error.localizedDescription
                }
            }
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func configureWindowSizing() {
        guard let window = view.window else { return }

        if configuredWindow !== window {
            if let windowScreenObserver {
                NotificationCenter.default.removeObserver(windowScreenObserver)
            }
            configuredWindow = window
            windowScreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.updateWindowMaximum(for: window)
            }
        }

        window.contentMinSize = .zero
        window.minSize = NSSize(width: Self.minimumWindowWidth, height: Self.minimumWindowHeight)
        updateWindowMaximum(for: window)
    }

    private func updateWindowMaximum(for window: NSWindow) {
        guard let visibleFrame = window.screen?.visibleFrame else { return }
        window.maxSize = visibleFrame.size

        guard window.frame.width > visibleFrame.width || window.frame.height > visibleFrame.height else { return }
        var fittedFrame = window.frame
        fittedFrame.size.width = min(fittedFrame.width, visibleFrame.width)
        fittedFrame.size.height = min(fittedFrame.height, visibleFrame.height)
        fittedFrame.origin.x = min(max(fittedFrame.minX, visibleFrame.minX), visibleFrame.maxX - fittedFrame.width)
        fittedFrame.origin.y = min(max(fittedFrame.minY, visibleFrame.minY), visibleFrame.maxY - fittedFrame.height)
        window.setFrame(fittedFrame, display: true)
    }


    private func setInitialDividerPositionsIfNeeded() {
        guard !didSetInitialDividerPositions,
              mainSplitController.view.bounds.width > 400,
              rightSplitController.view.bounds.height > 200 else { return }
        didSetInitialDividerPositions = true
        if let fileHistory {
            fileHistoryLeftPanelStartupState = mainSplitController.isCollapsed(leftSplitItem)
            mainSplitController.setCollapsed(true, for: leftSplitItem)
            revisionDiffController.fallbackFollowedFile = fileHistory.path
            fileTreeController.fallbackFollowedFile = fileHistory.path
        }
        if !restoreSplitter(("MainSplitContainer", mainSplitController)) { mainSplitController.setRetainedPosition(260) }
        if outputHistoryEnabled && !outputTabEnabled {
            if !restoreSplitter(("OutputHistorySplitContainer", leftPanelSplitController)) {
                leftPanelSplitController.setRetainedPosition(max(80, leftPanelSplitController.primaryLength - 160))
            }
        }
        if !restoreSplitter(("RightSplitContainer", rightSplitController)) {
            rightSplitController.setRetainedPosition(rightSplitController.splitView.bounds.height * (209.0 / 502.0))
        }
        restoreSplitter(("RevisionsSplitContainer.\(layout.commitInfoPosition.rawValue)", revisionsSplitController))
    }

    @discardableResult
    private func restoreSplitter(_ splitter: (String, RetainingSplitViewController)) -> Bool {
        let (name, controller) = splitter
        guard let distance = BrowserLayoutPreferences.restoredDistance(layout.splitters[name], size: Double(controller.primaryLength),
                                                                       fixed: controller.resizeBehavior),
              distance > 0, distance < Double(controller.primaryLength) else { return false }
        controller.setRetainedPosition(CGFloat(distance))
        return true
    }

    @objc private func refresh() {
        reloadRepositoryState()
    }

    @objc func toggleLeftPanel() {
        let willShowLeftPanel = mainSplitController.isCollapsed(leftSplitItem)
        mainSplitController.setCollapsed(!willShowLeftPanel, for: leftSplitItem)
        refreshLayoutToggleButtonStates()
        saveLayout()
    }


    @objc func toggleSplitLayout() {
        setShowSplitViewLayout(!layout.showSplitViewLayout)
    }


    @objc private func cycleCommitInfoPosition() {
        let next = (layout.commitInfoPosition.rawValue + 1) % BrowserLayoutPreferences.CommitInfoPosition.allCases.count
        setCommitInfoPosition(.init(rawValue: next) ?? .belowList)
    }

    @objc private func showCommitInfoPositionMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, item) in Self.commitPositionItems.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(chooseCommitInfoPosition(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.image = AppKitFactory.resourceImage(item.image, accessibilityDescription: item.title)
            menuItem.state = index == layout.commitInfoPosition.rawValue ? .on : .off
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func chooseCommitInfoPosition(_ sender: NSMenuItem) {
        setCommitInfoPosition(.init(rawValue: sender.tag) ?? .belowList)
    }


    @objc private func selectWorkingDirectory() {}

    @objc private func selectBranch() {
        guard let repositoryReferences,
              let title = branchPopUp.titleOfSelectedItem else { return }
        if title == "Checkout branch…" {
            if let current = repositoryReferences.branches.first(where: \.isCurrent) {
                branchPopUp.selectItem(withTitle: current.name)
            }
            uiCommands.startCheckoutBranch(initialTarget: nil)
            return
        }
        guard
              let branch = repositoryReferences.branches.first(where: { $0.name == title }) else { return }
        guard !branch.isCurrent else { return }
        uiCommands.checkout(.local(branch))
    }

    @objc private func selectPullAction() {
        let command = BrowserCommandCenter.command(from: pullPopUp.selectedItem) ?? .pull
        pullPopUp.selectItem(at: 0)
        performTopLevelCommand(command)
    }

    @objc private func pullMenuCommand(_ sender: NSMenuItem) {
        pullPopUp.selectItem(at: 0)
        performTopLevelCommand(BrowserCommandCenter.command(from: sender) ?? .pull)
    }

    @objc private func setDefaultPullAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = PullActionPreference(rawValue: raw) else { return }
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.defaultAction = action
        AppSettingsStore.shared.savePullPreferences(preferences)
        rebuildPullMenu()
    }

    @objc private func selectStashSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            uiCommands.startStashManagement()
        } else if sender.selectedSegment == 1 {
            stashMenu.popUp(
                positioning: nil,
                at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY),
                in: sender
            )
        }
    }

    @objc private func stashMenuCommand(_ sender: NSMenuItem) {
        let selectedAction = sender.representedObject as? String ?? sender.title
        switch selectedAction {
        case "Stash":
            beginQuickStash()
        case "Create a stash…":
            uiCommands.startStashManagement(manageStashes: false)
        case "Stash staged":
            beginStashStaged()
        case "Stash pop":
            performLatestStashPop()
        case "Manage stashes…":
            uiCommands.startStashManagement()
        default:
            showPlaceholderStatus(for: selectedAction)
        }
    }

    @objc private func commitToolbarButton(_ sender: NSButton) {
        uiCommands.startCommit(initialMode: .normal)
    }

    @objc private func pushToolbarButton(_ sender: NSButton) {
        uiCommands.startPush(immediately: NSEvent.modifierFlags.contains(.shift))
    }

    @objc private func fileExplorerToolbar(_ sender: NSButton) { uiCommands.openFileExplorer() }




    private static let pullShortcutButtons: [(String, String, String, BrowserCommand)] = [
        ("pull_shortcut_fetchToolStripMenuItem", "Fetch", "PullFetch", .fetch),
        ("pull_shortcut_fetchAllToolStripMenuItem", "Fetch all", "PullFetchAll", .fetchAll),
        ("pull_shortcut_fetchPruneAllToolStripMenuItem", "Fetch and prune all", "PullFetchPruneAll", .fetchAndPruneAll),
        ("pull_shortcut_mergeToolStripMenuItem", "Pull - merge", "PullMerge", .pullMerge),
        ("pull_shortcut_rebaseToolStripMenuItem1", "Pull - rebase", "PullRebase", .pullRebase),
        ("pull_shortcut_pullToolStripMenuItem1", "Open pull dialog...", "Pull", .openPullDialog)
    ]
    private var pullShortcutViews: [String: NSView] = [:]
    private var standardToolbarViews: [NSView] = []
    private var filtersToolbarViews: [NSView] = []
    private var scriptsToolbarViews: [NSView] = []
    private var toolbarVisible: [String: Bool] = ["Standard": true, "Filters": true, "Scripts": true]

    private var toolbarItems: [(toolbar: String, key: String, title: String, views: [NSView], defaultVisible: Bool)] = []

    @objc private func pullShortcutButton(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let command = Self.pullShortcutButtons.first(where: { $0.0 == key })?.3 else { return }
        performTopLevelCommand(command)
    }

    private func registerToolbarItems(scripts: NSView) {
        func view(_ tooltip: String) -> [NSView] {
            standardToolbarViews.filter { $0.toolTip == tooltip }
        }
        var items: [(String, String, String, [NSView], Bool)] = [
            ("Standard", "RefreshButton", "Refresh", view("Refresh"), true),
            ("Standard", "toggleLeftPanel", "Toggle left panel", [toggleLeftPanelButton], true),
            ("Standard", "toggleSplitViewLayout", "Toggle split view layout", [toggleSplitViewButton], true),
            ("Standard", "menuCommitInfoPosition", "Commit info position", [commitPositionButton] + view("Commit info position"), true),
            ("Standard", "toolStripButtonLevelUp", "Submodules", [levelUpButton] + view("Navigate submodules and superprojects"), true),
            ("Standard", "toolStripWorktrees", "Worktrees", [worktreeButton, worktreeDropdownButton], true),
            ("Standard", "_NO_TRANSLATE_WorkingDir", "Change working directory", [workingDirectoryPopUp], true),
            ("Standard", "branchSelect", "Change current branch", [branchPopUp], true)
        ]
        items += Self.pullShortcutButtons.map { ("Standard", $0.0, $0.1, [pullShortcutViews[$0.0]].compactMap { $0 }, false) }
        items += [
            ("Standard", "toolStripButtonPull", "Pull", [pullPopUp], true),
            ("Standard", "toolStripButtonPush", "Push", [pushButton], true),
            ("Standard", "toolStripButtonCommit", "Commit", [commitButton], true),
            ("Standard", "toolStripSplitStash", "Manage stashes", [stashSplitButton], true),
            ("Standard", "toolStripFileExplorer", "File Explorer", view("File Explorer (Finder)"), true),
            ("Standard", "userShell", "Git bash", view("Terminal"), true),
            ("Standard", "EditSettings", "Settings", view("Settings"), true)
        ]
        items += filterToolbar.customizableItems.map { ("Filters", $0.key, $0.title, $0.views, true) }
        items.append(("Scripts", "Scripts", "Scripts", [scripts], true))
        toolbarItems = items.map { (toolbar: $0.0, key: $0.1, title: $0.2, views: $0.3, defaultVisible: $0.4) }
        applyToolbarVisibility()
    }

    private func isToolbarItemVisible(_ key: String) -> Bool {
        layout.toolbarItemVisibility[key] ?? (toolbarItems.first { $0.key == key }?.defaultVisible ?? true)
    }

    private func applyToolbarVisibility() {
        for item in toolbarItems {
            let visible = (toolbarVisible[item.toolbar] ?? true) && isToolbarItemVisible(item.key)
            item.views.forEach { $0.isHidden = !visible }
        }
        refreshToolbarNavigationStateVisibility()
        BrowserCommandAvailability.shared.toolbars = ["Standard", "Filters", "Scripts"].map { toolbar in
            BrowserToolbarState(id: toolbar, isVisible: toolbarVisible[toolbar] ?? true,
                                items: toolbarItems.filter { $0.toolbar == toolbar }
                                    .map { .init(id: $0.key, title: $0.title, isVisible: isToolbarItemVisible($0.key)) })
        }
    }


    private func toggleToolbar(_ name: String) {
        toolbarVisible[name] = !(toolbarVisible[name] ?? true)
        applyToolbarVisibility()
    }


    private func toggleToolbarItem(_ key: String) {
        guard let item = toolbarItems.first(where: { $0.key == key }) else { return }
        let visible = !isToolbarItemVisible(key)
        layout.toolbarItemVisibility[key] = visible == item.defaultVisible ? nil : visible
        AppSettingsStore.shared.saveBrowserLayoutPreferences(layout)
        applyToolbarVisibility()
    }
    @objc private func terminalToolbar(_ sender: NSButton) { uiCommands.openTerminal() }


    @objc private func levelUpToolbar() {
        if let superproject = superprojectURL {
            _ = onApplicationCommand?(.openRecentRepository(superproject))
        } else {
            showSubmodulesMenu(levelUpButton)
        }
    }

    private var superprojectURL: URL? {
        guard let current = repositoryNavigation?.submoduleTree.first(where: \.isCurrent), !current.isTop else { return nil }
        return current.parentURL
    }


    private func refreshToolbarNavigationState() {
        let inSubmodule = superprojectURL != nil
        levelUpButton.image = AppKitFactory.resourceImage(inSubmodule ? "NavigateUp" : "SubmodulesManage",
                                                          accessibilityDescription: inSubmodule ? "Go to superproject" : "Submodules")
        levelUpButton.toolTip = inSubmodule ? "Go to superproject" : "Submodules"
        levelUpButton.isEnabled = !(repositoryIdentity?.currentRepository.isBare ?? true)
        refreshToolbarNavigationStateVisibility()
        rebuildWorkingDirectoryMenu()
    }


    private func refreshToolbarNavigationStateVisibility() {
        let showsWorktrees = (repositoryNavigation?.worktrees.count ?? 0) > 1
            && (toolbarVisible["Standard"] ?? true) && isToolbarItemVisible("toolStripWorktrees")
        worktreeButton.isHidden = !showsWorktrees
        worktreeDropdownButton.isHidden = !showsWorktrees
    }


    private func rebuildWorkingDirectoryMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let path = repositoryIdentity?.currentRepository.path

        var caption = "No working directory"
        if let path {
            let settings = AppSettingsStore.shared.recentRepositorySettings
            let history = RepositoryHistory.addAsMostRecent(path, to: AppSettingsStore.shared.recentRepositories)
            let split = RecentRepoSplitter(settings: settings, measure: RepositoryHistoryUIService.menuMeasure).split(history)
            let info = (split.top + split.recent).first { RepositoryHistory.samePath($0.repo.path, path) }
            caption = RepositoryHistory.displayPath(info?.caption ?? path)
        }
        menu.addItem(withTitle: caption, action: nil, keyEquivalent: "")
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        search.placeholderString = "Search repositories..."
        search.target = self
        search.action = #selector(filterWorkingDirectoryMenu(_:))
        let searchItem = NSMenuItem()
        searchItem.view = search
        menu.addItem(searchItem)
        menu.addItem(.separator())
        let service = RepositoryHistoryUIService.shared
        service.reload()
        func historyItem(_ item: RepositoryHistoryUIService.MenuItem) -> NSMenuItem {
            let menuItem = NSMenuItem(title: item.title, action: #selector(openWorkingDirectoryItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.path
            menuItem.toolTip = item.toolTip
            if let branch = item.branch, #available(macOS 14.4, *) { menuItem.subtitle = branch }
            if item.anchored { menuItem.image = AppKitFactory.resourceImage("Pin", accessibilityDescription: "Pinned") }
            menuItem.tag = 1
            return menuItem
        }
        if !service.favourites.isEmpty {
            let favourites = NSMenuItem(title: "Favorite repositories", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for category in service.favourites {
                let categoryItem = NSMenuItem(title: category.id, action: nil, keyEquivalent: "")
                categoryItem.submenu = NSMenu()
                category.items.forEach { categoryItem.submenu?.addItem(historyItem($0)) }
                submenu.addItem(categoryItem)
            }
            favourites.submenu = submenu
            menu.addItem(favourites)
        }
        service.pinned.forEach { menu.addItem(historyItem($0)) }
        if !service.recent.isEmpty {
            if !service.pinned.isEmpty { menu.addItem(.separator()) }
            service.recent.forEach { menu.addItem(historyItem($0)) }
        }
        menu.addItem(.separator())
        for (title, command) in [("Open...", BrowserCommand.openRepository), ("Close (go to Dashboard)", .closeToDashboard)] {
            let item = NSMenuItem(title: title, action: #selector(workingDirectoryCommand(_:)), keyEquivalent: "")
            item.target = self
            BrowserCommandCenter.assign(command, to: item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let configure = menu.addItem(withTitle: "Configure this menu...", action: #selector(configureWorkingDirectoryMenu), keyEquivalent: "")
        configure.target = self
        workingDirectoryPopUp.menu = menu
        workingDirectoryPopUp.toolTip = """
            Change working directory
            Left click opens the drop-down menu.
            Then hold Command (or Control) in order to open the selected repository in a new instance.
            """
        updatePopUpWidth(workingDirectoryPopUp, constraint: workingDirectoryWidthConstraint, title: caption, minimum: 83, includesLeadingImage: false)
    }

    @objc private func configureWorkingDirectoryMenu() {
        guard let window = view.window else { return }
        RecentRepositoriesSettingsDialog.present(owner: window) { [weak self] _ in self?.rebuildWorkingDirectoryMenu() }
    }

    @objc private func filterWorkingDirectoryMenu(_ sender: NSSearchField) {
        let text = sender.stringValue
        for item in workingDirectoryPopUp.menu?.items ?? [] where item.tag == 1 {
            item.isHidden = !text.isEmpty && !item.title.localizedCaseInsensitiveContains(text)
        }
    }

    @objc private func openWorkingDirectoryItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let modifiers = NSEvent.modifierFlags
        guard modifiers.contains(.command) || modifiers.contains(.control) || path != repositoryIdentity?.currentRepository.path else { return }
        RepositoryHistoryUIService.shared.open(path, owner: view.window)
    }

    @objc private func workingDirectoryCommand(_ sender: NSMenuItem) {
        guard let command = BrowserCommandCenter.command(from: sender) else { return }
        if onApplicationCommand?(command) == true { return }
        performTopLevelCommand(command)
    }

    @objc private func settingsToolbarButton(_ sender: NSButton) {
        performTopLevelCommand(.settings)
    }

    @objc private func placeholderPopUp(_ sender: NSPopUpButton) {
        showPlaceholderStatus(for: sender.titleOfSelectedItem ?? "Option")
    }


    func showRevisionFilterDialog() {
        guard let window = view.window else { return }
        RevisionFilterDialogController.present(filter: revisionGridController.currentFilter,
            defaultLimit: AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount, window: window) { [weak self] result in
            guard let result else { return }
            self?.revisionGridController.updateFilter { $0 = result }
        }
    }


    private func loadGridLabelContext() {
        labelContextTask?.cancel()
        let gridSource = repositoryModule as? any RepositoryRevisionGridDataSource
        let remoteSource = repositoryModule as? any RepositoryRemoteManagingDataSource
        labelContextTask = Task { @MainActor [weak self] in
            let preferences = AppSettingsStore.shared.revisionGridPreferences
            var context = RevisionLabelContext()
            if AppSettingsStore.shared.browseDisplayPreferences.showAheadBehind {
                context.aheadBehindByLocal = await gridSource?.aheadBehindData() ?? [:]
            }
            context.superproject = await gridSource?.superprojectInfo(branches: preferences.showSuperprojectBranches,
                                                                      remoteBranches: preferences.showSuperprojectRemoteBranches,
                                                                      tags: preferences.showSuperprojectTags)
            for remote in (try? await remoteSource?.loadRemoteConfigurations()) ?? [] where !remote.isDisabled {
                if let color = remote.color.flatMap(NSColor.init(hexString:)) { context.remoteColors[remote.name] = color }
                if let prefix = remote.prefix, !prefix.isEmpty { context.remotePrefixes[remote.name] = prefix }
            }
            guard !Task.isCancelled, let self else { return }
            revisionGridController.labelContext = context
        }
    }


    func publishGridMenuState() {
        BrowserCommandAvailability.shared.gridMenuState = revisionGridController.menuState
    }

    private func restartRevisionReadForFilterChange() {
        revisionReadTask?.cancel()
        revisionReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try await repositoryModule.revisionReadRequest()
                guard !Task.isCancelled else { return }
                startRevisionRead(request, preferredCommitID: selectedCommitID)
            } catch is CancellationError {
                return
            } catch {
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func showPlaceholderStatus(for title: String) {
        statusLabel.stringValue = "\(title) — not implemented"
    }

    @objc private func manageWorktreesToolbar(_ sender: NSButton) { uiCommands.startWorktreeManagement() }

    @objc private func showWorktreesMenu(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for worktree in repositoryNavigation?.worktrees ?? [] {
            let item = NSMenuItem(title: worktree.displayName(worktree.name), action: #selector(openToolbarWorktree(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = worktree.path
            item.state = worktree.isCurrent ? .on : .off; item.isEnabled = worktree.canOpen
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, selector) in [("Create worktree…", #selector(createToolbarWorktree)), ("Prune worktrees", #selector(pruneToolbarWorktrees)), ("Manage worktrees…", #selector(manageToolbarWorktrees))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func openToolbarWorktree(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let worktree = repositoryNavigation?.worktrees.first(where: { $0.path == path }) else { return }
        uiCommands.startOpenWorktree(worktree, confirm: false)
    }
    @objc private func createToolbarWorktree() { uiCommands.startCreateWorktree() }
    @objc private func pruneToolbarWorktrees() { uiCommands.startPruneWorktrees() }
    @objc private func manageToolbarWorktrees() { uiCommands.startWorktreeManagement() }
    @objc private func manageSubmodulesToolbar() { uiCommands.startSubmoduleManagement() }

    @objc private func showSubmodulesMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let preferences = AppSettingsStore.shared.browseDisplayPreferences
        let showsStatus = preferences.showSubmoduleStatus
            && (preferences.showChangedFilesOnCommitButton || preferences.showArtificialRevisionCounts)
        for item in repositoryNavigation?.submoduleTree ?? [] {
            let action = NSMenuItem(title: SubmoduleTreePresentation.menuTitle(item, showsStatus: showsStatus), action: #selector(openSubmoduleMenuItem(_:)), keyEquivalent: "")
            action.target = self
            action.representedObject = item
            action.isEnabled = item.isInitialized
            action.state = item.isCurrent ? .on : .off
            action.image = AppKitFactory.resourceImage(showsStatus ? SubmoduleTreePresentation.icon(item) : "FolderSubmodule", accessibilityDescription: action.title)
            action.toolTip = showsStatus ? SubmoduleTreePresentation.toolTip(item) : item.repositoryURL.path
            menu.addItem(action)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No submodules", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func openSubmoduleMenuItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SubmoduleTreeItem else { return }
        uiCommands.startOpenSubmodule(item, newWindow: item.isCurrent)
    }



    private func refRevision(_ id: ObjectID, label: String) -> Commit {
        revisions.first { $0.id == .object(id) } ?? RevisionCommitBuilder.placeholderRevision(id: id, subject: label)
    }

    private func performRepositoryCommand(_ identifier: String, node: RepositoryTreeNode) {
        switch identifier {
        case "repository.submodules.manage": uiCommands.startSubmoduleManagement(); return
        case "repository.submodules.update": uiCommands.startSubmoduleAction(.update(path: nil)); return
        case "repository.submodules.synchronize": uiCommands.startSubmoduleAction(.synchronize(path: nil)); return
        case "repository.submodule.update":
            if case .submodule(let item) = node.kind { uiCommands.startSubmoduleTreeUpdate(item) }; return
        case "repository.submodule.open":
            if case .submodule(let item) = node.kind { uiCommands.startOpenSubmodule(item) }; return
        case "repository.submodule.openGE":
            if case .submodule(let item) = node.kind { uiCommands.startOpenSubmodule(item, newWindow: true) }; return
        case "repository.submodule.reset":
            if case .submodule(let item) = node.kind { uiCommands.startSubmoduleChildAction(.reset, submodule: item) }; return
        case "repository.submodule.stash":
            if case .submodule(let item) = node.kind { uiCommands.startSubmoduleChildAction(.stash, submodule: item) }; return
        case "repository.submodule.commit":
            if case .submodule(let item) = node.kind { uiCommands.startSubmoduleChildAction(.commit, submodule: item) }; return
        case "repository.worktrees.create": uiCommands.startCreateWorktree(); return
        case "repository.worktrees.prune": uiCommands.startPruneWorktrees(); return
        case "repository.worktrees.manage": uiCommands.startWorktreeManagement(); return
        case "repository.worktree.open":
            if case .worktree(let item) = node.kind { uiCommands.startOpenWorktree(item) }; return
        case "repository.worktree.delete":
            if case .worktree(let item) = node.kind { uiCommands.startDeleteWorktree(item) }; return
        default: break
        }
        switch (identifier, node.kind) {
        case ("repository.branch.checkout", .branch(let branch)):
            uiCommands.checkout(.local(branch), confirmDirectCheckout: true)
        case ("repository.branch.create", .branch(let branch)):
            let commit = refRevision(branch.commitID, label: branch.name)
            uiCommands.createBranch(sourceRevision: commit)
        case ("repository.branch.rename", .branch(let branch)):
            uiCommands.renameBranch(branch.name)
        case ("repository.branch.delete", .branch(let branch)):
            guard !branch.isCurrent else { return }
            uiCommands.deleteBranches(initiallySelected: [branch.name])
        case ("repository.branch.push", .branch(let branch)):
            uiCommands.startPush(initialBranch: branch.name)
        case ("repository.branch.merge", .branch(let branch)):
            guard !branch.isCurrent else { return }
            uiCommands.startMergeBranches(initialTarget: branch.name)
        case ("repository.branch.reset", .branch(let branch)):
            uiCommands.startResetCurrentBranch(to: branch.commitID, label: branch.name)
        case ("repository.remoteBranch.checkout", .remoteBranch(let branch)):
            uiCommands.checkout(.remote(branch), confirmDirectCheckout: true)
        case ("repository.remoteBranch.create", .remoteBranch(let branch)):
            let commit = refRevision(branch.commitID, label: branch.name)
            uiCommands.createBranch(sourceRevision: commit)
        case ("repository.remoteBranch.merge", .remoteBranch(let branch)):
            guard let remote = branch.remoteName else { return }
            uiCommands.startMergeBranches(initialTarget: "\(remote)/\(branch.name)")
        case ("repository.remoteBranch.reset", .remoteBranch(let branch)):
            let name = branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
            uiCommands.startResetCurrentBranch(to: branch.commitID, label: name)
        case ("repository.remoteBranch.delete", .remoteBranch(let branch)):
            presentRemoteBranchDeleteWindow(branch)
        case ("repository.remoteBranch.fetch", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .none)
        case ("repository.remoteBranch.fetchCheckout", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .checkout)
        case ("repository.remoteBranch.fetchCreate", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .create)
        case ("repository.remoteBranch.pull", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .merge)
        case ("repository.remoteBranch.fetchRebase", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .rebase)
        case ("repository.remote.manage", .remote(let remote)):
            uiCommands.startRemoteManagement(selectedRemote: remote.name)
        case ("repository.remote.fetch", .remote(let remote)):
            uiCommands.fetchRemote(named: remote.name, prune: false)
        case ("repository.remote.prune", .remote(let remote)):
            uiCommands.fetchRemote(named: remote.name, prune: true)
        case ("repository.remote.openURL", .remote(let remote)):
            guard let url = URL(string: remote.fetchURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        case ("repository.remote.disable", .remote(let remote)):
            uiCommands.setRemote(named: remote.name, disabled: true, fetchAfterEnabling: false)
        case ("repository.remote.enable", .remote(let remote)):
            uiCommands.setRemote(named: remote.name, disabled: false, fetchAfterEnabling: false)
        case ("repository.remote.enableFetch", .remote(let remote)):
            uiCommands.setRemote(named: remote.name, disabled: false, fetchAfterEnabling: true)
        case ("repository.remotes.manage", _):
            uiCommands.startRemoteManagement()
        case ("repository.remotes.fetch", _):
            uiCommands.startFetchAll(prune: false)
        case ("repository.remotes.prune", _):
            uiCommands.startFetchAll(prune: true)
        case ("repository.tag.checkout", .tag(let tag)):
            let commit = refRevision(tag.commitID, label: tag.name)
            uiCommands.checkout(.revision(commit))
        case ("repository.tag.createBranch", .tag(let tag)):
            let commit = refRevision(tag.commitID, label: tag.name)
            uiCommands.createBranch(sourceRevision: commit)
        case ("repository.folder.create", .folder(let prefix, false)):
            uiCommands.createBranch(sourceRevision: nil, suggestedPrefix: prefix + "/")
        case ("repository.folder.deleteAll", .folder(_, false)):
            uiCommands.deleteBranches(initiallySelected: localBranchNames(in: node))
        case ("repository.tag.merge", .tag(let tag)):
            uiCommands.startMergeBranches(initialTarget: tag.name)
        case ("repository.tag.reset", .tag(let tag)):
            uiCommands.startResetCurrentBranch(to: tag.commitID, label: tag.name)
        case ("repository.branch.rebase", .branch(let branch)),
             ("repository.remoteBranch.rebase", .remoteBranch(let branch)):
            let commit = refRevision(branch.commitID, label: branch.name)
            uiCommands.startRebase(on: commit, interactive: false)
        case ("repository.tag.rebase", .tag(let tag)):
            let commit = refRevision(tag.commitID, label: tag.name)
            uiCommands.startRebase(on: commit, interactive: false)
        case ("repository.tag.delete", .tag(let tag)):
            uiCommands.startDeleteTag(initialName: tag.name)
        case ("repository.stash.apply", .stash(let stash)):
            performStashMutation(.apply, stash: stash)
        case ("repository.stash.pop", .stash(let stash)):
            performStashMutation(.pop, stash: stash)
        case ("repository.stash.drop", .stash(let stash)):
            beginDropStash(stash)
        case ("repository.stash.open", .stash(let stash)):
            uiCommands.startStashManagement(initialStash: stash.selector)
        case ("repository.stashes.create", _):
            beginQuickStash()
        case ("repository.stashes.staged", _):
            beginStashStaged()
        case ("repository.stashes.manage", _):
            uiCommands.startStashManagement()
        default:
            showPlaceholderStatus(for: identifier)
        }
    }

    private func localBranchNames(in node: RepositoryTreeNode) -> [String] {
        var result: [String] = []
        func appendBranches(_ candidate: RepositoryTreeNode) {
            if case .branch(let branch) = candidate.kind, !branch.isRemote {
                result.append(branch.name)
            }
            candidate.children.forEach(appendBranches)
        }
        appendBranches(node)
        return result
    }

    private func presentRemoteBranchDeleteWindow(_ branch: Branch) {
        guard let pushSource = repositoryModule as? any RepositoryPushingDataSource,
              let remote = branch.remoteName
        else { return }
        if let remoteBranchDeleteWindowController {
            remoteBranchDeleteWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        remoteBranchDeleteWindowController = RemoteBranchDeleteDialog.present(
            source: pushSource,
            initialRemote: remote,
            initialBranch: branch.name,
            scriptHooks: uiCommands.scriptHooks,
            onRepositoryChanged: { [weak self] preferredCommitID in
                self?.uiCommands.notifyRepositoryChanged(
                    preferredCommitID: preferredCommitID ?? self?.selectedCommitID
                )
            },
            onClose: { [weak self] in self?.remoteBranchDeleteWindowController = nil }
        )
    }

    func performRevisionCommand(_ identifier: String, selected: [Commit], focused: Commit) {
        if identifier.hasPrefix("revision.compare.") {
            uiCommands.startRevisionComparison(identifier, selected: selected, base: revisionGridController.comparisonBase)
            return
        }
        if identifier == "revision.artificial.resetChanges" {
            uiCommands.startResetChanges(onlyWorkTree: focused.kind == .workingDirectory)
            return
        }
        if identifier == "revision.artificial.commit" {
            uiCommands.startCommit()
            return
        }
        if identifier == "revision.commit.archive" {
            uiCommands.startArchive(selected: selected)
            return
        }
        if identifier == "revision.other.formatPatch" {
            uiCommands.startPatch(.format, selected: selected)
            return
        }
        if identifier == "revision.other.reflog" {
            revisionGridController.toggleShowReflogReferences()
            return
        }
        let selectPrefix = "revision.selectInLeftPanel.ref."
        if identifier.hasPrefix(selectPrefix) {
            let referenceID = String(identifier.dropFirst(selectPrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }) else { return }
            outlineController.select(reference: reference)
            return
        }
        if identifier == "revision.bisect.bad" {
            uiCommands.markBisect(.bad, revision: focused)
            return
        }
        if identifier == "revision.bisect.good" {
            uiCommands.markBisect(.good, revision: focused)
            return
        }
        if identifier == "revision.bisect.skip" {
            uiCommands.markBisect(.skip, revision: focused)
            return
        }
        if identifier == "revision.bisect.stop" {
            uiCommands.stopBisect()
            return
        }
        if identifier == "revision.rebase.continue" {
            beginMutation(errorTitle: "Continue rebase failed") { source in
                try await source.continueRebase()
            }
            return
        }
        if identifier == "revision.rebase.skip" {
            beginMutation(errorTitle: "Skip rebase patch failed") { source in
                try await source.skipRebase()
            }
            return
        }
        if identifier == "revision.rebase.abort" {
            beginAbortRebase()
            return
        }
        if identifier == "revision.branch.rebase.selected" {
            guard !focused.isArtificial else { return }
            uiCommands.startRebase(on: focused, interactive: false)
            return
        }
        if identifier == "revision.branch.rebase.interactive" {
            guard !focused.isArtificial else { return }
            uiCommands.startRebase(on: focused, interactive: true)
            return
        }
        if identifier == "revision.branch.rebase.advanced" {
            guard !focused.isArtificial else { return }
            let boundary = selected.first(where: { $0.id != focused.id && !$0.isArtificial })?.objectID?.string
            uiCommands.startRebase(on: focused, interactive: false, advancedFrom: boundary, showAdvancedOptions: true)
            return
        }
        if identifier == "revision.branch.resetCurrent" {
            guard !focused.isArtificial else { return }
            uiCommands.startResetCurrentBranch(to: focused)
            return
        }
        if identifier == "revision.branch.resetOther" {
            guard !focused.isArtificial else { return }
            uiCommands.startResetAnotherBranch(to: focused)
            return
        }
        if identifier == "revision.commit.edit" || identifier == "revision.commit.reword" {
            guard !focused.isArtificial,
                  let parentID = focused.parentIDs.first,
                  let parent = revisions.first(where: { $0.id == .object(parentID) }),
                  let focusedObjectID = focused.objectID
            else { return }
            let action: RepositoryRebaseTodoAction = identifier == "revision.commit.edit"
                ? .edit
                : .reword(focused.subject + (focused.body.isEmpty ? "" : "\n\n\(focused.body)"))
            uiCommands.startRebase(on: parent, interactive: true, initialActions: [focusedObjectID: action])
            return
        }
        if identifier == "revision.cherryPick.continue" {
            beginMutation(errorTitle: "Continue cherry-pick failed") { source in
                try await source.continueCherryPick()
            }
            return
        }
        if identifier == "revision.cherryPick.abort" {
            beginAbortCherryPick()
            return
        }
        if identifier == "revision.commit.cherryPick" {
            uiCommands.startCherryPick(selected.isEmpty ? [focused] : selected)
            return
        }
        if identifier == "revision.commit.revert" {
            uiCommands.startRevert(selected.isEmpty ? [focused] : selected)
            return
        }
        if identifier == "revision.branch.merge.commit" {
            guard !focused.isArtificial else { return }
            uiCommands.startMergeBranches(initialTarget: focused.objectID?.string)
            return
        }
        let mergePrefix = "revision.branch.merge.ref."
        if identifier.hasPrefix(mergePrefix) {
            let referenceID = String(identifier.dropFirst(mergePrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }) else { return }
            uiCommands.startMergeBranches(initialTarget: reference.name)
            return
        }
        if identifier.hasPrefix("revision.stash."),
           let stash = repositoryNavigation?.stashes.first(where: { $0.commitID == focused.objectID }) {
            switch identifier {
            case "revision.stash.apply": performStashMutation(.apply, stash: stash)
            case "revision.stash.pop": performStashMutation(.pop, stash: stash)
            case "revision.stash.drop": beginDropStash(stash)
            default: break
            }
            return
        }
        if identifier == "revision.commit.fixup" {
            uiCommands.startCommit(initialMode: .normal, specialKind: .fixup(focused))
            return
        }
        if identifier == "revision.commit.squash" {
            uiCommands.startCommit(initialMode: .normal, specialKind: .squash(focused))
            return
        }
        if identifier == "revision.commit.amend" {
            uiCommands.startCommit(initialMode: .normal, specialKind: .amendAutosquash(focused))
            return
        }
        if identifier == "revision.commit.checkout" {
            guard !focused.isArtificial else { return }
            uiCommands.checkout(.revision(focused))
            return
        }
        if identifier == "revision.branch.create" {
            guard !focused.isArtificial else { return }
            uiCommands.createBranch(sourceRevision: focused)
            return
        }
        if identifier == "revision.tag.create" {
            uiCommands.startCreateTag(initialTarget: focused.objectID)
            return
        }
        let deleteTagPrefix = "revision.tag.delete.ref."
        if identifier.hasPrefix(deleteTagPrefix) {
            let referenceID = String(identifier.dropFirst(deleteTagPrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID && $0.kind == .tag }) else { return }
            uiCommands.startDeleteTag(initialName: reference.name)
            return
        }

        let prefix = "revision.branch.checkout.ref."
        if identifier.hasPrefix(prefix) {
            let referenceID = String(identifier.dropFirst(prefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }) else { return }
            switch reference.kind {
            case .currentBranch:
                return
            case .localBranch:
                if let branch = repositoryReferences?.branches.first(where: { !$0.isRemote && $0.name == reference.name }) {
                    uiCommands.checkout(.local(branch))
                }
            case .remoteBranch:
                let parts = reference.name.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let branch = repositoryNavigation?.remotes.first(where: { $0.name == parts[0] })?.branches.first(where: { $0.name == parts[1] })
                else { return }
                uiCommands.checkout(.remote(branch))
            default:
                break
            }
            return
        }
        let pushPrefix = "revision.branch.push.ref."
        if identifier.hasPrefix(pushPrefix) {
            let referenceID = String(identifier.dropFirst(pushPrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }),
                  (reference.kind == .currentBranch || reference.kind == .localBranch)
            else { return }
            uiCommands.startPush(initialBranch: reference.name)
            return
        }
        let deletePrefix = "revision.branch.delete.ref."
        if identifier.hasPrefix(deletePrefix) {
            let referenceID = String(identifier.dropFirst(deletePrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }) else { return }
            if reference.kind == .localBranch {
                uiCommands.deleteBranches(initiallySelected: [reference.name])
                return
            }
            guard reference.kind == .remoteBranch,
                  let slash = reference.name.firstIndex(of: "/"), let repositoryNavigation else { return }
            let remote = String(reference.name[..<slash])
            let name = String(reference.name[reference.name.index(after: slash)...])
            guard let branch = repositoryNavigation.remotes
                .first(where: { $0.name == remote })?
                .branches.first(where: { $0.name == name }) else { return }
            presentRemoteBranchDeleteWindow(branch)
            return
        }
        let renamePrefix = "revision.branch.rename.ref."
        if identifier.hasPrefix(renamePrefix) {
            let referenceID = String(identifier.dropFirst(renamePrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }),
                  reference.kind == .localBranch || reference.kind == .currentBranch else { return }
            uiCommands.renameBranch(reference.name)
            return
        }
        showPlaceholderStatus(for: identifier)
    }

    private func performFileMutation(
        _ identifier: String,
        files: [ChangedFile],
        scope: ChangedFileSelectionScope
    ) {
        guard scope == .workingTree || scope == .index else { return }
        beginMutation(errorTitle: scope == .workingTree ? "Stage failed" : "Unstage failed") { source in
            switch identifier {
            case "file.stage":
                return try await source.stage(paths: files.map(\.path))
            case "file.unstage":
                return try await source.unstage(paths: files.map(\.path))
            case "file.stageAll":
                return try await source.stageAll()
            case "file.unstageAll":
                return try await source.unstageAll()
            default:
                throw RepositoryMutationError.unavailable
            }
        }
    }


    private func performFileViewerCommand(_ identifier: String, item: FileStatusListItem) {
        guard let repository = repositoryIdentity?.currentRepository else { return }
        let fileURL = URL(fileURLWithPath: repository.path, isDirectory: true).appendingPathComponent(item.file.path)
        switch identifier {
        case "file.history": uiCommands.startFileHistory(file: item.file.path, revision: revisions.first { $0.id == item.second })
        case "file.open.local":
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            NSWorkspace.shared.open(fileURL)
        case "file.showFinder":
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        default:
            break
        }
    }


    private func configureFileStatusController(_ controller: RevisionDiffViewController) {
        guard let repository = repositoryIdentity?.currentRepository else { return }
        controller.isBareRepository = repository.isBare
        controller.repositoryURL = URL(fileURLWithPath: repository.path, isDirectory: true)
        let snapshot = revisions
        controller.describe = { id in
            guard let commit = snapshot.first(where: { $0.id == .object(id) }) else { return id.shortString }
            return RevisionDescription.describe(commit)
        }
    }


    func describeRevision(_ revision: RevisionID?) -> String {
        switch revision {
        case .object(let id)?: revisions.first { $0.id == .object(id) }.map(RevisionDescription.describe) ?? id.shortString
        case .workingDirectory?: "Working directory"
        case .index?: "Commit index"
        case nil: ""
        }
    }


    private func loadDiffTools() {
        guard let source = repositoryModule as? any RepositoryFileStatusDataSource else { return }
        Task { @MainActor [weak self] in
            let tools = (try? await source.loadDiffTools()) ?? []
            self?.revisionDiffController.diffTools = tools
            self?.fileTreeController.diffTools = tools
        }
    }


    private func parents(of revision: RevisionID) -> [RevisionID] {
        switch revision {
        case .workingDirectory: [.index]
        case .index: repositoryIdentity?.headID.map { [.object($0)] } ?? []
        case .object: revisions.first { $0.id == revision }?.parentIDs.map { .object($0) } ?? []
        }
    }


    private func refreshArtificialRevisions() {
        guard revisions.contains(where: \.isArtificial) else { return }
        reloadRepositoryState(preferredCommitID: selectedCommitID)
    }


    private func applicationActivated() {
        guard AppSettingsStore.shared.commitPreferences.refreshOnFocus, repositoryIdentity != nil else { return }
        if selectedDetailController === revisionDiffController { revisionDiffController.refreshArtificial() }
        else if selectedDetailController === fileTreeController { fileTreeController.refreshArtificial() }
    }


    private func performFileListHotkey(_ identifier: String) {
        let diffVisible = selectedDetailController === revisionDiffController
        let treeVisible = selectedDetailController === fileTreeController
        switch identifier {
        case "openWithDifftool":
            if diffVisible { revisionDiffController.filesController.perform("file.difftool") }
            else if treeVisible { fileTreeController.filesController.perform("file.difftool") }
        case "openWithDifftoolFirstToLocal" where diffVisible: revisionDiffController.filesController.perform("file.difftool.firstToLocal")
        case "openWithDifftoolSelectedToLocal" where diffVisible: revisionDiffController.filesController.perform("file.difftool.selectedToLocal")
        case "openAsTempFile" where treeVisible: fileTreeController.filesController.perform("file.open.revision")
        case "openAsTempFileWith" where treeVisible: fileTreeController.filesController.perform("file.open.revisionWith")
        case "editFile":

            if diffVisible { revisionDiffController.filesController.performIfEnabled("file.edit.local") }
            else if treeVisible { fileTreeController.filesController.performIfEnabled("file.edit.local") }
        case "findFileInSelectedCommit":

            if let commit = revisions.first(where: { $0.id == selectedCommitID }), commit.isArtificial, let head = repositoryIdentity?.headID {
                revisionGridController.selectCommit(id: .object(head))
            }
            if !layout.showSplitViewLayout { setShowSplitViewLayout(true) }
            selectDetailTab(fileTreeController)
            fileTreeController.filesController.perform("file.find")
        default:
            break
        }
    }


    private func performFileStatusCommand(_ command: FileStatusListCommand, from controller: RevisionDiffViewController) {
        switch command.identifier {
        case "file.blame": controller.toggleBlame()
        case "file.stage":
            let files = command.items.filter { $0.file.staged == .workTree }.map(\.file)
            if !files.isEmpty { performFileMutation("file.stage", files: files, scope: .workingTree) }
        case "file.unstage":
            let files = command.items.filter { $0.file.staged == .index }.map(\.file)
            if !files.isEmpty { performFileMutation("file.unstage", files: files, scope: .index) }
        case "file.showFileTree":

            guard let path = command.folder ?? command.items.first?.file.path else { return }
            fileTreeController.selectFileOrFolder(path)
            if !layout.showSplitViewLayout { setShowSplitViewLayout(true) }
            selectDetailTab(fileTreeController)
            fileTreeController.focusFileList()
        case "file.filterGrid":

            let filter = command.folder ?? command.items.map { "\"\($0.file.path)\"" }.joined(separator: " ")
            revisionGridController.setAndApplyPathFilter(filter)
        case "file.goToFirstParent": revisionGridController.goToParent(first: true); controller.focusFileList()
        case "file.goToLastParent": revisionGridController.goToParent(last: true); controller.focusFileList()
        default:
            uiCommands.performFileStatusCommand(command)
        }
    }

    private func performHunkMutation(_ selection: RepositoryHunkSelection) {
        let title = selection.direction == .stage ? "Stage hunk failed" : "Unstage hunk failed"
        beginMutation(errorTitle: title) { source in
            try await source.applyHunk(selection)
        }
    }

    private enum StashMutationKind {
        case apply
        case pop
    }

    func presentMergeDialog(
        source: any RepositoryMergingDataSource,
        context: RepositoryMergeContext,
        initialTarget: String?,
        distributedSettings: DistributedSettings? = nil,
        previousSelection: RevisionID?,
        owner: NSWindow
    ) -> NSWindowController {
        MergeDialog.present(
            source: source,
            context: context,
            initialTarget: initialTarget,
            distributedSettings: distributedSettings,
            owner: owner,
            scriptHooks: uiCommands.scriptHooks,
            onRepositoryChanged: { [weak self] selected in
                guard let self else { return }
                uiCommands.notifyRepositoryChanged(preferredCommitID: selected ?? previousSelection)
                statusLabel.stringValue = "Repository refreshed after Merge."
                refreshOperationIndicators()
            },
            onClose: { [weak self] in
                self?.mergeWindowController = nil
            }
        )
    }

    func presentCommitDialog(
        source: any RepositoryCommitWorkflowDataSource,
        pushSource: (any RepositoryPushingDataSource)?,
        initialMode: RepositoryCommitMode,
        specialKind: CommitWorkflowSpecialKind?,
        head: Commit?,
        draft: CommitDialogDraft?,
        owner: NSWindow,
        previousSelection: RevisionID?
    ) -> NSWindowController {
        CommitWorkflowDialog.present(
            source: source,
            pushSource: pushSource,
            initialMode: initialMode,
            specialKind: specialKind,
            head: head,
            draft: draft,
            owner: owner,
            onManageRemotes: { [weak self] remote, localBranch in
                self?.uiCommands.startRemoteManagement(
                    selectedRemote: remote,
                    selectedLocalBranch: localBranch
                )
            },
            onDifftool: { [weak self] commit, file in self?.uiCommands.startDifftool(commit: commit, file: file) },
            onBlame: { [weak self] file, window in self?.uiCommands.startFileHistory(file: file.path, revision: head, showBlame: true, owner: window) },
            onFileHistory: { [weak self] file, window in self?.uiCommands.startFileHistory(file: file.path, revision: head, owner: window) },
            scriptHooks: uiCommands.scriptHooks,
            onEditIgnoredFiles: { [weak self] localExclude, window, completion in
                self?.uiCommands.startEditGitIgnore(localExclude: localExclude, owner: window, onClosed: completion)
            },
            onRepositoryChanged: { [weak self] selected in
                guard let self else { return }
                commitDraft = nil
                uiCommands.notifyRepositoryChanged(preferredCommitID: selected ?? previousSelection)
                statusLabel.stringValue = "Repository refreshed after Commit"
            },
            onClose: { [weak self] in
                self?.commitWindowController = nil
                self?.statusLabel.stringValue = "Commit window closed"
                self?.uiCommands.pluginEvent("PostCommit", succeeded: true)
            }
        )
    }

    func showPlaceholderStatus(_ title: String) {
        showPlaceholderStatus(for: title)
    }

    private func performStashMutation(_ kind: StashMutationKind, stash: Stash) {
        performStashOperation(errorTitle: kind == .apply ? "Stash apply failed" : "Stash pop failed") { source in
            switch kind {
            case .apply: try await source.applyStash(stash)
            case .pop: try await source.popStash(stash)
            }
        }
    }

    private func performLatestStashPop() {
        performStashOperation(errorTitle: "Stash pop failed") { source in
            try await source.popStash(nil)
        }
    }

    private func beginQuickStash() {
        let includeUntracked = AppSettingsStore.shared.stashPreferences.includeUntracked
        performStashOperation(errorTitle: "Stash failed") { source in
            try await source.createStash(RepositoryStashCreateRequest(
                message: "",
                includeUntracked: includeUntracked,
                keepIndex: false,
                stagedOnly: false
            ))
        }
    }

    private func beginStashStaged() {
        performStashOperation(errorTitle: "Stash failed") { source in
            try await source.createStash(RepositoryStashCreateRequest(
                message: "",
                includeUntracked: false,
                keepIndex: false,
                stagedOnly: true
            ))
        }
    }

    private func performStashOperation(
        errorTitle: String,
        operation: @escaping @Sendable (any RepositoryStashWorkflowDataSource) async throws -> RepositoryMutationResult
    ) {
        guard let mutationSource = repositoryModule as? any RepositoryStashWorkflowDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Stash is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                statusLabel.stringValue = "Updating stash state…"
                revisionDetailsTask?.cancel()
                let result = try await operation(mutationSource)
                guard !Task.isCancelled else { return }
                uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                switch result.outcome {
                case .completed:
                    statusLabel.stringValue = result.message
                case .conflicts(let paths):
                    statusLabel.stringValue = "\(result.message) \(paths.count) conflicted path(s) remain."
                    if await MutationDialogs.confirmResolveStashConflicts(paths: paths, window: window),
                       await WorkflowManagementDialogs.resolveConflicts(source: mutationSource, window: window, scriptHooks: uiCommands.scriptHooks) {
                        uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                        statusLabel.stringValue = "Repository refreshed after resolving stash conflicts."
                    }
                case .paused(let reason):
                    statusLabel.stringValue = reason
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection) }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: errorTitle, window: window)
            }
        }
    }

    private func beginDropStash(_ stash: Stash) {
        guard let mutationSource = repositoryModule as? any RepositoryStashWorkflowDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Drop stash is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            guard await MutationDialogs.confirmDrop(stash: stash, window: window) else {
                statusLabel.stringValue = "Drop stash cancelled"
                return
            }
            do {
                statusLabel.stringValue = "Dropping \(stash.selector)…"
                revisionDetailsTask?.cancel()
                let result = try await mutationSource.dropStash(stash)
                guard !Task.isCancelled else { return }
                uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection) }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Drop stash failed", window: window)
            }
        }
    }

    func startCherryPickWorkflow(
        orderedRevisions ordered: [Commit],
        history: [Commit],
        mutationSource: any RepositoryCherryPickDataSource,
        window: NSWindow,
        previousSelection: RevisionID?
    ) {
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var options = RepositoryCherryPickOptions(
                automaticallyCommit: AppSettingsStore.shared.cherryPickPreferences.automaticallyCommit,
                addReference: AppSettingsStore.shared.cherryPickPreferences.addReference
            )
            var completedCount = 0
            var preferredCommitID = previousSelection

            for proposedCommit in ordered {
                guard !Task.isCancelled else { return }
                guard let selection = await CherryPickDialog.present(
                    commit: proposedCommit,
                    history: history,
                    options: options,
                    owner: window
                ) else {
                    statusLabel.stringValue = completedCount == 0
                        ? "Cherry-pick cancelled."
                        : "Cherry-picked \(completedCount) commit(s); remaining revisions were cancelled."
                    refreshOperationIndicators()
                    return
                }

                options = selection.options
                AppSettingsStore.shared.saveCherryPickPreferences(CherryPickPreferences(
                    automaticallyCommit: options.automaticallyCommit,
                    addReference: options.addReference
                ))

                do {
                    statusLabel.stringValue = "Cherry-picking \(selection.commit.shortID)…"
                    revisionDetailsTask?.cancel()
                    let result = try await mutationSource.cherryPick(RepositoryCherryPickRequest(
                        items: [RepositoryCherryPickItem(
                            commitID: selection.commit.objectID!,
                            mainlineParent: selection.mainlineParent
                        )],
                        options: selection.options
                    ))
                    guard !Task.isCancelled else { return }
                    preferredCommitID = result.selectedCommitID ?? preferredCommitID
                    uiCommands.notifyRepositoryChanged(preferredCommitID: preferredCommitID)

                    switch result.outcome {
                    case .completed:
                        completedCount += 1
                        statusLabel.stringValue = result.message
                    case .conflicts(let paths):
                        statusLabel.stringValue = "\(result.message) Resolve and stage \(paths.count) path(s), then Continue or Abort."
                        refreshOperationIndicators()
                        guard await MutationDialogs.confirmResolveCherryPickConflicts(paths: paths, window: window) else {
                            return
                        }
                        let resolution = await WorkflowManagementDialogs.resolveCherryPickConflicts(
                            source: mutationSource,
                            window: window, scriptHooks: uiCommands.scriptHooks
                        )
                        if resolution.repositoryChanged {
                            uiCommands.notifyRepositoryChanged(preferredCommitID: preferredCommitID)
                        }
                        refreshOperationIndicators()
                        switch resolution.sequencerAction {
                        case .continued:
                            completedCount += 1
                            statusLabel.stringValue = "Cherry-pick continued."
                        case .aborted:
                            statusLabel.stringValue = completedCount == 0
                                ? "Cherry-pick aborted."
                                : "Cherry-pick aborted after \(completedCount) completed commit(s)."
                            return
                        case .none:
                            statusLabel.stringValue = "Cherry-pick remains paused. Resolve all conflicts, then Continue or Abort."
                            return
                        }
                    case .paused(let reason):
                        statusLabel.stringValue = reason
                        refreshOperationIndicators()
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if !Task.isCancelled { uiCommands.notifyRepositoryChanged(preferredCommitID: preferredCommitID) }
                    statusLabel.stringValue = error.localizedDescription
                    await MutationDialogs.showError(error, title: "Cherry-pick failed", window: window)
                    refreshOperationIndicators()
                    return
                }
            }

            statusLabel.stringValue = completedCount == 1
                ? "Cherry-picked 1 commit."
                : "Cherry-picked \(completedCount) commits."
            refreshOperationIndicators()
        }
    }

    func beginCherryPick(_ selected: [Commit]) {
        uiCommands.startCherryPick(selected)
    }

    private func beginAbortCherryPick() {
        guard let mutationSource = repositoryModule as? any RepositoryCherryPickDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Abort cherry-pick is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            guard await MutationDialogs.confirmAbortCherryPick(window: window) else {
                statusLabel.stringValue = "Abort cherry-pick cancelled"
                return
            }
            do {
                statusLabel.stringValue = "Aborting cherry-pick…"
                let result = try await mutationSource.abortCherryPick()
                guard !Task.isCancelled else { return }
                uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection) }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Abort cherry-pick failed", window: window)
            }
        }
    }

    func startRebaseWorkflow(
        on target: Commit,
        interactive: Bool,
        initialActions: [ObjectID: RepositoryRebaseTodoAction],
        advancedFrom: String?,
        showAdvancedOptions: Bool,
        mutationSource: any RepositoryRebaseDataSource,
        window: NSWindow,
        previousSelection: RevisionID?
    ) {
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            statusLabel.stringValue = "Opening Rebase…"
            revisionDetailsTask?.cancel()
            if await WorkflowManagementDialogs.startRebase(
                source: mutationSource,
                target: target,
                interactive: interactive,
                initialActions: initialActions,
                advancedFrom: advancedFrom,
                showAdvancedOptions: showAdvancedOptions,
                window: window, scriptHooks: uiCommands.scriptHooks
            ) {
                uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection)
                statusLabel.stringValue = "Repository refreshed after Rebase."
            } else {
                statusLabel.stringValue = "Rebase closed."
            }
            refreshOperationIndicators()
        }
    }

    func beginRebase(
        on target: Commit,
        interactive: Bool,
        initialActions: [ObjectID: RepositoryRebaseTodoAction] = [:],
        advancedFrom: String? = nil,
        showAdvancedOptions: Bool = false
    ) {
        uiCommands.startRebase(
            on: target,
            interactive: interactive,
            initialActions: initialActions,
            advancedFrom: advancedFrom,
            showAdvancedOptions: showAdvancedOptions
        )
    }

    private func beginAbortRebase() {
        guard let mutationSource = repositoryModule as? any RepositoryRebaseDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Abort rebase is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                statusLabel.stringValue = "Aborting rebase…"
                let result = try await mutationSource.abortRebase()
                guard !Task.isCancelled else { return }
                uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection) }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Abort rebase failed", window: window)
            }
        }
    }

    private func refreshOperationIndicators() {
        operationStateTask?.cancel()
        guard let mutationSource = repositoryModule as? any RepositoryMutationStateDataSource else {
            revisionGridController.setCherryPickInProgress(false, hasConflicts: false)
            revisionGridController.setRebaseInProgress(false, hasConflicts: false)
            revisionGridController.setBisectInProgress(false)
            updateBisectBanner(inProgress: false)
            updateGitActionBanner(.none, hasConflicts: false)
            return
        }
        operationStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let state = try? await mutationSource.loadMutationState()
            let bisectState: RepositoryBisectState? = if let source = repositoryModule as? any RepositoryBisectingDataSource {
                try? await source.loadBisectState()
            } else {
                nil
            }
            guard !Task.isCancelled else { return }
            revisionGridController.setCherryPickInProgress(
                state?.cherryPickInProgress == true,
                hasConflicts: !(state?.conflictedPaths.isEmpty ?? true)
            )
            revisionGridController.setRebaseInProgress(
                state?.rebaseInProgress == true,
                hasConflicts: !(state?.conflictedPaths.isEmpty ?? true)
            )
            revisionGridController.setBisectInProgress(bisectState?.isActive == true)
            updateBisectBanner(inProgress: bisectState?.isActive == true)
            let patchApplying: Bool = if let patches = repositoryModule as? any RepositoryPatchingDataSource {
                (try? await patches.loadPatchState())?.isApplying == true
            } else {
                false
            }
            guard !Task.isCancelled else { return }
            updateGitActionBanner(.detect(rebase: state?.rebaseInProgress == true, merge: state?.mergeInProgress == true,
                                          patch: patchApplying),
                                  hasConflicts: !(state?.conflictedPaths.isEmpty ?? true))
        }
    }

    private func updateBisectBanner(inProgress: Bool) {
        bisectBanner.isHidden = !inProgress
        bisectBannerHeightConstraint?.constant = inProgress ? 34 : 0
        bisectBannerLabel.stringValue = "Bisect is currently in progress."
    }

    @objc private func showBisectManager() {
        guard let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial })
            ?? revisions.first(where: { !$0.isArtificial }) else { return }
        uiCommands.startBisect([commit])
    }


    private func updateGitActionBanner(_ action: BrowserGitAction, hasConflicts: Bool) {
        gitAction = action
        let presentation = action.presentation(hasConflicts: hasConflicts)
        rebaseBanner.isHidden = presentation == nil
        rebaseBannerHeightConstraint?.constant = presentation == nil ? 0 : 34
        guard let presentation else { return }
        rebaseBannerLabel.stringValue = presentation.message
        rebaseResolveButton.isHidden = !presentation.buttons.contains(.resolve)
        rebaseContinueButton.isHidden = !presentation.buttons.contains(.continue)
        gitActionAbortButton.isHidden = !presentation.buttons.contains(.abort)
        gitActionMoreButton.isHidden = !presentation.buttons.contains(.more)
        gitActionIcon.image = NSImage(systemSymbolName: hasConflicts ? "exclamationmark.triangle.fill" : "info.circle.fill",
                                      accessibilityDescription: presentation.message)
        rebaseBanner.layer?.backgroundColor = (hasConflicts ? NSColor.systemOrange : NSColor.systemBlue)
            .withAlphaComponent(0.22).cgColor
    }

    @objc private func continueGitActionFromBanner() {
        switch gitAction {
        case .rebase: continueRebaseFromBanner()
        case .merge:
            guard let source = repositoryModule as? any RepositoryConflictDataSource else { return }
            runBannerMutation(errorTitle: "Continue merge failed") { try await source.continueMerge() }
        case .patch: continuePatchFromBanner(.resolved)
        case .none: break
        }
    }

    @objc private func abortGitActionFromBanner() {
        switch gitAction {
        case .rebase: abortRebaseFromBanner()
        case .merge:
            guard let source = repositoryModule as? any RepositoryConflictDataSource else { return }
            runBannerMutation(errorTitle: "Abort merge failed") { try await source.abortMerge() }
        case .patch: continuePatchFromBanner(.abort)
        case .none: break
        }
    }

    @objc private func resolveGitActionFromBanner() {
        if gitAction == .rebase { resolveRebaseFromBanner() } else { uiCommands.startConflictResolution() }
    }

    @objc private func showGitActionMore() {
        switch gitAction {
        case .rebase: showRebaseManager()
        case .patch: uiCommands.startPatch(.apply)
        default: break
        }
    }

    private func runBannerMutation(errorTitle: String, _ operation: @escaping @Sendable () async throws -> RepositoryMutationResult) {
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await operation()
                uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection)
                if let window = view.window { await MutationDialogs.showError(error, title: errorTitle, window: window) }
            }
        }
    }

    private func continuePatchFromBanner(_ action: PatchContinuation) {
        guard let source = repositoryModule as? any RepositoryPatchingDataSource else { return }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await source.continuePatches(action) { _ in }
                uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection)
            } catch {
                uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection)
                if let window = view.window {
                    await MutationDialogs.showError(error, title: action == .abort ? "Abort patch failed" : "Continue patch failed", window: window)
                }
            }
        }
    }

    @objc private func continueRebaseFromBanner() {
        beginMutation(errorTitle: "Continue rebase failed") { try await $0.continueRebase() }
    }

    @objc private func abortRebaseFromBanner() { beginAbortRebase() }

    @objc private func resolveRebaseFromBanner() {
        guard let source = repositoryModule as? any RepositoryRebaseDataSource, let window = view.window else { return }
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            if await WorkflowManagementDialogs.resolveConflicts(source: source, window: window, scriptHooks: uiCommands.scriptHooks) {
                uiCommands.notifyRepositoryChanged(preferredCommitID: selectedCommitID)
            }
            refreshOperationIndicators()
        }
    }

    @objc private func showRebaseManager() {
        guard let source = repositoryModule as? any RepositoryRebaseDataSource, let window = view.window else { return }
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            if await WorkflowManagementDialogs.manageRebase(source: source, window: window, scriptHooks: uiCommands.scriptHooks) {
                uiCommands.notifyRepositoryChanged(preferredCommitID: selectedCommitID)
            }
            refreshOperationIndicators()
        }
    }

    private func beginMutation(
        errorTitle: String,
        operation: @escaping @Sendable (any RepositoryBrowserMutationDataSource) async throws -> RepositoryMutationResult
    ) {
        guard let mutationSource = repositoryModule as? any RepositoryBrowserMutationDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Repository mutation is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                statusLabel.stringValue = "Updating repository…"
                revisionDetailsTask?.cancel()
                let result = try await operation(mutationSource)
                guard !Task.isCancelled else { return }
                uiCommands.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? previousSelection)
                switch result.outcome {
                case .completed:
                    statusLabel.stringValue = result.message
                case .conflicts(let paths):
                    statusLabel.stringValue = "\(result.message) \(paths.count) conflicted path(s) remain."
                case .paused(let reason):
                    statusLabel.stringValue = reason
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { uiCommands.notifyRepositoryChanged(preferredCommitID: previousSelection) }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: errorTitle, window: window)
            }
        }
    }
}
