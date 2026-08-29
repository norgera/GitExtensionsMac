import GitExtensionsCore
import GitCommands
import AppKit

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
    private let revisionDiffController = RevisionDiffViewController()
    private let fileTreeController = FileTreeViewController()
    private let gpgController = GPGInfoViewController()
    private let detailTabs = DetailTabsViewController()

    private let mainSplitController = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
    private let rightSplitController = RetainingSplitViewController(resizeBehavior: .proportional)
    private lazy var leftSplitItem = NSSplitViewItem(viewController: outlineController)
    private lazy var gridSplitItem = NSSplitViewItem(viewController: revisionGridController)
    private lazy var detailsSplitItem = NSSplitViewItem(viewController: detailTabs)

    let statusLabel = NSTextField(labelWithString: "Loading repository…")
    private let repositoryStateLabel = NSTextField(labelWithString: "")
    private let branchFilterField = NSTextField()
    private let revisionFilterField = NSTextField()
    private let workingDirectoryPopUp = NSPopUpButton()
    private let branchPopUp = NSPopUpButton()
    private let commitPositionPopUp = NSPopUpButton()
    private let pullPopUp = NSPopUpButton()
    private let stashSplitButton = NSSegmentedControl()
    private let stashMenu = NSMenu(title: "Stash")
    private let pushButton = NSButton()
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
            remotes: repositoryNavigation.remotes,
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
            remotes: repositoryNavigation.remotes,
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
    private var windowScreenObserver: NSObjectProtocol?
    private weak var configuredWindow: NSWindow?
    private var didSetInitialDividerPositions = false
    private var repositoryStateLoadTask: Task<Void, Never>?
    private var activeRevisionReader: RevisionReader?
    private var revisionReadTask: Task<Void, Never>?
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
    private let rebaseBanner = NSView()
    private let rebaseBannerLabel = NSTextField(labelWithString: "")
    private let rebaseResolveButton = NSButton(title: "Resolve…", target: nil, action: nil)
    private let rebaseContinueButton = NSButton(title: "Continue", target: nil, action: nil)
    private var rebaseBannerHeightConstraint: NSLayoutConstraint?
    private var preferencesObserver: NSObjectProtocol?
    private var pullPreferencesObserver: NSObjectProtocol?
    private var repositoryChangeSubscription: RepositoryChangedSubscription?
    private var notifierPreferredCommitID: RevisionID?
    var selectedCommitID: RevisionID?
    var commitDraft: CommitDialogDraft?

    init(repositoryModule: any RepositoryBrowsingDataSource) {
        self.repositoryModule = repositoryModule
        super.init(nibName: nil, bundle: nil)
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
    }

    override func loadView() {
        configureDetailTabs()
        configureSplitHierarchy()

        let root = NSView()
        let browserToolbar = makeBrowserToolbar()
        let rebaseBanner = makeRebaseBanner()
        let statusBar = makeStatusBar()

        addChild(mainSplitController)
        let contentView = mainSplitController.view
        [browserToolbar, rebaseBanner, contentView, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        let toolbarHeight = browserToolbar.heightAnchor.constraint(equalToConstant: BrowserMetrics.primaryToolbarHeight)
        toolbarHeight.priority = .defaultHigh
        let statusHeight = statusBar.heightAnchor.constraint(equalToConstant: BrowserMetrics.statusHeight)
        statusHeight.priority = .defaultHigh
        let rebaseHeight = rebaseBanner.heightAnchor.constraint(equalToConstant: 0)
        rebaseBannerHeightConstraint = rebaseHeight
        NSLayoutConstraint.activate([
            browserToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            browserToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarHeight,

            rebaseBanner.topAnchor.constraint(equalTo: browserToolbar.bottomAnchor),
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
        rebaseBannerLabel.font = .systemFont(ofSize: 12)
        let abort = NSButton(title: "Abort", target: self, action: #selector(abortRebaseFromBanner))
        let more = NSButton(title: "More…", target: self, action: #selector(showRebaseManager))
        rebaseContinueButton.target = self; rebaseContinueButton.action = #selector(continueRebaseFromBanner)
        rebaseResolveButton.target = self; rebaseResolveButton.action = #selector(resolveRebaseFromBanner)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, rebaseBannerLabel, spacer, rebaseResolveButton, rebaseContinueButton, abort, more])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        rebaseBanner.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rebaseBanner.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: rebaseBanner.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: rebaseBanner.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: rebaseBanner.bottomAnchor, constant: -3),
            icon.widthAnchor.constraint(equalToConstant: 22)
        ])
        rebaseBanner.isHidden = true
        return rebaseBanner
    }

    private func applyPreferences() {
        let settings = AppSettingsStore.shared.preferences
        revisionGridController.setGraphConfiguration(
            mergeCommonParentLanes: settings.mergeCommonParentLanes,
            straightenDiagonals: settings.straightenGraphDiagonals
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = "gitextensions — Git Extensions"
        configureWindowSizing()
        setInitialDividerPositionsIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialDividerPositions {
            setInitialDividerPositionsIfNeeded()
        }
    }

    private func configureDetailTabs() {
        detailTabs.configure(
            items: [
                ("Commit", "CommitSummary", commitDetailController),
                ("Diff", "Diff", revisionDiffController),
                ("File tree", "FileTree", fileTreeController),
                ("GPG", "Key", gpgController)
            ],
            selectedIndex: 1
        )
    }

    private func configureSplitHierarchy() {
        mainSplitController.splitView.isVertical = true
        mainSplitController.splitView.dividerStyle = .paneSplitter
        leftSplitItem.minimumThickness = Self.collapsedPaneThickness
        leftSplitItem.canCollapse = false
        leftSplitItem.canCollapseFromWindowResize = false
        leftSplitItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        rightSplitController.splitView.isVertical = false
        rightSplitController.splitView.dividerStyle = .paneSplitter
        gridSplitItem.minimumThickness = Self.collapsedPaneThickness
        detailsSplitItem.minimumThickness = Self.collapsedPaneThickness
        gridSplitItem.preferredThicknessFraction = 209.0 / 502.0
        gridSplitItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        detailsSplitItem.holdingPriority = .defaultLow
        rightSplitController.addSplitViewItem(gridSplitItem)
        rightSplitController.addSplitViewItem(detailsSplitItem)

        let browserItem = NSSplitViewItem(viewController: rightSplitController)
        browserItem.minimumThickness = Self.collapsedMainContentThickness
        browserItem.holdingPriority = .defaultLow
        mainSplitController.addSplitViewItem(leftSplitItem)
        mainSplitController.addSplitViewItem(browserItem)
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
        stack.addArrangedSubview(AppKitFactory.resourceButton("LayoutSidebarLeft", tooltip: "Toggle left panel", target: self, action: #selector(toggleLeftPanel)))
        stack.addArrangedSubview(AppKitFactory.resourceButton("LayoutFooter", tooltip: "Toggle split view layout", target: self, action: #selector(toggleSplitLayout)))

        configureImagePopUp(
            commitPositionPopUp,
            imageName: "LayoutFooterTab",
            items: ["Commit info below graph", "Commit info left of graph", "Commit info right of graph"],
            width: 32,
            action: #selector(changeCommitInfoPosition)
        )
        commitPositionPopUp.toolTip = "Commit info position"
        stack.addArrangedSubview(commitPositionPopUp)
        stack.addArrangedSubview(AppKitFactory.separator())

        stack.addArrangedSubview(AppKitFactory.resourceButton("SubmodulesManage", tooltip: "Submodules", width: 32, target: self, action: #selector(placeholderToolbarButton(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("WorkTree", tooltip: "Worktrees", width: 32, target: self, action: #selector(placeholderToolbarButton(_:))))

        workingDirectoryWidthConstraint = configureCompactPopUp(workingDirectoryPopUp, items: ["gitextensions"], width: 83, action: #selector(selectWorkingDirectory))
        workingDirectoryPopUp.toolTip = "Working directory"
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
        stack.addArrangedSubview(AppKitFactory.resourceButton("BrowseFileExplorer", tooltip: "File Explorer", target: self, action: #selector(placeholderToolbarButton(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("GitForWindows", tooltip: "Git bash", target: self, action: #selector(placeholderToolbarButton(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("Settings", tooltip: "Settings", target: self, action: #selector(settingsToolbarButton(_:))))

        let toolbarGap = NSView()
        toolbarGap.translatesAutoresizingMaskIntoConstraints = false
        toolbarGap.widthAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(toolbarGap)

        stack.addArrangedSubview(AppKitFactory.resourceButton("FunnelPencil", tooltip: "Advanced filter", width: 32, target: self, action: #selector(placeholderToolbarButton(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("Book", tooltip: "Show reflog", target: self, action: #selector(placeholderToolbarButton(_:))))

        let branchScope = NSPopUpButton()
        branchScope.removeAllItems()
        branchScope.addItems(withTitles: ["All branches", "Current branch only", "Filtered branches"])
        compactImagePopUp(branchScope, imageName: "BranchLocal", width: 32)
        branchScope.target = self
        branchScope.action = #selector(changeBranchScope(_:))
        stack.addArrangedSubview(branchScope)
        let branchesLabel = AppKitFactory.label("Branches:")
        branchesLabel.alignment = .right
        branchesLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        stack.addArrangedSubview(branchesLabel)

        configureFilterField(branchFilterField, placeholder: "", width: 100)
        stack.addArrangedSubview(branchFilterField)

        let branchType = NSPopUpButton()
        branchType.removeAllItems()
        branchType.addItems(withTitles: ["Local", "Remote", "Tag"])
        compactImagePopUp(branchType, imageName: "EditFilter", width: 29)
        branchType.target = self
        branchType.action = #selector(placeholderPopUp(_:))
        stack.addArrangedSubview(branchType)
        stack.addArrangedSubview(AppKitFactory.separator())
        let filterLabel = AppKitFactory.label("Filter:")
        filterLabel.alignment = .right
        filterLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        stack.addArrangedSubview(filterLabel)

        configureFilterField(revisionFilterField, placeholder: "", width: 100)
        stack.addArrangedSubview(revisionFilterField)

        let filterType = NSPopUpButton()
        filterType.removeAllItems()
        filterType.addItems(withTitles: ["Commit message", "Committer", "Author", "Diff contains (SLOW)"])
        compactImagePopUp(filterType, imageName: "EditFilter", width: 29)
        filterType.target = self
        filterType.action = #selector(placeholderPopUp(_:))
        stack.addArrangedSubview(filterType)
        stack.addArrangedSubview(AppKitFactory.resourceButton("ShowOnlyFirstParent", tooltip: "Show only first parent", target: self, action: #selector(toggleFirstParent(_:))))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        let scripts = AppKitFactory.popUp("Scripts", width: 58)
        scripts.addItems(withTitles: ["Open terminal here", "Run repository script…"])
        scripts.target = self
        scripts.action = #selector(placeholderPopUp(_:))
        stack.addArrangedSubview(scripts)

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
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repositoryStateLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
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
        button.font = .systemFont(ofSize: 11)
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
        button.font = .systemFont(ofSize: 11)
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
        commitButton.title = "Commit (\(count))"
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
        button.font = .systemFont(ofSize: 11)
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
        let hasMultipleRemotes = (repositoryNavigation?.remotes.count ?? 0) > 1
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
        field.font = .systemFont(ofSize: 11)
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
        revisionGridController.onSelection = { [weak self] commit in
            self?.select(commit: commit)
        }
        commitDetailController.onSelectRevision = { [weak self] objectID in
            self?.revisionGridController.selectCommit(id: .object(objectID))
        }
        outlineController.onSelection = { [weak self] node in
            self?.select(treeNode: node)
        }
        outlineController.onCommand = { [weak self] identifier, node in
            self?.performRepositoryCommand(identifier, node: node)
        }
        revisionGridController.onCommand = { [weak self] identifier, selected, focused in
            self?.performRevisionCommand(identifier, selected: selected, focused: focused)
        }
        revisionDiffController.onFileMutation = { [weak self] identifier, files, scope in
            self?.performFileMutation(identifier, files: files, scope: scope)
        }
        revisionDiffController.onHunkMutation = { [weak self] selection in
            self?.performHunkMutation(selection)
        }
        detailTabs.onSelectionChanged = { [weak self] _ in
            self?.loadActiveDetailTab()
        }
        let source = repositoryModule
        revisionDiffController.diffProvider = { commit, file in
            try await source.loadDiff(for: commit, file: file)
        }
        fileTreeController.contentProvider = { commit, file in
            try await source.loadFileContent(for: commit, file: file)
        }
    }

    private func observePlaceholderActions() {
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
        guard let window = view.window else { return }
        switch command {
        case .openRepository: presentOpenRepositoryPanel()
        case .refresh: reloadRepositoryState()
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
        case .manageStashes: uiCommands.startStashManagement()
        case .solveMergeConflicts: uiCommands.startConflictResolution()
        case .cherryPick:
            if let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial }) {
                uiCommands.startCherryPick([commit])
            }
        case .rebase:
            if let commit = revisions.first(where: { $0.id == selectedCommitID && !$0.isArtificial }) {
                uiCommands.startRebase(on: commit, interactive: false, showAdvancedOptions: true)
            }
        case .settings:
            Task { @MainActor [weak self] in
                await ApplicationShellDialogs.presentSettings(from: window)
                self?.updateToolbarRepositoryState()
            }
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
        let previousRevisions = revisions
        let previousRepositoryID = repositoryIdentity?.currentRepository.id
        let sameRepository = previousRepositoryID == state.identity.currentRepository.id
        let requestedSelection = preferredCommitID ?? (sameRepository ? selectedCommitID : nil)
        applyRepositoryState(state)
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
        BrowserCommandAvailability.shared.canMerge = false
        let canManageBranches = !state.identity.currentRepository.isBare
            && repositoryModule is any RepositoryCheckoutBranchDataSource
        BrowserCommandAvailability.shared.canCreateBranch = canManageBranches
        BrowserCommandAvailability.shared.canDeleteBranch = canManageBranches && !state.references.branches.isEmpty
        BrowserCommandAvailability.shared.canCheckoutBranch = canManageBranches
            && (!state.references.branches.isEmpty || state.navigation.remotes.contains { !$0.branches.isEmpty })
        BrowserCommandAvailability.shared.canCheckoutRevision = false
        outlineController.apply(
            identity: state.identity,
            references: state.references,
            navigation: state.navigation
        )

        workingDirectoryPopUp.removeAllItems()
        state.identity.repositories.forEach { repository in
            workingDirectoryPopUp.addItem(withTitle: repository.id == state.identity.currentRepository.id
                ? repositoryDisplayTitle(repository)
                : repository.name)
        }
        workingDirectoryPopUp.selectItem(at: state.identity.repositories.firstIndex(where: { $0.id == state.identity.currentRepository.id }) ?? 0)
        updatePopUpWidth(
            workingDirectoryPopUp,
            constraint: workingDirectoryWidthConstraint,
            title: workingDirectoryPopUp.titleOfSelectedItem ?? state.identity.currentRepository.name,
            minimum: 83,
            includesLeadingImage: false
        )

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
            let counts = branch.ahead > 0 || branch.behind > 0 ? " ↑\(branch.ahead) ↓\(branch.behind)" : ""
            return "   \(branch.name)\(counts)"
        } ?? "   Detached HEAD"
        repositoryStateLabel.stringValue = "\(revisionCount) revisions\(branchState)"
        view.window?.title = "\(state.identity.currentRepository.name) — Git Extensions"
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
        revisionGridController.beginIncrementalLoad(preferredCommitID: preferredCommitID)
        activeRevisionReader = request.reader
        revisionReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await request.reader.cancel()
                let batches = await request.reader.read(request.context)
                for try await batch in batches {
                    guard !Task.isCancelled, activeRevisionReader === request.reader else { return }
                    revisions.append(contentsOf: batch)
                    revisionGridController.appendIncrementalBatch(batch)
                    updateRevisionCount()
                }
                guard !Task.isCancelled, activeRevisionReader === request.reader else { return }
                let restored = RevisionSelectionRestorer.restoredID(
                    requestedID: preferredCommitID,
                    previousCommits: oldRevisions,
                    refreshedCommits: revisions
                )
                if let restored { revisionGridController.selectCommit(id: restored) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func updateRevisionCount() {
        guard let repositoryReferences else { return }
        let revisionCount = revisions.filter { !$0.isArtificial }.count
        let branchState = repositoryReferences.branches.first(where: \.isCurrent).map { branch in
            let counts = branch.ahead > 0 || branch.behind > 0 ? " ↑\(branch.ahead) ↓\(branch.behind)" : ""
            return "   \(branch.name)\(counts)"
        } ?? "   Detached HEAD"
        repositoryStateLabel.stringValue = "\(revisionCount) revisions\(branchState)"
    }

    private func select(commit: Commit) {
        guard let repositoryIdentity else { return }
        selectedCommitID = commit.id
        BrowserCommandAvailability.shared.canMerge = !commit.isArtificial
            && !repositoryIdentity.currentRepository.isBare
            && revisionGridController.selectedCommitCount == 1
            && repositoryModule is any RepositoryMergingDataSource
        BrowserCommandAvailability.shared.canCheckoutRevision = !commit.isArtificial
            && !repositoryIdentity.currentRepository.isBare
            && revisionGridController.selectedCommitCount == 1
            && repositoryModule is any RepositoryCheckoutBranchDataSource
        revisionDetailsTask?.cancel()
        let relations = CommitRelationsResolver.resolve(commit: commit, history: revisions)
        let comparisonCommit = commit.parentIDs.first.flatMap { parentID in
            revisions.first(where: { $0.id == .object(parentID) })
        }
        commitDetailController.apply(commit: commit, relations: relations, history: revisions)
        revisionDiffController.apply(commit: commit, comparisonCommit: comparisonCommit, files: [], diffsByFile: [:])
        fileTreeController.apply(commit: commit, files: [])
        gpgController.apply(commit: commit, info: nil)
        statusLabel.stringValue = commit.isArtificial ? "Selected \(commit.subject)" : "Selected \(commit.shortID): \(commit.subject)"

        loadActiveDetailTab(commit: commit, comparisonCommit: comparisonCommit)
    }

    private func loadActiveDetailTab(
        commit: Commit? = nil,
        comparisonCommit: Commit? = nil
    ) {
        guard repositoryIdentity != nil else { return }
        guard let activeCommit = commit ?? revisions.first(where: { $0.id == selectedCommitID }) else { return }
        let activeComparisonCommit = comparisonCommit ?? activeCommit.parentIDs.first.flatMap { parentID in
            revisions.first(where: { $0.id == .object(parentID) })
        }

        revisionDetailsTask?.cancel()
        switch detailTabs.selectedTabIndex {
        case 1: // Diff
            revisionDetailsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let details = try await repositoryModule.loadRevisionDetails(for: activeCommit)
                    guard !Task.isCancelled, selectedCommitID == activeCommit.id else { return }
                    revisionDiffController.apply(
                        commit: activeCommit,
                        comparisonCommit: activeComparisonCommit,
                        files: details.files,
                        diffsByFile: details.diffsByFile
                    )
                    let revisionCount = revisions.filter { !$0.isArtificial }.count
                    repositoryStateLabel.stringValue = "\(details.files.count) changed files   \(revisionCount) revisions"
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, selectedCommitID == activeCommit.id else { return }
                    statusLabel.stringValue = error.localizedDescription
                }
            }
        case 2: // File tree
            revisionDetailsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let files = try await repositoryModule.loadRepositoryFiles(for: activeCommit)
                    guard !Task.isCancelled, selectedCommitID == activeCommit.id else { return }
                    fileTreeController.apply(commit: activeCommit, files: files)
                    let revisionCount = revisions.filter { !$0.isArtificial }.count
                    repositoryStateLabel.stringValue = "\(files.count) files   \(revisionCount) revisions"
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, selectedCommitID == activeCommit.id else { return }
                    statusLabel.stringValue = error.localizedDescription
                }
            }
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
        case .remote(let remote):
            statusLabel.stringValue = "Remote \(remote.name): \(remote.fetchURL)"
        case .submodule(let submodule):
            statusLabel.stringValue = "Submodule \(submodule.path): \(submodule.state.rawValue)"
        case .group, .folder:
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
              mainSplitController.view.bounds.width > 800,
              rightSplitController.view.bounds.height > 350 else { return }
        didSetInitialDividerPositions = true
        mainSplitController.setRetainedPosition(220)
        let graphHeight = rightSplitController.splitView.bounds.height * (209.0 / 502.0)
        rightSplitController.setRetainedPosition(graphHeight)
    }

    @objc private func refresh() {
        reloadRepositoryState()
    }

    @objc private func toggleLeftPanel() {
        let willShowLeftPanel = mainSplitController.isCollapsed(leftSplitItem)
        mainSplitController.setCollapsed(!willShowLeftPanel, for: leftSplitItem)
        showPlaceholderStatus(for: willShowLeftPanel ? "Left panel shown" : "Left panel hidden")
    }

    @objc private func toggleSplitLayout() {
        let targetIndex = rightSplitController.splitView.isVertical ? 0 : 2
        commitPositionPopUp.selectItem(at: targetIndex)
        changeCommitInfoPosition()
    }

    @objc private func changeCommitInfoPosition() {
        let selection = commitPositionPopUp.indexOfSelectedItem
        rightSplitController.removeSplitViewItem(gridSplitItem)
        rightSplitController.removeSplitViewItem(detailsSplitItem)
        switch selection {
        case 1:
            rightSplitController.splitView.isVertical = true
            rightSplitController.addSplitViewItem(detailsSplitItem)
            rightSplitController.addSplitViewItem(gridSplitItem)
        case 2:
            rightSplitController.splitView.isVertical = true
            rightSplitController.addSplitViewItem(gridSplitItem)
            rightSplitController.addSplitViewItem(detailsSplitItem)
        default:
            rightSplitController.splitView.isVertical = false
            rightSplitController.addSplitViewItem(gridSplitItem)
            rightSplitController.addSplitViewItem(detailsSplitItem)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let length = rightSplitController.splitView.isVertical ? rightSplitController.view.bounds.width : rightSplitController.view.bounds.height
            rightSplitController.setRetainedPosition(length * 0.55)
        }
        showPlaceholderStatus(for: commitPositionPopUp.titleOfSelectedItem ?? "Commit info position")
    }

    @objc private func selectWorkingDirectory() {
        showPlaceholderStatus(for: "Working directory: \(workingDirectoryPopUp.titleOfSelectedItem ?? "")")
    }

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

    @objc private func placeholderToolbarButton(_ sender: NSButton) {
        let title = sender.toolTip ?? sender.title
        BrowserCommandCenter.perform(.unavailable(title))
    }

    @objc private func settingsToolbarButton(_ sender: NSButton) {
        performTopLevelCommand(.settings)
    }

    @objc private func placeholderPopUp(_ sender: NSPopUpButton) {
        showPlaceholderStatus(for: sender.titleOfSelectedItem ?? "Option")
    }

    @objc private func changeBranchScope(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 1, let current = repositoryReferences?.branches.first(where: \.isCurrent) {
            branchFilterField.stringValue = current.name
            revisionGridController.setBranchFilter(current.name)
            restartRevisionReadForFilterChange()
        } else if sender.indexOfSelectedItem == 0 {
            branchFilterField.stringValue = ""
            revisionGridController.setBranchFilter("")
            restartRevisionReadForFilterChange()
        }
        showPlaceholderStatus(for: sender.titleOfSelectedItem ?? "Branch scope")
    }

    @objc private func toggleFirstParent(_ sender: NSButton) {
        sender.state = sender.state == .on ? .off : .on
        showPlaceholderStatus(for: sender.state == .on ? "Showing first-parent history" : "Showing complete history")
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === branchFilterField {
            revisionGridController.setBranchFilter(field.stringValue)
            restartRevisionReadForFilterChange()
            showPlaceholderStatus(for: field.stringValue.isEmpty ? "Branch filter cleared" : "Branch filter: \(field.stringValue)")
        } else if field === revisionFilterField {
            revisionGridController.setTextFilter(field.stringValue)
            restartRevisionReadForFilterChange()
            showPlaceholderStatus(for: field.stringValue.isEmpty ? "Revision filter cleared" : "Revision filter: \(field.stringValue)")
        }
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

    private func performRepositoryCommand(_ identifier: String, node: RepositoryTreeNode) {
        switch (identifier, node.kind) {
        case ("repository.branch.checkout", .branch(let branch)):
            uiCommands.checkout(.local(branch), confirmDirectCheckout: true)
        case ("repository.branch.create", .branch(let branch)):
            guard let commit = revisions.first(where: { $0.id == .object(branch.commitID) }) else { return }
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
        case ("repository.remoteBranch.checkout", .remoteBranch(let branch)):
            uiCommands.checkout(.remote(branch), confirmDirectCheckout: true)
        case ("repository.remoteBranch.create", .remoteBranch(let branch)):
            guard let commit = revisions.first(where: { $0.id == .object(branch.commitID) }) else { return }
            uiCommands.createBranch(sourceRevision: commit)
        case ("repository.remoteBranch.merge", .remoteBranch(let branch)):
            guard let remote = branch.remoteName else { return }
            uiCommands.startMergeBranches(initialTarget: "\(remote)/\(branch.name)")
        case ("repository.remoteBranch.delete", .remoteBranch(let branch)):
            presentRemoteBranchDeleteWindow(branch)
        case ("repository.remoteBranch.fetch", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .none)
        case ("repository.remoteBranch.fetchCheckout", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .checkout)
        case ("repository.remoteBranch.fetchCreate", .remoteBranch(let branch)):
            uiCommands.fetchRemoteBranch(branch, then: .create)
        case ("repository.tag.checkout", .tag(let tag)):
            guard let commit = revisions.first(where: { $0.id == .object(tag.commitID) }) else { return }
            uiCommands.checkout(.revision(commit))
        case ("repository.tag.createBranch", .tag(let tag)):
            guard let commit = revisions.first(where: { $0.id == .object(tag.commitID) }) else { return }
            uiCommands.createBranch(sourceRevision: commit)
        case ("repository.folder.create", .folder(let prefix, false)):
            uiCommands.createBranch(sourceRevision: nil, suggestedPrefix: prefix + "/")
        case ("repository.folder.deleteAll", .folder(_, false)):
            uiCommands.deleteBranches(initiallySelected: localBranchNames(in: node))
        case ("repository.tag.merge", .tag(let tag)):
            uiCommands.startMergeBranches(initialTarget: tag.name)
        case ("repository.branch.rebase", .branch(let branch)),
             ("repository.remoteBranch.rebase", .remoteBranch(let branch)):
            guard let commit = revisions.first(where: { $0.id == .object(branch.commitID) }) else { return }
            uiCommands.startRebase(on: commit, interactive: false)
        case ("repository.tag.rebase", .tag(let tag)):
            guard let commit = revisions.first(where: { $0.id == .object(tag.commitID) }) else { return }
            uiCommands.startRebase(on: commit, interactive: false)
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
            onRepositoryChanged: { [weak self] preferredCommitID in
                self?.uiCommands.notifyRepositoryChanged(
                    preferredCommitID: preferredCommitID ?? self?.selectedCommitID
                )
            },
            onClose: { [weak self] in self?.remoteBranchDeleteWindowController = nil }
        )
    }

    private func performRevisionCommand(_ identifier: String, selected: [Commit], focused: Commit) {
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
        previousSelection: RevisionID?,
        owner: NSWindow
    ) -> NSWindowController {
        MergeDialog.present(
            source: source,
            context: context,
            initialTarget: initialTarget,
            owner: owner,
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
            onRepositoryChanged: { [weak self] selected in
                guard let self else { return }
                commitDraft = nil
                uiCommands.notifyRepositoryChanged(preferredCommitID: selected ?? previousSelection)
                statusLabel.stringValue = "Repository refreshed after Commit"
            },
            onClose: { [weak self] in
                self?.commitWindowController = nil
                self?.statusLabel.stringValue = "Commit window closed"
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
                       await WorkflowManagementDialogs.resolveConflicts(source: mutationSource, window: window) {
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
                            window: window
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
                window: window
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
            updateRebaseBanner(inProgress: false, hasConflicts: false)
            return
        }
        operationStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let state = try? await mutationSource.loadMutationState()
            guard !Task.isCancelled else { return }
            revisionGridController.setCherryPickInProgress(
                state?.cherryPickInProgress == true,
                hasConflicts: !(state?.conflictedPaths.isEmpty ?? true)
            )
            revisionGridController.setRebaseInProgress(
                state?.rebaseInProgress == true,
                hasConflicts: !(state?.conflictedPaths.isEmpty ?? true)
            )
            updateRebaseBanner(
                inProgress: state?.rebaseInProgress == true,
                hasConflicts: !(state?.conflictedPaths.isEmpty ?? true)
            )
        }
    }

    private func updateRebaseBanner(inProgress: Bool, hasConflicts: Bool) {
        rebaseBanner.isHidden = !inProgress
        rebaseBannerHeightConstraint?.constant = inProgress ? 34 : 0
        rebaseBannerLabel.stringValue = hasConflicts
            ? "Rebase is currently in progress with merge conflicts."
            : "Rebase is currently in progress."
        rebaseResolveButton.isHidden = !hasConflicts
        rebaseContinueButton.isHidden = hasConflicts
        rebaseBanner.layer?.backgroundColor = (hasConflicts ? NSColor.systemOrange : NSColor.systemBlue)
            .withAlphaComponent(0.22).cgColor
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
            if await WorkflowManagementDialogs.resolveConflicts(source: source, window: window) {
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
            if await WorkflowManagementDialogs.manageRebase(source: source, window: window) {
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
