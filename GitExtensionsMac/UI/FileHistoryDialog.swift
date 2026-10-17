import AppKit
import GitCommands
import GitExtensionsCore


@MainActor
final class FileHistoryWindowController: NSWindowController, NSWindowDelegate {
    let controller: FileHistoryViewController
    var onClose: (() -> Void)?

    init(source: any RepositoryBrowsingDataSource, history: any RepositoryFileHistoryDataSource,
         file: String, revision: Commit?, filterByRevision: Bool, showBlame: Bool,
         action: @escaping (String, [Commit], FileStatusListItem?) -> Void) {
        controller = FileHistoryViewController(source: source, history: history, file: file,
            revision: revision, filterByRevision: filterByRevision, showBlame: showBlame, action: action)
        let window = FileHistoryWindow(contentViewController: controller)
        window.title = "File History - \(file)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 748, height: 444))
        window.minSize = NSSize(width: 299, height: 198)
        window.setFrameAutosaveName("GitExtensionsMac.FileHistory")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.difftool = { [weak controller] in controller?.openDiffTool($0) ?? false }
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { controller.cancel(); onClose?() }
}

private final class FileHistoryWindow: NSWindow {
    var difftool: ((String) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let command = ApplicationHotkeys.shared.matching(event, category: "File status list"),
           ["file.difftool", "file.difftool.selectedToLocal"].contains(command), difftool?(command) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

private final class FileHistoryIconTab: NSTabViewItem {
    override func sizeOfLabel(_ computeMin: Bool) -> NSSize {
        var size = super.sizeOfLabel(computeMin)
        if image != nil { size.width += 20; size.height = max(size.height, 16) }
        return size
    }
    override func drawLabel(_ shouldTruncateLabel: Bool, in rect: NSRect) {
        guard let image else { super.drawLabel(shouldTruncateLabel, in: rect); return }
        image.draw(in: NSRect(x: rect.minX, y: rect.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        super.drawLabel(shouldTruncateLabel, in: NSRect(x: rect.minX + 20, y: rect.minY, width: max(0, rect.width - 20), height: rect.height))
    }
}

private final class FileHistoryTabs: NSTabViewController {
    var onChange: (() -> Void)?
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let control = tabView.subviews.compactMap({ $0 as? NSSegmentedControl }).first,
              control.segmentCount == tabViewItems.count else { return }
        for (index, item) in tabViewItems.enumerated() where control.image(forSegment: index) !== item.image {
            control.setImage(item.image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
    }
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onChange?()
    }
}

@MainActor
final class FileHistoryViewController: NSViewController, NSMenuDelegate {
    var onLinePatch: ((FileStatusLinePatchKind, ChangedFile, FileDiff, Set<String>) -> Void)?
    let grid = RevisionGridViewController()
    let info = CommitDetailViewController()
    let commitDiff = RevisionDiffViewController(mode: .diff, groupsByRevision: false)
    let diff = DiffContentViewController()
    let fileView = RevisionFileContentViewController()
    let blame = BlameViewController()
    let blameInfo = CommitDetailViewController()
    private let tabs = FileHistoryTabs()
    private let filters = RevisionFilterToolbar()
    private let toolbarOverflow = ToolStripOverflow()
    private let status = NSTextField(labelWithString: "")
    private let source: any RepositoryBrowsingDataSource
    private let history: any RepositoryFileHistoryDataSource
    private let action: (String, [Commit], FileStatusListItem?) -> Void
    let file: String
    private var readTask: Task<Void, Never>?
    private var viewTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private let watcher = BuildServerWatcher()
    private let report = BuildReportViewController()
    private var showBuildReport = false
    private var reader: RevisionReader?
    private var generation = 0
    private var viewGeneration = 0
    private(set) var revisions: [Commit] = []
    private(set) var selectedPath: String?
    private(set) var shownItem: FileStatusListItem?
    private(set) var isLoading = false
    private var headID: ObjectID?
    private var initialRevision: RevisionID?
    private let startsWithBlame: Bool
    private var wantsRevisionFilter: Bool
    private var configuringTabs = false
    private var diffTools: [String] = []
    private var repositoryPath: String?
    private var isBare = false
    private var isSubmodule = false
    var onShowChanges: ((ObjectID) -> Void)?
    var onFileStatusCommand: ((FileStatusListCommand) -> Void)?
    private let loadButton = SplitToolbarPopUpButton(frame: .zero, pullsDown: true)
    private let fullHistoryButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let blameOptionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var commandTab: NSTabViewItem!
    private var diffTab: NSTabViewItem!
    private var viewTab: NSTabViewItem!
    private var blameTab: NSTabViewItem!
    private var reportTab: NSTabViewItem!
    var selectedTab: String { tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex) ? tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String ?? "" : "" }

    init(source: any RepositoryBrowsingDataSource, history: any RepositoryFileHistoryDataSource,
         file: String, revision: Commit?, filterByRevision: Bool, showBlame: Bool,
         action: @escaping (String, [Commit], FileStatusListItem?) -> Void) {
        self.source = source; self.history = history; self.file = file
        self.action = action; initialRevision = revision?.objectID.map(RevisionID.object)
        startsWithBlame = showBlame; wantsRevisionFilter = filterByRevision
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { readTask?.cancel(); viewTask?.cancel(); infoTask?.cancel(); buildTask?.cancel() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 748, height: 444))
        root.autoresizingMask = [.width, .height]
        let toolbar = NSStackView(); toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        filters.grid = grid
        for control in filters.views { toolbar.addArrangedSubview(control) }
        configureMenuButton(loadButton, title: "Load file history", image: "ReloadRevisions", width: 32)
        loadButton.onPrimaryClick = { [weak self] in self?.reload() }
        configureMenuButton(fullHistoryButton, title: "Show Full History", image: "FileHistory", width: 29)
        configureMenuButton(blameOptionsButton, title: "Blame options", image: "Blame", width: 29)
        for control in [loadButton, fullHistoryButton, blameOptionsButton] { toolbar.addArrangedSubview(control) }
        let log = NSButton(title: "Command log", target: self, action: #selector(logClicked))
        toolbar.addArrangedSubview(log)
        toolbar.addArrangedSubview(toolbarOverflow.button)
        toolbarOverflow.isAvailable = { [weak self] control in
            guard let self else { return false }
            return control !== blameOptionsButton || tabs.tabViewItems.contains(blameTab)
        }
        toolbarOverflow.attach(to: toolbar, groups: filters.overflowGroups + [[loadButton], [fullHistoryButton], [blameOptionsButton], [log]])
        grid.onSelection = { [weak self] _ in self?.selectionChanged() }
        grid.onRefreshRequested = { [weak self] in self?.reload() }
        grid.onFilterChanged = { [weak self] in self?.filters.filterChanged($0) }
        grid.onShowAdvancedFilter = { [weak self] in self?.advancedFilter() }
        grid.dataSource = source as? any RepositoryRevisionGridDataSource
        grid.specializedContextMenu = { [weak self] menu, selected in self?.buildMenu(menu, selected: selected) }
        grid.onViewSelected = { [weak self] selected in self?.action("showChanges", selected, nil) }
        grid.onCommand = { [weak self] id, selected, _ in

            if id == "revision.view" || id == "revision.compare" {
                guard selected.first?.objectID != nil else { return }
                self?.action("showChanges", selected, nil)
            }
        }
        filters.resolveRevision = { [source] expression in await (source as? any RepositoryRevisionGridDataSource)?.resolveRevision(expression) }
        filters.showAdvancedFilter = { [weak self] in self?.advancedFilter() }
        info.source = source as? any RepositoryCommitInfoDataSource
        blameInfo.source = info.source
        for controller in [info, blameInfo] {
            controller.onGoToRevision = { [weak self] id in self?.grid.selectCommit(id: id) }
        }
        commitDiff.fileStatusSource = source as? any RepositoryFileStatusDataSource
        commitDiff.onLinePatch = { [weak self] kind, file, diff, ids in self?.onLinePatch?(kind, file, diff, ids) }
        commitDiff.onCommand = { [weak self] command in
            if let handler = self?.onFileStatusCommand { handler(command) }
            else { self?.action(command.identifier, [], command.focused ?? command.items.first) }
        }
        commitDiff.onFileCommand = { [weak self] id, item in self?.action(id, [], item) }
        commitDiff.filesController.canShowInFileTree = false
        commitDiff.filesController.canFilterInGrid = false
        commitDiff.onFileHistory = { [weak self] path, revision in
            guard let self, let revision else { return }
            let file = ChangedFile(id: path, path: path, oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
            let group = FileStatusGroup(first: nil, second: revision, summary: path, files: [file])
            action("file.history", [], FileStatusListItem(group: group, file: file))
        }
        diff.onOptionsChanged = { [weak self] _ in self?.selectionChanged() }
        diff.supportsDiffAppearance = true
        diff.difftasticAvailability = { [source] in await (source as? any RepositoryFileStatusDataSource)?.isDifftasticEnabled() ?? false }
        diff.linePatchingSupported = { [weak self] in
            guard let self, onLinePatch != nil, !isBare, let item = shownItem, item.file.isSubmodule == false else { return false }
            let exists = repositoryPath.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent(item.file.path).path) } ?? false
            return exists || item.file.changeType == .added
        }
        diff.onLinePatch = { [weak self] kind, file, diff, ids in self?.onLinePatch?(kind, file, diff, ids) }
        diff.supportedFileCommands = ["file.open.local", "file.showFinder", "file.difftool"]
        diff.onFileCommand = { [weak self] id, _ in
            if id == "file.blame" { self?.selectTab("blame") }
            else { self?.action(id, [], self?.shownItem) }
        }
        fileView.onEncodingChanged = { [weak self] in self?.selectionChanged() }
        fileView.onBlame = { [weak self] in self?.selectTab("blame") }
        fileView.onFileHistory = { [weak self] in self?.action("file.history", [], self?.shownItem) }
        blame.source = source as? any RepositoryBlameDataSource
        let remotes = source as? any RepositoryRemoteManagingDataSource
        blame.context = .init(revisionInGrid: { [weak self] in self?.grid.visibleRevision($0) },
            selectFileInRevision: { [weak self] id, _ in
                guard self?.grid.visibleRevision(id) != nil else { return false }
                self?.grid.selectCommit(id: .object(id)); return true
            }, hostedRemotes: { HostedRemote.gitHubRemotes((try? await remotes?.loadRemoteConfigurations()) ?? []) })
        blame.onShowChanges = { [weak self] id in
            self?.onShowChanges?(id)
        }
        blame.onSelectedCommit = { [weak self] selected in
            guard let self, let source = source as? any RepositoryBlameDataSource else { return }
            infoTask?.cancel()
            infoTask = Task { @MainActor [weak self] in
                guard let commit = try? await source.loadBlameRevision(selected.objectID), !Task.isCancelled else { return }
                self?.blameInfo.apply(commit: commit, children: [])
            }
        }
        func pane(_ first: NSViewController, _ second: NSViewController) -> NSViewController {
            let split = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
            split.splitView.isVertical = false


            split.view.frame = NSRect(x: 0, y: 0, width: 748, height: 300)
            split.addSplitViewItem(NSSplitViewItem(viewController: first))
            split.addSplitViewItem(NSSplitViewItem(viewController: second))
            split.setRetainedPosition(160)
            return split
        }
        func tab(_ id: String, _ title: String, _ controller: NSViewController) -> NSTabViewItem {
            let item = FileHistoryIconTab(viewController: controller); item.identifier = id; item.label = title
            if let image = ["commit": "CommitSummary", "diff": "Diff", "view": "ViewFile", "blame": "Blame"][id] { item.image = AppKitFactory.resourceImage(image, accessibilityDescription: title) }
            return item
        }
        commandTab = tab("commit", "Commit", pane(info, commitDiff))
        diffTab = tab("diff", "Diff", diff)
        viewTab = tab("view", "View", fileView)
        blameTab = tab("blame", "Blame", pane(blameInfo, blame))
        reportTab = tab("build", "Build Report", report)
        tabs.tabStyle = .unspecified
        tabs.tabView.tabViewType = .topTabsBezelBorder
        tabs.tabViewItems = [commandTab, diffTab, viewTab, blameTab]
        tabs.selectedTabViewItemIndex = startsWithBlame ? 3 : 1
        tabs.onChange = { [weak self] in if self?.configuringTabs == false { self?.selectionChanged() } }
        let split = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
        split.splitView.isVertical = false
        split.view.frame = NSRect(x: 0, y: 0, width: 748, height: 388)
        split.addSplitViewItem(NSSplitViewItem(viewController: grid))
        split.addSplitViewItem(NSSplitViewItem(viewController: tabs))
        split.setRetainedPosition(101)
        addChild(split); split.view.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar); root.addSubview(split.view); root.addSubview(status)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 4), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -4),
            split.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4), split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.view.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4)
        ])
        view = root
        let preferences = AppSettingsStore.shared.revisionGridPreferences
        if preferences.loadFileHistoryOnShow || (startsWithBlame && preferences.loadBlameOnShow) { reload() }
        else { grid.view.isHidden = true }
    }

    func cancel() {
        generation += 1; viewGeneration += 1
        readTask?.cancel(); viewTask?.cancel(); infoTask?.cancel(); buildTask?.cancel()
        if let reader { Task { await reader.cancel() } }
        blame.cancel(); diff.previewPresentation.cancel(); fileView.previewPresentation.cancel(); commitDiff.cancelLoads(); watcher.cancel()
    }

    func reload() {
        grid.view.isHidden = false
        let selected = grid.selectedRevisionIDs.first ?? initialRevision
        readTask?.cancel(); viewTask?.cancel(); generation += 1
        let token = generation
        isLoading = true; revisions = []; shownItem = nil
        grid.beginIncrementalLoad(preferredCommitID: selected); grid.showLoading(spinner: true)
        readTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let reader { await reader.cancel() }
                let request = try await history.fileHistoryReadRequest()
                guard !Task.isCancelled, generation == token else { return }
                reader = request.reader; headID = request.context.headID
                grid.applyAuthorIdentity(request.identity)
                repositoryPath = request.identity.currentRepository.path
                isBare = request.identity.currentRepository.isBare
                commitDiff.isBareRepository = isBare
                filters.references = {
                    .init(local: request.references.branches.filter { !$0.isRemote }.map(\.name),
                          remote: request.references.branches.filter(\.isRemote).map(\.name), tags: request.references.tags.map(\.name))
                }
                grid.updateFilter(refresh: false) { filter in
                    filter.byPathFilter = true; filter.pathFilter = "\"" + file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                    if wantsRevisionFilter, let id = initialRevision?.objectID { filter.byBranchFilter = true; filter.branchFilter = id.string }
                }
                wantsRevisionFilter = false
                var options = grid.readOptions
                options.followRenamesExactOnly = AppSettingsStore.shared.revisionGridPreferences.followRenamesInFileHistoryExactOnly
                for try await batch in await request.reader.read(request.context.with(options), maximumCount: AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount) {
                    guard !Task.isCancelled, generation == token else { return }
                    revisions += batch; grid.appendIncrementalBatch(batch)
                }
                guard !Task.isCancelled, generation == token else { return }
                grid.finishLoading(isBareRepository: isBare)
                if let selected, revisions.contains(where: { $0.id == selected }) { grid.selectCommit(id: selected) }
                else if selected == nil, !grid.userSelectedDuringLoad, let first = revisions.first(where: { !$0.isArtificial }) { grid.selectCommit(id: first.id) }
                initialRevision = nil; isLoading = false
                status.stringValue = "\(revisions.filter { !$0.isArtificial }.count) revisions"
                selectionChanged(); launchBuildWatcher()
                diffTools = AppSettingsStore.shared.fileViewerPreferences.availableDiffTools((try? await (source as? any RepositoryFileStatusDataSource)?.loadDiffTools()) ?? [])
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                isLoading = false; status.stringValue = error.localizedDescription; grid.finishLoading(failed: true)
            }
        }
    }

    func selectTab(_ id: String) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == id }) { tabs.selectedTabViewItemIndex = index }
    }

    private func selectionChanged() {
        viewTask?.cancel(); infoTask?.cancel(); blame.cancel(); diff.previewPresentation.cancel(); fileView.previewPresentation.cancel(); viewGeneration += 1
        shownItem = nil
        let token = viewGeneration
        let selected = grid.selectedRevisionIDsBySelectionOrder.compactMap { id in revisions.first { $0.id == id } }
        guard let commit = selected.first, let reader else { return }
        viewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let exact = AppSettingsStore.shared.revisionGridPreferences.followRenamesInFileHistoryExactOnly
                let path = if let id = commit.objectID ?? headID { await reader.fileName(at: id, path: file, exactOnly: exact) } else { file }
                let entry = file.hasSuffix("/") ? nil : try await source.loadRepositoryFiles(for: commit).first { $0.path == path }
                guard !Task.isCancelled, token == viewGeneration else { return }
                selectedPath = path
                let folder = file.hasSuffix("/")
                let available = entry != nil
                configureTabs(commit: commit, available: available, folder: folder, submodule: entry?.gitObjectType == "commit")
                isSubmodule = entry?.gitObjectType == "commit"
                blameOptionsButton.isHidden = isSubmodule || folder || !available
                fileView.canBlame = available && !commit.isArtificial && entry?.gitObjectType != "commit"
                if fileView.canBlame { diff.supportedFileCommands.insert("file.blame") }
                else { diff.supportedFileCommands.remove("file.blame") }
                let children = CommitRelationsResolver.resolve(commit: commit, history: revisions).childIDs


                let actual = if let id = commit.objectID, let resolved = source as? any RepositoryBlameDataSource {
                    try await resolved.loadBlameRevision(id)
                } else { commit }
                guard !Task.isCancelled, token == viewGeneration else { return }
                let first = selected.count > 1 ? selected.last!.id : FileStatusDiffCalculator.parents(of: actual, headID: headID).first
                var oldPath: String?
                if let id = first?.objectID {
                    let old = await reader.fileName(at: id, path: file, exactOnly: exact)
                    if old != path { oldPath = old }
                }
                let changed = ChangedFile(id: path, path: path, oldPath: oldPath, changeType: first == nil ? .added : .modified, additions: 0, deletions: 0)
                let group = FileStatusGroup(first: first, second: commit.id, summary: path, files: [changed])
                shownItem = FileStatusListItem(group: group, file: changed)
                diff.selectionScope = commit.kind == .workingDirectory ? .workingTree : commit.kind == .index ? .index : .revision
                view.window?.title = "File History - \(file)" + (path == file ? "" : " (\(path))") + (repositoryPath.map { " - \($0)" } ?? "")
                switch selectedTab {
                case "commit":
                    info.apply(commit: commit, children: children)
                    commitDiff.fallbackFollowedFile = path
                    commitDiff.setDiffs(revisions: [actual], headID: headID)
                case "view":
                    if let entry {
                        fileView.applyRevision(commit); fileView.apply(file: entry, selectedPath: path)
                        let presentation = try await source.prepareFilePresentation(for: commit, file: entry, encoding: fileView.selectedEncoding)
                        guard !Task.isCancelled, token == viewGeneration else { return }
                        fileView.apply(preview: presentation, file: entry)
                    }
                case "blame":
                    blameInfo.apply(commit: commit, children: children)
                    if let id = commit.objectID { blame.load(revision: id, file: path, encoding: fileView.selectedEncoding) }
                case "diff":
                    if let files = source as? any RepositoryFileStatusDataSource {
                        diff.apply(file: changed, diff: nil)
                        let content = try await files.prepareFileStatusPreview(group: group, file: changed, options: diff.diffOptions, grep: GitGrepOptions())
                        guard !Task.isCancelled, token == viewGeneration else { return }
                        diff.apply(preview: content, file: changed)
                    }
                default: break
                }
            } catch {
                guard !Task.isCancelled, token == viewGeneration else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func configureTabs(commit: Commit, available: Bool, folder: Bool, submodule: Bool) {
        let previous = selectedTab
        var items: [NSTabViewItem] = []
        if !commit.isArtificial { commandTab.label = "Commit" + (folder || available ? "" : " - Git could not identify the file"); items.append(commandTab) }
        if available { items.append(diffTab) }
        if available && !commit.isArtificial { items.append(viewTab); if !submodule { items.append(blameTab) } }
        let info = grid.selectedCommitCount == 1 ? grid.buildStatus(for: commit.id) : nil
        let url = info?.url
        report.show(showBuildReport ? info : nil)
        if showBuildReport && url != nil { items.append(reportTab) }
        configuringTabs = true
        if tabs.tabViewItems != items { tabs.tabViewItems = items }
        if let index = items.firstIndex(where: { $0.identifier as? String == previous }) { tabs.selectedTabViewItemIndex = index }
        else if let index = items.firstIndex(where: { $0 === (commit.isArtificial ? diffTab : commandTab) }) { tabs.selectedTabViewItemIndex = index }
        configuringTabs = false
    }

    @objc private func loadClicked() { reload() }
    @objc private func logClicked() { action("commandLog", [], nil) }
    private func advancedFilter() {
        guard let window = view.window else { return }
        RevisionFilterDialogController.present(filter: grid.currentFilter, defaultLimit: AppSettingsStore.shared.browseDisplayPreferences.maximumRevisionCount, window: window) { [weak self] result in
            if let result { self?.grid.updateFilter { $0 = result } }
        }
    }

    private func configureMenuButton(_ button: NSPopUpButton, title: String, image: String, width: CGFloat) {
        button.addItem(withTitle: title)
        button.item(at: 0)?.image = AppKitFactory.resourceImage(image, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.controlSize = .small
        button.bezelStyle = .texturedRounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.menu?.autoenablesItems = false
        button.menu?.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === loadButton.menu { buildLoadOptions(menu) }
        else if menu === fullHistoryButton.menu { buildHistoryOptions(menu) }
        else if menu === blameOptionsButton.menu { buildBlameOptions(menu) }
    }

    private func startOptions(_ menu: NSMenu, title: String) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    }

    private func add(_ title: String, id: String, to menu: NSMenu, enabled: Bool = true, checked: Bool? = nil) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self; item.identifier = .init(id); item.isEnabled = enabled
        if let image = ["file.difftool": "Diff", "file.save": "SaveAs", "revert": "RevertCommit", "cherryPick": "CherryPick"][id] { AppKitFactory.setMenuImage(image, for: item) }
        if let checked { item.state = checked ? .on : .off }
        if id == "file.difftool" || id == "file.difftool.selectedToLocal", let chord = ApplicationHotkeys.shared.chord(for: id) {
            item.keyEquivalent = chord.key; item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: chord.modifiers)
        }
        menu.addItem(item)
    }
    private func buildLoadOptions(_ menu: NSMenu) {
        startOptions(menu, title: "Load file history")
        let p = AppSettingsStore.shared.revisionGridPreferences
        add("Load history on show", id: "loadHistory", to: menu, checked: p.loadFileHistoryOnShow)
        add("Load blame on show", id: "loadBlame", to: menu, checked: p.loadBlameOnShow && tabs.tabViewItems.contains(blameTab))
    }

    private func buildHistoryOptions(_ menu: NSMenu) {
        startOptions(menu, title: "Show Full History")
        let p = AppSettingsStore.shared.revisionGridPreferences
        add("Show full history", id: "full", to: menu, checked: p.fullHistoryInFileHistory)
        add("Simplify merges", id: "simplify", to: menu, enabled: p.fullHistoryInFileHistory, checked: p.simplifyMergesInFileHistory)
    }

    private func buildBlameOptions(_ menu: NSMenu) {
        startOptions(menu, title: "Blame options")
        let b = AppSettingsStore.shared.blamePreferences
        add("Blame settings:", id: "blame.caption.settings", to: menu, enabled: false)
        for (id, label, value) in [("ignoreWhitespace", "Ignore whitespace", b.ignoreWhitespace),
            ("detectCopyInFile", "Detect move and copy in this file", b.detectCopyInFile),
            ("detectCopyInAll", "Detect move and copy in all files", b.detectCopyInAll)] {
            add(label, id: "blame." + id, to: menu, checked: value)
        }
        menu.addItem(.separator())
        add("Display result settings:", id: "blame.caption.display", to: menu, enabled: false)
        for (id, label, value) in [("displayAuthorFirst", "Display author first", b.displayAuthorFirst),
            ("showAuthorAvatar", "Show author avatar", b.showAuthorAvatar), ("showAuthor", "Show author", b.showAuthor),
            ("showAuthorDate", "Show author date", b.showAuthorDate), ("showAuthorTime", "Show author time", b.showAuthorTime),
            ("showLineNumbers", "Show line numbers", b.showLineNumbers), ("showOriginalFilePath", "Show original file path", b.showOriginalFilePath)] {
            add(label, id: "blame." + id, to: menu, enabled: id != "showAuthorTime" || b.showAuthorDate, checked: value)
        }
    }

    func buildMenu(_ menu: NSMenu, selected: [Commit]) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        let real = selected.first?.isArtificial == false
        let single = selected.count == 1
        populatePlaceholderMenu(menu, with: [RevisionContextMenuBuilder.copyMenu(selected)])
        let copy = menu.items.first!
        copy.isEnabled = real && !selected.isEmpty
        if let submenu = copy.submenu {
            for entry in submenu.items where entry.isEnabled {
                entry.target = self
                entry.action = #selector(menuAction(_:))
            }
        }
        AppKitFactory.applyRevisionCopyImages(to: menu)
        menu.addItem(.separator())
        let canDiff = (1...2).contains(selected.count) && shownItem != nil
        add("Open with difftool", id: "file.difftool", to: menu, enabled: canDiff)
        if !diffTools.isEmpty {
            let tools = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
            let toolMenu = NSMenu(); toolMenu.autoenablesItems = false
            for tool in diffTools { add(tool, id: "difftool.named." + tool, to: toolMenu, enabled: canDiff) }
            toolMenu.addItem(.separator()); add("Disable", id: "difftool.disableTools", to: toolMenu, enabled: true)
            tools.submenu = toolMenu; menu.addItem(tools)
        }
        let exists = repositoryPath.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent(selectedPath ?? file).path) } ?? false
        add("Difftool selected < - > local", id: "file.difftool.selectedToLocal", to: menu, enabled: single && !isBare && exists && selected.first?.kind != .workingDirectory && shownItem != nil)
        if !diffTools.isEmpty {
            let tools = NSMenuItem(title: "Selected < - > local with", action: nil, keyEquivalent: "")
            let toolMenu = NSMenu(); toolMenu.autoenablesItems = false
            for tool in diffTools { add(tool, id: "difftool.local." + tool, to: toolMenu, enabled: single && !isBare && exists && selected.first?.kind != .workingDirectory && shownItem != nil) }
            toolMenu.addItem(.separator()); add("Disable", id: "difftool.disableTools", to: toolMenu, enabled: true)
            tools.submenu = toolMenu; menu.addItem(tools)
        }
        if !isSubmodule { add("Save as", id: "file.save", to: menu, enabled: single && shownItem != nil) }
        let manipulate = NSMenuItem(title: "Manipulate commit", action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.autoenablesItems = false
        add("Revert commit", id: "revert", to: sub, enabled: single && real && !isBare)
        add("Cherry pick commit", id: "cherryPick", to: sub, enabled: single && real && !isBare)
        manipulate.submenu = sub; manipulate.isEnabled = single && real && !isBare; menu.addItem(manipulate)
        menu.addItem(.separator())
        let p = AppSettingsStore.shared.revisionGridPreferences
        add("Detect and follow renames", id: "follow", to: menu, checked: p.followRenamesInFileHistory)
        add("Detect and follow - exact renames and copies only", id: "exact", to: menu, enabled: p.followRenamesInFileHistory, checked: p.followRenamesInFileHistoryExactOnly)
        menu.addItem(.separator())
        for (title, commands) in [("Navigate", RevisionGridMenuModel.navigate(grid.menuState)), ("View", RevisionGridMenuModel.view(grid.menuState))] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(); RevisionGridMenuModel.fill(submenu, commands, target: self, action: #selector(gridAction(_:)))
            item.submenu = submenu; menu.addItem(item)
        }
    }
    @objc private func gridAction(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { _ = grid.performGridCommand(id) } }
    func openDiffTool(_ identifier: String = "file.difftool") -> Bool {
        let selected = grid.selectedRevisionIDsBySelectionOrder.compactMap { id in revisions.first { $0.id == id } }
        guard (1...2).contains(selected.count), let shownItem else { return false }
        if identifier == "file.difftool.selectedToLocal" {
            guard selected.count == 1, selected.first?.kind != .workingDirectory, !isBare,
                  let repositoryPath, FileManager.default.fileExists(atPath: URL(fileURLWithPath: repositoryPath).appendingPathComponent(shownItem.file.path).path) else { return false }
        }
        action(identifier, selected, shownItem); return true
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        if id.hasPrefix("revision.copy") { grid.copyToClipboard(id); return }
        if id == "difftool.disableTools" {
            var viewer = AppSettingsStore.shared.fileViewerPreferences
            viewer.showAvailableDiffTools = false
            AppSettingsStore.shared.saveFileViewerPreferences(viewer)
            diffTools = []
            return
        }
        var p = AppSettingsStore.shared.revisionGridPreferences
        switch id {
        case "loadHistory": p.loadFileHistoryOnShow.toggle()
        case "loadBlame": p.loadBlameOnShow.toggle()
        case "full": p.fullHistoryInFileHistory.toggle()
        case "simplify": p.simplifyMergesInFileHistory.toggle()
        case "follow": p.followRenamesInFileHistory.toggle()
        case "exact": p.followRenamesInFileHistoryExactOnly.toggle()
        default:
            if id.hasPrefix("blame.") {
                var b = AppSettingsStore.shared.blamePreferences
                let keys: [String: WritableKeyPath<BlamePreferences, Bool>] = ["ignoreWhitespace": \.ignoreWhitespace, "detectCopyInFile": \.detectCopyInFile,
                    "detectCopyInAll": \.detectCopyInAll, "displayAuthorFirst": \.displayAuthorFirst, "showAuthor": \.showAuthor, "showAuthorDate": \.showAuthorDate,
                    "showAuthorTime": \.showAuthorTime, "showLineNumbers": \.showLineNumbers, "showOriginalFilePath": \.showOriginalFilePath, "showAuthorAvatar": \.showAuthorAvatar]
                if let key = keys[String(id.dropFirst(6))] { b[keyPath: key].toggle() }
                if !b.showAuthor { b.showAuthorDate = true }; if !b.showAuthorDate { b.showAuthor = true }
                AppSettingsStore.shared.saveBlamePreferences(b); return
            }
            let selected = grid.selectedRevisionIDsBySelectionOrder.compactMap { id in revisions.first { $0.id == id } }
            action(id, selected, shownItem); return
        }
        AppSettingsStore.shared.saveRevisionGridPreferences(p)
        if !id.hasPrefix("load") { reload() }
    }

    private func launchBuildWatcher() {
        buildTask?.cancel(); watcher.cancel()
        guard let remotes = source as? any RepositoryRemoteManagingDataSource, let settings = source as? any RepositorySettingsDataSource else { return }
        let hosting = source as? any RepositoryHostingDataSource
        buildTask = Task { @MainActor [weak self] in
            let configs = (try? await remotes.loadRemoteConfigurations()) ?? []
            let locations = try? await DistributedSettings.loadLocations(from: settings)
            let values = (try? BuildServerSettingsStore(locations: locations).values(.effective)) ?? [:]
            let resolved = await BuildServerAdapterResolver.resolve(settings: values, remotes: configs, currentRemote: nil,
                credential: { await hosting?.hostCredentialPassword(for: $0) },
                isCommitVisible: { [weak self] id in await MainActor.run { self?.revisions.contains { $0.id == .object(id) } ?? false } })
            guard let self, !Task.isCancelled else { return }
            showBuildReport = BuildServerSettingsStore.bool(values[BuildServerSettingKeys.showBuildResultPage]) ?? false
            grid.setBuildStatusColumn(enabled: resolved.adapter != nil || resolved.explicitlyEnabled)
            watcher.onUpdate = { [weak self] infos in self?.grid.applyBuildInfos(infos); self?.selectionChanged() }
            watcher.onInitializationError = { [weak self] error in BuildServerErrorPresenter.present(error, window: self?.view.window) { self?.action("settings", [], nil) } }
            watcher.launch(resolved.adapter)
        }
    }
}
