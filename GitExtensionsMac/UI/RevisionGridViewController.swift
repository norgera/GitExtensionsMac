import AppKit

final class RevisionGridViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onCommand: ((String, [Commit], Commit) -> Void)?
    var onSelection: ((Commit) -> Void)?

    private let tableView = RevisionTableView()
    private let quickSearchLabel = NSTextField(labelWithString: "")
    private var allCommits: [Commit] = []
    private var commits: [Commit] = []
    private var graphRows: [RevisionGraphLayout.Row] = []
    private var textFilter = ""
    private var branchFilter = ""
    private var visibleRowsObserver: NSObjectProtocol?
    private var quickSearchString = ""
    private var lastQuickSearchString = ""
    private var quickSearchTimer: Timer?
    private var menuFocusedCommitID: String?
    private var isCherryPicking = false
    private var cherryPickHasConflicts = false
    private var isRebasing = false
    private var rebaseHasConflicts = false
    private var graphTask: Task<Void, Never>?
    private var graphGeneration = 0
    private var pendingSelectionID: String?
    private var lastViewportSize = NSSize.zero
    private var graphWidthRefreshScheduled = false
    private var graphConfiguration = RevisionGraphLayout.Configuration.gitExtensionsDefault

    deinit {
        graphTask?.cancel()
        if let visibleRowsObserver {
            NotificationCenter.default.removeObserver(visibleRowsObserver)
        }
    }

    override func loadView() {
        let scrollView = NSScrollView()
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
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = false
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
            self?.performNavigation(command)
            return true
        }

        addColumn("Graph", width: 54, min: 22, max: 646, resizable: false)
        addColumn("Message", width: 500, min: 25, max: 1_600, resizable: true)
        addColumn("Author Name", width: 130, min: 25, max: 320, resizable: true)
        addColumn("Date", width: 130, min: 25, max: 220, resizable: true)
        addColumn("Commit ID", width: 60, min: 32, max: 330, resizable: true)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView

        quickSearchLabel.isHidden = true
        quickSearchLabel.font = .boldSystemFont(ofSize: 11)
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
        scheduleGraphColumnWidthRefresh()
    }

    func apply(commits: [Commit], preferredCommitID: String? = nil) {
        pendingSelectionID = preferredCommitID
        allCommits = commits
        applyFilters(selectFirst: true)
    }

    func setCherryPickInProgress(_ inProgress: Bool, hasConflicts: Bool = false) {
        isCherryPicking = inProgress
        cherryPickHasConflicts = hasConflicts
    }

    func setRebaseInProgress(_ inProgress: Bool, hasConflicts: Bool) {
        isRebasing = inProgress
        rebaseHasConflicts = hasConflicts
    }

    func setTextFilter(_ value: String) {
        textFilter = value
        applyFilters(selectFirst: true)
    }

    func setBranchFilter(_ value: String) {
        branchFilter = value
        applyFilters(selectFirst: true)
    }

    func selectCommit(id: String) {
        guard let index = commits.firstIndex(where: { $0.id == id }) else {
            if allCommits.contains(where: { $0.id == id }) { pendingSelectionID = id }
            return
        }
        pendingSelectionID = nil
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        onSelection?(commits[index])
    }

    var visibleCommitCount: Int { commits.count }

    func setGraphConfiguration(mergeCommonParentLanes: Bool, straightenDiagonals: Bool) {
        let configuration = RevisionGraphLayout.Configuration(
            mergeCommonParentLanes: mergeCommonParentLanes,
            straightenDiagonals: straightenDiagonals
        )
        guard configuration != graphConfiguration else { return }
        graphConfiguration = configuration
        applyFilters(selectFirst: false)
    }

    private func applyFilters(selectFirst: Bool) {
        let filteredCommits = allCommits.filter { commit in
            let matchesText = textFilter.isEmpty
                || commit.subject.localizedCaseInsensitiveContains(textFilter)
                || commit.body.localizedCaseInsensitiveContains(textFilter)
                || commit.authorName.localizedCaseInsensitiveContains(textFilter)
                || commit.id.localizedCaseInsensitiveContains(textFilter)
            let matchesBranch = branchFilter.isEmpty
                || commit.references.contains { $0.name.localizedCaseInsensitiveContains(branchFilter) }
                || commit.subject.localizedCaseInsensitiveContains(branchFilter)
            return matchesText && matchesBranch
        }

        let completeHistory = allCommits
        let configuration = graphConfiguration
        graphGeneration += 1
        let generation = graphGeneration
        graphTask?.cancel()
        graphTask = Task { @MainActor [weak self] in
            let graph = await Task.detached(priority: .userInitiated) {
                RevisionGraphLayout.build(commits: filteredCommits, completeHistory: completeHistory, configuration: configuration)
            }.value
            guard let self, !Task.isCancelled, generation == self.graphGeneration else { return }
            self.commits = filteredCommits
            self.graphRows = graph.rows
            self.tableView.reloadData()
            self.updateGraphColumnWidthForVisibleRows(fallbackLaneCount: graph.maximumLaneCount)
            guard !filteredCommits.isEmpty else { return }
            let requestedIndex = self.pendingSelectionID.flatMap { id in filteredCommits.firstIndex(where: { $0.id == id }) }
            let index = requestedIndex ?? (selectFirst ? filteredCommits.firstIndex(where: { !$0.isArtificial }) ?? 0 : 0)
            self.pendingSelectionID = nil
            self.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            self.tableView.scrollRowToVisible(index)
            self.onSelection?(filteredCommits[index])
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
        GitExtensionsSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < commits.count, row < graphRows.count, let identifier = tableColumn?.identifier else { return nil }
        let commit = commits[row]

        switch identifier.rawValue {
        case "Graph":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CommitGraphCellView) ?? CommitGraphCellView()
            cell.identifier = identifier
            cell.configure(row: graphRows[row])
            return cell
        case "Message":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RevisionMessageCellView) ?? RevisionMessageCellView()
            cell.identifier = identifier
            cell.configure(commit: commit)
            return cell
        case "Author Name":
            return textCell(identifier, value: commit.isArtificial ? "" : commit.authorName, font: .systemFont(ofSize: 11))
        case "Date":
            let date = commit.isArtificial ? "" : Self.relativeFormatter.localizedString(for: commit.commitDate, relativeTo: Date())
            return textCell(identifier, value: date, font: .systemFont(ofSize: 11))
        case "Commit ID":
            return textCell(identifier, value: commit.isArtificial ? "" : commit.shortID, font: .monospacedSystemFont(ofSize: 10.5, weight: .regular))
        default:
            return nil
        }
    }

    private func textCell(_ identifier: NSUserInterfaceItemIdentifier, value: String, font: NSFont) -> NSTableCellView {
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
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            rowView.subviews.forEach { $0.needsDisplay = true }
        }
        guard tableView.selectedRow >= 0, tableView.selectedRow < commits.count else { return }
        onSelection?(commits[tableView.selectedRow])
    }

    @objc private func openSelectedCommit() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < commits.count else { return }
        BrowserCommandCenter.perform("Open commit \(commits[row].shortID)")
    }

    private func copySelectedCommitIDs() {
        let ids = tableView.selectedRowIndexes.compactMap { index in
            index < commits.count ? commits[index].id : nil
        }
        guard !ids.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
    }

    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if modifiers == .option, event.keyCode == 125 || event.keyCode == 126 {
            showAdjacentQuickSearchResult(down: event.keyCode == 125)
            return true
        }

        if event.keyCode == 53 { // Escape
            guard !quickSearchLabel.isHidden else { return false }
            hideQuickSearch()
            return true
        }

        if event.keyCode == 51 { // Backspace
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
            commit.id,
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
        quickSearchTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
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
        guard row >= 0, row < commits.count else {
            menu.removeAllItems()
            return
        }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let selectedCommits = tableView.selectedRowIndexes.compactMap { index in
            index < commits.count ? commits[index] : nil
        }
        let currentBranchName = allCommits
            .lazy
            .flatMap(\.references)
            .first(where: { $0.kind == .currentBranch })?
            .name
        let context = RevisionContextMenuContext(
            focusedCommit: commits[row],
            selectedCommits: selectedCommits,
            history: allCommits,
            currentBranchName: currentBranchName,
            isCherryPicking: isCherryPicking,
            cherryPickHasConflicts: cherryPickHasConflicts,
            isRebasing: isRebasing,
            rebaseHasConflicts: rebaseHasConflicts
        )
        populatePlaceholderMenu(menu, with: RevisionContextMenuBuilder.build(context))
        menuFocusedCommitID = commits[row].id
        for identifier in [
            "revision.navigate.child",
            "revision.navigate.parent",
            "revision.navigate.firstParent",
            "revision.navigate.lastParent",
            "revision.navigate.mergeBase",
            "revision.navigate.current"
        ] {
            guard let item = menuItem(withIdentifier: identifier, in: menu) else { continue }
            item.target = self
            item.action = #selector(navigateFromMenu(_:))
        }
        retargetMenuItems(
            in: menu,
            where: { identifier in
                identifier == "revision.commit.checkout"
                    || identifier == "revision.commit.amend"
                    || identifier == "revision.commit.fixup"
                    || identifier == "revision.commit.squash"
                    || identifier == "revision.commit.cherryPick"
                    || identifier == "revision.cherryPick.continue"
                    || identifier == "revision.cherryPick.abort"
                    || identifier.hasPrefix("revision.rebase.")
                    || identifier == "revision.commit.edit"
                    || identifier == "revision.commit.reword"
                    || identifier.hasPrefix("revision.stash.")
                    || identifier.hasPrefix("revision.branch.checkout.ref.")
                    || identifier.hasPrefix("revision.branch.rebase.")
            },
            target: self,
            action: #selector(performMutationMenuCommand(_:))
        )
    }

    @objc private func performMutationMenuCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue,
              let focused = focusedCommit(id: menuFocusedCommitID) else { return }
        var selected = tableView.selectedRowIndexes.compactMap { index in
            index < commits.count ? commits[index] : nil
        }
        if selected.isEmpty { selected = [focused] }
        onCommand?(identifier, selected, focused)
    }

    @objc private func navigateFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue else { return }
        performNavigation(identifier, focusedCommitID: menuFocusedCommitID)
    }

    private func performNavigation(_ identifier: String, focusedCommitID: String? = nil) {
        guard let focused = focusedCommit(id: focusedCommitID) else { return }
        let targetID: String?

        switch identifier {
        case "revision.navigate.child":
            targetID = RevisionNavigationResolver.childID(of: focused, in: allCommits)
        case "revision.navigate.parent", "revision.navigate.firstParent":
            targetID = RevisionNavigationResolver.parentID(of: focused)
        case "revision.navigate.lastParent":
            targetID = RevisionNavigationResolver.parentID(of: focused, last: true)
        case "revision.navigate.mergeBase":
            targetID = mergeBaseForCurrentSelection(focused: focused)
        case "revision.navigate.current":
            targetID = allCommits.first(where: \.isHEAD)?.id
        default:
            targetID = nil
        }

        guard let targetID else { return }
        selectCommit(id: targetID)
    }

    private func focusedCommit(id: String?) -> Commit? {
        if let id, let commit = allCommits.first(where: { $0.id == id }) { return commit }
        guard tableView.selectedRow >= 0, tableView.selectedRow < commits.count else { return nil }
        return commits[tableView.selectedRow]
    }

    private func mergeBaseForCurrentSelection(focused: Commit) -> String? {
        var selected = tableView.selectedRowIndexes.compactMap { index in
            index < commits.count ? commits[index] : nil
        }
        if selected.isEmpty { selected = [focused] }
        return RevisionNavigationResolver.mergeBaseID(
            selectedCommits: selected,
            history: allCommits,
            headCommit: allCommits.first(where: \.isHEAD)
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private final class RevisionTableView: NSTableView {
    var copySelectedRows: (() -> Void)?
    var handleQuickSearchKey: ((NSEvent) -> Bool)?
    var handleNavigationKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelectedRows?()
            return
        }

        let navigationModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let navigationID: String?
        if navigationModifiers == .control, key == "n" {
            navigationID = "revision.navigate.child"
        } else if navigationModifiers == .control, key == "p" {
            navigationID = "revision.navigate.parent"
        } else if navigationModifiers == .control, event.keyCode == 123 {
            navigationID = "revision.navigate.firstParent"
        } else if navigationModifiers == .control, event.keyCode == 124 {
            navigationID = "revision.navigate.lastParent"
        } else if navigationModifiers == [.control, .shift], key == "k" {
            navigationID = "revision.navigate.mergeBase"
        } else if navigationModifiers == [.control, .shift], key == "c" {
            navigationID = "revision.navigate.current"
        } else {
            navigationID = nil
        }
        if let navigationID, handleNavigationKey?(navigationID) == true { return }

        if handleQuickSearchKey?(event) == true { return }

        if modifiers.isEmpty || modifiers == .function {
            switch event.keyCode {
            case 115: // Home
                selectAndReveal(row: 0)
                return
            case 119: // End
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
    private var graphRow: RevisionGraphLayout.Row?
    override var isFlipped: Bool { true }

    func configure(row: RevisionGraphLayout.Row) {
        graphRow = row
        needsDisplay = true
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

        let nodeX = laneX(graphRow.nodeLane, originX: originX)
        let nodeRect = NSRect(x: nodeX - 5, y: centerY - 5, width: 10, height: 10)
        let nodePath = graphRow.hasReferences
            ? NSBezierPath(rect: nodeRect.integral)
            : NSBezierPath(ovalIn: nodeRect)
        let nodeColor: NSColor
        if graphRow.commitKind != .revision {
            nodeColor = .tertiaryLabelColor
        } else if !graphRow.isRelative {
            nodeColor = GitExtensionsPalette.nonRelativeGraph
        } else {
            nodeColor = GitExtensionsPalette.graph[graphRow.nodeColorIndex % GitExtensionsPalette.graph.count]
        }
        nodeColor.setFill()
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
        let color: NSColor
        if graphRow?.commitKind != .revision {
            color = .tertiaryLabelColor
        } else if !edge.isRelative {
            color = GitExtensionsPalette.nonRelativeGraph
        } else {
            color = GitExtensionsPalette.graph[edge.colorIndex % GitExtensionsPalette.graph.count]
        }
        color.setStroke()
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
            if singleLane {
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

final class RevisionMessageCellView: NSTableCellView {
    private enum BadgeShape {
        case notchLeft
        case notchRight
        case pointLeft
        case pointRight
        case rect
    }

    private struct Badge {
        let reference: RevisionReference
        let name: String
        let frame: NSRect
        let shape: BadgeShape
        let pointWidth: CGFloat
        let color: NSColor
        let font: NSFont
        let showsHEADArrow: Bool

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
    private var badges: [Badge] = []
    private var hoveredBadge: Int?
    private var trackingAreaReference: NSTrackingArea?
    override var isFlipped: Bool { true }

    func configure(commit: Commit) {
        self.commit = commit
        hoveredBadge = nil
        toolTip = nil
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
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
        if commit.isArtificial {
            drawArtificialRevision(commit)
            return
        }
        badges = layoutBadges(for: commit)
        for (index, badge) in badges.enumerated() {
            draw(badge: badge, highlighted: hoveredBadge == index)
        }

        let subjectX = badges.last.map { $0.frame.maxX + 5 } ?? 6
        guard subjectX < bounds.maxX else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let subjectColor: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let font = NSFont.systemFont(ofSize: 11)
        let height = ceil(font.boundingRectForFont.height)
        let rect = NSRect(x: subjectX, y: bounds.midY - height / 2, width: bounds.maxX - subjectX - 2, height: height)
        (commit.subject as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: subjectColor, .paragraphStyle: paragraph]
        )
    }

    private func drawArtificialRevision(_ commit: Commit) {
        badges = []
        let font = NSFont.systemFont(ofSize: 11)
        let textSize = (commit.subject as NSString).size(withAttributes: [.font: font])
        let commonTextWidth = max(
            ("Working directory" as NSString).size(withAttributes: [.font: font]).width,
            ("Commit index" as NSString).size(withAttributes: [.font: font]).width
        )
        let labelHeight = ceil(textSize.height) + 3
        let labelWidth = ceil(textSize.width) + 10
        let frame = NSRect(
            x: 6,
            y: floor((bounds.height - labelHeight) / 2),
            width: min(labelWidth, max(0, bounds.width - 6)),
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

        let statusX = frame.minX + ceil(commonTextWidth) + 12
        let indicatorRect = NSRect(x: statusX, y: frame.midY - 6, width: 12, height: 12)
        if indicatorRect.maxX <= bounds.maxX,
           let image = AppKitFactory.resourceImage("RepoStateClean", accessibilityDescription: "Clean") {
            image.draw(in: indicatorRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = badges.firstIndex { $0.contains(point) }
        guard next != hoveredBadge else { return }
        hoveredBadge = next
        toolTip = next.map { tooltip(for: badges[$0].reference) }
        if next == nil {
            NSCursor.arrow.set()
        } else {
            NSCursor.pointingHand.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBadge = nil
        toolTip = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown, let badge = badges.first(where: { $0.contains(point) }) {
            BrowserCommandCenter.perform("Go to \(badge.reference.name)")
            return
        }
        super.mouseDown(with: event)
    }

    private func layoutBadges(for commit: Commit) -> [Badge] {
        let references = commit.references.sorted { rank($0) == rank($1) ? $0.name < $1.name : rank($0) < rank($1) }
        var consumed: Set<String> = []
        var result: [Badge] = []
        var offset: CGFloat = 6

        for reference in references where !consumed.contains(reference.id) {
            consumed.insert(reference.id)
            if reference.kind == .currentBranch || reference.kind == .localBranch,
               let remote = references.first(where: { candidate in
                   !consumed.contains(candidate.id)
                       && reference.tracks(candidate)
               }) {
                let branch = makeBadge(reference: reference, name: reference.name, shape: .pointRight, offset: offset)
                result.append(branch)
                consumed.insert(remote.id)
                offset = max(6, branch.frame.maxX - branch.pointWidth + 1)
                let remoteName = remote.remoteName ?? remote.name
                let nestled = makeBadge(reference: remote, name: remoteName, shape: .notchLeft, offset: offset)
                result.append(nestled)
                offset = nestled.frame.maxX + 5
                continue
            }

            let shape: BadgeShape = reference.kind == .tag ? .pointLeft : .rect
            let badge = makeBadge(reference: reference, name: reference.name, shape: shape, offset: offset)
            result.append(badge)
            offset = badge.frame.maxX + 5
            if offset >= bounds.maxX { break }
        }
        return result
    }

    private func makeBadge(reference: RevisionReference, name: String, shape: BadgeShape, offset: CGFloat) -> Badge {
        let isHEAD = reference.kind == .head || reference.kind == .currentBranch
        let font = isHEAD ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11)
        let textSize = (name as NSString).size(withAttributes: [.font: font])
        let backgroundHeight = ceil(textSize.height) + 4 - 1
        let pointWidth = floor(backgroundHeight / 2)
        let iconWidth = isHEAD ? bounds.height / 2 : 0
        let extraWidth: CGFloat
        switch shape {
        case .notchLeft, .notchRight: extraWidth = pointWidth
        case .pointLeft, .pointRight: extraWidth = pointWidth / 2
        case .rect: extraWidth = 0
        }
        let desiredWidth = ceil(textSize.width) + iconWidth + 8 + extraWidth - 1
        let width = min(max(0, bounds.width - offset), desiredWidth)
        let frame = NSRect(x: offset, y: floor((bounds.height - backgroundHeight) / 2), width: width, height: backgroundHeight)
        return Badge(
            reference: reference,
            name: name,
            frame: frame,
            shape: shape,
            pointWidth: pointWidth,
            color: GitExtensionsPalette.referenceColor(for: reference.kind),
            font: font,
            showsHEADArrow: isHEAD
        )
    }

    private func draw(badge: Badge, highlighted: Bool) {
        guard badge.frame.width > 0, badge.frame.height > 0 else { return }
        let path = badgePath(frame: badge.frame, shape: badge.shape, pointWidth: badge.pointWidth)
        if backgroundStyle == .emphasized {
            NSColor.textBackgroundColor.setFill()
            path.fill()
        }

        let border = badge.color.blended(withFraction: 0.5, of: .textBackgroundColor) ?? badge.color
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
        if highlighted {
            badge.color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        var textX = badge.frame.minX + 4
        if badge.shape == .notchLeft || badge.shape == .pointLeft { textX += badge.pointWidth }
        if badge.shape == .pointLeft { textX -= badge.pointWidth / 2 }
        if badge.showsHEADArrow {
            drawHEADArrow(in: badge.frame, color: badge.color)
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

    private func drawHEADArrow(in frame: NSRect, color: NSColor) {
        let x = frame.minX + 4
        let y = frame.minY + 3
        let height = frame.height - 6
        let width = height / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + width, y: y + height / 2))
        path.line(to: NSPoint(x: x, y: y + height))
        path.close()
        color.setFill()
        path.fill()
    }

    private func rank(_ reference: RevisionReference) -> Int {
        switch reference.kind {
        case .head: 0
        case .currentBranch: 1
        case .localBranch: 3
        case .remoteBranch: 4
        case .tag: 5
        case .stash: 6
        }
    }

    private func tooltip(for reference: RevisionReference) -> String {
        switch reference.kind {
        case .head:
            return "[HEAD]\nDetached HEAD"
        case .currentBranch:
            return trackingDescription(for: reference, base: "[\(reference.name)]\nCurrent branch (HEAD)")
        case .localBranch:
            return trackingDescription(for: reference, base: "[\(reference.name)]\nLocal branch")
        case .remoteBranch:
            let trackingLocal = commit?.references.first(where: { $0.tracks(reference) })
            return trackingLocal.map { "[\(reference.name)]\nRemote branch\nTracked by \($0.name)" }
                ?? "[\(reference.name)]\nRemote branch"
        case .tag: return "[\(reference.name)]\nTag"
        case .stash: return "[\(reference.name)]\nStash"
        }
    }

    private func trackingDescription(for reference: RevisionReference, base: String) -> String {
        guard let remote = reference.trackingRemote, let mergeWith = reference.mergeWith else { return base }
        return "\(base)\nTracking \(remote)/\(mergeWith)"
    }
}

private enum GitExtensionsPalette {
    static let graph: [NSColor] = [
        dynamic(light: 0xF064A0, dark: 0xDB5B93),
        dynamic(light: 0x78B4E6, dark: 0x6FA7D4),
        dynamic(light: 0x24C221, dark: 0x1DA31B),
        dynamic(light: 0xA078F0, dark: 0x8A67CF),
        dynamic(light: 0xDD3228, dark: 0xC02A22),
        dynamic(light: 0x1AC6A6, dark: 0x17AA8F),
        dynamic(light: 0xE7B00F, dark: 0xCA9B0D)
    ]

    static let nonRelativeGraph = dynamic(light: 0xD3D3D3, dark: 0x707070)

    static func referenceColor(for kind: RevisionReference.Kind) -> NSColor {
        switch kind {
        case .head, .currentBranch, .localBranch: dynamic(light: 0x008000, dark: 0x7FE28A)
        case .remoteBranch: dynamic(light: 0x8B0009, dark: 0xFD9797)
        case .tag: dynamic(light: 0x00008B, dark: 0x40BAF7)
        case .stash: dynamic(light: 0x808080, dark: 0xCFB3B3)
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
