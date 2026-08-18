import AppKit

final class RevisionDiffViewController: RetainingSplitViewController {
    var onFileMutation: ((String, [ChangedFile], ChangedFileSelectionScope) -> Void)?
    var onHunkMutation: ((RepositoryHunkSelection) -> Void)?
    var diffProvider: (@Sendable (Commit, ChangedFile) async throws -> FileDiff?)?
    private static let collapsedFilePaneThickness: CGFloat = 1
    private static let collapsedDiffPaneThickness: CGFloat = 1

    private let filesController = ChangedFilesViewController()
    private let diffController = DiffContentViewController()
    private var diffsByFile: [String: FileDiff] = [:]
    private var currentCommit: Commit?
    private var selectedFileID: String?
    private var diffTask: Task<Void, Never>?
    private var didSetInitialDivider = false

    init() {
        super.init(resizeBehavior: .fixedLeadingPane)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        diffTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter

        let filesItem = NSSplitViewItem(viewController: filesController)
        filesItem.minimumThickness = Self.collapsedFilePaneThickness
        filesItem.preferredThicknessFraction = 300.0 / 850.0
        filesItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        addSplitViewItem(filesItem)

        let diffItem = NSSplitViewItem(viewController: diffController)
        diffItem.minimumThickness = Self.collapsedDiffPaneThickness
        diffItem.holdingPriority = .defaultLow
        addSplitViewItem(diffItem)

        filesController.onSelection = { [weak self] file in
            guard let self else { return }
            selectedFileID = file.id
            if let cached = diffsByFile[file.id] {
                diffController.apply(file: file, diff: cached)
                return
            }
            diffController.apply(file: file, diff: nil)
            guard let currentCommit, let diffProvider else { return }
            diffTask?.cancel()
            diffTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let diff = try await diffProvider(currentCommit, file)
                    guard !Task.isCancelled,
                          self.currentCommit?.id == currentCommit.id,
                          self.selectedFileID == file.id
                    else { return }
                    if let diff { self.diffsByFile[file.id] = diff }
                    self.diffController.apply(file: file, diff: diff)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.selectedFileID == file.id else { return }
                    self.diffController.apply(file: file, diff: nil)
                    BrowserCommandCenter.perform(error.localizedDescription)
                }
            }
        }
        filesController.onMutation = { [weak self] identifier, files, scope in
            self?.onFileMutation?(identifier, files, scope)
        }
        diffController.onHunkMutation = { [weak self] selection in
            self?.onHunkMutation?(selection)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialDivider, splitView.bounds.width >= 650 else { return }
        didSetInitialDivider = true
        setRetainedPosition(300)
    }

    func apply(commit: Commit, comparisonCommit: Commit?, files: [ChangedFile], diffsByFile: [String: FileDiff]) {
        diffTask?.cancel()
        currentCommit = commit
        selectedFileID = nil
        self.diffsByFile = diffsByFile
        let comparisonTitle = RevisionDiffSummaryResolver.summary(selected: commit, comparison: comparisonCommit)
        let scope: ChangedFileSelectionScope = switch commit.kind {
        case .revision: .revision
        case .workingDirectory: .workingTree
        case .index: .index
        }
        diffController.selectionScope = scope
        filesController.apply(files: files, scope: scope, comparisonTitle: comparisonTitle)
    }
}

final class ChangedFilesViewController: NSViewController, NSOutlineViewDelegate, NSOutlineViewDataSource, NSMenuDelegate, NSTextFieldDelegate {
    var onSelection: ((ChangedFile) -> Void)?
    var onMutation: ((String, [ChangedFile], ChangedFileSelectionScope) -> Void)?

    private enum Grouping: Int, Hashable {
        case path
        case fileExtension
        case status
    }

    private let outlineView = NSOutlineView()
    private let filterField = NSTextField()
    private let treeModeButton = NSButton()
    private var groupingButtons: [Grouping: NSButton] = [:]
    private var allFiles: [ChangedFile] = []
    private var files: [ChangedFile] = []
    private var rootNodes: [ChangedFileNode] = []
    private var selectionScope: ChangedFileSelectionScope = .revision
    private var comparisonTitle = "Diff with parent"
    private var isTreeMode = true
    private var grouping: Grouping = .path
    private var usesDenseTree = true
    private var showsGroupNodesInFlatList = false

    override func loadView() {
        let root = NSView()

        let toolbar = AppKitFactory.toolbarBackground()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(AppKitFactory.resourceButton("CollapseAll", tooltip: "Collapse all groups, otherwise expand the selected group", target: self, action: #selector(toggleGroupExpansion)))
        stack.addArrangedSubview(AppKitFactory.separator())
        let refresh = AppKitFactory.resourceButton("ReloadRevisions", tooltip: "Refresh artificial commit", target: self, action: #selector(placeholder(_:)))
        refresh.isEnabled = false
        stack.addArrangedSubview(refresh)
        stack.addArrangedSubview(AppKitFactory.separator())

        let viewMode = NSStackView()
        viewMode.orientation = .horizontal
        viewMode.spacing = 0
        treeModeButton.image = AppKitFactory.resourceImage("FileTree", accessibilityDescription: "Toggle flat list / tree")
        treeModeButton.imagePosition = .imageOnly
        treeModeButton.isBordered = false
        treeModeButton.setButtonType(.pushOnPushOff)
        treeModeButton.state = .on
        treeModeButton.toolTip = "Toggle flat list / tree"
        treeModeButton.target = self
        treeModeButton.action = #selector(toggleTreeMode)
        treeModeButton.translatesAutoresizingMaskIntoConstraints = false
        treeModeButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        treeModeButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        viewMode.addArrangedSubview(treeModeButton)
        viewMode.addArrangedSubview(makeViewModeMenu())
        stack.addArrangedSubview(viewMode)
        stack.addArrangedSubview(AppKitFactory.separator())

        stack.addArrangedSubview(makeGroupingButton(.path, image: "FolderClosed", tooltip: "Group by file path"))
        stack.addArrangedSubview(makeGroupingButton(.fileExtension, image: "File", tooltip: "Group by file type (extension)"))
        stack.addArrangedSubview(makeGroupingButton(.status, image: "FileStatusModified", tooltip: "Group by diff status"))
        stack.addArrangedSubview(AppKitFactory.separator())
        stack.addArrangedSubview(makeFindMenu())
        stack.addArrangedSubview(AppKitFactory.separator())
        stack.addArrangedSubview(makeSettingsMenu())
        toolbar.addSubview(stack)

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        fileColumn.title = "File"
        fileColumn.minWidth = 140
        fileColumn.width = 300
        outlineView.addTableColumn(fileColumn)
        outlineView.outlineTableColumn = fileColumn
        outlineView.headerView = nil
        outlineView.rowHeight = BrowserMetrics.fileRowHeight
        outlineView.indentationPerLevel = 15
        outlineView.intercellSpacing = .zero
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.doubleAction = #selector(openFile)
        outlineView.target = self

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = "Filter files using a regular expression..."
        filterField.font = .systemFont(ofSize: 11)
        filterField.controlSize = .small
        filterField.isBezeled = true
        filterField.isBordered = true
        filterField.bezelStyle = .squareBezel
        filterField.focusRingType = .exterior
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(filterField)
        root.addSubview(scroll)
        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 25)
        toolbarHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarHeight,
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 3),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            filterField.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            filterField.heightAnchor.constraint(equalToConstant: 23),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    func apply(files: [ChangedFile], scope: ChangedFileSelectionScope, comparisonTitle: String) {
        let selectedIDs = selectedFileIDs()
        allFiles = files
        selectionScope = scope
        self.comparisonTitle = comparisonTitle
        reloadFilteredFiles(preferredIDs: selectedIDs)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === filterField else { return }
        reloadFilteredFiles(preferredIDs: selectedFileIDs())
    }

    private func reloadFilteredFiles(preferredIDs: Set<String>) {
        let pattern = filterField.stringValue
        if pattern.isEmpty {
            files = allFiles
            filterField.backgroundColor = .textBackgroundColor
            filterField.toolTip = nil
        } else if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            files = allFiles.filter { file in
                let range = NSRange(file.path.startIndex..<file.path.endIndex, in: file.path)
                return expression.firstMatch(in: file.path, range: range) != nil
            }
            filterField.backgroundColor = .textBackgroundColor
            filterField.toolTip = nil
        } else {
            files = allFiles
            filterField.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16)
            filterField.toolTip = "The file filter is not a valid regular expression."
        }

        rootNodes = makeRootNodes()
        outlineView.reloadData()
        if isTreeMode {
            rootNodes.forEach { outlineView.expandItem($0, expandChildren: true) }
        }

        var selectedRows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? ChangedFileNode,
                  let file = node.file,
                  preferredIDs.contains(file.id) else { continue }
            selectedRows.insert(row)
        }
        if selectedRows.isEmpty, let row = firstFileRow() { selectedRows.insert(row) }
        outlineView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        if let first = selectedFiles().first {
            onSelection?(first)
        }
    }

    private func makeRootNodes() -> [ChangedFileNode] {
        let leaves: [ChangedFileNode]
        if !isTreeMode {
            leaves = files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }.map {
                ChangedFileNode.file($0, title: $0.path)
            }
            if showsGroupNodesInFlatList, grouping != .path, !leaves.isEmpty {
                return groupedNodes(wrapping: leaves)
            }
            return leaves
        }

        switch grouping {
        case .path:
            leaves = ChangedFilePathTreeBuilder.build(files: files, dense: usesDenseTree)
        case .fileExtension, .status:
            leaves = groupedNodes(wrapping: files.map { ChangedFileNode.file($0, title: $0.path) })
        }
        guard !leaves.isEmpty else { return [] }
        let title = "(\(files.count)) \(comparisonTitle)"
        return [ChangedFileNode(id: "diff-root", title: title, imageName: "Diff", children: leaves)]
    }

    private func groupedNodes(wrapping leaves: [ChangedFileNode]) -> [ChangedFileNode] {
        let groups = Dictionary(grouping: leaves) { node -> String in
            guard let file = node.file else { return "" }
            switch grouping {
            case .path: return "Files"
            case .fileExtension:
                let value = (file.path as NSString).pathExtension
                return value.isEmpty ? "(no extension)" : ".\(value.lowercased())"
            case .status: return file.changeType.description
            }
        }
        return groups.keys.sorted().map { key in
            let children = (groups[key] ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let imageName = grouping == .status ? children.first?.imageName ?? "FileStatusModified" : "File"
            return ChangedFileNode(id: "group:\(grouping.rawValue):\(key)", title: "(\(children.count)) \(key)", imageName: imageName, children: children)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ChangedFileNode)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ChangedFileNode)?.children[index] ?? rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ChangedFileNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GitExtensionsSelectionRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ChangedFileNode else { return nil }
        guard let identifier = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ChangedFileCellView) ?? ChangedFileCellView()
        cell.identifier = identifier
        cell.apply(node: node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let first = selectedFiles().first { onSelection?(first) }
    }

    @objc private func placeholder(_ sender: NSButton) {
        BrowserCommandCenter.perform(sender.toolTip ?? "File list option")
    }

    @objc private func toggleTreeMode() {
        isTreeMode.toggle()
        treeModeButton.state = isTreeMode ? .on : .off
        reloadFilteredFiles(preferredIDs: selectedFileIDs())
    }

    @objc private func chooseGrouping(_ sender: NSButton) {
        guard let next = Grouping(rawValue: sender.tag) else { return }
        grouping = next
        updateGroupingButtonStates()
        reloadFilteredFiles(preferredIDs: selectedFileIDs())
    }

    @objc private func chooseViewMode(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0, 1: grouping = .path
        case 2, 3: grouping = .fileExtension
        case 4, 5: grouping = .status
        case 10:
            usesDenseTree.toggle()
            sender.state = usesDenseTree ? .on : .off
        case 11:
            showsGroupNodesInFlatList.toggle()
            sender.state = showsGroupNodesInFlatList ? .on : .off
        default: return
        }
        if sender.tag < 10 { isTreeMode = sender.tag.isMultiple(of: 2) }
        treeModeButton.state = isTreeMode ? .on : .off
        updateGroupingButtonStates()
        reloadFilteredFiles(preferredIDs: selectedFileIDs())
    }

    @objc private func toggleGroupExpansion() {
        let expandable = (0..<outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }.filter { !$0.children.isEmpty }
        if expandable.contains(where: { outlineView.isItemExpanded($0) }) {
            rootNodes.forEach { outlineView.collapseItem($0, collapseChildren: true) }
        } else {
            rootNodes.forEach { outlineView.expandItem($0, expandChildren: true) }
        }
    }

    @objc private func openFile() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ChangedFileNode else { return }
        if let file = node.file {
            BrowserCommandCenter.perform("Open \(file.path)")
        } else if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outlineView.clickedRow
        if row >= 0, !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let selectedNodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }
        let selectedFiles = Array(Set(selectedNodes.flatMap(\.descendantFiles)))
        let context = ChangedFileContextMenuContext(
            selectedFiles: selectedFiles,
            scope: selectionScope,
            supportPatches: true,
            allFilesExist: selectedFiles.allSatisfy { $0.changeType != .deleted }
        )
        populatePlaceholderMenu(menu, with: ChangedFileContextMenuBuilder.build(context))
        retargetMenuItems(
            in: menu,
            where: { ["file.stage", "file.unstage", "file.stageAll", "file.unstageAll"].contains($0) },
            target: self,
            action: #selector(performMutationMenuCommand(_:))
        )

        if selectedNodes.contains(where: { !$0.children.isEmpty }) {
            let selectAll = NSMenuItem(title: "Select all", action: #selector(selectAllDescendantFiles), keyEquivalent: "")
            selectAll.target = self
            let collapse = NSMenuItem(title: "Collapse all", action: #selector(collapseSelectedNodes), keyEquivalent: "")
            collapse.target = self
            let expand = NSMenuItem(title: "Expand all", action: #selector(expandSelectedNodes), keyEquivalent: "")
            expand.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(expand, at: 0)
            menu.insertItem(collapse, at: 0)
            menu.insertItem(selectAll, at: 0)
        }
    }

    @objc private func performMutationMenuCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onMutation?(identifier, selectedFiles(), selectionScope)
    }

    @objc private func selectAllDescendantFiles() {
        let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }
        nodes.forEach { outlineView.expandItem($0, expandChildren: true) }
        let IDs = Set(nodes.flatMap(\.descendantFiles).map(\.id))
        var rows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let file = (outlineView.item(atRow: row) as? ChangedFileNode)?.file, IDs.contains(file.id) { rows.insert(row) }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    @objc private func collapseSelectedNodes() {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }.forEach { outlineView.collapseItem($0, collapseChildren: true) }
    }

    @objc private func expandSelectedNodes() {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }.forEach { outlineView.expandItem($0, expandChildren: true) }
    }

    private func selectedFiles() -> [ChangedFile] {
        outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? ChangedFileNode)?.file }
    }

    private func selectedFileIDs() -> Set<String> { Set(selectedFiles().map(\.id)) }

    private func firstFileRow() -> Int? {
        (0..<outlineView.numberOfRows).first { (outlineView.item(atRow: $0) as? ChangedFileNode)?.file != nil }
    }

    private func makeGroupingButton(_ grouping: Grouping, image: String, tooltip: String) -> NSButton {
        let button = AppKitFactory.resourceButton(image, tooltip: tooltip, target: self, action: #selector(chooseGrouping(_:)))
        button.setButtonType(.pushOnPushOff)
        button.tag = grouping.rawValue
        button.state = self.grouping == grouping ? .on : .off
        groupingButtons[grouping] = button
        return button
    }

    private func updateGroupingButtonStates() {
        groupingButtons.forEach { $0.value.state = $0.key == grouping ? .on : .off }
    }

    private func makeViewModeMenu() -> NSPopUpButton {
        let button = imagePullDown("FileTree", tooltip: "File list grouping options", width: 10)
        [
            ("Group by file path - tree", 0), ("Group by file path - flat", 1),
            ("Group by file extension - tree", 2), ("Group by file extension - flat", 3),
            ("Group by file status - tree", 4), ("Group by file status - flat", 5)
        ].forEach { title, tag in
            let item = NSMenuItem(title: title, action: #selector(chooseViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            button.menu?.addItem(item)
        }
        button.menu?.addItem(.separator())
        let dense = NSMenuItem(title: "Dense tree (merge single item with its folder node)", action: #selector(chooseViewMode(_:)), keyEquivalent: "")
        dense.target = self
        dense.tag = 10
        dense.state = .on
        button.menu?.addItem(dense)
        let groups = NSMenuItem(title: "Show group nodes in flat list (if multiple)", action: #selector(chooseViewMode(_:)), keyEquivalent: "")
        groups.target = self
        groups.tag = 11
        button.menu?.addItem(groups)
        return button
    }

    private func makeFindMenu() -> NSPopUpButton {
        let button = imagePullDown("ViewFile", tooltip: "Toggle 'Find in commit files using git-grep'", width: 32)
        ["Match case", "Match whole word", "Options", "Using dialog", "Using input box", "Using both"].forEach {
            button.menu?.addItem(placeholderMenuItem($0))
        }
        return button
    }

    private func makeSettingsMenu() -> NSPopUpButton {
        let button = imagePullDown("Settings", tooltip: "Settings", width: 29)
        ["Show skip-worktree files", "Show untracked files", "Edit ignored files", "Edit locally ignored files", "Show file differences for all parents", "Toolbar"].forEach {
            button.menu?.addItem(placeholderMenuItem($0))
        }
        return button
    }

    private func imagePullDown(_ imageName: String, tooltip: String, width: CGFloat) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.addItem(withTitle: "")
        button.item(at: 0)?.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        return button
    }
}

private final class ChangedFileCellView: NSTableCellView {
    private let statusImage = NSImageView()
    private let changeCount = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 11)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        changeCount.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        changeCount.textColor = .secondaryLabelColor
        changeCount.alignment = .right
        changeCount.translatesAutoresizingMaskIntoConstraints = false
        textField = text
        imageView = statusImage
        addSubview(statusImage)
        addSubview(text)
        addSubview(changeCount)
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 16),
            statusImage.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 3),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            changeCount.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 4),
            changeCount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            changeCount.centerYAnchor.constraint(equalTo: centerYAnchor),
            changeCount.widthAnchor.constraint(equalToConstant: 64)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(node: ChangedFileNode) {
        textField?.stringValue = node.title
        textField?.font = node.file == nil ? .systemFont(ofSize: 11) : .systemFont(ofSize: 11)
        if let file = node.file {
            changeCount.stringValue = "+\(file.additions) −\(file.deletions)"
            statusImage.image = AppKitFactory.resourceImage(node.imageName, accessibilityDescription: file.changeType.description)
        } else {
            changeCount.stringValue = ""
            statusImage.image = AppKitFactory.resourceImage(node.imageName, accessibilityDescription: node.title)
        }
    }
}

private final class ChangedFileNode: NSObject {
    let id: String
    let title: String
    let imageName: String
    let file: ChangedFile?
    let children: [ChangedFileNode]

    init(id: String, title: String, imageName: String, file: ChangedFile? = nil, children: [ChangedFileNode] = []) {
        self.id = id
        self.title = title
        self.imageName = imageName
        self.file = file
        self.children = children
    }

    static func file(_ file: ChangedFile, title: String) -> ChangedFileNode {
        let imageName: String
        switch file.changeType {
        case .added: imageName = "FileStatusAdded"
        case .modified: imageName = "FileStatusModified"
        case .deleted: imageName = "FileStatusModifiedOnlyA"
        case .renamed: imageName = "FileStatusRenamed"
        case .copied: imageName = "FileStatusCopied"
        }
        return ChangedFileNode(id: "file:\(file.id)", title: title, imageName: imageName, file: file)
    }

    var descendantFiles: [ChangedFile] {
        if let file { return [file] }
        return children.flatMap(\.descendantFiles)
    }
}

private enum ChangedFilePathTreeBuilder {
    private final class Branch {
        let name: String
        let path: String
        var file: ChangedFile?
        var children: [String: Branch] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    static func build(files: [ChangedFile], dense: Bool) -> [ChangedFileNode] {
        let root = Branch(name: "", path: "")
        for file in files {
            var current = root
            var path = ""
            for component in file.path.split(separator: "/").map(String.init) {
                path = path.isEmpty ? component : "\(path)/\(component)"
                if current.children[component] == nil {
                    current.children[component] = Branch(name: component, path: path)
                }
                current = current.children[component]!
            }
            current.file = file
        }
        return sortedChildren(of: root).map { makeNode($0, dense: dense) }
    }

    private static func makeNode(_ branch: Branch, dense: Bool) -> ChangedFileNode {
        var current = branch
        var title = branch.name
        while dense, current.file == nil, current.children.count == 1, let child = current.children.values.first {
            title += "/\(child.name)"
            current = child
        }
        if let file = current.file {
            return ChangedFileNode.file(file, title: title)
        }
        let children = sortedChildren(of: current).map { makeNode($0, dense: dense) }
        return ChangedFileNode(id: "folder:\(current.path)", title: title, imageName: "FolderClosed", children: children)
    }

    private static func sortedChildren(of branch: Branch) -> [Branch] {
        branch.children.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

final class DiffContentViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onHunkMutation: ((RepositoryHunkSelection) -> Void)?
    var selectionScope: ChangedFileSelectionScope = .revision
    private let tableView = NSTableView()
    private let hoverToolbar = AppKitFactory.toolbarBackground()
    private var presentations: [DiffLinePresentation] = []
    private var numberColumnWidth: CGFloat = 23
    private var caretRow = -1
    private var showsNonPrintingCharacters = false
    private var showsSyntaxHighlighting = true
    private var currentFile: ChangedFile?
    private var currentDiff: FileDiff?

    override func loadView() {
        let root = DiffTrackingView()
        root.onPointerPresenceChanged = { [weak self] isPresent in
            self?.hoverToolbar.isHidden = !isPresent
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DiffLine"))
        column.width = 900
        column.minWidth = 500
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = BrowserMetrics.diffRowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .textBackgroundColor
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .none

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        configureHoverToolbar(in: root)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    func apply(file: ChangedFile, diff: FileDiff?) {
        currentFile = file
        currentDiff = diff
        hoverToolbar.toolTip = "\(file.path) — \(file.changeType.description), +\(file.additions) −\(file.deletions)"
        let lines = diff?.lines ?? []
        presentations = DiffLinePresentation.build(from: lines)
        numberColumnWidth = Self.numberColumnWidth(for: lines)
        caretRow = -1
        tableView.reloadData()
        if !presentations.isEmpty { tableView.scrollRowToVisible(0) }
    }

    private static func numberColumnWidth(for lines: [DiffLine]) -> CGFloat {
        let maximum = lines.flatMap { [$0.oldLineNumber, $0.newLineNumber] }.compactMap { $0 }.max() ?? 0
        let digits = max(1, String(maximum).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
        let completeMarginWidth = 4 + (2 * CGFloat(digits + 1) * digitWidth)
        return ceil(completeMarginWidth / 2)
    }

    private func configureHoverToolbar(in root: NSView) {
        hoverToolbar.translatesAutoresizingMaskIntoConstraints = false
        hoverToolbar.isHidden = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        @discardableResult
        func addButton(_ image: String, _ tooltip: String, adaptsToTheme: Bool = false) -> NSButton {
            let button = AppKitFactory.resourceButton(
                image,
                tooltip: tooltip,
                isTemplate: adaptsToTheme,
                target: self,
                action: #selector(performToolbarAction(_:))
            )
            stack.addArrangedSubview(button)
            return button
        }

        addButton("ArrowDown", "Next change")
        addButton("ArrowUp", "Previous change")
        stack.addArrangedSubview(AppKitFactory.separator())
        addButton("NumberOfLinesIncrease", "Increase the number of lines of context")
        addButton("NumberOfLinesDecrease", "Decrease the number of lines of context")
        stack.addArrangedSubview(AppKitFactory.separator())
        addButton("ShowEntireFile", "Show entire file")
        let nonPrintingButton = addButton("ShowWhitespace", "Show nonprinting characters", adaptsToTheme: true)
        nonPrintingButton.setButtonType(.pushOnPushOff)
        nonPrintingButton.state = showsNonPrintingCharacters ? .on : .off
        let syntaxButton = addButton("SyntaxHighlighting", "Show syntax highlighting", adaptsToTheme: true)
        syntaxButton.setButtonType(.pushOnPushOff)
        syntaxButton.state = showsSyntaxHighlighting ? .on : .off
        addButton("WhitespaceIgnoreEol", "Ignore whitespace changes at end of line", adaptsToTheme: true)
        addButton("WhitespaceIgnore", "Ignore changes in amount of whitespace", adaptsToTheme: true)
        addButton("WhitespaceIgnoreAll", "Ignore all whitespace changes", adaptsToTheme: true)

        let encoding = NSPopUpButton()
        encoding.controlSize = .small
        encoding.font = .systemFont(ofSize: 11)
        encoding.addItem(withTitle: "Unicode (UTF-8)")
        encoding.toolTip = "Encoding"
        encoding.target = self
        encoding.action = #selector(placeholderPopUp(_:))
        encoding.translatesAutoresizingMaskIntoConstraints = false
        encoding.widthAnchor.constraint(equalToConstant: 110).isActive = true
        stack.addArrangedSubview(encoding)
        addButton("Settings", "Settings")

        hoverToolbar.addSubview(stack)
        root.addSubview(hoverToolbar)
        let leading = hoverToolbar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor)
        leading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            hoverToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            hoverToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            hoverToolbar.heightAnchor.constraint(equalToConstant: 23),
            leading,
            stack.leadingAnchor.constraint(equalTo: hoverToolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: hoverToolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: hoverToolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: hoverToolbar.bottomAnchor)
        ])
    }

    @objc private func placeholderPopUp(_ sender: NSPopUpButton) {
        BrowserCommandCenter.perform(sender.toolTip ?? "Diff option")
    }

    @objc private func performToolbarAction(_ sender: NSButton) {
        switch sender.toolTip {
        case "Next change":
            navigateToChange(forward: true)
        case "Previous change":
            navigateToChange(forward: false)
        case "Show nonprinting characters":
            showsNonPrintingCharacters = sender.state == .on
            reloadRenderedLines()
        case "Show syntax highlighting":
            showsSyntaxHighlighting = sender.state == .on
            reloadRenderedLines()
        default:
            BrowserCommandCenter.perform(sender.toolTip ?? "Diff option")
        }
    }

    private func navigateToChange(forward: Bool) {
        let starts = presentations.indices.filter { index in
            let isChange = presentations[index].line.kind == .addition || presentations[index].line.kind == .deletion
            guard isChange else { return false }
            guard index > 0 else { return true }
            let previousKind = presentations[index - 1].line.kind
            return previousKind != .addition && previousKind != .deletion
        }

        let destination: Int?
        if forward {
            destination = starts.first { $0 > caretRow }
        } else {
            let origin = caretRow < 0 ? presentations.count : caretRow
            destination = starts.last { $0 < origin }
        }

        guard let destination else {
            NSSound.beep()
            return
        }
        caretRow = destination
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(max(0, destination - 4))
        tableView.scrollRowToVisible(destination)
    }

    private func reloadRenderedLines() {
        let selectedRows = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presentations.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { BrowserMetrics.diffRowHeight }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DiffLineCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? DiffLineCellView) ?? DiffLineCellView()
        cell.identifier = identifier
        cell.apply(
            presentation: presentations[row],
            numberColumnWidth: numberColumnWidth,
            showsNonPrintingCharacters: showsNonPrintingCharacters,
            showsSyntaxHighlighting: showsSyntaxHighlighting
        )
        return cell
    }

    @objc private func placeholder(_ sender: NSButton) {
        BrowserCommandCenter.perform(sender.toolTip ?? "Diff option")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        ["Copy", "Select all", "Open file", "Open file with…"].forEach {
            menu.addItem(placeholderMenuItem($0))
        }

        let mutationTitle: String?
        switch selectionScope {
        case .workingTree: mutationTitle = "Stage selected hunk"
        case .index: mutationTitle = "Unstage selected hunk"
        case .revision: mutationTitle = nil
        }
        if let mutationTitle {
            let item = NSMenuItem(title: mutationTitle, action: #selector(applySelectedHunk(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = currentHunkLineID() != nil
            menu.addItem(item)
        }

        ["Reset selected lines", "Show blame", "Show file history", "Diff options"].forEach {
            menu.addItem(placeholderMenuItem($0))
        }
    }

    @objc private func applySelectedHunk(_ sender: NSMenuItem) {
        guard let currentFile, let currentDiff, let lineID = currentHunkLineID() else { return }
        let direction: RepositoryHunkDirection = selectionScope == .index ? .unstage : .stage
        onHunkMutation?(RepositoryHunkSelection(file: currentFile, diff: currentDiff, lineID: lineID, direction: direction))
    }

    private func currentHunkLineID() -> String? {
        let clicked = tableView.clickedRow
        let row = clicked >= 0 ? clicked : tableView.selectedRow
        guard row >= 0, row < presentations.count else { return nil }
        let line = presentations[row].line
        guard line.kind == .hunk || line.kind == .context || line.kind == .addition || line.kind == .deletion else { return nil }
        return line.id
    }
}

struct DiffLinePresentation {
    struct InlineChange {
        let location: Int
        let length: Int
    }

    let line: DiffLine
    let inlineChange: InlineChange?

    static func build(from lines: [DiffLine]) -> [DiffLinePresentation] {
        var changes: [Int: InlineChange] = [:]
        var index = 0

        while index < lines.count {
            guard lines[index].kind == .deletion else {
                index += 1
                continue
            }

            let deletionStart = index
            while index < lines.count, lines[index].kind == .deletion { index += 1 }
            let deletionEnd = index
            let additionStart = index
            while index < lines.count, lines[index].kind == .addition { index += 1 }
            let additionEnd = index

            let pairCount = min(deletionEnd - deletionStart, additionEnd - additionStart)
            for offset in 0..<pairCount {
                let deletionIndex = deletionStart + offset
                let additionIndex = additionStart + offset
                let pair = inlineChanges(
                    removed: lines[deletionIndex].text,
                    added: lines[additionIndex].text
                )
                changes[deletionIndex] = pair.removed
                changes[additionIndex] = pair.added
            }
        }

        return lines.enumerated().map { index, line in
            DiffLinePresentation(line: line, inlineChange: changes[index])
        }
    }

    private static func inlineChanges(
        removed: String,
        added: String
    ) -> (removed: InlineChange, added: InlineChange) {
        let old = Array(removed.utf16)
        let new = Array(added.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] {
            suffix += 1
        }

        return (
            InlineChange(location: prefix, length: max(0, old.count - prefix - suffix)),
            InlineChange(location: prefix, length: max(0, new.count - prefix - suffix))
        )
    }
}

final class DiffLineCellView: NSTableCellView {
    private let oldNumber = NSTextField(labelWithString: "")
    private let newNumber = NSTextField(labelWithString: "")
    private let prefix = NSTextField(labelWithString: "")
    private let content = NSTextField(labelWithString: "")
    private var oldNumberWidthConstraint: NSLayoutConstraint!
    private var newNumberWidthConstraint: NSLayoutConstraint!
    private var presentation: DiffLinePresentation?
    private var numberColumnWidth: CGFloat = 23
    private let prefixWidth: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [oldNumber, newNumber, prefix, content])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        [oldNumber, newNumber].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            $0.textColor = .tertiaryLabelColor
            $0.alignment = .right
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        oldNumberWidthConstraint = oldNumber.widthAnchor.constraint(equalToConstant: numberColumnWidth)
        newNumberWidthConstraint = newNumber.widthAnchor.constraint(equalToConstant: numberColumnWidth)
        oldNumberWidthConstraint.isActive = true
        newNumberWidthConstraint.isActive = true
        prefix.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        prefix.alignment = .center
        prefix.translatesAutoresizingMaskIntoConstraints = false
        prefix.widthAnchor.constraint(equalToConstant: prefixWidth).isActive = true
        content.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.lineBreakMode = .byClipping
        content.maximumNumberOfLines = 1
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let presentation else { return }

        let gutterWidth = numberColumnWidth * 2
        let baseColor: NSColor?
        switch presentation.line.kind {
        case .addition:
            baseColor = NSColor.systemGreen.withAlphaComponent(0.13)
        case .deletion:
            baseColor = NSColor.systemRed.withAlphaComponent(0.13)
        case .hunk:
            baseColor = NSColor.systemBlue.withAlphaComponent(0.10)
        case .header, .context:
            baseColor = nil
        }

        if let baseColor {
            baseColor.setFill()
            NSRect(x: 0, y: 0, width: min(gutterWidth, bounds.width), height: bounds.height).fill()

            if presentation.line.kind == .addition || presentation.line.kind == .deletion {
                let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                let textWidth = ceil((presentation.line.text as NSString).size(withAttributes: [.font: font]).width)
                let width = min(prefixWidth + textWidth + 1, max(0, bounds.width - gutterWidth))
                NSRect(x: gutterWidth, y: 0, width: width, height: bounds.height).fill()
            }
        }

        if let change = presentation.inlineChange,
           presentation.line.kind == .addition || presentation.line.kind == .deletion {
            let string = presentation.line.text as NSString
            let safeLocation = min(max(0, change.location), string.length)
            let safeLength = min(max(0, change.length), string.length - safeLocation)
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let leadingText = string.substring(with: NSRange(location: 0, length: safeLocation))
            let changedText = string.substring(with: NSRange(location: safeLocation, length: safeLength))
            let leadingWidth = ceil((leadingText as NSString).size(withAttributes: [.font: font]).width)
            let changedWidth = max(2, ceil((changedText as NSString).size(withAttributes: [.font: font]).width))
            let emphasis = presentation.line.kind == .addition
                ? NSColor.systemGreen.withAlphaComponent(0.24)
                : NSColor.systemRed.withAlphaComponent(0.24)
            emphasis.setFill()
            NSRect(
                x: gutterWidth + prefixWidth + leadingWidth,
                y: 0,
                width: min(changedWidth, max(0, bounds.width - gutterWidth - prefixWidth - leadingWidth)),
                height: bounds.height
            ).fill()
        }

        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSRect(x: gutterWidth - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    func apply(
        presentation: DiffLinePresentation,
        numberColumnWidth: CGFloat,
        showsNonPrintingCharacters: Bool,
        showsSyntaxHighlighting: Bool
    ) {
        self.presentation = presentation
        self.numberColumnWidth = numberColumnWidth
        oldNumberWidthConstraint.constant = numberColumnWidth
        newNumberWidthConstraint.constant = numberColumnWidth
        let line = presentation.line
        oldNumber.stringValue = line.oldLineNumber.map(String.init) ?? ""
        newNumber.stringValue = line.newLineNumber.map(String.init) ?? ""
        let displayText = showsNonPrintingCharacters
            ? line.text.replacingOccurrences(of: "\t", with: "→").replacingOccurrences(of: " ", with: "·")
            : line.text
        content.attributedStringValue = DiffSyntaxHighlighter.attributedText(
            for: line,
            displayText: displayText,
            enabled: showsSyntaxHighlighting
        )
        switch line.kind {
        case .addition:
            prefix.stringValue = "+"
            prefix.textColor = .systemGreen
        case .deletion:
            prefix.stringValue = "−"
            prefix.textColor = .systemRed
        case .hunk:
            prefix.stringValue = ""
        case .header:
            prefix.stringValue = ""
        case .context:
            prefix.stringValue = " "
        }
        needsDisplay = true
    }
}

private enum DiffSyntaxHighlighter {
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let keywordExpression = try! NSRegularExpression(
        pattern: #"\b(?:using|namespace|internal|sealed|class|public|private|protected|readonly|static|void|return|new|if|else|for|while|async|await|var|let)\b"#
    )
    private static let stringExpression = try! NSRegularExpression(pattern: #"\"(?:\\.|[^\"\\])*\""#)
    private static let commentExpression = try! NSRegularExpression(pattern: #"//.*$"#)

    static func attributedText(for line: DiffLine, displayText: String, enabled: Bool) -> NSAttributedString {
        let baseColor: NSColor
        switch line.kind {
        case .header:
            baseColor = .secondaryLabelColor
        case .hunk:
            baseColor = .systemBlue
        case .context, .addition, .deletion:
            baseColor = .labelColor
        }

        let result = NSMutableAttributedString(
            string: displayText,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        guard enabled,
              line.kind == .context || line.kind == .addition || line.kind == .deletion else {
            return result
        }

        let fullRange = NSRange(location: 0, length: (displayText as NSString).length)
        keywordExpression.enumerateMatches(in: displayText, range: fullRange) { match, _, _ in
            if let range = match?.range { result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range) }
        }
        stringExpression.enumerateMatches(in: displayText, range: fullRange) { match, _, _ in
            if let range = match?.range { result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range) }
        }
        commentExpression.enumerateMatches(in: displayText, range: fullRange) { match, _, _ in
            if let range = match?.range { result.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: range) }
        }
        return result
    }
}

private final class DiffTrackingView: NSView {
    var onPointerPresenceChanged: ((Bool) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerPresenceChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerPresenceChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerPresenceChanged?(false)
    }
}

final class FileTreeViewController: RetainingSplitViewController {
    private static let collapsedPaneThickness: CGFloat = 1

    private let outlineController = RevisionFileTreeOutlineViewController()
    private let contentController = RevisionFileContentViewController()
    private var didSetInitialDivider = false
    private var currentCommit: Commit?
    private var contentLoadTask: Task<Void, Never>?
    var contentProvider: (@Sendable (Commit, RepositoryFileEntry) async throws -> RepositoryFileEntry)?

    init() {
        super.init(resizeBehavior: .fixedLeadingPane)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter

        let treeItem = NSSplitViewItem(viewController: outlineController)
        treeItem.minimumThickness = Self.collapsedPaneThickness
        treeItem.preferredThicknessFraction = 300.0 / 850.0
        treeItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        addSplitViewItem(treeItem)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = Self.collapsedPaneThickness
        contentItem.holdingPriority = .defaultLow
        addSplitViewItem(contentItem)

        outlineController.onSelection = { [weak self] file, path in
            guard let self else { return }
            contentLoadTask?.cancel()
            contentController.apply(file: file, selectedPath: path)
            guard let file, let commit = currentCommit, let contentProvider else { return }
            contentLoadTask = Task { @MainActor [weak self] in
                do {
                    let loaded = try await contentProvider(commit, file)
                    guard !Task.isCancelled,
                          self?.currentCommit?.id == commit.id,
                          self?.outlineController.selectedFilePath == file.path
                    else { return }
                    self?.contentController.apply(file: loaded, selectedPath: loaded.path)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.contentController.apply(error: error, selectedPath: file.path)
                }
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialDivider, splitView.bounds.width >= 650 else { return }
        didSetInitialDivider = true
        setRetainedPosition(300)
    }

    func apply(commit: Commit, files: [RepositoryFileEntry]) {
        _ = view
        currentCommit = commit
        contentLoadTask?.cancel()
        contentController.applyRevision(commit)
        outlineController.apply(files: files)
    }
}

private final class RevisionFileTreeOutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelection: ((RepositoryFileEntry?, String?) -> Void)?

    private let outlineView = NSOutlineView()
    private var roots: [RevisionFileTreeItem] = []
    private(set) var selectedFilePath: String?
    private var isApplyingSnapshot = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RevisionFileTree"))
        column.title = "File"
        column.minWidth = 100
        column.width = 300
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = BrowserMetrics.fileRowHeight
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 19
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = true
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(openSelectedItem)
        outlineView.target = self

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        view = scroll
    }

    func apply(files: [RepositoryFileEntry]) {
        _ = view
        let pathToRestore = FileTreeSelectionResolver.selectedPath(previousPath: selectedFilePath, files: files)
        roots = RepositoryFileTreeBuilder.build(files: files).map { RevisionFileTreeItem(node: $0) }

        isApplyingSnapshot = true
        outlineView.reloadData()
        if let pathToRestore, let item = fileItem(path: pathToRestore) {
            expandAncestors(of: item)
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                selectedFilePath = pathToRestore
                onSelection?(item.node.file, item.node.path)
            }
        } else {
            selectedFilePath = nil
            outlineView.deselectAll(nil)
            onSelection?(nil, nil)
        }
        isApplyingSnapshot = false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? RevisionFileTreeItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? RevisionFileTreeItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? RevisionFileTreeItem)?.node.kind == .folder
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GitExtensionsSelectionRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? RevisionFileTreeItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RevisionFileTreeCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier

        let text: NSTextField
        let icon: NSImageView
        if let existingText = cell.textField, let existingIcon = cell.imageView {
            text = existingText
            icon = existingIcon
        } else {
            text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 11)
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = text
            cell.imageView = icon
            cell.addSubview(icon)
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        text.stringValue = item.node.name
        icon.image = AppKitFactory.resourceImage(
            item.node.kind == .folder ? "FolderClosed" : "FileTree",
            accessibilityDescription: item.node.kind == .folder ? "Folder" : "File"
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSnapshot else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? RevisionFileTreeItem else {
            onSelection?(nil, nil)
            return
        }
        if let file = item.node.file {
            selectedFilePath = file.path
            onSelection?(file, item.node.path)
        } else {
            onSelection?(nil, item.node.path)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outlineView.clickedRow
        if row >= 0, !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        menu.removeAllItems()
        [
            "Open file",
            "Open file with…",
            "Save as…",
            "Open containing folder",
            "Copy full path",
            "Show file history",
            "Blame",
            "Find in commit files",
            "Filter this file in the revision grid"
        ].forEach { menu.addItem(placeholderMenuItem($0)) }
    }

    @objc private func openSelectedItem() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? RevisionFileTreeItem else { return }
        if item.node.kind == .folder {
            outlineView.isItemExpanded(item) ? outlineView.collapseItem(item) : outlineView.expandItem(item)
        } else {
            BrowserCommandCenter.perform("Open \(item.node.path)")
        }
    }

    private func fileItem(path: String) -> RevisionFileTreeItem? {
        func search(_ items: [RevisionFileTreeItem]) -> RevisionFileTreeItem? {
            for item in items {
                if item.node.path == path, item.node.file != nil { return item }
                if let match = search(item.children) { return match }
            }
            return nil
        }
        return search(roots)
    }

    private func expandAncestors(of item: RevisionFileTreeItem) {
        var ancestors: [RevisionFileTreeItem] = []
        var current = item.parent
        while let value = current {
            ancestors.append(value)
            current = value.parent
        }
        ancestors.reversed().forEach { outlineView.expandItem($0) }
    }
}

private final class RevisionFileTreeItem: NSObject {
    let node: RepositoryFileTreeNode
    weak var parent: RevisionFileTreeItem?
    private(set) var children: [RevisionFileTreeItem] = []

    init(node: RepositoryFileTreeNode, parent: RevisionFileTreeItem? = nil) {
        self.node = node
        self.parent = parent
        super.init()
        children = node.children.map { RevisionFileTreeItem(node: $0, parent: self) }
    }
}

private final class RevisionFileContentViewController: NSViewController, NSMenuDelegate {
    private let pathLabel = NSTextField(labelWithString: "Select a file")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private var revisionName = ""

    override func loadView() {
        let root = NSView()
        let toolbar = AppKitFactory.toolbarBackground()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [pathLabel, metadataLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadataLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        toolbar.addSubview(header)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 7)
        let menu = NSMenu()
        menu.delegate = self
        textView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 25),
            header.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 5),
            header.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -5),
            header.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    func applyRevision(_ commit: Commit) {
        revisionName = commit.shortID
    }

    func apply(file: RepositoryFileEntry?, selectedPath: String?) {
        _ = view
        guard let file else {
            pathLabel.stringValue = selectedPath ?? "Select a file"
            metadataLabel.stringValue = selectedPath == nil ? "" : "Folder at \(revisionName)"
            textView.string = selectedPath == nil ? "Select a file to view its contents." : "Folder \(selectedPath ?? "")"
            return
        }
        pathLabel.stringValue = file.path
        metadataLabel.stringValue = "\(file.byteCount) bytes   \(revisionName)"
        textView.string = file.content.isEmpty && (file.gitObjectID != nil || file.gitObjectType == "working-tree")
            ? "Loading file…"
            : file.content
        textView.scrollToBeginningOfDocument(nil)
    }

    func apply(error: Error, selectedPath: String) {
        _ = view
        pathLabel.stringValue = selectedPath
        metadataLabel.stringValue = "Unable to load"
        textView.string = error.localizedDescription
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        ["Copy", "Select all", "Find…", "Open file", "Open file with…", "Show blame", "Show file history"].forEach {
            menu.addItem(placeholderMenuItem($0))
        }
    }
}

final class GPGInfoViewController: NSViewController {
    private let stack = NSStackView()
    private let commitRow = SignatureMessageView()
    private let tagRow = SignatureMessageView()

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(commitRow)
        stack.addArrangedSubview(tagRow)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }

    func apply(commit: Commit, info: RevisionGPGInfo?) {
        _ = view
        let presentation = RevisionGPGPresentationResolver.resolve(info: info)
        commitRow.apply(
            message: presentation.commit.message,
            appearance: Self.appearance(for: presentation.commit.indicator, isTag: false)
        )

        tagRow.isHidden = presentation.tag == nil
        guard let tag = presentation.tag else { return }
        tagRow.apply(
            message: tag.message,
            appearance: Self.appearance(for: tag.indicator, isTag: true)
        )
    }

    private static func appearance(for indicator: SignatureIndicator, isTag: Bool) -> SignatureMessageView.Appearance? {
        switch indicator {
        case .none: nil
        case .good: .init(imageName: isTag ? "TagOk" : "CommitSignatureOk")
        case .warning: .init(imageName: isTag ? "TagWarning" : "CommitSignatureWarning")
        case .error: .init(imageName: isTag ? "TagError" : "CommitSignatureError")
        case .many: .init(imageName: "TagMany")
        }
    }
}

private final class SignatureMessageView: NSView {
    struct Appearance {
        let imageName: String
    }

    private let imageView = NSImageView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 11)
        textView.textContainerInset = NSSize(width: 3, height: 3)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(message: String, appearance: Appearance?) {
        textView.string = message
        imageView.image = appearance.flatMap {
            AppKitFactory.resourceImage(
                $0.imageName,
                accessibilityDescription: message,
                size: NSSize(width: 32, height: 32)
            )
        }
        imageView.contentTintColor = nil
        imageView.isHidden = appearance == nil
        textView.scrollToBeginningOfDocument(nil)
    }
}
