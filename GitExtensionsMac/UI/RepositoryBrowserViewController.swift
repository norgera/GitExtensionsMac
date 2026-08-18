import AppKit

final class RepositoryBrowserViewController: NSViewController, NSTextFieldDelegate {
    var onApplicationCommand: ((String) -> Bool)?
    private static let collapsedPaneThickness: CGFloat = 1
    private static let collapsedMainContentThickness: CGFloat = 1
    private static let minimumWindowWidth: CGFloat = 120
    private static let minimumWindowHeight: CGFloat = 120

    private let dataSource: any RepositoryBrowsingDataSource

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

    private let statusLabel = NSTextField(labelWithString: "Loading repository…")
    private let repositoryStateLabel = NSTextField(labelWithString: "")
    private let branchFilterField = NSTextField()
    private let revisionFilterField = NSTextField()
    private let workingDirectoryPopUp = NSPopUpButton()
    private let branchPopUp = NSPopUpButton()
    private let commitPositionPopUp = NSPopUpButton()
    private let pullPopUp = NSPopUpButton()
    private let stashPopUp = NSPopUpButton()
    private let pushButton = NSButton()
    private let commitButton = NSButton()
    private var workingDirectoryWidthConstraint: NSLayoutConstraint?
    private var branchWidthConstraint: NSLayoutConstraint?
    private var snapshot: RepositorySnapshot?
    private var placeholderObserver: NSObjectProtocol?
    private var windowScreenObserver: NSObjectProtocol?
    private weak var configuredWindow: NSWindow?
    private var didSetInitialDividerPositions = false
    private var snapshotLoadTask: Task<Void, Never>?
    private var revisionDetailsTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var commitWindowController: NSWindowController?
    private var pullWindowController: NSWindowController?
    private var pushWindowController: NSWindowController?
    private var fetchWindowController: NSWindowController?
    private var remoteWindowController: NSWindowController?
    private var remoteBranchDeleteWindowController: NSWindowController?
    private var operationStateTask: Task<Void, Never>?
    private var preferencesObserver: NSObjectProtocol?
    private var pullPreferencesObserver: NSObjectProtocol?
    private var selectedCommitID: String?
    private var commitDraft: CommitDialogDraft?

    init(dataSource: any RepositoryBrowsingDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        snapshotLoadTask?.cancel()
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
    }

    override func loadView() {
        configureDetailTabs()
        configureSplitHierarchy()

        let root = NSView()
        let browserToolbar = makeBrowserToolbar()
        let statusBar = makeStatusBar()

        addChild(mainSplitController)
        let contentView = mainSplitController.view
        [browserToolbar, contentView, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        let toolbarHeight = browserToolbar.heightAnchor.constraint(equalToConstant: BrowserMetrics.primaryToolbarHeight)
        toolbarHeight.priority = .defaultHigh
        let statusHeight = statusBar.heightAnchor.constraint(equalToConstant: BrowserMetrics.statusHeight)
        statusHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            browserToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            browserToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarHeight,

            contentView.topAnchor.constraint(equalTo: browserToolbar.bottomAnchor),
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
        loadSnapshot()
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

        configureImagePopUp(
            stashPopUp,
            imageName: "stash",
            items: ["Stash", "Stash staged", "Stash pop", "Manage stashes…", "Create a stash…"],
            width: 32,
            action: #selector(selectStashAction)
        )
        stack.addArrangedSubview(stashPopUp)
        stack.addArrangedSubview(AppKitFactory.separator())
        stack.addArrangedSubview(AppKitFactory.resourceButton("BrowseFileExplorer", tooltip: "File Explorer", target: self, action: #selector(placeholderToolbarButton(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("GitForWindows", tooltip: "Git bash", target: self, action: #selector(placeholderToolbarButton(_:))))
        stack.addArrangedSubview(AppKitFactory.resourceButton("Settings", tooltip: "Settings", target: self, action: #selector(placeholderToolbarButton(_:))))

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

    private func updateToolbarRepositoryState(_ snapshot: RepositorySnapshot) {
        let count = snapshot.workingDirectoryChangeCount
        commitButton.title = "Commit (\(count))"
        commitButton.image = AppKitFactory.resourceImage(
            "RepoStateClean",
            accessibilityDescription: commitButton.title
        )
        commitButton.toolTip = count == 1 ? "Commit — 1 changed file" : "Commit — \(count) changed files"

        guard let currentBranch = snapshot.branches.first(where: \.isCurrent) else {
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
        let hasMultipleRemotes = (snapshot?.remotes.count ?? 0) > 1
        let menu = NSMenu(title: "Pull")

        let primary = NSMenuItem(title: "Pull", action: #selector(pullMenuCommand(_:)), keyEquivalent: "")
        primary.target = self
        primary.representedObject = "Pull"
        menu.addItem(primary)
        menu.addItem(.separator())

        let actions: [(String, PullActionPreference, String)] = [
            ("Open pull dialog…", .openDialog, "Pull"),
            ("Pull - merge", .merge, "PullMerge"),
            ("Pull - rebase", .rebase, "PullRebase"),
            ("Fetch", .fetch, "PullFetch"),
            ("Fetch all", .fetchAll, "PullFetchAll"),
            ("Fetch and prune all", .fetchPruneAll, "PullFetchPruneAll")
        ]
        for (title, action, imageName) in actions where action != .fetchAll || hasMultipleRemotes {
            let item = NSMenuItem(title: title, action: #selector(pullMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = title
            item.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: title)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let defaultItem = NSMenuItem(title: "Set default Pull button action", action: nil, keyEquivalent: "")
        let defaultMenu = NSMenu(title: defaultItem.title)
        for (title, action, imageName) in actions where action != .fetchAll || hasMultipleRemotes {
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
        commitDetailController.onSelectRevision = { [weak self] revisionID in
            self?.revisionGridController.selectCommit(id: revisionID)
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
        let source = dataSource
        revisionDiffController.diffProvider = { commit, file in
            try await source.loadDiff(for: commit, file: file)
        }
        fileTreeController.contentProvider = { commit, file in
            try await source.loadFileContent(for: commit, file: file)
        }
    }

    private func observePlaceholderActions() {
        placeholderObserver = NotificationCenter.default.addObserver(
            forName: .browserPlaceholderAction,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let title = notification.userInfo?["title"] as? String else { return }
            guard let self else { return }
            if self.onApplicationCommand?(title) == true { return }
            self.performTopLevelCommand(title)
        }
    }

    private func performTopLevelCommand(_ title: String) {
        guard let window = view.window else { return }
        switch title {
        case "Open repository": presentOpenRepositoryPanel()
        case "Commit": beginCommit(initialMode: .normal)
        case "Pull/Fetch":
            guard let snapshot else { return }
            presentPullAction(AppSettingsStore.shared.pullPreferences.formAction, immediately: false, snapshot: snapshot)
        case "Pull":
            guard let snapshot else { return }
            let preferences = AppSettingsStore.shared.pullPreferences
            if preferences.defaultAction == .openDialog {
                presentPullAction(preferences.formAction, immediately: false, snapshot: snapshot)
            } else {
                presentPullAction(preferences.defaultAction, immediately: true, snapshot: snapshot)
            }
        case "Open pull dialog…":
            guard let snapshot else { return }
            presentPullAction(AppSettingsStore.shared.pullPreferences.formAction, immediately: false, snapshot: snapshot)
        case "Pull - merge":
            guard let snapshot else { return }
            presentPullAction(.merge, immediately: true, snapshot: snapshot)
        case "Pull - rebase":
            guard let snapshot else { return }
            presentPullAction(.rebase, immediately: true, snapshot: snapshot)
        case "Push":
            guard let snapshot else { return }
            presentNetworkWindow(kind: .push, initialAction: .merge, snapshot: snapshot)
        case "Fetch":
            guard let snapshot else { return }
            presentPullAction(.fetch, immediately: true, snapshot: snapshot)
        case "Fetch all":
            guard let snapshot else { return }
            presentPullAction(.fetchAll, immediately: true, snapshot: snapshot)
        case "Fetch and prune all":
            guard let snapshot else { return }
            presentPullAction(.fetchPruneAll, immediately: true, snapshot: snapshot)
        case "Remote repositories", "Manage remotes":
            presentRemoteWindow(selectedRemote: nil)
        case "Merge branches":
            guard let snapshot else { return }
            Task { await ApplicationShellDialogs.mergeShell(snapshot: snapshot, window: window) }
        case "Manage stashes": beginManageStashes()
        case "Solve merge conflicts": beginResolveConflicts()
        case "Cherry pick":
            if let commit = snapshot?.commits.first(where: { $0.id == selectedCommitID }) { beginCherryPick([commit]) }
        case "Rebase":
            if let commit = snapshot?.commits.first(where: { $0.id == selectedCommitID && !$0.isArtificial }) { beginRebase(on: commit, interactive: false) }
        case "Settings":
            Task { await ApplicationShellDialogs.presentSettings(from: window) }
        default: showPlaceholderStatus(for: title)
        }
    }

    private func presentPullAction(_ action: PullActionPreference, immediately: Bool, snapshot: RepositorySnapshot) {
        let effectiveAction = action == .openDialog ? AppSettingsStore.shared.pullPreferences.formAction : action
        let initialAction: NetworkDialogInitialAction = switch effectiveAction {
        case .rebase: .rebase
        case .fetch: .fetch
        case .fetchAll: .fetchAll
        case .fetchPruneAll: .fetchPruneAll
        case .merge, .openDialog: .merge
        }
        let kind: NetworkOperationKind = switch initialAction {
        case .fetch, .fetchAll, .fetchPruneAll: .fetch
        case .merge, .rebase: .pull
        }
        presentNetworkWindow(kind: kind, initialAction: initialAction, executeImmediately: immediately, snapshot: snapshot)
    }

    private func presentNetworkWindow(
        kind: NetworkOperationKind,
        initialAction: NetworkDialogInitialAction,
        executeImmediately: Bool = false,
        pushBranch: String? = nil,
        snapshot: RepositorySnapshot
    ) {
        let existing: NSWindowController? = switch kind {
        case .pull, .fetch: pullWindowController
        case .push: pushWindowController
        }
        if let existing {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let close: () -> Void = { [weak self] in
            switch kind {
            case .pull, .fetch:
                self?.pullWindowController = nil
                self?.fetchWindowController = nil
            case .push: self?.pushWindowController = nil
            }
        }
        let controller: NSWindowController
        if kind == .push, let pushSource = dataSource as? any RepositoryPushingDataSource {
            controller = PushDialog.present(
                source: pushSource,
                snapshot: snapshot,
                initialBranch: pushBranch,
                executeImmediately: executeImmediately,
                onSnapshot: { [weak self] updated, preferredCommitID in
                    self?.apply(snapshot: updated, preferredCommitID: preferredCommitID ?? self?.selectedCommitID)
                },
                onClose: close
            )
        } else if kind != .push, let pullSource = dataSource as? any RepositoryPullingDataSource {
            controller = ApplicationShellDialogs.presentPullWindow(
                initialAction: initialAction,
                executeImmediately: executeImmediately,
                snapshot: snapshot,
                source: pullSource,
                onSnapshot: { [weak self] updated, preferredCommitID in
                    self?.apply(snapshot: updated, preferredCommitID: preferredCommitID ?? self?.selectedCommitID)
                },
                onClose: close
            )
        } else {
            let remoteSource = dataSource as? any RepositoryRemoteManagingDataSource
            controller = ApplicationShellDialogs.presentNetworkWindow(
                kind: kind,
                initialAction: initialAction,
                snapshot: snapshot,
                source: remoteSource,
                onSnapshot: { [weak self] updated in self?.apply(snapshot: updated, preferredCommitID: self?.selectedCommitID) },
                onClose: close
            )
        }
        switch kind {
        case .pull, .fetch: pullWindowController = controller
        case .push: pushWindowController = controller
        }
    }

    private func presentRemoteWindow(selectedRemote: String?) {
        if let remoteWindowController {
            remoteWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let source = dataSource as? any RepositoryRemoteManagingDataSource else {
            statusLabel.stringValue = "Remote management is unavailable for this data source."
            return
        }
        remoteWindowController = RemoteManagementDialog.present(
            source: source,
            selectedRemote: selectedRemote,
            onSnapshot: { [weak self] snapshot in self?.apply(snapshot: snapshot, preferredCommitID: self?.selectedCommitID) },
            onClose: { [weak self] in self?.remoteWindowController = nil }
        )
    }

    private func loadSnapshot() {
        snapshotLoadTask?.cancel()
        revisionDetailsTask?.cancel()
        statusLabel.stringValue = "Loading repository…"
        snapshotLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await dataSource.loadSnapshot()
                guard !Task.isCancelled else { return }
                apply(snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func apply(snapshot: RepositorySnapshot, preferredCommitID: String? = nil) {
        self.snapshot = snapshot
        outlineController.apply(snapshot: snapshot)
        let preferred = preferredCommitID.flatMap { id in snapshot.commits.first(where: { $0.id == id }) }
            ?? snapshot.commits.first(where: \.isHEAD)
            ?? snapshot.commits.first(where: { !$0.isArtificial })
        revisionGridController.apply(commits: snapshot.commits, preferredCommitID: preferred?.id)

        workingDirectoryPopUp.removeAllItems()
        snapshot.repositories.forEach { repository in
            workingDirectoryPopUp.addItem(withTitle: repository.id == snapshot.currentRepository.id
                ? repositoryDisplayTitle(repository)
                : repository.name)
        }
        workingDirectoryPopUp.selectItem(at: snapshot.repositories.firstIndex(where: { $0.id == snapshot.currentRepository.id }) ?? 0)
        updatePopUpWidth(
            workingDirectoryPopUp,
            constraint: workingDirectoryWidthConstraint,
            title: workingDirectoryPopUp.titleOfSelectedItem ?? snapshot.currentRepository.name,
            minimum: 83,
            includesLeadingImage: false
        )

        branchPopUp.removeAllItems()
        snapshot.branches.forEach { branchPopUp.addItem(withTitle: $0.name) }
        let branchImage = AppKitFactory.resourceImage("Branch", accessibilityDescription: "Branches")
        branchPopUp.itemArray.forEach { $0.image = branchImage }
        if let current = snapshot.branches.first(where: \.isCurrent) {
            branchPopUp.selectItem(withTitle: current.name)
        }
        updatePopUpWidth(
            branchPopUp,
            constraint: branchWidthConstraint,
            title: branchPopUp.titleOfSelectedItem ?? "Branch",
            minimum: 60,
            includesLeadingImage: true
        )
        updateToolbarRepositoryState(snapshot)
        rebuildPullMenu()

        statusLabel.stringValue = "Ready"
        let revisionCount = snapshot.commits.filter { !$0.isArtificial }.count
        let branchState = snapshot.branches.first(where: \.isCurrent).map { branch in
            let counts = branch.ahead > 0 || branch.behind > 0 ? " ↑\(branch.ahead) ↓\(branch.behind)" : ""
            return "   \(branch.name)\(counts)"
        } ?? "   Detached HEAD"
        repositoryStateLabel.stringValue = "\(revisionCount) revisions\(branchState)"
        view.window?.title = "\(snapshot.currentRepository.name) — Git Extensions"
        refreshOperationIndicators()
        setInitialDividerPositionsIfNeeded()
    }

    private func select(commit: Commit) {
        guard let snapshot else { return }
        selectedCommitID = commit.id
        revisionDetailsTask?.cancel()
        let relations = CommitRelationsResolver.resolve(commit: commit, history: snapshot.commits)
        let comparisonCommit = commit.parentIDs.first.flatMap { parentID in
            snapshot.commits.first(where: { $0.id == parentID })
        }
        commitDetailController.apply(commit: commit, relations: relations, history: snapshot.commits)
        revisionDiffController.apply(commit: commit, comparisonCommit: comparisonCommit, files: [], diffsByFile: [:])
        fileTreeController.apply(commit: commit, files: [])
        gpgController.apply(commit: commit, info: nil)
        statusLabel.stringValue = commit.isArtificial ? "Selected \(commit.subject)" : "Selected \(commit.shortID): \(commit.subject)"

        loadActiveDetailTab(commit: commit, snapshot: snapshot, comparisonCommit: comparisonCommit)
    }

    private func loadActiveDetailTab(
        commit: Commit? = nil,
        snapshot: RepositorySnapshot? = nil,
        comparisonCommit: Commit? = nil
    ) {
        guard let activeSnapshot = snapshot ?? self.snapshot else { return }
        guard let activeCommit = commit ?? activeSnapshot.commits.first(where: { $0.id == selectedCommitID }) else { return }
        let activeComparisonCommit = comparisonCommit ?? activeCommit.parentIDs.first.flatMap { parentID in
            activeSnapshot.commits.first(where: { $0.id == parentID })
        }

        revisionDetailsTask?.cancel()
        switch detailTabs.selectedTabIndex {
        case 1: // Diff
            revisionDetailsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let details = try await dataSource.loadRevisionDetails(for: activeCommit)
                    guard !Task.isCancelled, selectedCommitID == activeCommit.id else { return }
                    revisionDiffController.apply(
                        commit: activeCommit,
                        comparisonCommit: activeComparisonCommit,
                        files: details.files,
                        diffsByFile: details.diffsByFile
                    )
                    let revisionCount = activeSnapshot.commits.filter { !$0.isArtificial }.count
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
                    let files = try await dataSource.loadRepositoryFiles(for: activeCommit)
                    guard !Task.isCancelled, selectedCommitID == activeCommit.id else { return }
                    fileTreeController.apply(commit: activeCommit, files: files)
                    let revisionCount = activeSnapshot.commits.filter { !$0.isArtificial }.count
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
            revisionGridController.selectCommit(id: branch.commitID)
            statusLabel.stringValue = "Selected \(branch.isRemote ? "remote " : "")branch \(branch.name)"
        case .tag(let tag):
            revisionGridController.selectCommit(id: tag.commitID)
            statusLabel.stringValue = "Selected tag \(tag.name)"
        case .stash(let stash):
            revisionGridController.selectCommit(id: stash.commitID)
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
        guard dataSource is any RepositoryOpeningDataSource else {
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
                  let openingSource = dataSource as? any RepositoryOpeningDataSource
            else { return }

            snapshotLoadTask?.cancel()
            revisionDetailsTask?.cancel()
            statusLabel.stringValue = "Opening \(url.path)…"
            snapshotLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let loaded = try await openingSource.openRepository(at: url)
                    guard !Task.isCancelled else { return }
                    apply(snapshot: loaded)
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
        BrowserCommandCenter.perform("Refresh")
        loadSnapshot()
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
        guard let snapshot,
              let title = branchPopUp.titleOfSelectedItem,
              let branch = snapshot.branches.first(where: { $0.name == title }) else { return }
        guard !branch.isCurrent else { return }
        beginCheckout(.local(branch))
    }

    @objc private func selectPullAction() {
        let title = pullPopUp.titleOfSelectedItem ?? "Pull"
        pullPopUp.selectItem(at: 0)
        performTopLevelCommand(title)
    }

    @objc private func pullMenuCommand(_ sender: NSMenuItem) {
        pullPopUp.selectItem(at: 0)
        performTopLevelCommand((sender.representedObject as? String) ?? sender.title)
    }

    @objc private func setDefaultPullAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = PullActionPreference(rawValue: raw) else { return }
        var preferences = AppSettingsStore.shared.pullPreferences
        preferences.defaultAction = action
        AppSettingsStore.shared.savePullPreferences(preferences)
        rebuildPullMenu()
    }

    @objc private func selectStashAction() {
        let selectedAction = stashPopUp.titleOfSelectedItem ?? "Stash"
        stashPopUp.selectItem(at: 0)
        switch selectedAction {
        case "Stash", "Create a stash…":
            beginCreateStash()
        case "Stash staged":
            beginMutation(errorTitle: "Stash failed") { source in
                try await source.createStash(RepositoryStashCreateRequest(
                    message: "",
                    includeUntracked: false,
                    keepIndex: false,
                    stagedOnly: true
                ))
            }
        case "Stash pop":
            beginMutation(errorTitle: "Stash pop failed") { source in
                try await source.popStash(nil)
            }
        case "Manage stashes…":
            beginManageStashes()
        default:
            showPlaceholderStatus(for: selectedAction)
        }
    }

    @objc private func commitToolbarButton(_ sender: NSButton) {
        beginCommit(initialMode: .normal)
    }

    @objc private func pushToolbarButton(_ sender: NSButton) {
        guard let snapshot else { return }
        presentNetworkWindow(
            kind: .push,
            initialAction: .merge,
            executeImmediately: NSEvent.modifierFlags.contains(.shift),
            snapshot: snapshot
        )
    }

    @objc private func placeholderToolbarButton(_ sender: NSButton) {
        let title = sender.toolTip ?? sender.title
        if title == "Push" || title == "Settings" {
            performTopLevelCommand(title)
        } else {
            BrowserCommandCenter.perform(title)
        }
    }

    @objc private func placeholderPopUp(_ sender: NSPopUpButton) {
        showPlaceholderStatus(for: sender.titleOfSelectedItem ?? "Option")
    }

    @objc private func changeBranchScope(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 1, let current = snapshot?.branches.first(where: \.isCurrent) {
            branchFilterField.stringValue = current.name
            revisionGridController.setBranchFilter(current.name)
        } else if sender.indexOfSelectedItem == 0 {
            branchFilterField.stringValue = ""
            revisionGridController.setBranchFilter("")
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
            showPlaceholderStatus(for: field.stringValue.isEmpty ? "Branch filter cleared" : "Branch filter: \(field.stringValue)")
        } else if field === revisionFilterField {
            revisionGridController.setTextFilter(field.stringValue)
            showPlaceholderStatus(for: field.stringValue.isEmpty ? "Revision filter cleared" : "Revision filter: \(field.stringValue)")
        }
    }

    private func showPlaceholderStatus(for title: String) {
        statusLabel.stringValue = "\(title) — not implemented"
    }

    private func performRepositoryCommand(_ identifier: String, node: RepositoryTreeNode) {
        switch (identifier, node.kind) {
        case ("repository.branch.checkout", .branch(let branch)):
            beginCheckout(.local(branch))
        case ("repository.branch.push", .branch(let branch)):
            guard let snapshot else { return }
            presentNetworkWindow(kind: .push, initialAction: .merge, pushBranch: branch.name, snapshot: snapshot)
        case ("repository.remoteBranch.checkout", .remoteBranch(let branch)):
            beginCheckout(.remote(branch))
        case ("repository.remoteBranch.delete", .remoteBranch(let branch)):
            presentRemoteBranchDeleteWindow(branch)
        case ("repository.tag.checkout", .tag(let tag)):
            guard let commit = snapshot?.commits.first(where: { $0.id == tag.commitID }) else { return }
            beginCheckout(.revision(commit))
        case ("repository.branch.rebase", .branch(let branch)),
             ("repository.remoteBranch.rebase", .remoteBranch(let branch)):
            guard let commit = snapshot?.commits.first(where: { $0.id == branch.commitID }) else { return }
            beginRebase(on: commit, interactive: false)
        case ("repository.tag.rebase", .tag(let tag)):
            guard let commit = snapshot?.commits.first(where: { $0.id == tag.commitID }) else { return }
            beginRebase(on: commit, interactive: false)
        case ("repository.stash.apply", .stash(let stash)):
            performStashMutation(.apply, stash: stash)
        case ("repository.stash.pop", .stash(let stash)):
            performStashMutation(.pop, stash: stash)
        case ("repository.stash.drop", .stash(let stash)):
            beginDropStash(stash)
        case ("repository.stashes.create", _):
            beginCreateStash()
        case ("repository.stashes.staged", _):
            beginMutation(errorTitle: "Stash failed") { source in
                try await source.createStash(RepositoryStashCreateRequest(
                    message: "",
                    includeUntracked: false,
                    keepIndex: false,
                    stagedOnly: true
                ))
            }
        default:
            showPlaceholderStatus(for: identifier)
        }
    }

    private func presentRemoteBranchDeleteWindow(_ branch: Branch) {
        guard let pushSource = dataSource as? any RepositoryPushingDataSource,
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
            onSnapshot: { [weak self] updated, preferredCommitID in
                self?.apply(snapshot: updated, preferredCommitID: preferredCommitID ?? self?.selectedCommitID)
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
            beginRebase(on: focused, interactive: false)
            return
        }
        if identifier == "revision.branch.rebase.interactive" {
            guard !focused.isArtificial else { return }
            beginRebase(on: focused, interactive: true)
            return
        }
        if identifier == "revision.commit.edit" || identifier == "revision.commit.reword" {
            guard !focused.isArtificial,
                  let parentID = focused.parentIDs.first,
                  let parent = snapshot?.commits.first(where: { $0.id == parentID })
            else { return }
            let action: RepositoryRebaseTodoAction = identifier == "revision.commit.edit"
                ? .edit
                : .reword(focused.subject + (focused.body.isEmpty ? "" : "\n\n\(focused.body)"))
            beginRebase(on: parent, interactive: true, initialActions: [focused.id: action])
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
            beginCherryPick(selected.isEmpty ? [focused] : selected)
            return
        }
        if identifier.hasPrefix("revision.stash."),
           let stash = snapshot?.stashes.first(where: { $0.commitID == focused.id }) {
            switch identifier {
            case "revision.stash.apply": performStashMutation(.apply, stash: stash)
            case "revision.stash.pop": performStashMutation(.pop, stash: stash)
            case "revision.stash.drop": beginDropStash(stash)
            default: break
            }
            return
        }
        if identifier == "revision.commit.amend" {
            beginCommit(initialMode: .amend)
            return
        }
        if identifier == "revision.commit.checkout" {
            guard !focused.isArtificial else { return }
            beginCheckout(.revision(focused))
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
                if let branch = snapshot?.branches.first(where: { !$0.isRemote && $0.name == reference.name }) {
                    beginCheckout(.local(branch))
                }
            case .remoteBranch:
                let parts = reference.name.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let branch = snapshot?.remotes.first(where: { $0.name == parts[0] })?.branches.first(where: { $0.name == parts[1] })
                else { return }
                beginCheckout(.remote(branch))
            default:
                break
            }
            return
        }
        let pushPrefix = "revision.branch.push.ref."
        if identifier.hasPrefix(pushPrefix) {
            let referenceID = String(identifier.dropFirst(pushPrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }),
                  (reference.kind == .currentBranch || reference.kind == .localBranch),
                  let snapshot
            else { return }
            presentNetworkWindow(kind: .push, initialAction: .merge, pushBranch: reference.name, snapshot: snapshot)
            return
        }
        let deletePrefix = "revision.branch.delete.ref."
        if identifier.hasPrefix(deletePrefix) {
            let referenceID = String(identifier.dropFirst(deletePrefix.count))
            guard let reference = focused.references.first(where: { $0.id == referenceID }),
                  reference.kind == .remoteBranch,
                  let slash = reference.name.firstIndex(of: "/"),
                  let snapshot
            else { return }
            let remote = String(reference.name[..<slash])
            let name = String(reference.name[reference.name.index(after: slash)...])
            guard let branch = snapshot.branches.first(where: {
                $0.isRemote && $0.remoteName == remote && $0.name == name
            }) else { return }
            presentRemoteBranchDeleteWindow(branch)
            return
        }
        showPlaceholderStatus(for: identifier)
    }

    private func beginCheckout(_ target: CheckoutDialogTarget) {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window,
              let snapshot else {
            showPlaceholderStatus(for: "Checkout is unavailable for mock data")
            return
        }

        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                statusLabel.stringValue = "Checking repository state…"
                let state = try await mutationSource.loadMutationState()
                guard !Task.isCancelled else { return }
                guard let request = await MutationDialogs.checkoutRequest(
                    target: target,
                    state: state,
                    localBranches: snapshot.branches,
                    window: window
                ) else {
                    if let current = snapshot.branches.first(where: \.isCurrent) {
                        branchPopUp.selectItem(withTitle: current.name)
                    }
                    statusLabel.stringValue = "Checkout cancelled"
                    return
                }

                statusLabel.stringValue = "Checking out…"
                revisionDetailsTask?.cancel()
                let result = try await mutationSource.checkout(request)
                guard !Task.isCancelled else { return }
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID)
                switch result.outcome {
                case .completed:
                    statusLabel.stringValue = result.message
                case .conflicts(let paths):
                    statusLabel.stringValue = "Checkout completed with conflicts in \(paths.count) path(s)"
                case .paused(let reason):
                    statusLabel.stringValue = reason
                }
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Checkout failed", window: window)
            }
        }
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

    private func beginCommit(initialMode: RepositoryCommitMode) {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Commit is unavailable for mock data")
            return
        }

        if let commitWindowController {
            commitWindowController.showWindow(nil)
            commitWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }

        window.makeKeyAndOrderFront(nil)
        let previousSelection = selectedCommitID
        let head = snapshot?.commits.first(where: \.isHEAD)
            ?? snapshot?.commits.first(where: { !$0.isArtificial })
        commitWindowController = CommitWorkflowDialog.present(
            source: mutationSource,
            initialMode: initialMode,
            head: head,
            draft: commitDraft,
            owner: window
        ) { [weak self, weak window] request in
            guard let self else { return }
            self.commitWindowController = nil
            guard let request else {
                self.statusLabel.stringValue = "Commit cancelled"
                return
            }
            self.mutationTask?.cancel()
            self.mutationTask = Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                do {
                    commitDraft = CommitDialogDraft(request: request)
                    statusLabel.stringValue = request.mode == .normal ? "Committing…" : "Amending…"
                    revisionDetailsTask?.cancel()
                    let result = try await mutationSource.commit(request)
                    guard !Task.isCancelled else { return }
                    commitDraft = nil
                    apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID)
                    statusLabel.stringValue = result.message
                } catch is CancellationError {
                    return
                } catch {
                    if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                        apply(snapshot: refreshed, preferredCommitID: previousSelection)
                    }
                    statusLabel.stringValue = error.localizedDescription
                    await MutationDialogs.showError(error, title: "Commit failed", window: window)
                }
            }
        }
    }

    private enum StashMutationKind {
        case apply
        case pop
    }

    private func beginManageStashes() {
        guard let source = dataSource as? any RepositoryMutatingDataSource,
              let snapshot,
              let window = view.window else {
            showPlaceholderStatus(for: "Stash manager is unavailable for mock data")
            return
        }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            if let refreshed = await WorkflowManagementDialogs.manageStashes(source: source, snapshot: snapshot, window: window) {
                apply(snapshot: refreshed, preferredCommitID: selectedCommitID)
            }
        }
    }

    private func beginResolveConflicts() {
        guard let source = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Conflict resolver is unavailable for mock data")
            return
        }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            if let refreshed = await WorkflowManagementDialogs.resolveConflicts(source: source, window: window) {
                apply(snapshot: refreshed, preferredCommitID: selectedCommitID)
            }
        }
    }

    private func performStashMutation(_ kind: StashMutationKind, stash: Stash) {
        let title: String
        switch kind {
        case .apply: title = "Stash apply failed"
        case .pop: title = "Stash pop failed"
        }
        beginMutation(errorTitle: title) { source in
            switch kind {
            case .apply: return try await source.applyStash(stash)
            case .pop: return try await source.popStash(stash)
            }
        }
    }

    private func beginCreateStash() {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Stash is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            guard let request = await MutationDialogs.stashCreateRequest(window: window) else {
                statusLabel.stringValue = "Stash cancelled"
                return
            }
            do {
                statusLabel.stringValue = "Creating stash…"
                revisionDetailsTask?.cancel()
                let result = try await mutationSource.createStash(request)
                guard !Task.isCancelled else { return }
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID ?? previousSelection)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Stash failed", window: window)
            }
        }
    }

    private func beginDropStash(_ stash: Stash) {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
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
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Drop stash failed", window: window)
            }
        }
    }

    private func beginCherryPick(_ selected: [Commit]) {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window,
              let snapshot else {
            showPlaceholderStatus(for: "Cherry-pick is unavailable for mock data")
            return
        }
        let historyIndex = Dictionary(uniqueKeysWithValues: snapshot.commits.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = selected
            .filter { !$0.isArtificial }
            .sorted { (historyIndex[$0.id] ?? 0) > (historyIndex[$1.id] ?? 0) }
        guard !ordered.isEmpty else { return }

        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            guard let request = await MutationDialogs.cherryPickRequest(
                commits: ordered,
                history: snapshot.commits,
                window: window
            ) else {
                statusLabel.stringValue = "Cherry-pick cancelled"
                return
            }
            do {
                statusLabel.stringValue = "Cherry-picking…"
                revisionDetailsTask?.cancel()
                let result = try await mutationSource.cherryPick(request)
                guard !Task.isCancelled else { return }
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID ?? previousSelection)
                switch result.outcome {
                case .completed:
                    statusLabel.stringValue = result.message
                case .conflicts(let paths):
                    statusLabel.stringValue = "\(result.message) Resolve and stage \(paths.count) path(s), then Continue or Abort from the revision menu."
                case .paused(let reason):
                    statusLabel.stringValue = reason
                }
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Cherry-pick failed", window: window)
            }
        }
    }

    private func beginAbortCherryPick() {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
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
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Abort cherry-pick failed", window: window)
            }
        }
    }

    private func beginRebase(
        on target: Commit,
        interactive: Bool,
        initialActions: [String: RepositoryRebaseTodoAction] = [:]
    ) {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Rebase is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                let result: RepositoryMutationResult
                if interactive {
                    statusLabel.stringValue = "Loading interactive rebase plan…"
                    let plan = try await mutationSource.loadInteractiveRebasePlan(upstream: target.id)
                    guard !plan.isEmpty else { throw RepositoryMutationError.emptyRebasePlan }
                    guard let request = await MutationDialogs.interactiveRebaseRequest(
                        target: target,
                        plan: plan,
                        initialActions: initialActions,
                        window: window
                    ) else {
                        statusLabel.stringValue = "Rebase cancelled"
                        return
                    }
                    statusLabel.stringValue = "Rebasing interactively…"
                    revisionDetailsTask?.cancel()
                    result = try await mutationSource.interactiveRebase(request)
                } else {
                    guard let request = await MutationDialogs.rebaseRequest(target: target, window: window) else {
                        statusLabel.stringValue = "Rebase cancelled"
                        return
                    }
                    statusLabel.stringValue = "Rebasing…"
                    revisionDetailsTask?.cancel()
                    result = try await mutationSource.rebase(request)
                }
                guard !Task.isCancelled else { return }
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID ?? previousSelection)
                switch result.outcome {
                case .completed:
                    statusLabel.stringValue = result.message
                case .conflicts(let paths):
                    statusLabel.stringValue = "\(result.message) Resolve and stage \(paths.count) path(s), then Continue, Skip, or Abort from the revision menu."
                case .paused(let reason):
                    statusLabel.stringValue = reason
                }
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Rebase failed", window: window)
            }
        }
    }

    private func beginAbortRebase() {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
              let window = view.window else {
            showPlaceholderStatus(for: "Abort rebase is unavailable for mock data")
            return
        }
        let previousSelection = selectedCommitID
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            guard await MutationDialogs.confirmAbortRebase(window: window) else {
                statusLabel.stringValue = "Abort rebase cancelled"
                return
            }
            do {
                statusLabel.stringValue = "Aborting rebase…"
                let result = try await mutationSource.abortRebase()
                guard !Task.isCancelled else { return }
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID)
                statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Abort rebase failed", window: window)
            }
        }
    }

    private func refreshOperationIndicators() {
        operationStateTask?.cancel()
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource else {
            revisionGridController.setCherryPickInProgress(false, hasConflicts: false)
            revisionGridController.setRebaseInProgress(false, hasConflicts: false)
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
        }
    }

    private func beginMutation(
        errorTitle: String,
        operation: @escaping @Sendable (any RepositoryMutatingDataSource) async throws -> RepositoryMutationResult
    ) {
        guard let mutationSource = dataSource as? any RepositoryMutatingDataSource,
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
                apply(snapshot: result.snapshot, preferredCommitID: result.selectedCommitID ?? previousSelection)
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
                if let refreshed = try? await mutationSource.loadSnapshot(), !Task.isCancelled {
                    apply(snapshot: refreshed, preferredCommitID: previousSelection)
                }
                statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: errorTitle, window: window)
            }
        }
    }
}
