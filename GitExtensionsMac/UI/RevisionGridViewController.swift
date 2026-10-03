import GitExtensionsCore
import GitCommands
import AppKit


@MainActor
enum RevisionGridMessages {
    static var present: (_ message: String, _ caption: String) -> Void = { message, caption in
        let alert = NSAlert(); alert.messageText = caption; alert.informativeText = message; alert.alertStyle = .warning
        alert.runModal()
    }
    static func error(_ message: String, caption: String = "Error") { present(message, caption) }
    static func revisionFilteredInGrid(_ id: RevisionID) {
        present("Revision \"\(id.objectID?.shortString ?? id.description)\" is not visible in the revision grid. Remove the revision filter.", "Cannot find revision")
    }
}

final class RevisionGridViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onScript: ((ScriptDefinition) -> Void)?
    var onCommand: ((String, [Commit], Commit) -> Void)?
    var selectedCommitCount: Int { tableView.selectedRowIndexes.count }
    var selectedRevisionIDs: [RevisionID] { tableView.selectedRowIndexes.compactMap { commits.indices.contains($0) ? commits[$0].id : nil } }

    var selectedRevisionIDsBySelectionOrder: [RevisionID] {
        let selected = selectedRevisionIDs
        let ordered = selectionOrder.reversed().filter(selected.contains)
        return ordered + selected.filter { !ordered.contains($0) }
    }
    private var selectionOrder: [RevisionID] = []
    var onSelection: ((Commit) -> Void)?


    var specializedContextMenu: ((NSMenu, [Commit]) -> Void)?
    var onViewSelected: (([Commit]) -> Void)?
    var allowsArtificialViewSelection = false
    var allowsMultipleRevisionSelection = true { didSet { tableView.allowsMultipleSelection = allowsMultipleRevisionSelection } }
    private(set) var comparisonBase: Commit?
    private var isBareRepository = false

    private let tableView = RevisionTableView()
    private let quickSearchLabel = NSTextField(labelWithString: "")
    private var allCommits: [Commit] = []
    private var pendingOpeningSelection: [RevisionID] = []
    private var graphReloadPending = false
    private var commits: [Commit] = []
    private var repositoryStatus: RepositoryStatusSummary?
    private var highlightedAuthorEmail: String?
    private var graphRows: [RevisionGraphLayout.Row] = []

    private var sessionFilter = RevisionGridFilter()

    var onRefreshRequested: (() -> Void)?

    var onFilterChanged: ((RevisionGridFilter) -> Void)?
    private var showsTagReferences = AppSettingsStore.shared.tagPreferences.showTagsInRevisionGrid
    private var visibleRowsObserver: NSObjectProtocol?
    private var quickSearchString = ""
    private var lastQuickSearchString = ""
    private var quickSearchTimer: Timer?
    private var menuFocusedCommitID: RevisionID?
    private var isCherryPicking = false
    private var cherryPickHasConflicts = false
    private var isRebasing = false
    private var rebaseHasConflicts = false
    private var isBisecting = false
    private var graphTask: Task<Void, Never>?
    private var graphCache = RevisionGraphCache()
    private var historyCompleted = true
    private var graphRelatives = Set<RevisionID>()
    private var graphCacheRequestedThrough = -1
    private var graphScrollPending = false
    private var graphGeneration = 0
    private var pendingSelectionID: RevisionID?
    private var pendingFirstVisibleID: RevisionID?
    private var lastViewportSize = NSSize.zero
    private var graphWidthRefreshScheduled = false
    private var graphConfiguration = RevisionGraphLayout.Configuration.gitExtensionsDefault
    private var graphLayoutConfiguration = RevisionGraphLayout.Configuration.gitExtensionsDefault
    private var displayedGraph = RevisionGraphLayout(rows: [], maximumLaneCount: 1)
    private var graphCommits: [RevisionID: Commit] = [:]
    private var buildStatuses: [RevisionID: BuildInfo] = [:]
    private var buildColumnEnabled = false
    private static let buildColumn = "Build Status"

    deinit {
        graphTask?.cancel()
        if let visibleRowsObserver {
            NotificationCenter.default.removeObserver(visibleRowsObserver)
        }
    }

    override func loadView() {
        let scrollView = RevisionGridScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true

        tableView.headerView = nil
        tableView.rowHeight = BrowserMetrics.revisionRowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = allowsMultipleRevisionSelection

        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.backgroundColor = .controlBackgroundColor

        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(openSelectedCommit)
        tableView.target = self
        tableView.copySelectedRows = { [weak self] in self?.copySelectedCommitIDs() }
        tableView.handleQuickSearchKey = { [weak self] event in
            self?.handleQuickSearchKey(event) ?? false
        }
        tableView.handleNavigationKey = { [weak self] command in
            self?.performShortcut(command) ?? false
        }
        tableView.handleAddRelatedRefClick = { [weak self] event in self?.handleAddRelatedRefClick(event) ?? false }
        tableView.highlightSelectedBranch = { [weak self] in self?.highlightSelectedBranch() }
        tableView.handleDoubleClickLabel = { [weak self] event in self?.handleDoubleClickLabel(event) ?? false }
        tableView.navigateHistory = { [weak self] backward in
            if backward { self?.navigateBackward() } else { self?.navigateForward() }
        }
        tableView.dropPatchFiles = { [weak self] urls in self?.dropPatchFiles(urls) ?? false }
        tableView.userInteracted = { [weak self] in
            guard let self, isShowingLoading else { return }
            pendingSelectionID = nil
            userSelectedDuringLoad = true
        }
        tableView.registerForDraggedTypes([.fileURL])

        addColumn("Graph", width: 54, min: 22, max: 646, resizable: false)
        addColumn("Message", width: 500, min: 25, max: 100_000, resizable: true)

        addColumn("Notes", width: 50, min: 25, max: 1_600, resizable: true)

        addColumn("Avatar", width: BrowserMetrics.revisionRowHeight, min: 16, max: 64, resizable: false)
        addColumn("Author Name", width: 130, min: 25, max: 320, resizable: true)

        let dateWidth = AppSettingsStore.shared.revisionGridPreferences.relativeDate ? 130
            : ceil((RevisionGridPresentation.absoluteDate(Date()) as NSString).size(withAttributes: [.font: AppSettingsStore.shared.applicationFont(size: 11)]).width) + 8
        addColumn("Date", width: dateWidth, min: 25, max: 220, resizable: true)
        addColumn("Commit ID", width: 60, min: 32, max: 330, resizable: true)
        applyColumnSettings()
        addColumn(Self.buildColumn, width: 150, min: 16, max: 800, resizable: true)
        applyBuildStatusColumnSettings()
        tableView.action = #selector(gridClicked)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView

        quickSearchLabel.isHidden = true
        quickSearchLabel.font = AppSettingsStore.shared.applicationFont(size: 11, weight: .bold)
        quickSearchLabel.textColor = .controlTextColor
        quickSearchLabel.drawsBackground = true
        quickSearchLabel.backgroundColor = .controlBackgroundColor
        quickSearchLabel.translatesAutoresizingMaskIntoConstraints = false
        quickSearchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrollView.addSubview(quickSearchLabel)
        NSLayoutConstraint.activate([
            quickSearchLabel.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 4),
            quickSearchLabel.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 4),
            quickSearchLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
        view = scrollView

        visibleRowsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleGraphColumnWidthRefresh()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let viewportSize = view.bounds.size
        guard viewportSize != lastViewportSize else { return }
        lastViewportSize = viewportSize
        fitMessageColumn()
        scheduleGraphColumnWidthRefresh()
    }

    func apply(commits: [Commit], preferredCommitID: RevisionID? = nil) {
        historyCompleted = true
        pendingSelectionID = preferredCommitID
        allCommits = commits
        applyFilters(selectFirst: true)
    }


    private(set) var userSelectedDuringLoad = false

    func beginIncrementalLoad(preferredCommitID: RevisionID? = nil) {
        graphTask?.cancel()
        graphGeneration += 1
        graphCache = RevisionGraphCache()
        graphCacheRequestedThrough = -1
        graphScrollPending = false
        historyCompleted = false
        graphRelatives = []
        graphConfiguration.highlightedRevision = nil
        graphConfiguration.drawStyle = .drawNonRelativesGray
        userSelectedDuringLoad = false
        pendingOpeningSelection = []
        pendingSelectionID = preferredCommitID
        allCommits = []
        commits = []
        graphRows = []
        buildStatuses = [:]
        tableView.reloadData()
    }


    func applyColumnSettings() {
        let preferences = AppSettingsStore.shared.revisionGridPreferences
        for (identifier, visible) in [("Graph", preferences.showGraphColumn), ("Notes", preferences.showNotesColumn),
                                      ("Avatar", preferences.showAuthorAvatarColumn),
                                      ("Author Name", preferences.showAuthorNameColumn), ("Date", preferences.showDateColumn),
                                      ("Commit ID", preferences.showObjectIDColumn)] {
            tableView.tableColumn(withIdentifier: .init(identifier))?.isHidden = !visible
        }
        fitMessageColumn()
        tableView.reloadData()
    }

    func setBuildStatusColumn(enabled: Bool) {
        buildColumnEnabled = enabled
        applyBuildStatusColumnSettings()
    }
    func applyBuildStatusColumnSettings() {
        guard let column = tableView.tableColumn(withIdentifier: .init(Self.buildColumn)) else { return }
        let icon = AppSettingsStore.shared.showBuildStatusIconColumn, text = AppSettingsStore.shared.showBuildStatusTextColumn
        column.isHidden = !(buildColumnEnabled && (icon || text))
        column.resizingMask = text ? .userResizingMask : []
        if icon && !text { column.width = 16 } else if text && column.width == 16 { column.width = 150 }
        fitMessageColumn()
        tableView.reloadData()
    }
    func applyBuildInfos(_ infos: [BuildInfo]) {
        var changed = IndexSet()
        for info in infos {
            for id in info.revisions where info.replaces(buildStatuses[id]) {
                guard allCommits.contains(where: { $0.id == id }) else { continue }
                buildStatuses[id] = info
                if let row = commits.firstIndex(where: { $0.id == id }) { changed.insert(row) }
            }
        }
        guard !changed.isEmpty, let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == Self.buildColumn }) else { return }
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: column))
    }
    func buildStatus(for id: RevisionID?) -> BuildInfo? { id.flatMap { buildStatuses[$0] } }
    static func buildStatusColor(_ status: BuildStatus) -> NSColor? {
        switch status {
        case .unknown: nil
        case .success: .systemGreen
        case .failure: .systemRed
        case .inProgress: .systemBlue
        case .unstable: .systemOrange
        case .stopped: .systemGray
        }
    }
    static func buildStatusText(_ info: BuildInfo, icon: Bool, text: Bool) -> String {
        (icon ? info.status.symbol : "") + (text ? info.description ?? "" : "")
    }
    @objc private func gridClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedColumn >= 0,
              tableView.tableColumns[tableView.clickedColumn].identifier.rawValue == Self.buildColumn,
              commits.indices.contains(tableView.clickedRow),
              let url = buildStatuses[commits[tableView.clickedRow].id]?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func appendIncrementalBatch(_ batch: [Commit]) {
        guard !batch.isEmpty else { return }
        if loadingSpinner?.isHidden == false { showLoading(spinner: false) }
        allCommits.append(contentsOf: batch)
        applyFilters(selectFirst: true, preservingViewport: !selectedCommits.isEmpty)
    }

    func setCherryPickInProgress(_ inProgress: Bool, hasConflicts: Bool = false) {
        isCherryPicking = inProgress
        cherryPickHasConflicts = hasConflicts
    }

    func setRebaseInProgress(_ inProgress: Bool, hasConflicts: Bool) {
        isRebasing = inProgress
        rebaseHasConflicts = hasConflicts
    }

    func setBisectInProgress(_ inProgress: Bool) {
        isBisecting = inProgress
    }


    var currentFilter: RevisionGridFilter {
        let store = AppSettingsStore.shared
        var filter = sessionFilter
        filter.showCurrentBranchOnly = store.revisionGridRuntime.showCurrentBranchOnly
        filter.byBranchFilter = store.revisionGridRuntime.branchFilterEnabled
        filter.showReflogReferences = store.revisionGridRuntime.showReflogReferences
        let preferences = store.revisionGridPreferences
        filter.showOnlyFirstParent = preferences.showOnlyFirstParent
        filter.hideMergeCommits = preferences.hideMergeCommits
        filter.showSimplifyByDecoration = preferences.showSimplifyByDecoration
        filter.showFullHistory = preferences.fullHistoryInFileHistory
        filter.showSimplifyMerges = preferences.simplifyMergesInFileHistory
        return filter
    }


    func updateFilter(refresh: Bool = true, _ change: (inout RevisionGridFilter) -> Void) {
        var filter = currentFilter
        change(&filter)
        let store = AppSettingsStore.shared
        store.revisionGridRuntime.showCurrentBranchOnly = filter.showCurrentBranchOnly
        store.revisionGridRuntime.branchFilterEnabled = filter.byBranchFilter
        store.revisionGridRuntime.showReflogReferences = filter.showReflogReferences
        var preferences = store.revisionGridPreferences
        preferences.showOnlyFirstParent = filter.showOnlyFirstParent
        preferences.hideMergeCommits = filter.hideMergeCommits
        preferences.showSimplifyByDecoration = filter.showSimplifyByDecoration
        preferences.fullHistoryInFileHistory = filter.showFullHistory
        preferences.simplifyMergesInFileHistory = filter.showSimplifyMerges
        if preferences != store.revisionGridPreferences { store.saveRevisionGridPreferences(preferences) }
        sessionFilter = filter
        if refresh { requestRefresh() }
    }

    func requestRefresh() {
        onFilterChanged?(currentFilter)
        onRefreshRequested?()
    }



    func showAllBranches() {
        guard !currentFilter.isShowAllBranchesChecked else { return }
        updateFilter { $0.byBranchFilter = false; $0.showCurrentBranchOnly = false }
    }
    func showCurrentBranchOnly() {
        guard !currentFilter.isShowCurrentBranchOnlyChecked else { return }
        updateFilter { $0.byBranchFilter = false; $0.showCurrentBranchOnly = true }
    }
    func showFilteredBranches() {
        guard !currentFilter.isShowFilteredBranchesChecked else { return }

        updateFilter { $0.byBranchFilter = true; $0.showCurrentBranchOnly = false }
    }
    func toggleShowReflogReferences() { updateFilter { $0.showReflogReferences.toggle() } }
    func toggleShowOnlyFirstParent() { updateFilter { $0.showOnlyFirstParent.toggle() } }
    func toggleHideMergeCommits() { updateFilter { $0.hideMergeCommits.toggle() } }
    func setAndApplyBranchFilter(_ filter: String) { updateFilter { $0.setBranchFilter(filter) } }
    func setAndApplyRevisionFilter(_ filter: RevisionGridFilter.TextFilter) {
        var next = currentFilter
        guard next.apply(filter) else { return }
        updateFilter { $0 = next }
    }
    func setAndApplyPathFilter(_ path: String) {
        updateFilter { filter in
            filter.byPathFilter = !path.trimmingCharacters(in: .whitespaces).isEmpty
            if filter.byPathFilter { filter.pathFilter = path }
        }
    }
    func resetAllFiltersAndRefresh() { updateFilter { $0.resetAllFilters() } }


    var readOptions: RevisionReadOptions {
        let store = AppSettingsStore.shared
        let preferences = store.revisionGridPreferences
        var options = RevisionReadOptions()
        options.filter = currentFilter
        options.sortOrder = store.revisionGridRuntime.sortOrder
        options.showStashes = preferences.showStashes
        options.showGitNotes = preferences.showGitNotes
        options.showSessionRefs = preferences.showSessionRefs
        options.showArtificialCommits = preferences.showArtificialCommits
        options.loadNotes = preferences.showGitNotes || preferences.showNotesColumn
        options.followRenames = preferences.followRenamesInFileHistory
        return options
    }

    func setShowsTagReferences(_ value: Bool) {
        guard value != showsTagReferences else { return }
        showsTagReferences = value
        tableView.reloadData()
    }

    func selectCommit(id: RevisionID) {
        guard let index = commits.firstIndex(where: { $0.id == id }) else {
            if allCommits.contains(where: { $0.id == id }) { pendingSelectionID = id }
            return
        }


        pendingSelectionID = graphReloadPending ? id : nil
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        onSelection?(commits[index])
    }

    func scrollRevisionToTop(_ id: RevisionID) {
        pendingFirstVisibleID = id
        guard !graphReloadPending, let row = commits.firstIndex(where: { $0.id == id }),
              let scroll = tableView.enclosingScrollView else { return }
        pendingFirstVisibleID = nil
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: tableView.rect(ofRow: row).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func selectCommits(ids: [RevisionID]) {
        pendingOpeningSelection = ids
        guard !graphReloadPending else { return }
        let requested = Set(ids)
        let indices = IndexSet(commits.indices.filter { requested.contains(commits[$0].id) })
        guard let first = indices.first else { return }
        pendingOpeningSelection = []
        pendingSelectionID = nil
        tableView.selectRowIndexes(indices, byExtendingSelection: false)
        tableView.scrollRowToVisible(first)
        onSelection?(commits[first])
    }

    var visibleCommitCount: Int { commits.count }
    var cachedGraphRowCount: Int { graphRows.count }
    func visibleRevision(_ id: ObjectID) -> Commit? { commits.first { $0.objectID == id } }

    func reloadAppearance() {
        applyFilters(selectFirst: false, preservingViewport: true)
    }

    func highlightSelectedBranch() {
        guard let selected = latestSelected else { return }
        graphConfiguration.highlightedRevision = selected.id
        applyFilters(selectFirst: false, preservingViewport: true)
    }

    func applyStatus(_ status: RepositoryStatusSummary) {
        repositoryStatus = status
        tableView.reloadData()
    }

    func setGraphConfiguration(mergeCommonParentLanes: Bool, straightenDiagonals: Bool, renderWithDiagonals: Bool = true) {
        var configuration = RevisionGraphLayout.Configuration(
            mergeCommonParentLanes: mergeCommonParentLanes,
            straightenDiagonals: straightenDiagonals,
            renderWithDiagonals: renderWithDiagonals
        )
        configuration.highlightedRevision = graphConfiguration.highlightedRevision
        configuration.drawStyle = graphConfiguration.drawStyle
        configuration.colorCount = GitExtensionsPalette.graph.count
        guard configuration != graphConfiguration else { return }
        graphConfiguration = configuration
        applyFilters(selectFirst: false, preservingViewport: true)
    }

    private func applyFilters(selectFirst: Bool, preservingViewport: Bool = false) {
        let filteredCommits = allCommits
        let selectedIDs = preservingViewport ? Set(selectedCommits.map(\.id)) : []
        let viewport = tableView.enclosingScrollView?.contentView.bounds.origin

        let completeHistory = allCommits
        var configuration = graphConfiguration
        configuration.drawStyle = configuration.highlightedRevision != nil ? .highlightSelected
            : (AppSettingsStore.shared.colorPreferences.nonRelativeGraphGray ? .drawNonRelativesGray : .normal)
        configuration.onlyFirstParent = currentFilter.showOnlyFirstParent
        configuration.colorCount = GitExtensionsPalette.graph.count
        graphGeneration += 1
        graphReloadPending = true
        graphScrollPending = false
        let generation = graphGeneration
        let cache = graphCache
        let completed = historyCompleted
        let visible = tableView.rows(in: tableView.visibleRect)
        let visibleCount = max(30, visible.length)
        let through = (visible.location == NSNotFound ? 0 : visible.location) + 2 * visibleCount
        graphCacheRequestedThrough = through
        graphTask?.cancel()
        graphTask = Task { @MainActor [weak self] in

            await Task.yield()
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try await cache.prepare(commits: filteredCommits, completeHistory: completeHistory,
                                        configuration: configuration, through: through, completed: completed)
            }
            let snapshot: RevisionGraphCache.Snapshot
            do {
                snapshot = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
            } catch { return }
            guard let self, !Task.isCancelled, generation == self.graphGeneration else { return }
            let graph = snapshot.layout
            self.graphReloadPending = false
            let byID = Dictionary(filteredCommits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let orderedCommits = snapshot.orderedIDs.compactMap { byID[$0] }
            self.commits = orderedCommits
            self.graphRows = graph.rows
            self.displayedGraph = graph
            self.graphCommits = byID
            self.graphRelatives = snapshot.relatives
            self.graphLayoutConfiguration = graph.configuration
            self.tableView.reloadData()
            self.updateGraphColumnWidthForVisibleRows(fallbackLaneCount: graph.maximumLaneCount)
            self.prepareVisibleGraphRows()
            defer { if let id = self.pendingFirstVisibleID { self.scrollRevisionToTop(id) } }
            guard !orderedCommits.isEmpty else { return }
            if preservingViewport, !selectedIDs.isEmpty, self.pendingOpeningSelection.isEmpty,
               self.pendingSelectionID == nil {
                let rows = IndexSet(orderedCommits.indices.filter { selectedIDs.contains(orderedCommits[$0].id) })
                if !rows.isEmpty {
                    self.tableView.selectRowIndexes(rows, byExtendingSelection: false)
                    if let viewport, let scroll = self.tableView.enclosingScrollView {
                        scroll.contentView.scroll(to: viewport)
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    return
                }
            }
            if !self.pendingOpeningSelection.isEmpty {
                let ids = self.pendingOpeningSelection
                self.pendingOpeningSelection = []
                if ids.contains(where: { id in orderedCommits.contains(where: { $0.id == id }) }) {
                    self.selectCommits(ids: ids)
                    return
                }
            }
            let requestedID = self.pendingSelectionID
            let requestedIndex = requestedID.flatMap { id in orderedCommits.firstIndex(where: { $0.id == id }) }
            let index = requestedIndex ?? (selectFirst ? orderedCommits.firstIndex(where: { !$0.isArtificial }) ?? 0 : 0)
            if requestedIndex != nil || requestedID == nil {
                self.pendingSelectionID = nil
            }
            self.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            self.tableView.scrollRowToVisible(index)
            self.onSelection?(orderedCommits[index])
        }
    }

    private func scheduleGraphColumnWidthRefresh() {
        guard !graphWidthRefreshScheduled else { return }
        graphWidthRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.graphWidthRefreshScheduled = false
            self.view.layoutSubtreeIfNeeded()
            self.updateGraphColumnWidthForVisibleRows()
            self.prepareVisibleGraphRows()
        }
    }



    private func prepareVisibleGraphRows() {
        guard !graphReloadPending, !commits.isEmpty else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let first = visible.location == NSNotFound ? 0 : visible.location
        let through = min(commits.count - 1, first + 2 * max(30, visible.length))
        if graphRows.count > through {
            if graphScrollPending, through < graphCacheRequestedThrough {
                graphTask?.cancel()
                graphScrollPending = false
                graphCacheRequestedThrough = graphRows.count - 1
            }
            return
        }
        guard through != graphCacheRequestedThrough else { return }
        graphCacheRequestedThrough = through
        graphScrollPending = true
        graphGeneration += 1
        let cache = graphCache
        let generation = graphGeneration
        let input = allCommits
        let configuration = graphLayoutConfiguration
        let completed = historyCompleted


        graphTask?.cancel()
        graphTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try await cache.prepare(commits: input, configuration: configuration, through: through, completed: completed)
            }
            let snapshot: RevisionGraphCache.Snapshot
            do {
                snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            } catch { return }
            guard let self, !Task.isCancelled, generation == self.graphGeneration else { return }
            self.graphScrollPending = false
            self.graphRows = snapshot.layout.rows
            self.displayedGraph = snapshot.layout
            if let column = self.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "Graph" }) {
                let visible = self.tableView.rows(in: self.tableView.visibleRect)
                if visible.location != NSNotFound {
                    let end = min(self.graphRows.count, visible.location + visible.length)
                    if visible.location < end {
                        self.tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<end), columnIndexes: IndexSet(integer: column))
                    }
                }
            }
            self.updateGraphColumnWidthForVisibleRows()
        }
    }

    private func updateGraphColumnWidthForVisibleRows(fallbackLaneCount: Int = 1) {
        guard let graphColumn = tableView.tableColumn(withIdentifier: .init("Graph")) else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let first = visible.location == NSNotFound ? 0 : visible.location
        let last = min(graphRows.count, first + visible.length)
        let laneCount: Int
        if first < last {
            laneCount = graphRows[first..<last].map(\.laneCount).max() ?? fallbackLaneCount
        } else {
            laneCount = fallbackLaneCount
        }
        let visibleLaneCount = min(RevisionGraphLayout.maximumVisibleLanes, max(1, laneCount))
        let width = CGFloat(6 + visibleLaneCount * RevisionGraphLayout.laneWidth)
        if abs(graphColumn.width - width) >= 0.5 {
            graphColumn.width = width
            fitMessageColumn()
        }
    }

    private func addColumn(_ title: String, width: CGFloat, min: CGFloat, max: CGFloat, resizable: Bool) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        column.title = title
        column.width = width
        column.minWidth = min
        column.maxWidth = max
        column.resizingMask = resizable ? .userResizingMask : []
        tableView.addTableColumn(column)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = GitExtensionsSelectionRowView()
        view.repositoryBackgroundColor = rowBackground(row)
        return view
    }

    private func rowBackground(_ row: Int) -> NSColor {
        let preferences = AppSettingsStore.shared.colorPreferences
        if commits.indices.contains(row), !commits[row].isArtificial, preferences.highlightAuthored,
           let email = highlightedAuthorEmail, !email.isEmpty, commits[row].authorEmail.caseInsensitiveCompare(email) == .orderedSame {
            return ApplicationColors.color("AuthoredHighlight", fallback: NSColor.systemBlue.withAlphaComponent(0.08))
        }
        let base = ApplicationColors.color("PanelBackground", fallback: .controlBackgroundColor)
        if preferences.alternateRows, row % 2 == 0 {
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return base.blended(withFraction: dark ? 0.018 : 0.025, of: dark ? .white : .black) ?? base
        }
        return base
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < commits.count, let identifier = tableColumn?.identifier else { return nil }
        let commit = commits[row]
        let isRelative = graphRelatives.contains(commit.id)

        switch identifier.rawValue {
        case "Graph":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CommitGraphCellView) ?? CommitGraphCellView()
            cell.identifier = identifier
            cell.configure(row: graphRows.indices.contains(row) ? graphRows[row] : nil, configuration: graphLayoutConfiguration)
            cell.laneDescription = { [weak self] lane in
                guard let self, AppSettingsStore.shared.revisionGridPreferences.showRevisionGridTooltips else { return nil }
                let text = RevisionGridPresentation.laneInfo(layout: self.displayedGraph, row: row, lane: lane, commits: self.graphCommits)
                return text.isEmpty ? nil : text
            }
            return cell
        case "Message":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RevisionMessageCellView) ?? RevisionMessageCellView()
            cell.identifier = identifier
            let preferences = AppSettingsStore.shared.revisionGridPreferences
            var labels = labelContext
            labels.showAnnotatedTagsMessages = preferences.showAnnotatedTagsMessages
            let context = labels
            cell.configure(commit: commit, showsTags: showsTagReferences, isRelative: isRelative,
                           showsRemoteBranches: preferences.showRemoteBranches,
                           body: RevisionGridPresentation.bodySuffix(commit, showBody: preferences.showCommitBody,
                                                                     notesInSeparateColumn: preferences.showNotesColumn),
                           toolTip: RevisionGridPresentation.messageToolTip(commit, notesInSeparateColumn: preferences.showNotesColumn,
                                                                            aheadBehind: { context.aheadBehind($0) }),
                           labels: labels)
            cell.changeCounts = commit.kind == .index ? repositoryStatus?.index : repositoryStatus?.worktree
            return cell
        case "Notes":
            let cell = textCell(identifier, value: commit.notes.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "",
                                font: AppSettingsStore.shared.applicationFont(size: 11), isRelative: isRelative)
            cell.toolTip = commit.notes.isEmpty ? nil : commit.notes
            return cell
        case "Avatar":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RevisionAvatarCellView) ?? RevisionAvatarCellView()
            cell.identifier = identifier
            cell.configure(commit: commit)
            return cell
        case "Author Name":
            let highlighted = !commit.isArtificial && AppSettingsStore.shared.colorPreferences.highlightAuthored
                && highlightedAuthorEmail.map { !$0.isEmpty && commit.authorEmail.caseInsensitiveCompare($0) == .orderedSame } == true
            let cell = textCell(identifier, value: commit.isArtificial ? "" : commit.authorName,
                                font: AppSettingsStore.shared.applicationFont(size: 11, weight: highlighted ? .bold : .regular), isRelative: isRelative)
            cell.toolTip = RevisionGridPresentation.authorToolTip(commit)
            return cell
        case "Date":
            let preferences = AppSettingsStore.shared.revisionGridPreferences
            let cell = textCell(identifier, value: RevisionGridPresentation.dateText(commit, showAuthorDate: preferences.showAuthorDate, relative: preferences.relativeDate),
                                font: AppSettingsStore.shared.applicationFont(size: 11), isRelative: isRelative)
            cell.toolTip = RevisionGridPresentation.dateToolTip(commit)
            return cell
        case "Commit ID":
            let font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 10.5, weight: .regular))
            let width = tableColumn?.width ?? 60
            let characterWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
            let cell = textCell(identifier, value: RevisionGridPresentation.commitIDText(commit, width: width, characterWidth: characterWidth),
                                font: font, isRelative: isRelative)
            cell.textField?.lineBreakMode = .byClipping
            cell.toolTip = commit.objectID?.string
            return cell
        case Self.buildColumn:
            let info = buildStatuses[commit.id]
            let cell = textCell(identifier, value: info.map { Self.buildStatusText($0, icon: AppSettingsStore.shared.showBuildStatusIconColumn, text: AppSettingsStore.shared.showBuildStatusTextColumn) } ?? "",
                                font: AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 10.5, weight: .regular)), isRelative: true)
            if let info, let color = Self.buildStatusColor(info.status) { cell.textField?.textColor = color }
            cell.toolTip = info.flatMap { $0.tooltip ?? $0.description }
            return cell
        default:
            return nil
        }
    }

    private func textCell(_ identifier: NSUserInterfaceItemIdentifier, value: String, font: NSFont, isRelative: Bool) -> NSTableCellView {
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            view.textField = text
            view.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()
        cell.textField?.stringValue = value
        cell.textField?.font = font
        cell.textField?.lineBreakMode = .byTruncatingTail
        cell.toolTip = nil
        cell.textField?.textColor = !isRelative && AppSettingsStore.shared.colorPreferences.nonRelativeTextGray
            ? .secondaryLabelColor : ApplicationColors.color("WindowText", fallback: .labelColor)
        return cell
    }


    func fitMessageColumn() {
        guard let message = tableView.tableColumn(withIdentifier: .init("Message")),
              let clipWidth = tableView.enclosingScrollView?.contentView.bounds.width, clipWidth > 0 else { return }
        let visible = tableView.tableColumns.filter { !$0.isHidden }
        let others = visible.filter { $0 !== message }.reduce(0) { $0 + $1.width }
        let width = max(message.minWidth, floor(clipWidth - others - tableView.intercellSpacing.width * CGFloat(visible.count)))
        if abs(message.width - width) >= 0.5 { message.width = width }
    }
    var messageColumnWidth: CGFloat { tableView.tableColumn(withIdentifier: .init("Message"))?.width ?? 0 }

    func tableViewColumnDidResize(_ notification: Notification) {
        if let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn, column.identifier.rawValue != "Message" {
            fitMessageColumn()
        }
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn, column.identifier.rawValue == "Commit ID",
              let index = tableView.tableColumns.firstIndex(of: column) else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: IndexSet(integer: index))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !tableView.isReloadingContent else { return }
        let selected = selectedRevisionIDs
        if graphReloadPending, !selected.isEmpty {


            pendingOpeningSelection = selected
        }
        selectionOrder.removeAll { !selected.contains($0) }
        if tableView.selectedRow >= 0, tableView.selectedRow < commits.count {

            let latest = commits[tableView.selectedRow].id
            selectionOrder.removeAll { $0 == latest }
            selectionOrder += selected.filter { !selectionOrder.contains($0) && $0 != latest } + [latest]
        }
        selectionChangedForNavigation()
        if tableView.selectedRowIndexes.count <= 1 {
            highlightedAuthorEmail = commits.indices.contains(tableView.selectedRow) ? commits[tableView.selectedRow].authorEmail : nil
        }
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView as? GitExtensionsSelectionRowView)?.repositoryBackgroundColor = self.rowBackground(row)
            rowView.needsDisplay = true
            rowView.subviews.forEach { $0.needsDisplay = true }
        }
        guard tableView.selectedRow >= 0, tableView.selectedRow < commits.count else { return }
        onSelection?(commits[tableView.selectedRow])
    }


    @objc private func openSelectedCommit() {
        if let event = NSApp.currentEvent, tableView.handleDoubleClickLabel?(event) == true { return }
        let selected = selectedRevisionIDsBySelectionOrder.compactMap { id in commits.first { $0.id == id } }
        if selected.first?.isArtificial == true && !allowsArtificialViewSelection { return }
        onViewSelected?(selected)
    }

    private func copySelectedCommitIDs() {
        let ids = tableView.selectedRowIndexes.compactMap { index in
            index < commits.count ? commits[index].id.description : nil
        }
        guard !ids.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
    }

    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if event.keyCode == 53 {
            guard !quickSearchLabel.isHidden else { return false }
            hideQuickSearch()
            return true
        }

        if event.keyCode == 51 {
            guard !quickSearchString.isEmpty else { return false }
            if quickSearchString.count > 1 {
                quickSearchString.removeLast()
                updateQuickSearch(startingAt: max(0, tableView.selectedRow))
            } else {
                hideQuickSearch()
            }
            return true
        }

        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let pasted = NSPasteboard.general.string(forType: .string),
           !pasted.isEmpty {
            quickSearchString += pasted.lowercased()
            updateQuickSearch(startingAt: max(0, tableView.selectedRow))
            return true
        }

        guard modifiers.isEmpty || modifiers == .shift,
              let characters = event.characters,
              !characters.isEmpty,
              characters.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return false
        }

        quickSearchString += characters.lowercased()
        updateQuickSearch(startingAt: max(0, tableView.selectedRow))
        return true
    }

    private func updateQuickSearch(startingAt start: Int) {
        restartQuickSearchTimer()
        lastQuickSearchString = quickSearchString
        let found = findQuickSearchMatch(startingAt: start, reverse: false)
        showQuickSearch(found: found)
    }

    private func showAdjacentQuickSearchResult(down: Bool) {
        restartQuickSearchTimer()
        quickSearchString = lastQuickSearchString
        let selected = tableView.selectedRow
        let start = selected >= 0 ? selected + (down ? 1 : -1) : 0
        let found = findQuickSearchMatch(startingAt: start, reverse: !down)
        showQuickSearch(found: found)
    }

    @discardableResult
    private func findQuickSearchMatch(startingAt start: Int, reverse: Bool) -> Bool {
        guard !commits.isEmpty else { return false }
        let normalizedStart: Int
        if reverse {
            normalizedStart = (0..<commits.count).contains(start) ? start : commits.count - 1
        } else {
            normalizedStart = (0..<commits.count).contains(start) ? start : 0
        }

        let indexes: [Int]
        if reverse {
            indexes = Array(stride(from: normalizedStart, through: 0, by: -1))
                + Array(stride(from: commits.count - 1, through: normalizedStart + 1, by: -1))
        } else {
            indexes = Array(normalizedStart..<commits.count) + Array(0..<normalizedStart)
        }

        guard let match = indexes.first(where: { quickSearchMatches(commits[$0], query: quickSearchString) }) else {
            return false
        }
        if tableView.selectedRowIndexes != IndexSet(integer: match) {
            tableView.selectRowIndexes(IndexSet(integer: match), byExtendingSelection: false)
            tableView.scrollRowToVisible(match)
        }
        return true
    }

    private func quickSearchMatches(_ commit: Commit, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            commit.subject,
            commit.body,
            commit.authorName,
            commit.authorEmail,
            commit.committerName,
            commit.committerEmail,
            commit.id.description,
            commit.shortID,
            commit.references.map(\.name).joined(separator: " ")
        ].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func showQuickSearch(found: Bool) {
        quickSearchLabel.stringValue = "  Searching for: \(quickSearchString)  "
        quickSearchLabel.textColor = found ? .controlTextColor : .systemRed
        quickSearchLabel.isHidden = false
    }

    private func restartQuickSearchTimer() {
        quickSearchTimer?.invalidate()
        let interval = Double(AppSettingsStore.shared.browseDisplayPreferences.quickSearchTimeoutMilliseconds) / 1000
        quickSearchTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, interval), repeats: false) { [weak self] _ in
            self?.hideQuickSearch()
        }
    }

    private func hideQuickSearch() {
        quickSearchTimer?.invalidate()
        quickSearchTimer = nil
        quickSearchString = ""
        quickSearchLabel.isHidden = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow

        rightClickedHit = tableView.clickedRow >= 0 ? labelHit(row: tableView.clickedRow, column: tableView.clickedColumn) : nil
        populateMenu(menu, row: row)
    }


    var menuState: RevisionGridMenuModel.State {
        let store = AppSettingsStore.shared
        var state = RevisionGridMenuModel.State()
        state.filter = currentFilter
        state.preferences = store.revisionGridPreferences
        state.sortOrder = store.revisionGridRuntime.sortOrder
        state.showTags = showsTagReferences
        state.nonRelativesGray = store.colorPreferences.nonRelativeGraphGray
        state.buildIcon = store.showBuildStatusIconColumn
        state.buildText = store.showBuildStatusTextColumn
        state.canNavigateBackward = canNavigateBackward
        state.canNavigateForward = canNavigateForward
        return state
    }

    var onMenuStateChanged: (() -> Void)?

    var onDeleteBranch: ((String) -> Void)?

    var onApplyPatch: ((URL) -> Void)?

    var onShowAdvancedFilter: (() -> Void)?
    private var rightClickedHit: RevisionLabelHit?

    var labelContext = RevisionLabelContext() {
        didSet { tableView.reloadData() }
    }

    private func performShortcut(_ command: String) -> Bool {

        if command == "revision.ref.delete" && !quickSearchString.isEmpty { return false }
        switch command {
        case "revision.commit.fixup", "revision.commit.squash", "revision.commit.amend":
            guard let latest = latestSelected, !latest.isArtificial else { return true }
            performCommand(command, focusedCommitID: latest.id)
            return true
        default:
            return performGridCommand(command)
        }
    }


    @discardableResult
    func performGridCommand(_ id: String) -> Bool {
        let store = AppSettingsStore.shared
        func preferences(refresh: Bool, _ change: (inout RevisionGridPreferences) -> Void) {
            var value = store.revisionGridPreferences
            change(&value)
            store.saveRevisionGridPreferences(value)
            applyColumnSettings()
            tableView.reloadData()
            if refresh { requestRefresh() }
        }
        switch id {
        case "revision.view.highlightBranch": highlightSelectedBranch()
        case _ where id.hasPrefix("revision.navigate."): performNavigation(id)
        case "revision.search.next", "revision.search.previous": showAdjacentQuickSearchResult(down: id == "revision.search.next")
        case "revision.search.help": RevisionGridMessages.present("Start typing in revision grid to start quick search.", "Information")
        case "revision.branches.all": showAllBranches()
        case "revision.branches.current": showCurrentBranchOnly()
        case "revision.branches.filtered": showFilteredBranches()
        case "revision.other.reflog": toggleShowReflogReferences()
        case "revision.firstParent": toggleShowOnlyFirstParent()
        case "revision.hideMerges": toggleHideMergeCommits()
        case "revision.filter.advanced": onShowAdvancedFilter?()
        case "revision.filter.reset": resetAllFiltersAndRefresh()
        case "revision.filter.resetPath": setAndApplyPathFilter("")
        case "revision.view.nonRelativesGray":
            var colors = store.colorPreferences
            colors.nonRelativeGraphGray.toggle()
            store.colorPreferences = colors
            reloadAppearance()
        case "revision.view.artificial": preferences(refresh: true) { $0.showArtificialCommits.toggle() }
        case "revision.view.stashes": preferences(refresh: true) { $0.showStashes.toggle() }
        case "revision.view.gitNotes": preferences(refresh: true) { $0.showGitNotes.toggle() }
        case "revision.view.sessionRefs": preferences(refresh: true) { $0.showSessionRefs.toggle() }
        case "revision.view.remoteBranches": preferences(refresh: false) { $0.showRemoteBranches.toggle() }
        case "revision.view.tags":
            var tags = store.tagPreferences
            tags.showTagsInRevisionGrid.toggle()
            store.saveTagPreferences(tags)
            setShowsTagReferences(tags.showTagsInRevisionGrid)
        case "revision.view.superprojectTags": preferences(refresh: true) { $0.showSuperprojectTags.toggle() }
        case "revision.view.superprojectRemoteBranches": preferences(refresh: true) { $0.showSuperprojectRemoteBranches.toggle() }
        case "revision.view.superprojectBranches": preferences(refresh: true) { $0.showSuperprojectBranches.toggle() }
        case "revision.view.buildIcon": BrowserCommandCenter.perform(.toggleBuildStatusIcon)
        case "revision.view.buildText": BrowserCommandCenter.perform(.toggleBuildStatusText)
        case "revision.view.commitBody": preferences(refresh: false) { $0.showCommitBody.toggle() }
        case "revision.view.authorDate": preferences(refresh: false) { $0.showAuthorDate.toggle() }
        case "revision.view.relativeDate": preferences(refresh: false) { $0.relativeDate.toggle() }
        case "revision.column.graph": preferences(refresh: false) { $0.showGraphColumn.toggle() }
        case "revision.column.notes": preferences(refresh: true) { $0.showNotesColumn.toggle() }
        case "revision.column.avatar": preferences(refresh: false) { $0.showAuthorAvatarColumn.toggle() }
        case "revision.column.author": preferences(refresh: false) { $0.showAuthorNameColumn.toggle() }
        case "revision.column.date": preferences(refresh: false) { $0.showDateColumn.toggle() }
        case "revision.column.id": preferences(refresh: false) { $0.showObjectIDColumn.toggle() }
        case "revision.sort.authorDate", "revision.sort.topo":
            let order: RevisionSortOrder = id == "revision.sort.authorDate" ? .authorDate : .topology
            store.revisionGridRuntime.sortOrder = store.revisionGridRuntime.sortOrder != order ? order : .gitDefault
            requestRefresh()
        case "revision.view.saveDefaults": store.saveCurrentViewSettingsAsDefault()
        case "revision.ref.delete": deleteRef()
        case "revision.ref.rename": renameRef()
        case "revision.compare.difftool": diffSelectedCommitsWithDifftool()
        case "revision.compare.setBase": comparisonBase = latestSelected; onMenuStateChanged?()
        case "revision.compare.branch", "revision.compare.current", "revision.compare.base", "revision.compare.worktree", "revision.compare.selected":
            performCommand(id, focusedCommitID: latestSelected?.id)
        default: return false
        }
        onMenuStateChanged?()
        return true
    }

    private func populateMenu(_ menu: NSMenu, row: Int) {
        guard row >= 0, row < commits.count else {
            menu.removeAllItems()
            return
        }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let focused = latestSelected ?? commits[row]
        if let specializedContextMenu {
            menu.removeAllItems()
            specializedContextMenu(menu, selectedRevisionIDsBySelectionOrder.compactMap { id in commits.first { $0.id == id } })
            return
        }
        let scripts = ((try? ApplicationScriptsStore.shared.load()) ?? []).filter(\.enabled)
        var context = RevisionContextMenuContext(
            focusedCommit: focused,
            selectedCommits: selectedRevisionIDsBySelectionOrder.compactMap { id in commits.first { $0.id == id } },
            history: allCommits,
            currentBranchName: currentBranchName,
            isBisecting: isBisecting,
            isCherryPicking: isCherryPicking,
            cherryPickHasConflicts: cherryPickHasConflicts,
            isRebasing: isRebasing,
            rebaseHasConflicts: rebaseHasConflicts,
            buildStatus: buildStatuses[focused.id]
        )
        let clicked = rightClickedHit.flatMap { $0.isStash ? nil : ($0.virtualSource ?? $0.reference) }
        context.clickedReference = clicked
        context.hasComparisonBase = comparisonBase != nil
        context.isBareRepository = isBareRepository

        context.refFocused = clicked != nil && !NSEvent.modifierFlags.contains(.shift)
            && !AppSettingsStore.shared.pushPreferences.showAdvancedOptions
        context.scripts = scripts.map { ($0.id.uuidString, $0.name, $0.addToRevisionGridContextMenu) }
        context.gridMenuState = menuState
        rightClickedHit = nil
        menuFocusedCommitID = focused.id
        populatePlaceholderMenu(menu, with: RevisionContextMenuBuilder.build(context))
        routeMenuItems(in: menu)
        let state = menuState
        for (id, commands) in [("revision.navigate", RevisionGridMenuModel.navigate(state)), ("revision.view", RevisionGridMenuModel.view(state))] {
            guard let item = menuItem(withIdentifier: id, in: menu) else { continue }
            let submenu = NSMenu(title: item.title)
            RevisionGridMenuModel.fill(submenu, commands, target: self, action: #selector(gridMenuCommand(_:)))
            item.submenu = submenu
        }
        for script in scripts {
            guard let item = menuItem(withIdentifier: "revision.script.run.\(script.id.uuidString)", in: menu) else { continue }
            if let path = script.iconFilePath { item.image = NSImage(contentsOfFile: path) }
            if item.image == nil, let icon = script.icon { item.image = AppKitFactory.resourceImage(icon) }
        }
        for (id, icon) in [("revision.copy", "CopyToClipboard"), ("revision.copy.hash", "CommitId"), ("revision.copy.message", "Message"),
                           ("revision.copy.author", "Author"), ("revision.copy.date", "Date"), ("revision.copy.authorDate", "Date"),
                           ("revision.copy.commitDate", "Date")] {
            menuItem(withIdentifier: id, in: menu)?.image = AppKitFactory.resourceImage(icon)
        }
        for id in ["revision.commit.fixup", "revision.commit.squash", "revision.commit.amend", "revision.compare.difftool", "revision.compare.base", "revision.compare.setBase", "revision.compare.worktree"] {
            guard let item = menuItem(withIdentifier: id, in: menu), let chord = ApplicationHotkeys.shared.chord(for: id),
                  let key = chord.key.first else { continue }
            item.keyEquivalent = String(key)
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: chord.modifiers)
        }
    }

    private var currentBranchName: String? {
        allCommits.lazy.flatMap(\.references).first(where: { $0.kind == .currentBranch })?.name
    }


    private func routeMenuItems(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { routeMenuItems(in: submenu); continue }
            guard item.identifier != nil, item.isEnabled else { continue }
            item.target = self
            item.action = #selector(contextMenuCommand(_:))
        }
    }

    @objc private func gridMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        performGridCommand(id)
    }

    @objc private func contextMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        let focusedID = menuFocusedCommitID
        switch id {
        case _ where id.hasPrefix("revision.copy."): copyToClipboard(id)
        case _ where id.hasPrefix("revision.script.run."):
            let scriptID = String(id.dropFirst("revision.script.run.".count))
            if let script = ((try? ApplicationScriptsStore.shared.load()) ?? []).first(where: { $0.id.uuidString == scriptID }) { onScript?(script) }
        case "revision.buildReport", "revision.pullRequestPage":
            guard let info = buildStatus(for: focusedID) else { return }
            if let url = id == "revision.buildReport" ? info.url : info.pullRequestURL { NSWorkspace.shared.open(url) }
        case "revision.commit.advancedHelp":
            if let url = URL(string: "https://git-extensions-documentation.readthedocs.io/en/latest/modify_history.html#using-autosquash-rebase-feature") {
                NSWorkspace.shared.open(url)
            }
        default:
            if performGridCommand(id) { return }
            performCommand(id, focusedCommitID: focusedID)
        }
    }


    func copyToClipboard(_ id: String) {
        let selected = selectedCommits
        let valuePrefix = "revision.copy.value."
        let text: String
        switch id {
        case _ where id.hasPrefix(valuePrefix): text = String(id.dropFirst(valuePrefix.count))
        case "revision.copy.hash": text = RevisionContextMenuBuilder.copyValues(selected, \.id.description).joined(separator: "\n")
        case "revision.copy.message":
            text = RevisionContextMenuBuilder.copyValues(selected) { $0.body.isEmpty ? $0.subject : $0.subject + "\n" + $0.body }.joined(separator: "\n")
        case "revision.copy.author": text = RevisionContextMenuBuilder.copyValues(selected) { "\($0.authorName) <\($0.authorEmail)>" }.joined(separator: "\n")
        case "revision.copy.date", "revision.copy.authorDate":
            text = RevisionContextMenuBuilder.copyValues(selected) { RevisionContextMenuBuilder.copyDate($0.authorDate) }.joined(separator: "\n")
        case "revision.copy.commitDate":
            text = RevisionContextMenuBuilder.copyValues(selected) { RevisionContextMenuBuilder.copyDate($0.commitDate) }.joined(separator: "\n")
        default: return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func performCommand(_ identifier: String, focusedCommitID: RevisionID?) {
        guard let focused = focusedCommit(id: focusedCommitID) else { return }
        var selected = selectedRevisionIDsBySelectionOrder.compactMap { id in commits.first { $0.id == id } }
        if selected.isEmpty { selected = [focused] }
        onCommand?(identifier, selected, focused)
    }

    private func focusedCommit(id: RevisionID?) -> Commit? {
        if let id, let commit = allCommits.first(where: { $0.id == id }) { return commit }
        return latestSelected
    }


    func deleteRef() {
        guard let revision = latestSelected else { return }
        let current = currentBranchName
        let branches = revision.references.filter { [.currentBranch, .localBranch, .remoteBranch].contains($0.kind) }
        let refs = branches.filter { $0.kind == .remoteBranch || $0.name != current } + revision.references.filter { $0.kind == .tag }
        chooseRef(refs, action: "Delete") { [weak self] reference in
            let id = reference.kind == .tag ? "revision.tag.delete.ref." : "revision.branch.delete.ref."
            self?.performCommand(id + reference.id, focusedCommitID: revision.id)
        }
    }


    func renameRef() {
        guard let revision = latestSelected else { return }
        let refs = revision.references.filter { $0.kind == .localBranch || $0.kind == .currentBranch }
        chooseRef(refs, action: "Rename") { [weak self] reference in
            self?.performCommand("revision.branch.rename.ref." + reference.id, focusedCommitID: revision.id)
        }
    }


    private func chooseRef(_ refs: [RevisionReference], action: String, perform: @escaping (RevisionReference) -> Void) {
        guard !refs.isEmpty else { return }
        if refs.count == 1 { perform(refs[0]); return }
        let menu = NSMenu(title: action)
        let header = menu.addItem(withTitle: action, action: nil, keyEquivalent: "")
        header.isEnabled = false
        for reference in refs {
            let item = ClosureMenuItem(title: reference.name) { perform(reference) }
            item.image = AppKitFactory.resourceImage(reference.kind == .tag ? "Tag" : reference.kind == .remoteBranch ? "BranchRemote" : "BranchLocal")
            menu.addItem(item)
        }
        let rect = tableView.rect(ofRow: max(0, tableView.selectedRow))
        menu.popUp(positioning: nil, at: NSPoint(x: tableView.rect(ofColumn: 0).maxX, y: rect.maxY), in: tableView)
    }


    func diffSelectedCommitsWithDifftool() {
        let selected = selectedRevisionIDsBySelectionOrder.compactMap { id in commits.first { $0.id == id } }
        guard let latest = selected.first ?? latestSelected, let dataSource else { return }
        let first: RevisionID? = RevisionComparison.firstID(in: selected)
        guard first != nil || latest.isArtificial else { return }
        Task { @MainActor in
            do { try await dataSource.openDirDiffWithDifftool(first: first, second: latest.id) }
            catch { RevisionGridMessages.error(error.localizedDescription) }
        }
    }



    private var loadingSpinner: NSProgressIndicator?
    private var loadingLabel: NSTextField?
    private var pageView: NSView?


    func showLoading(spinner: Bool) {
        setPage(nil)
        if loadingSpinner == nil {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "Loading")
            label.drawsBackground = true
            label.backgroundColor = ApplicationColors.color("Info", fallback: NSColor(calibratedRed: 1, green: 1, blue: 0.88, alpha: 1))
            label.textColor = ApplicationColors.color("InfoText", fallback: .black)
            label.font = AppSettingsStore.shared.applicationFont(size: 11)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(indicator)
            view.addSubview(label)
            NSLayoutConstraint.activate([
                indicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                indicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4)
            ])
            loadingSpinner = indicator
            loadingLabel = label
        }
        loadingSpinner?.isHidden = !spinner
        if spinner { loadingSpinner?.startAnimation(nil) } else { loadingSpinner?.stopAnimation(nil) }
        loadingLabel?.isHidden = spinner
    }

    var isShowingLoading: Bool { loadingSpinner?.isHidden == false || loadingLabel?.isHidden == false }


    func finishLoading(failed: Bool = false, isBareRepository: Bool = false) {
        historyCompleted = true
        if !failed && !allCommits.isEmpty { applyFilters(selectFirst: true, preservingViewport: !selectedCommits.isEmpty) }
        self.isBareRepository = isBareRepository
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
        loadingLabel?.isHidden = true
        if failed { setPage(Self.errorPage()); return }
        if allCommits.isEmpty && !currentFilter.hasFilter {
            setPage(emptyRepositoryPage(isBare: isBareRepository))
        } else {
            setPage(nil)
        }
    }

    var visiblePage: String? { pageView?.identifier?.rawValue }

    private func setPage(_ page: NSView?) {
        pageView?.removeFromSuperview()
        pageView = page
        (view as? RevisionGridScrollView)?.page = page
        guard let page else { return }


        page.translatesAutoresizingMaskIntoConstraints = true
        page.frame = view.bounds
        page.wantsLayer = true
        page.layer?.zPosition = 1
        view.addSubview(page, positioned: .above, relativeTo: nil)
    }

    private static func errorPage() -> NSView {
        let container = RevisionGridPageView()
        container.identifier = NSUserInterfaceItemIdentifier("revisionGrid.error")
        let image = NSImageView(image: AppKitFactory.resourceImage("StatusBadgeError", accessibilityDescription: "Error") ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                                     image.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        return container
    }


    private func emptyRepositoryPage(isBare: Bool) -> NSView {
        let container = RevisionGridPageView()
        container.identifier = NSUserInterfaceItemIdentifier("revisionGrid.empty")
        let label = NSTextField(wrappingLabelWithString: "This repository does not yet contain any commits.")
        label.alignment = .center
        label.font = AppSettingsStore.shared.applicationFont(size: 13)
        let gitIgnore = NSButton(title: "Edit .gitignore", target: self, action: #selector(emptyRepositoryEditGitIgnore))
        gitIgnore.setAccessibilityIdentifier("revisionGrid.empty.editGitIgnore")
        let commit = NSButton(title: "Commit", target: self, action: #selector(emptyRepositoryCommit))
        let buttons = NSStackView(views: [gitIgnore, commit])
        buttons.isHidden = isBare
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32)])
        return container
    }

    @objc private func emptyRepositoryCommit() {
        onEmptyRepositoryCommit?()
    }

    var onEmptyRepositoryCommit: (() -> Void)?

    @objc private func emptyRepositoryEditGitIgnore() {
        onEmptyRepositoryEditGitIgnore?()
    }

    var onEmptyRepositoryEditGitIgnore: (() -> Void)?



    private var messageColumnIndex: Int { tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("Message")) }


    private func labelHit(row: Int, column: Int, event: NSEvent? = NSApp.currentEvent) -> RevisionLabelHit? {
        guard row >= 0, column == messageColumnIndex, let event,
              let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? RevisionMessageCellView
        else { return nil }
        return cell.label(atWindowPoint: event.locationInWindow)
    }


    private func goToRelatedRef(_ hit: RevisionLabelHit, handleGone: Bool, toggle: Bool = false) {
        let target: String
        if let source = hit.virtualSource {
            if hit.reference.name == AheadBehindData.goneSymbol {
                if handleGone { onDeleteBranch?(source.name) }
                return
            }
            target = hit.virtualTarget ?? ""
        } else if let data = labelContext.aheadBehind(hit.reference) {
            if data.isGone {
                if handleGone { onDeleteBranch?(hit.reference.name) }
                return
            }
            target = hit.reference.kind == .remoteBranch ? "refs/heads/" + data.branch : data.remoteRef
        } else { return }
        goToRef(target, showNoRevisionMessage: true, toggle: toggle)
    }


    func goToRef(_ name: String, showNoRevisionMessage: Bool, toggle: Bool = false) {
        guard !name.isEmpty, let dataSource else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let id = await dataSource.resolveRevision(name) else {
                if showNoRevisionMessage { RevisionGridMessages.error("No revision found.") }
                return
            }
            if !setSelectedRevision(.object(id), toggle: toggle), showNoRevisionMessage {
                RevisionGridMessages.revisionFilteredInGrid(.object(id))
            }
        }
    }


    fileprivate func handleAddRelatedRefClick(_ event: NSEvent) -> Bool {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point), column = tableView.column(at: point)
        guard row >= 0, tableView.selectedRowIndexes == IndexSet(integer: row) else { return false }
        if let hit = labelHit(row: row, column: column, event: event), !hit.isStash {
            goToRelatedRef(hit, handleGone: false, toggle: true)
            return true
        }
        if commits.indices.contains(row), commits[row].isArtificial {

            goToRef("HEAD~1", showNoRevisionMessage: false, toggle: true)
            return true
        }
        return false
    }

    fileprivate func handleDoubleClickLabel(_ event: NSEvent) -> Bool {
        let point = tableView.convert(event.locationInWindow, from: nil)
        guard let hit = labelHit(row: tableView.row(at: point), column: tableView.column(at: point), event: event), !hit.isStash else { return false }
        goToRelatedRef(hit, handleGone: true)
        return true
    }


    func dropPatchFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        view.window?.makeKeyAndOrderFront(nil)
        if urls.count > 10 {
            RevisionGridMessages.error("For you own protection dropping more than 10 patch files at once is blocked!")
            return true
        }
        for url in urls where url.pathExtension.lowercased() == "patch" { onApplyPatch?(url) }
        return true
    }

    private func performNavigation(_ identifier: String, focusedCommitID: RevisionID? = nil) {
        switch identifier {
        case "revision.navigate.child": goToChild()
        case "revision.navigate.parent": goToParent()
        case "revision.navigate.firstParent": goToParent(first: true)
        case "revision.navigate.lastParent": goToParent(last: true)
        case "revision.navigate.mergeBase": goToMergeBase()
        case "revision.navigate.current": selectCurrentRevision()
        case "revision.navigate.commit": goToCommit()
        case "revision.navigate.backward": navigateBackward()
        case "revision.navigate.forward": navigateForward()
        case "revision.navigate.toggleArtificial": toggleBetweenArtificialAndHeadCommits()
        case "revision.navigate.forkPoint": selectNextForkPointAsDiffBase()
        default: break
        }
    }




    var dataSource: (any RepositoryRevisionGridDataSource)?

    var referenceNames: () -> (branches: [String], tags: [String]) = { ([], []) }
    private var navigationBackward: [RevisionID] = []
    private var navigationForwardItems: [RevisionID] = []
    private var parentHistory: [RevisionID] = []
    private var childHistory: [RevisionID] = []
    private var navigatingParentChild = false

    private var latestSelected: Commit? {
        commits.indices.contains(tableView.selectedRow) ? commits[tableView.selectedRow] : nil
    }

    var selectedCommits: [Commit] { tableView.selectedRowIndexes.compactMap { commits.indices.contains($0) ? commits[$0] : nil } }


    @discardableResult
    func setSelectedRevision(_ id: RevisionID, toggle: Bool = false, updateHistory: Bool = true) -> Bool {
        guard let index = commits.firstIndex(where: { $0.id == id }) else {
            guard graphReloadPending, allCommits.contains(where: { $0.id == id }) else { return false }
            pendingSelectionID = id
            return true
        }
        pendingSelectionID = graphReloadPending ? id : nil
        if toggle {
            let selected = tableView.selectedRowIndexes
            if selected.contains(index) {
                if selected.count > 1 { tableView.deselectRow(index) }
            } else { tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true) }
        } else {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(index)
        if updateHistory { pushNavigation(id) }
        return true
    }

    private func pushNavigation(_ id: RevisionID) {
        if navigationBackward.last != id { navigationBackward.append(id); navigationForwardItems.removeAll() }
    }
    var canNavigateBackward: Bool { navigationBackward.count > 1 }
    var canNavigateForward: Bool { !navigationForwardItems.isEmpty }
    func navigateBackward() {
        guard canNavigateBackward else { return }
        navigationForwardItems.append(navigationBackward.removeLast())
        select(navigationBackward.last!, updateHistory: false)
    }
    func navigateForward() {
        guard canNavigateForward else { return }
        let next = navigationForwardItems.removeLast()
        navigationBackward.append(next)
        select(next, updateHistory: false)
    }

    func resetNavigationHistory() { navigationBackward.removeAll(); navigationForwardItems.removeAll(); onMenuStateChanged?() }


    func goToRevision(_ id: RevisionID) { select(id) }


    private func select(_ id: RevisionID, updateHistory: Bool = true, toggle: Bool = false) {
        guard !setSelectedRevision(id, toggle: toggle, updateHistory: updateHistory) else { return }
        RevisionGridMessages.revisionFilteredInGrid(id)
    }

    private func navigateParentChild(from current: RevisionID, to target: RevisionID, parent: Bool) {
        if parent { childHistory.append(current) } else { parentHistory.append(current) }
        navigatingParentChild = true
        select(target)
        navigatingParentChild = false
    }

    private func selectionChangedForNavigation() {
        if !navigatingParentChild { parentHistory.removeAll(); childHistory.removeAll() }
        if tableView.selectedRowIndexes.count == 1, let selected = latestSelected { pushNavigation(selected.id) }
        onMenuStateChanged?()
    }
    private func children(of id: RevisionID) -> [Commit] { allCommits.filter { $0.graphParentIDs.contains(id) } }

    func goToChild() {
        guard let current = latestSelected else { return }
        if let previous = childHistory.popLast() { navigateParentChild(from: current.id, to: previous, parent: false) }
        else if let child = children(of: current.id).first { navigateParentChild(from: current.id, to: child.id, parent: false) }
    }
    func goToParent(first: Bool = false, last: Bool = false) {
        guard let current = latestSelected else { return }
        if !first && !last, let previous = parentHistory.popLast() {
            navigateParentChild(from: current.id, to: previous, parent: true); return
        }
        let parents = current.graphParentIDs
        guard let target = last ? parents.last : parents.first else { return }
        navigateParentChild(from: current.id, to: target, parent: true)
    }
    func selectCurrentRevision() {
        guard let head = allCommits.first(where: \.isHEAD) ?? allCommits.first(where: { !$0.isArtificial && $0.references.contains { $0.kind == .head } }) else {
            if let id = headObjectID { RevisionGridMessages.revisionFilteredInGrid(.object(id)) }
            return
        }
        select(head.id)
    }

    var headObjectID: ObjectID? { allCommits.first(where: \.isHEAD)?.objectID ?? allCommits.first(where: { $0.kind == .index })?.parentIDs.first }

    func goToMergeBase() {
        let selected = selectedCommits
        let revisions = selected.compactMap(\.objectID)
        let artificial = selected.contains(where: \.isArtificial)
        Task { @MainActor [weak self] in
            guard let self, let dataSource else { return }
            do {
                guard let base = try await dataSource.mergeBase(of: revisions, includesArtificial: artificial) else {
                    if !revisions.isEmpty || artificial { RevisionGridMessages.error("There is no common ancestor for the selected commits.") }
                    return
                }
                select(.object(base))
            } catch { RevisionGridMessages.error(error.localizedDescription) }
        }
    }


    func goToCommit() {
        guard let window = view.window else { return }
        let names = referenceNames()
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            let initial = clipboard.isEmpty ? "" : (await dataSource?.resolveRevision(clipboard) != nil ? clipboard : "")
            GoToCommitDialog.present(window: window, branches: names.branches, tags: names.tags, initialExpression: initial) { [weak self] expression in
                guard let self, let expression else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let id = await dataSource?.resolveRevision(expression) else {
                        RevisionGridMessages.error("No revision found.", caption: "Cannot find revision"); return
                    }
                    select(.object(id))
                }
            }
        }
    }


    func toggleBetweenArtificialAndHeadCommits() {
        func next(_ id: RevisionID?) -> RevisionID? {
            switch id {
            case .workingDirectory: return .index
            case .index: return headObjectID.map(RevisionID.object)
            default: return .workingDirectory
            }
        }
        var candidate = latestSelected?.id
        for _ in 0..<3 {
            candidate = next(candidate)
            guard let id = candidate else { continue }
            if AppSettingsStore.shared.browseDisplayPreferences.showArtificialRevisionCounts, id.objectID == nil,
               let counts = id == .workingDirectory ? repositoryStatus?.worktree : repositoryStatus?.index,
               counts.changed.isEmpty && counts.added.isEmpty && counts.deleted.isEmpty
                && counts.submodulesChanged.isEmpty && counts.submodulesDirty.isEmpty { continue }
            if id.objectID != nil, !commits.contains(where: { $0.id == id }),
               AppSettingsStore.shared.revisionGridPreferences.showArtificialCommits {
                setSelectedRevision(.workingDirectory); return
            }
            setSelectedRevision(id); return
        }
        if let head = headObjectID { setSelectedRevision(.object(head)) }
    }


    func selectNextForkPointAsDiffBase() {
        let selected = selectedCommits
        guard var revision = selected.last else { return }
        let byID = Dictionary(allCommits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while revision.isArtificial, let parent = revision.graphParentIDs.first.flatMap({ byID[$0] }) { revision = parent }
        repeat {
            guard let parent = revision.graphParentIDs.first.flatMap({ byID[$0] }) else { break }
            revision = parent
        } while !revision.references.contains(where: { [.localBranch, .currentBranch, .remoteBranch].contains($0.kind) })
            && children(of: revision.id).count == 1
        setSelectedRevision(revision.id, updateHistory: false)
        for other in selected.prefix(max(1, selected.count - 1)) { setSelectedRevision(other.id, toggle: true, updateHistory: false) }
    }

}


final class RevisionAvatarCellView: NSTableCellView {
    private let avatar = AuthorAvatarView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.cornerRadius = 2
        addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.heightAnchor.constraint(equalTo: heightAnchor, constant: -4),
            avatar.widthAnchor.constraint(equalTo: avatar.heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(commit: Commit) {
        avatar.isHidden = commit.isArtificial
        avatar.apply(name: commit.authorName, email: commit.authorEmail)
        toolTip = nil
    }
}


private final class RevisionGridScrollView: NSScrollView {
    weak var page: NSView?
    override func tile() {
        super.tile()
        page?.frame = bounds
    }
}

private final class RevisionGridPageView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

private final class RevisionTableView: NSTableView {
    var copySelectedRows: (() -> Void)?
    var handleQuickSearchKey: ((NSEvent) -> Bool)?
    var handleNavigationKey: ((String) -> Bool)?
    var handleAddRelatedRefClick: ((NSEvent) -> Bool)?
    var highlightSelectedBranch: (() -> Void)?
    var handleDoubleClickLabel: ((NSEvent) -> Bool)?
    var navigateHistory: ((Bool) -> Void)?
    var dropPatchFiles: (([URL]) -> Bool)?


    override func selectAll(_ sender: Any?) {}


    private(set) var isReloadingContent = false




    override func reloadData() {
        let selected = selectedRowIndexes
        isReloadingContent = true
        defer { isReloadingContent = false }
        super.reloadData()
        if !selected.isEmpty, selected != selectedRowIndexes, let last = selected.last, last < numberOfRows {
            selectRowIndexes(selected, byExtendingSelection: false)
        }
    }
    var userInteracted: (() -> Void)?

    override func mouseDown(with event: NSEvent) {

        userInteracted?()

        if event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           handleAddRelatedRefClick?(event) == true {
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
        if event.modifierFlags.contains(.option) { highlightSelectedBranch?() }
    }


    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: navigateHistory?(true)
        case 4: navigateHistory?(false)
        default: super.otherMouseDown(with: event)
        }
    }

    private func patchFiles(_ info: NSDraggingInfo) -> [URL]? {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = patchFiles(sender) else { return super.draggingEntered(sender) }
        return urls.allSatisfy { $0.pathExtension.lowercased() == "patch" } ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = patchFiles(sender) else { return super.draggingUpdated(sender) }
        return urls.allSatisfy { $0.pathExtension.lowercased() == "patch" } ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = patchFiles(sender) else { return super.performDragOperation(sender) }
        return dropPatchFiles?(urls) ?? false
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelectedRows?()
            return
        }

        let navigationID = ApplicationHotkeys.shared.matching(event, category: "Revision grid")
        if let navigationID, handleNavigationKey?(navigationID) == true { return }

        if handleQuickSearchKey?(event) == true { return }

        if modifiers.isEmpty || modifiers == .function {
            switch event.keyCode {
            case 115:
                selectAndReveal(row: 0)
                return
            case 119:
                selectAndReveal(row: numberOfRows - 1)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func selectAndReveal(row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
    }
}

final class CommitGraphCellView: NSTableCellView {
    var laneDescription: ((Int) -> String?)?
    private var graphRow: RevisionGraphLayout.Row?
    private var configuration = RevisionGraphLayout.Configuration.gitExtensionsDefault
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeAllToolTips()
        guard let graphRow else { return }
        for lane in 0..<graphRow.laneCount {
            addToolTip(NSRect(x: 6 + CGFloat(lane) * 16, y: 0, width: 16, height: bounds.height), owner: self, userData: nil)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        laneDescription?(Int(floor((point.x - 6) / 16))) ?? ""
    }

    func configure(row: RevisionGraphLayout.Row?, configuration: RevisionGraphLayout.Configuration = .gitExtensionsDefault) {
        graphRow = row
        self.configuration = configuration
        updateTrackingAreas()
        needsDisplay = true
    }


    private func color(index: Int?, isRelative: Bool) -> NSColor {
        guard let index, isRelative || configuration.drawStyle == .normal else { return GitExtensionsPalette.nonRelativeGraph }
        let palette = GitExtensionsPalette.graph
        return palette[index % palette.count]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let graphRow else { return }
        let originX: CGFloat = 6
        let centerY = bounds.midY
        for edge in graphRow.edges.sorted(by: { lhs, rhs in
            lhs.isRelative == rhs.isRelative ? false : !lhs.isRelative && rhs.isRelative
        }) {
            draw(edge: edge, originX: originX, centerY: centerY)
        }


        guard graphRow.nodeLane < RevisionGraphLayout.maximumVisibleLanes else { return }
        let nodeX = laneX(graphRow.nodeLane, originX: originX)
        let nodeRect = NSRect(x: nodeX - 5, y: centerY - 5, width: 10, height: 10)
        let nodePath = graphRow.hasReferences
            ? NSBezierPath(rect: nodeRect.integral)
            : NSBezierPath(ovalIn: nodeRect)
        color(index: graphRow.nodeColorIndex, isRelative: graphRow.isRelative).setFill()
        nodePath.fill()

        if graphRow.isHEAD {
            let outlineRect = nodeRect.insetBy(dx: -1, dy: -1)
            let outline = graphRow.hasReferences ? NSBezierPath(rect: outlineRect.integral) : NSBezierPath(ovalIn: outlineRect)
            NSColor.labelColor.setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    private func draw(edge: RevisionGraphLayout.Edge, originX: CGFloat, centerY: CGFloat) {
        color(index: edge.colorIndex, isRelative: edge.isRelative).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let diagonal = edge.diagonal
        let rowHeight = bounds.height
        let halfPerpendicularHeight = rowHeight / 6
        let startY = centerY - rowHeight
        let endY = centerY + rowHeight
        var previousPoint: NSPoint?
        var previousPerpendicular = true
        func drawTo(_ point: NSPoint, perpendicularly: Bool = true) {
            guard let existingPoint = previousPoint else {
                previousPoint = point
                previousPerpendicular = perpendicularly
                path.move(to: point)
                return
            }
            appendSegment(
                path,
                from: existingPoint,
                to: point,
                fromPerpendicular: previousPerpendicular,
                toPerpendicular: perpendicularly
            )
            previousPoint = point
            previousPerpendicular = perpendicularly
        }

        if !configuration.renderWithDiagonals {

            if diagonal.drawsFromStart, let topLane = edge.topLane { drawTo(NSPoint(x: laneX(topLane, originX: originX), y: startY)) }
            drawTo(NSPoint(x: laneX(edge.centerLane, originX: originX), y: centerY))
            if diagonal.drawsToEnd, let bottomLane = edge.bottomLane { drawTo(NSPoint(x: laneX(bottomLane, originX: originX), y: endY)) }
            path.stroke()
            return
        }

        if diagonal.drawsFromStart, let topLane = edge.topLane {
            let previous = edge.previousDiagonal
            let startX = laneX(topLane, originX: originX) + (previous?.horizontalOffset ?? 0)
            if previous?.centerToEndPerpendicularly == true {
                drawTo(NSPoint(x: startX, y: startY + halfPerpendicularHeight))
            } else if previous?.drawsCenter == true {
                drawTo(
                    NSPoint(x: startX, y: startY),
                    perpendicularly: previous?.centerPerpendicularly ?? true
                )
            } else {
                drawTo(NSPoint(x: startX, y: startY - halfPerpendicularHeight))
            }
        }

        let centerX = laneX(edge.centerLane, originX: originX) + diagonal.horizontalOffset
        if diagonal.centerToStartPerpendicularly {
            drawTo(NSPoint(x: centerX, y: centerY - halfPerpendicularHeight))
        }
        if diagonal.drawsCenter {
            drawTo(
                NSPoint(x: centerX, y: centerY),
                perpendicularly: diagonal.centerPerpendicularly
            )
        }
        if diagonal.centerToEndPerpendicularly {
            drawTo(NSPoint(x: centerX, y: centerY + halfPerpendicularHeight))
        }

        if diagonal.drawsToEnd, let bottomLane = edge.bottomLane {
            let next = edge.nextDiagonal
            let endX = laneX(bottomLane, originX: originX) + (next?.horizontalOffset ?? 0)
            if next?.centerToStartPerpendicularly == true {
                drawTo(NSPoint(x: endX, y: endY - halfPerpendicularHeight))
            } else if next?.drawsCenter == true {
                drawTo(
                    NSPoint(x: endX, y: endY),
                    perpendicularly: next?.centerPerpendicularly ?? true
                )
            } else {
                drawTo(NSPoint(x: endX, y: endY + halfPerpendicularHeight))
            }
        }
        path.stroke()
    }

    private func appendSegment(
        _ path: NSBezierPath,
        from: NSPoint,
        to: NSPoint,
        fromPerpendicular: Bool,
        toPerpendicular: Bool
    ) {
        guard from.x != to.x else {
            path.line(to: to)
            return
        }

        var start = from
        var end = to
        let height = to.y - from.y
        let laneWidth = CGFloat(RevisionGraphLayout.laneWidth)
        let width = to.x - from.x
        let singleLane = abs(width) <= laneWidth
        if singleLane, !fromPerpendicular, !toPerpendicular {
            path.line(to: to)
            return
        }

        let horizontalDirection: CGFloat = width < 0 ? -1 : 1
        let cellShift = NSSize(width: horizontalDirection * laneWidth, height: bounds.height)
        var control1 = start
        var control2 = end
        if fromPerpendicular && toPerpendicular {
            if configuration.renderWithDiagonals && singleLane {
                let perpendicularOffset = cellShift.height / 4
                control1.y += perpendicularOffset
                control2.y -= perpendicularOffset
                let middle = NSPoint(x: (start.x + to.x) / 2, y: (start.y + to.y) / 2)
                let shift = NSSize(width: cellShift.width / 4, height: cellShift.height / 4)
                path.curve(
                    to: middle,
                    controlPoint1: control1,
                    controlPoint2: NSPoint(x: middle.x - shift.width, y: middle.y - shift.height)
                )
                path.move(to: to)
                path.curve(
                    to: middle,
                    controlPoint1: control2,
                    controlPoint2: NSPoint(x: middle.x + shift.width, y: middle.y + shift.height)
                )
                path.move(to: to)
                return
            }
            let middleY = (start.y + to.y) / 2
            control1.y = middleY
            control2.y = middleY
        } else if singleLane {
            let fraction: CGFloat = height < cellShift.height ? 0.4 : 0.5
            if fromPerpendicular {
                let shift = NSSize(width: -fraction * cellShift.width, height: -fraction * cellShift.height)
                let diagonalEnd = NSPoint(x: to.x + shift.width, y: to.y + shift.height)
                path.move(to: end)
                path.line(to: diagonalEnd)
                path.move(to: start)
                end = diagonalEnd
                control2 = NSPoint(x: end.x - cellShift.width / 4, y: end.y - cellShift.height / 4)
                control1.y += cellShift.height / 4
            } else {
                let shift = NSSize(width: fraction * cellShift.width, height: fraction * cellShift.height)
                let diagonalEnd = NSPoint(x: start.x + shift.width, y: start.y + shift.height)
                path.line(to: diagonalEnd)
                start = diagonalEnd
                control1 = NSPoint(
                    x: diagonalEnd.x + cellShift.width / 4,
                    y: diagonalEnd.y + cellShift.height / 4
                )
                control2.y -= cellShift.height / 4
            }
        } else {
            if fromPerpendicular {
                control1.y += cellShift.height / 4
            } else {
                let shift = NSSize(width: cellShift.width / 6, height: cellShift.height / 6)
                let diagonalEnd = NSPoint(x: start.x + shift.width, y: start.y + shift.height)
                path.line(to: diagonalEnd)
                start = diagonalEnd
                control1 = NSPoint(
                    x: diagonalEnd.x + shift.width,
                    y: diagonalEnd.y + shift.height
                )
            }
            if toPerpendicular {
                control2.y -= cellShift.height / 4
            } else {
                let shift = NSSize(width: -cellShift.width / 6, height: -cellShift.height / 6)
                let diagonalEnd = NSPoint(x: end.x + shift.width, y: end.y + shift.height)
                path.move(to: end)
                path.line(to: diagonalEnd)
                path.move(to: start)
                end = diagonalEnd
                control2 = NSPoint(
                    x: end.x + shift.width,
                    y: end.y + shift.height
                )
            }
        }
        path.curve(
            to: end,
            controlPoint1: control1,
            controlPoint2: control2
        )
    }

    private func laneX(_ lane: Int, originX: CGFloat) -> CGFloat {
        originX + (CGFloat(lane) + 0.5) * CGFloat(RevisionGraphLayout.laneWidth)
    }
}


struct RevisionLabelContext {
    var aheadBehindByLocal: [String: AheadBehindData] = [:] {
        didSet { aheadBehindByRemote = Dictionary(aheadBehindByLocal.values.map { ($0.remoteRef, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    private(set) var aheadBehindByRemote: [String: AheadBehindData] = [:]
    var superproject: SuperprojectInfo?
    var remoteColors: [String: NSColor] = [:]

    var remotePrefixes: [String: String] = [:]
    var showAnnotatedTagsMessages = true


    func aheadBehind(_ reference: RevisionReference) -> AheadBehindData? {
        switch reference.kind {
        case .remoteBranch: aheadBehindByRemote[reference.id]
        case .localBranch, .currentBranch: aheadBehindByLocal[reference.name]
        default: nil
        }
    }
}


struct RevisionLabelHit: Equatable {
    var reference: RevisionReference

    var virtualTarget: String?

    var virtualSource: RevisionReference?
    var isStash = false
}

final class RevisionMessageCellView: NSTableCellView {
    var changeCounts: RevisionChangeCounts?
    private enum BadgeShape {
        case notchLeft
        case notchRight
        case pointLeft
        case pointRight
        case rect
    }
    private enum Arrow { case none, filled, outline }

    private struct Badge {
        let hit: RevisionLabelHit?
        let name: String
        let frame: NSRect
        let shape: BadgeShape
        let pointWidth: CGFloat
        let color: NSColor
        let font: NSFont
        let arrow: Arrow
        let dashed: Bool
        var image: NSImage?

        func contains(_ point: NSPoint) -> Bool {
            guard frame.contains(point), pointWidth > 0, shape != .rect else { return frame.contains(point) }
            let halfHeight = frame.height / 2
            guard halfHeight > 0 else { return true }
            let dy = min(abs(point.y - frame.midY), halfHeight)
            let slant = pointWidth * dy / halfHeight
            switch shape {
            case .pointRight: return point.x <= frame.maxX - slant
            case .notchRight: return point.x <= frame.maxX - pointWidth + slant
            case .pointLeft: return point.x >= frame.minX + slant
            case .notchLeft: return point.x >= frame.minX + pointWidth - slant
            case .rect: return true
            }
        }
    }

    private var commit: Commit?
    private var showsTags = true
    private var isRelative = true
    private var badges: [Badge] = []
    private var hoveredBadge: Int?
    private var trackingAreaReference: NSTrackingArea?
    private var labels = RevisionLabelContext()
    override var isFlipped: Bool { true }

    func configure(commit: Commit, showsTags: Bool, isRelative: Bool, showsRemoteBranches: Bool = true,
                   body: String = "", toolTip messageToolTip: String? = nil, labels: RevisionLabelContext = .init()) {
        self.commit = commit
        self.showsTags = showsTags
        self.showsRemoteBranches = showsRemoteBranches
        self.isRelative = isRelative
        self.bodySuffix = body
        self.messageToolTip = messageToolTip
        self.labels = labels
        hoveredBadge = nil
        toolTip = messageToolTip
        needsDisplay = true
    }
    private var showsRemoteBranches = true
    private var bodySuffix = ""
    private var messageToolTip: String?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }


    func label(atWindowPoint point: NSPoint) -> RevisionLabelHit? {
        if badges.isEmpty, commit != nil { badges = layoutBadges(for: commit!) }
        let local = convert(point, from: nil)
        return badges.first { $0.hit != nil && $0.contains(local) }?.hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let commit else { return }
        badges = layoutBadges(for: commit)
        for (index, badge) in badges.enumerated() {
            draw(badge: badge, highlighted: hoveredBadge == index)
        }
        if commit.isArtificial {
            drawArtificialRevision(commit, offset: badges.last.map { $0.frame.maxX + 5 } ?? 6)
            return
        }

        var subjectX = badges.last.map { $0.frame.maxX + 5 } ?? 6
        guard subjectX < bounds.maxX else { return }
        if RevisionGridPresentation.hasAutosquashMarker(commit.subject),
           let marker = AppKitFactory.resourceImage("FixupAndSquashMessageMarker", accessibilityDescription: "Autosquash") {
            marker.draw(in: NSRect(x: subjectX, y: bounds.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
            subjectX += 18
        }
        guard subjectX < bounds.maxX else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let subjectColor: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
            : (!isRelative && AppSettingsStore.shared.colorPreferences.nonRelativeTextGray ? .secondaryLabelColor : ApplicationColors.color("WindowText", fallback: .labelColor))

        let font = AppSettingsStore.shared.applicationFont(size: 11, weight: commit.isHEAD ? .bold : .regular)
        let height = ceil(font.boundingRectForFont.height)
        let message = NSMutableAttributedString(string: commit.subject, attributes: [.font: font, .foregroundColor: subjectColor, .paragraphStyle: paragraph])
        if !bodySuffix.isEmpty {
            let bodyColor: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            message.append(NSAttributedString(string: bodySuffix, attributes: [.font: font, .foregroundColor: bodyColor, .paragraphStyle: paragraph]))
        }
        let rect = NSRect(x: subjectX, y: bounds.midY - height / 2, width: bounds.maxX - subjectX - 2, height: height)
        message.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawArtificialRevision(_ commit: Commit, offset: CGFloat) {
        let font = AppSettingsStore.shared.applicationFont(size: 11)
        let textSize = (commit.subject as NSString).size(withAttributes: [.font: font])
        let commonTextWidth = max(
            ("Working directory" as NSString).size(withAttributes: [.font: font]).width,
            ("Commit index" as NSString).size(withAttributes: [.font: font]).width
        )
        let labelHeight = ceil(textSize.height) + 3
        let labelWidth = ceil(textSize.width) + 10
        let frame = NSRect(
            x: offset,
            y: floor((bounds.height - labelHeight) / 2),
            width: min(labelWidth, max(0, bounds.width - offset)),
            height: labelHeight
        )
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textColor: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let height = ceil(font.boundingRectForFont.height)
        (commit.subject as NSString).draw(
            at: NSPoint(x: frame.minX + 5, y: frame.midY - height / 2),
            withAttributes: [.font: font, .foregroundColor: textColor]
        )

        guard AppSettingsStore.shared.browseDisplayPreferences.showArtificialRevisionCounts else { return }
        var statusX = frame.minX + ceil(commonTextWidth) + 12
        var groups: [(String, Int, String)] = []
        if let counts = changeCounts {
            groups = [("FileStatusModified", counts.changed.count, "changed files"),
                      ("FileStatusAdded", counts.added.count, "new files"),
                      ("FileStatusRemoved", counts.deleted.count, "deleted files"),
                      ("SubmoduleRevisionDown", counts.submodulesChanged.count, "changed submodules"),
                      ("SubmoduleDirty", counts.submodulesDirty.count, "dirty submodules")].filter { $0.1 > 0 }
            if groups.isEmpty { groups = [("RepoStateClean", 0, "Clean")] }
        } else { groups = [("RepoStateUnknown", 0, "Status unknown")] }
        for (icon, count, label) in groups {
            let rect = NSRect(x: statusX, y: frame.midY - 6, width: 12, height: 12)
            guard rect.maxX <= bounds.maxX else { break }
            AppKitFactory.resourceImage(icon, accessibilityDescription: label)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            statusX += 16
            if count > 0 {
                let text = String(count) as NSString
                text.draw(at: NSPoint(x: statusX, y: frame.midY - height / 2), withAttributes: [.font: font, .foregroundColor: textColor])
                statusX += ceil(text.size(withAttributes: [.font: font]).width) + 5
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = badges.firstIndex { $0.hit != nil && $0.contains(point) }
        guard next != hoveredBadge else { return }
        hoveredBadge = next
        toolTip = next.flatMap { badges[$0].hit }.map(tooltip(for:)) ?? messageToolTip
        if next == nil {
            NSCursor.arrow.set()
        } else {
            NSCursor.pointingHand.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBadge = nil
        toolTip = messageToolTip
        NSCursor.arrow.set()
        needsDisplay = true
    }



    private func layoutBadges(for commit: Commit) -> [Badge] {
        var result: [Badge] = []
        var offset: CGFloat = 6
        func append(_ badge: Badge, spacing: CGFloat = 5) {
            result.append(badge)
            offset = badge.frame.maxX + spacing
        }

        var superprojectRefs: [RevisionReference] = []
        if let spi = labels.superproject, let id = commit.objectID {
            let color = NSColor.systemOrange
            for (label, match, current) in [("", spi.currentCommit, true), ("Base", spi.conflictBase, false),
                                            ("Local", spi.conflictLocal, false), ("Remote", spi.conflictRemote, false)] where match == id {
                append(makeBadge(hit: nil, name: label, kind: .head, shape: .rect, offset: offset, color: color,
                                 arrow: current ? .filled : .outline, dashed: true, bold: false))
            }
            superprojectRefs = spi.refs[id] ?? []
        }

        let references = RevisionGridPresentation.sortedReferences(commit.references.filter {
            (showsTags || $0.kind != .tag) && (showsRemoteBranches || $0.kind != .remoteBranch) && $0.kind != .stash
        })

        var trackedRemotes: [String: RevisionReference] = [:]
        for remote in references where remote.kind == .remoteBranch {
            for local in references where (local.kind == .localBranch || local.kind == .currentBranch) && local.tracks(remote) {
                trackedRemotes[local.name] = remote
            }
        }
        let localBranches = references.filter { $0.kind == .localBranch || $0.kind == .currentBranch }
        let singleLocalBranchName = localBranches.count == 1 ? trackedRemotes.keys.first : nil
        let trackedIDs = Set(trackedRemotes.values.map(\.id))

        for reference in references {
            if offset > bounds.maxX { break }
            if reference.kind == .bisectGood || reference.kind == .bisectBad {
                if let image = AppKitFactory.resourceImage(reference.kind == .bisectGood ? "BisectGood" : "BisectBad", accessibilityDescription: reference.name),
                   offset + 16 < bounds.maxX {
                    var badge = Badge(hit: nil, name: "", frame: NSRect(x: offset, y: bounds.midY - 8, width: 16, height: 16), shape: .rect,
                                      pointWidth: 0, color: .clear, font: .systemFont(ofSize: 11), arrow: .none, dashed: false)
                    badge.image = image
                    append(badge, spacing: 4)
                }
                continue
            }
            if trackedIDs.contains(reference.id) { continue }
            let superprojectRef = superprojectRefs.firstIndex { $0.id == reference.id }.map { superprojectRefs.remove(at: $0) }
            let dashed = superprojectRef != nil

            if let remote = trackedRemotes[reference.name], reference.kind != .remoteBranch {
                let nestledName = remote.remoteName.map { name in
                    remote.name == "\(name)/\(labels.remotePrefixes[name] ?? "")\(reference.name)" ? name : remote.name
                } ?? remote.name
                appendNested(reference, dashed: dashed, nestled: remote, nestledName: nestledName,
                             nestledHit: RevisionLabelHit(reference: remote), nestledDashed: false, into: &result, offset: &offset)
                continue
            }
            if let data = labels.aheadBehind(reference) {
                let isRemote = reference.kind == .remoteBranch
                let text = data.display(withCounts: false, reverse: !isRemote)
                if !text.isEmpty {
                    let target = isRemote ? "refs/heads/" + data.branch : data.remoteRef
                    let virtual = RevisionReference(id: target, name: text, kind: isRemote ? .localBranch : .remoteBranch,
                                                    trackingRemote: reference.trackingRemote, mergeWith: reference.id)
                    appendNested(reference, dashed: dashed, nestled: virtual, nestledName: text,
                                 nestledHit: RevisionLabelHit(reference: virtual, virtualTarget: target, virtualSource: reference),
                                 nestledDashed: true, into: &result, offset: &offset)
                    continue
                }
            }
            var name = reference.name
            if reference.kind == .remoteBranch, let single = singleLocalBranchName, let remote = reference.remoteName,
               reference.name == "\(remote)/\(labels.remotePrefixes[remote] ?? "")\(single)" {
                name = remote
            }
            if reference.kind == .tag && reference.isAnnotated && labels.showAnnotatedTagsMessages { name += " [...]" }
            append(makeBadge(hit: RevisionLabelHit(reference: reference), name: name, kind: reference.kind,
                             shape: reference.kind == .tag ? .pointLeft : .rect, offset: offset, remote: reference.remoteName, dashed: dashed))
        }


        for (index, reference) in superprojectRefs.prefix(SuperprojectInfo.maxRefs).enumerated() {
            append(makeBadge(hit: nil, name: index < SuperprojectInfo.maxRefs - 1 ? reference.name : "…", kind: reference.kind,
                             shape: .rect, offset: offset, dashed: true))
        }

        if let stash = commit.references.first(where: { $0.kind == .stash }) {
            append(makeBadge(hit: RevisionLabelHit(reference: stash, isStash: true), name: stash.name, kind: .stash, shape: .rect, offset: offset))
        }
        return result
    }


    private func appendNested(_ reference: RevisionReference, dashed: Bool, nestled: RevisionReference, nestledName: String,
                              nestledHit: RevisionLabelHit, nestledDashed: Bool, into result: inout [Badge], offset: inout CGFloat) {
        let isRemote = reference.kind == .remoteBranch
        let branch = makeBadge(hit: RevisionLabelHit(reference: reference), name: reference.name, kind: reference.kind,
                               shape: isRemote ? .notchRight : .pointRight, offset: offset, remote: reference.remoteName, dashed: dashed)
        result.append(branch)
        guard branch.frame.width > 0 else { return }
        offset = max(offset, branch.frame.maxX - branch.pointWidth + 1)
        let nestledBadge = makeBadge(hit: nestledHit, name: nestledName, kind: nestled.kind, shape: isRemote ? .pointLeft : .notchLeft,
                                     offset: offset, remote: nestled.kind == .remoteBranch ? (nestled.remoteName ?? nestled.trackingRemote) : nil,
                                     arrow: Arrow.none, dashed: nestledDashed, bold: nestledName == AheadBehindData.goneSymbol)
        result.append(nestledBadge)
        offset = nestledBadge.frame.maxX + 5
    }

    private func makeBadge(hit: RevisionLabelHit?, name: String, kind: RevisionReference.Kind, shape: BadgeShape, offset: CGFloat,
                           remote: String? = nil, color: NSColor? = nil, arrow: Arrow? = nil, dashed: Bool = false, bold: Bool? = nil) -> Badge {
        let isHEAD = kind == .head || kind == .currentBranch
        let arrow = arrow ?? (isHEAD ? .filled : .none)
        let font = AppSettingsStore.shared.applicationFont(size: 11, weight: (bold ?? isHEAD) ? .bold : .regular)
        let textSize = (name as NSString).size(withAttributes: [.font: font])
        let backgroundHeight = ceil(textSize.height) + 4 - 1
        let pointWidth = floor(backgroundHeight / 2)
        let iconWidth = arrow == .none ? 0 : bounds.height / 2
        let extraWidth: CGFloat
        switch shape {
        case .notchLeft, .notchRight: extraWidth = pointWidth
        case .pointLeft, .pointRight: extraWidth = pointWidth / 2
        case .rect: extraWidth = 0
        }

        let desiredWidth = ceil(textSize.width) + iconWidth + 8 + extraWidth + 1
        let width = min(max(0, bounds.width - offset), desiredWidth)
        let frame = NSRect(x: offset, y: floor((bounds.height - backgroundHeight) / 2), width: width, height: backgroundHeight)
        let resolved = color ?? remote.flatMap { labels.remoteColors[$0] } ?? GitExtensionsPalette.referenceColor(for: kind)
        return Badge(hit: hit, name: name, frame: frame, shape: shape, pointWidth: pointWidth, color: resolved,
                     font: font, arrow: arrow, dashed: dashed)
    }

    private func draw(badge: Badge, highlighted: Bool) {
        if let image = badge.image {
            image.draw(in: badge.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        guard badge.frame.width > 0, badge.frame.height > 0 else { return }
        let path = badgePath(frame: badge.frame, shape: badge.shape, pointWidth: badge.pointWidth)
        if AppSettingsStore.shared.colorPreferences.fillRefLabels {
            badge.color.withAlphaComponent(0.23).setFill()
            path.fill()
        } else if backgroundStyle == .emphasized {
            NSColor.textBackgroundColor.setFill()
            path.fill()
        }

        let border = badge.color.blended(withFraction: 0.5, of: .textBackgroundColor) ?? badge.color
        border.setStroke()
        path.lineWidth = 1
        if badge.dashed { path.setLineDash([4, 2], count: 2, phase: 0) }
        path.stroke()
        if highlighted {
            badge.color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        var textX = badge.frame.minX + 4
        if badge.shape == .notchLeft || badge.shape == .pointLeft { textX += badge.pointWidth }
        if badge.shape == .pointLeft { textX -= badge.pointWidth / 2 }
        if badge.arrow != .none {
            drawHEADArrow(in: badge.frame, color: badge.color, filled: badge.arrow == .filled)
            textX += bounds.height / 2
        }

        let textColor = badge.color.blended(withFraction: 0.25, of: .black) ?? badge.color
        let height = ceil(badge.font.boundingRectForFont.height)
        let textRect = NSRect(
            x: textX,
            y: badge.frame.midY - height / 2,
            width: max(0, badge.frame.maxX - textX - 4),
            height: height
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (badge.name as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: badge.font, .foregroundColor: textColor, .paragraphStyle: paragraph]
        )
    }

    private func badgePath(frame: NSRect, shape: BadgeShape, pointWidth: CGFloat) -> NSBezierPath {
        let radius: CGFloat = min(5, frame.height / 2)
        if shape == .rect { return NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius) }

        let path = NSBezierPath()
        let left = frame.minX
        let right = frame.maxX
        let top = frame.minY
        let bottom = frame.maxY
        let middle = frame.midY

        switch shape {
        case .pointRight:
            path.move(to: NSPoint(x: left + radius, y: top))
            path.line(to: NSPoint(x: right - pointWidth, y: top))
            path.line(to: NSPoint(x: right, y: middle))
            path.line(to: NSPoint(x: right - pointWidth, y: bottom))
            path.line(to: NSPoint(x: left + radius, y: bottom))
        case .notchRight:
            path.move(to: NSPoint(x: left + radius, y: top))
            path.line(to: NSPoint(x: right, y: top))
            path.line(to: NSPoint(x: right - pointWidth, y: middle))
            path.line(to: NSPoint(x: right, y: bottom))
            path.line(to: NSPoint(x: left + radius, y: bottom))
        case .pointLeft:
            path.move(to: NSPoint(x: left, y: middle))
            path.line(to: NSPoint(x: left + pointWidth, y: top))
            path.line(to: NSPoint(x: right - radius, y: top))
            path.line(to: NSPoint(x: right, y: top + radius))
            path.line(to: NSPoint(x: right, y: bottom - radius))
            path.line(to: NSPoint(x: right - radius, y: bottom))
            path.line(to: NSPoint(x: left + pointWidth, y: bottom))
        case .notchLeft:
            path.move(to: NSPoint(x: left, y: top))
            path.line(to: NSPoint(x: left + pointWidth, y: middle))
            path.line(to: NSPoint(x: left, y: bottom))
            path.line(to: NSPoint(x: right - radius, y: bottom))
            path.line(to: NSPoint(x: right, y: bottom - radius))
            path.line(to: NSPoint(x: right, y: top + radius))
            path.line(to: NSPoint(x: right - radius, y: top))
        case .rect:
            break
        }
        path.close()
        return path
    }

    private func drawHEADArrow(in frame: NSRect, color: NSColor, filled: Bool) {
        let x = frame.minX + 4
        let y = frame.minY + 3
        let height = frame.height - 6
        let width = height / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + width, y: y + height / 2))
        path.line(to: NSPoint(x: x, y: y + height))
        path.close()
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func tooltip(for hit: RevisionLabelHit) -> String? {
        if hit.isStash { return messageToolTip ?? hit.reference.name }
        let showsDetails = AppSettingsStore.shared.revisionGridPreferences.showRevisionGridTooltips
        let labels = labels
        guard let label = RevisionGridPresentation.referenceToolTip(hit, aheadBehind: { labels.aheadBehind($0) }, showTooltips: showsDetails)
        else { return nil }
        guard showsDetails, let messageToolTip, !messageToolTip.isEmpty else { return label }
        return label + "\n\n" + messageToolTip
    }
}

@MainActor private enum GitExtensionsPalette {
    private static var graphGeneration = -1
    private static var cachedGraph: [NSColor] = []
    static var graph: [NSColor] {
        if graphGeneration == ApplicationColors.generation { return cachedGraph }


        var colors: [NSColor] = []
        for color in defaultGraph.enumerated().map({ index, color in ApplicationColors.color("GraphBranch\(index + 1)", fallback: color) })
            + [ApplicationColors.color("GraphBranch8", fallback: .clear)] where color.alphaComponent > 0 {
            if !colors.contains(where: { $0.isEqual(color) }) { colors.append(color) }
        }
        if colors.count < 4 { colors = [.cyan, .magenta, .yellow, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)] }
        cachedGraph = colors
        graphGeneration = ApplicationColors.generation
        return cachedGraph
    }
    private static let defaultGraph: [NSColor] = [
        dynamic(light: 0xF064A0, dark: 0xDB5B93),
        dynamic(light: 0x78B4E6, dark: 0x6FA7D4),
        dynamic(light: 0x24C221, dark: 0x1DA31B),
        dynamic(light: 0xA078F0, dark: 0x8A67CF),
        dynamic(light: 0xDD3228, dark: 0xC02A22),
        dynamic(light: 0x1AC6A6, dark: 0x17AA8F),
        dynamic(light: 0xE7B00F, dark: 0xCA9B0D)
    ]

    static var nonRelativeGraph: NSColor { ApplicationColors.color("GraphNonRelativeBranch", fallback: dynamic(light: 0xD3D3D3, dark: 0x707070)) }

    static func referenceColor(for kind: RevisionReference.Kind) -> NSColor {
        switch kind {
        case .bisectGood, .bisectBad: ApplicationColors.color("OtherTag", fallback: dynamic(light: 0x808080, dark: 0xCFB3B3))
        case .head, .currentBranch, .localBranch: ApplicationColors.color("Branch", fallback: dynamic(light: 0x008000, dark: 0x7FE28A))
        case .remoteBranch: ApplicationColors.color("RemoteBranch", fallback: dynamic(light: 0x8B0009, dark: 0xFD9797))
        case .tag: ApplicationColors.color("Tag", fallback: dynamic(light: 0x00008B, dark: 0x40BAF7))
        case .stash: ApplicationColors.color("OtherTag", fallback: dynamic(light: 0x808080, dark: 0xCFB3B3))
        }
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
