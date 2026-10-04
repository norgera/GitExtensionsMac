import GitExtensionsCore
import GitCommands
import AppKit


struct FileStatusListItem: Hashable {
    let group: FileStatusGroup
    let file: ChangedFile
    var first: RevisionID? { group.first }
    var second: RevisionID { group.second }

    static func == (lhs: FileStatusListItem, rhs: FileStatusListItem) -> Bool {
        lhs.group.id == rhs.group.id && lhs.file.id == rhs.file.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(group.id)
        hasher.combine(file.id)
    }
}


struct RememberedDiffFile: Equatable {
    let path: String
    let oldPath: String?
    let first: RevisionID?
    let second: RevisionID
    let isNew: Bool
    let isDeleted: Bool
    let isSubmodule: Bool

    init(item: FileStatusListItem) {
        path = item.file.path
        oldPath = item.file.oldPath
        first = item.first
        second = item.second
        isNew = item.file.changeType == .added || !item.file.isTracked
        isDeleted = item.file.changeType == .deleted
        isSubmodule = item.file.isSubmodule
    }


    init?(firstOf item: FileStatusListItem) {
        guard let first = item.first else { return nil }
        path = item.file.oldPath ?? item.file.path
        oldPath = item.file.oldPath == nil ? nil : item.file.path
        self.first = item.second
        second = first
        isNew = item.file.changeType == .deleted
        isDeleted = item.file.changeType == .added || !item.file.isTracked
        isSubmodule = item.file.isSubmodule
    }


    func canUseAsSecond(secondRevision: Bool) -> Bool { !isSubmodule && (secondRevision ? !isDeleted : !isNew) }
    func canUseAsFirst(secondRevision: Bool) -> Bool {
        canUseAsSecond(secondRevision: secondRevision) && (secondRevision ? second : first) != .workingDirectory
    }
    var canUseAsFirst: Bool { canUseAsFirst(secondRevision: false) || canUseAsFirst(secondRevision: true) }
    var canUseAsSecond: Bool { canUseAsSecond(secondRevision: false) || canUseAsSecond(secondRevision: true) }


    func side(secondRevision: Bool) -> (revision: RevisionID?, path: String) {
        (secondRevision ? second : first, !secondRevision ? (oldPath ?? path) : path)
    }
}


struct FileStatusListCommand {
    let identifier: String
    let items: [FileStatusListItem]
    let folder: String?

    let tool: String?

    let focused: FileStatusListItem?
    let remembered: RememberedDiffFile?

    var lineNumber: Int? = nil
}

enum FileStatusListMode {

    case plain

    case diff

    case fileTree
}

private final class FileStatusOutlineView: NSOutlineView {
    var onShortcut: ((String) -> Bool)?
    var onMouseSelection: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           let command = ApplicationHotkeys.shared.matching(event, category: "File status list"),
           onShortcut?(command) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if let command = ApplicationHotkeys.shared.matching(event, category: "File status list"), onShortcut?(command) == true { return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseSelection?()
    }
}


final class ChangedFilesViewController: NSViewController, NSOutlineViewDelegate, NSOutlineViewDataSource, NSMenuDelegate, NSComboBoxDelegate {

    var onSelection: ((ChangedFile) -> Void)?
    var isBareRepository = false


    let mode: FileStatusListMode
    var onScript: ((ScriptDefinition) -> Void)?
    var onSelectionChanged: (([FileStatusListItem], String?) -> Void)?
    var onCommand: ((FileStatusListCommand) -> Void)?
    var onRefreshArtificial: (() -> Void)?

    var onRecalculate: (() -> Void)?
    var onDoubleClick: ((FileStatusListItem) -> Void)?
    var repositoryURL: URL?
    var describe: (RevisionID?) -> String = { $0.map { $0.objectID?.shortString ?? String(describing: $0) } ?? "" }
    var supportLinePatching: () -> Bool = { false }
    var selectedText: () -> String = { "" }

    var currentLineNumber: () -> Int? = { nil }
    var diffTools: [String] = []

    var parentsOf: (RevisionID) -> [RevisionID] = { _ in [] }
    var canCherryPick = false
    var canShowInFileTree = false
    var canFilterInGrid = false
    var canBlame = false
    var canFileHistory = false
    var isBlameShown = false
    var canOpenSubmodule = false
    var canUseFindInCommitFilesGitGrep: Bool { mode != .plain }


    private(set) var showsUntrackedFiles = true
    private(set) var showsSkipWorktreeFiles = false

    private(set) var grepText = ""

    private static var remembered: RememberedDiffFile?
    private var submoduleStatuses: [String: FileStatusSubmodule] = [:]
    static func repositoryChanged() { remembered = nil }

    private let outlineView = FileStatusOutlineView()
    private let scrollView = NSScrollView()
    private let filterBox = NSComboBox()
    private let grepBox = NSComboBox()
    private let noFilesLabel = NSTextField(labelWithString: "No changes")
    private let toolbar = AppKitFactory.toolbarBackground()
    private let toolbarStack = NSStackView()
    private var toolbarHeight: NSLayoutConstraint?
    private var grepHeight: NSLayoutConstraint?
    private var toolbarItems: [(name: String, title: String, view: NSView)] = []
    private var refreshButton: NSButton?
    private var collapseButton: NSButton?
    private let treeModeButton = NSButton()
    private var groupingButtons: [FileStatusGrouping: NSButton] = [:]
    private var diffStatusButtons: [DiffBranchStatus: NSButton] = [:]
    private var diffStatusFilter: Set<DiffBranchStatus> = [.unequal, .onlyB, .onlyA, .same]
    private weak var viewModeMenu: NSMenu?
    private weak var grepMenu: NSMenu?
    private weak var settingsMenu: NSMenu?

    private var groups: [FileStatusGroup] = []
    private var revisions: [RevisionID] = []
    private var itemsByNodeFileID: [String: FileStatusListItem] = [:]
    private var rootNodes: [ChangedFileNode] = []
    private var isTreeMode = AppSettingsStore.shared.fileStatusListPreferences.isTreeMode
    private var grouping = AppSettingsStore.shared.fileStatusListPreferences.grouping
    private var usesDenseTree = AppSettingsStore.shared.fileStatusListPreferences.usesDenseTree
    private var showsGroupNodesInFlatList = AppSettingsStore.shared.fileStatusListPreferences.showsGroupNodesInFlatList
    private var filter: NSRegularExpression?
    private var filterTask: Task<Void, Never>?
    private var grepTask: Task<Void, Never>?
    private var grepWindow: FindInCommitFilesGitGrepWindowController?
    private var focusedFileID: String?
    private var suppressSelectionEvents = false

    var isLoading = false
    private var pendingFindFile = false


    private var plainFiles: [ChangedFile] = []
    private var plainSections: [ChangedFileSection]?
    private var plainTitle = "Diff with parent"
    private var selectionScope: ChangedFileSelectionScope = .revision

    init(mode: FileStatusListMode = .plain) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private var preferences: FileStatusListPreferences { AppSettingsStore.shared.fileStatusListPreferences }
    private func updatePreferences(_ change: (inout FileStatusListPreferences) -> Void) {
        var value = AppSettingsStore.shared.fileStatusListPreferences
        change(&value)
        AppSettingsStore.shared.saveFileStatusListPreferences(value)
    }



    override func loadView() {
        let root = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 0
        toolbarStack.alignment = .centerY
        toolbarStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        buildToolbar()
        toolbar.addSubview(toolbarStack)

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        fileColumn.title = "Files"
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
        outlineView.allowsEmptySelection = mode != .plain
        outlineView.allowsMultipleSelection = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.target = self
        outlineView.setAccessibilityIdentifier("FileStatusList")
        outlineView.onShortcut = { [weak self] command in self?.performShortcut(command) ?? false }
        outlineView.onMouseSelection = { [weak self] in
            guard let self, outlineView.clickedRow >= 0,
                  let file = (outlineView.item(atRow: outlineView.clickedRow) as? ChangedFileNode)?.file else { return }
            focusedFileID = file.id
        }
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        for box in [filterBox, grepBox] {
            box.font = AppSettingsStore.shared.applicationFont(size: 11, weight: .bold)
            box.controlSize = .small
            box.completes = false
            box.usesDataSource = false
            box.delegate = self
            box.numberOfVisibleItems = 10
            box.translatesAutoresizingMaskIntoConstraints = false
        }
        filterBox.placeholderString = "Filter files using a regular expression..."
        filterBox.addItems(withObjectValues: ["^(?!.*NotThisWord)", #"^(?!.*\bg?tests?/)"#])
        filterBox.setAccessibilityIdentifier("FileStatusFilter")
        grepBox.placeholderString = "Find in commit files using git-grep regular expression..."
        grepBox.setAccessibilityIdentifier("FileStatusGitGrep")

        noFilesLabel.font = NSFontManager.shared.convert(AppSettingsStore.shared.applicationFont(size: 11), toHaveTrait: .italicFontMask)
        noFilesLabel.textColor = .secondaryLabelColor
        noFilesLabel.translatesAutoresizingMaskIntoConstraints = false
        noFilesLabel.isHidden = true

        root.addSubview(toolbar)
        root.addSubview(grepBox)
        root.addSubview(filterBox)
        root.addSubview(scrollView)
        root.addSubview(noFilesLabel)
        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: mode == .fileTree ? 0 : 25)
        toolbarHeight.priority = .defaultHigh
        self.toolbarHeight = toolbarHeight
        let grepHeight = grepBox.heightAnchor.constraint(equalToConstant: 0)
        self.grepHeight = grepHeight
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarHeight,
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 3),
            toolbarStack.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -3),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            grepBox.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            grepBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grepBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grepHeight,
            filterBox.topAnchor.constraint(equalTo: grepBox.bottomAnchor),
            filterBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            filterBox.heightAnchor.constraint(equalToConstant: 23),
            scrollView.topAnchor.constraint(equalTo: filterBox.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            noFilesLabel.topAnchor.constraint(equalTo: filterBox.topAnchor, constant: 4),
            noFilesLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6)
        ])
        toolbar.isHidden = mode == .fileTree
        view = root
        setGrepBoxVisible(canUseFindInCommitFilesGitGrep && preferences.showFindInCommitFilesGitGrep, focus: false)
        updateToolbar()
    }



    private func buildToolbar() {
        var items: [(String, String, NSView)] = []
        let collapse = AppKitFactory.resourceButton("CollapseAll", tooltip: "Collapse all groups, otherwise expand the selected group", target: self, action: #selector(collapseGroups))
        collapseButton = collapse
        items.append(("btnCollapseGroups", collapse.toolTip!, collapse))
        items.append(("sepRefresh", "", AppKitFactory.separator()))
        let refresh = AppKitFactory.resourceButton("ReloadRevisions", tooltip: "Refresh artificial commit", target: self, action: #selector(refreshArtificial))
        refresh.isEnabled = false
        refreshButton = refresh
        items.append(("btnRefresh", refresh.toolTip!, refresh))
        items.append(("sepAsTree", "", AppKitFactory.separator()))

        let viewMode = NSStackView()
        viewMode.orientation = .horizontal
        viewMode.spacing = 0
        treeModeButton.imagePosition = .imageOnly
        treeModeButton.isBordered = false
        treeModeButton.toolTip = "Toggle flat list / tree"
        treeModeButton.target = self
        treeModeButton.action = #selector(toggleTreeMode)
        treeModeButton.translatesAutoresizingMaskIntoConstraints = false
        treeModeButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        treeModeButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        viewMode.addArrangedSubview(treeModeButton)
        viewMode.addArrangedSubview(makeViewModeMenu())
        items.append(("btnAsTree", "Toggle flat list / tree", viewMode))
        items.append(("sepGroupBy", "", AppKitFactory.separator()))
        items.append(("btnByPath", "Group by file path", makeGroupingButton(.path, tag: 0, image: "FolderClosed", tooltip: "Group by file path")))
        items.append(("btnByExtension", "Group by file type (extension)", makeGroupingButton(.fileExtension, tag: 1, image: "File", tooltip: "Group by file type (extension)")))
        items.append(("btnByStatus", "Group by diff status", makeGroupingButton(.status, tag: 2, image: "FileStatusModified", tooltip: "Group by diff status")))
        items.append(("sepFilter", "", AppKitFactory.separator()))
        for (status, title, tooltip) in [(DiffBranchStatus.unequal, "!", "Show files with different changes"),
                                         (.onlyB, "B", "Show files changed in B only"),
                                         (.onlyA, "A", "Show files changed in A only"),
                                         (.same, "=", "Show files changed equally")] {
            let button = NSButton(title: title, target: self, action: #selector(toggleDiffStatusFilter(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .boldSystemFont(ofSize: 11)
            button.state = .on
            button.toolTip = tooltip
            button.identifier = NSUserInterfaceItemIdentifier("filter.\(title)")
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            diffStatusButtons[status] = button
            items.append(("btn\(title)", tooltip, button))
        }
        items.append(("sepOptions", "", AppKitFactory.separator()))
        items.append(("btnFindInFilesGitGrep", "Toggle 'Find in commit files using git-grep'", makeGrepButton()))
        items.append(("sepSettings", "", AppKitFactory.separator()))
        items.append(("btnSettings", "Settings", makeSettingsMenu()))
        toolbarItems = items.map { (name: $0.0, title: $0.1, view: $0.2) }

        for (index, item) in toolbarItems.enumerated() {
            toolbarStack.addArrangedSubview(item.view)
            toolbarStack.setVisibilityPriority(Self.toolbarPriority(item.name, index: index), for: item.view)
        }
    }

    private static func toolbarPriority(_ name: String, index: Int) -> NSStackView.VisibilityPriority {
        name == "btnSettings" ? .mustHold : NSStackView.VisibilityPriority(rawValue: 900 - Float(index) * 10)
    }


    func isToolbarItemVisible(_ name: String) -> Bool {
        guard let view = toolbarItems.first(where: { $0.name == name })?.view else { return false }
        return toolbarStack.visibilityPriority(for: view) != .notVisible
    }


    private func updateToolbar() {
        guard isViewLoaded, mode != .fileTree else { return }
        let hasGroups = canUseFindInCommitFilesGitGrep || rootNodes.first?.isDiffGroup == true
        let hasDiffAB = groups.contains { $0.kind == .diffA || $0.kind == .diffB }
        let hidden = Set(preferences.hiddenToolbarItems)
        let refreshVisible = mode == .diff
        for item in toolbarItems {
            var visible: Bool
            switch item.name {
            case "btnCollapseGroups": visible = hasGroups
            case "sepRefresh": visible = hasGroups && refreshVisible
            case "btnRefresh": visible = refreshVisible
            case "sepAsTree": visible = hasGroups || refreshVisible
            case "sepFilter", "btn!", "btnB", "btnA", "btn=": visible = hasDiffAB
            case "sepOptions", "btnFindInFilesGitGrep": visible = canUseFindInCommitFilesGitGrep
            default: visible = true
            }
            if hidden.contains(item.name) && item.name != "btnSettings" { visible = false }
            toolbarStack.setVisibilityPriority(visible ? Self.toolbarPriority(item.name, index: toolbarItems.firstIndex { $0.name == item.name } ?? 0) : .notVisible,
                                               for: item.view)
        }
        treeModeButton.image = AppKitFactory.resourceImage(isTreeMode ? "FileTree" : "DocumentTree", accessibilityDescription: "Toggle flat list / tree", adaptLightness: !isTreeMode)
        treeModeButton.setAccessibilityLabel("Toggle flat list / tree")
        updateGroupingButtonStates()
        let hasArtificial = revisions.contains { $0.objectID == nil }
        refreshButton?.isEnabled = hasArtificial && onRefreshArtificial != nil
    }

    @objc private func refreshArtificial() { onRefreshArtificial?() }

    @objc private func toggleDiffStatusFilter(_ sender: NSButton) {
        guard let status = diffStatusButtons.first(where: { $0.value === sender })?.key else { return }
        if sender.state == .on { diffStatusFilter.insert(status) } else { diffStatusFilter.remove(status) }
        reloadNodes(preferredIDs: selectedFileIDs(), causedByFilter: true)
    }

    private func makeGroupingButton(_ grouping: FileStatusGrouping, tag: Int, image: String, tooltip: String) -> NSButton {
        let button = AppKitFactory.resourceButton(image, tooltip: tooltip, target: self, action: #selector(chooseGrouping(_:)))
        button.setButtonType(.pushOnPushOff)
        button.tag = tag
        button.state = self.grouping == grouping ? .on : .off
        groupingButtons[grouping] = button
        return button
    }

    private func updateGroupingButtonStates() {
        groupingButtons.forEach { $0.value.state = $0.key == grouping ? .on : .off }
        viewModeMenu?.items.forEach { item in
            if item.action == #selector(chooseViewMode(_:)), item.tag < 10 {
                let itemGrouping: FileStatusGrouping = switch item.tag {
                case 2, 3: .fileExtension
                case 4, 5: .status
                default: .path
                }
                item.state = itemGrouping == grouping && item.tag.isMultiple(of: 2) == isTreeMode ? .on : .off
            } else if item.tag == 10 {
                item.state = usesDenseTree ? .on : .off
                item.isEnabled = isTreeMode
            } else if item.tag == 11 {
                item.state = showsGroupNodesInFlatList ? .on : .off
                item.isEnabled = !isTreeMode && grouping != .path
            }
        }
    }

    private func persistViewPreferences() {
        updatePreferences {
            $0.grouping = grouping
            $0.isTreeMode = isTreeMode
            $0.usesDenseTree = usesDenseTree
            $0.showsGroupNodesInFlatList = showsGroupNodesInFlatList
        }
    }

    @objc private func toggleTreeMode() {
        isTreeMode.toggle()
        persistViewPreferences()
        reloadNodes(preferredIDs: selectedFileIDs(), causedByFilter: true)
    }

    @objc private func chooseGrouping(_ sender: NSButton) {
        grouping = switch sender.tag {
        case 1: .fileExtension
        case 2: .status
        default: .path
        }
        persistViewPreferences()
        reloadNodes(preferredIDs: selectedFileIDs(), causedByFilter: true)
    }

    @objc private func chooseViewMode(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0, 1: grouping = .path
        case 2, 3: grouping = .fileExtension
        case 4, 5: grouping = .status
        case 10: usesDenseTree.toggle()
        case 11: showsGroupNodesInFlatList.toggle()
        default: return
        }
        if sender.tag < 10 { isTreeMode = sender.tag.isMultiple(of: 2) }
        persistViewPreferences()
        reloadNodes(preferredIDs: selectedFileIDs(), causedByFilter: true)
    }

    private func makeViewModeMenu() -> NSPopUpButton {
        let button = imagePullDown("FileTree", tooltip: "File list grouping options", width: 10)
        [("Group by file path - tree", 0), ("Group by file path - flat", 1),
         ("Group by file extension - tree", 2), ("Group by file extension - flat", 3),
         ("Group by file status - tree", 4), ("Group by file status - flat", 5)].forEach { title, tag in
            let item = NSMenuItem(title: title, action: #selector(chooseViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            button.menu?.addItem(item)
        }
        button.menu?.addItem(.separator())
        for (title, tag) in [("Dense tree (merge single item with its folder node)", 10), ("Show group nodes in flat list (if multiple)", 11)] {
            let item = NSMenuItem(title: title, action: #selector(chooseViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            button.menu?.addItem(item)
        }
        viewModeMenu = button.menu
        return button
    }



    private func makeGrepButton() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        let toggle = AppKitFactory.resourceButton("ViewFile", tooltip: "Toggle 'Find in commit files using git-grep'", target: self, action: #selector(toggleGrepButton))
        stack.addArrangedSubview(toggle)
        let pullDown = imagePullDown("", tooltip: "Find in commit files using git-grep options", width: 10)
        pullDown.menu?.delegate = self
        grepMenu = pullDown.menu
        stack.addArrangedSubview(pullDown)
        return stack
    }

    private func populateGrepMenu(_ menu: NSMenu) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let options = preferences
        func add(_ title: String, _ action: Selector, state: Bool, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = state ? .on : .off
            item.tag = tag
            menu.addItem(item)
            return item
        }
        _ = add("Match case", #selector(grepMatchCase), state: !options.gitGrepIgnoreCase)
        _ = add("Match whole word", #selector(grepWholeWord), state: options.gitGrepMatchWholeWord)
        let optionsItem = NSMenuItem(title: "Options: \(options.gitGrepUserArguments)", action: nil, keyEquivalent: "")
        let optionsMenu = NSMenu()
        for argument in ["--basic-regexp", "--extended-regexp", "--fixed-strings", "--perl-regexp"] {
            let item = NSMenuItem(title: argument, action: #selector(grepOption(_:)), keyEquivalent: "")
            item.target = self
            item.state = options.gitGrepUserArguments == argument ? .on : .off
            optionsMenu.addItem(item)
        }
        optionsItem.submenu = optionsMenu
        menu.addItem(optionsItem)
        menu.addItem(.separator())
        for (index, title) in ["Using dialog", "Using input box", "Using both"].enumerated() {
            _ = add(title, #selector(grepUsing(_:)), state: options.findInFilesGitGrepTypeIndex == index, tag: index)
        }
    }

    @objc private func grepMatchCase() {
        updatePreferences { $0.gitGrepIgnoreCase.toggle() }
        runGrep()
    }

    @objc private func grepWholeWord() {
        updatePreferences { $0.gitGrepMatchWholeWord.toggle() }
        runGrep()
    }

    @objc private func grepOption(_ sender: NSMenuItem) {
        updatePreferences { $0.gitGrepUserArguments = sender.title }
        runGrep()
    }

    @objc private func grepUsing(_ sender: NSMenuItem) {
        updatePreferences { $0.findInFilesGitGrepTypeIndex = sender.tag }
        toggleGrep(fromButton: false)
    }

    @objc private func toggleGrepButton() { toggleGrep(fromButton: true) }


    private func toggleGrep(fromButton: Bool) {
        let type = preferences.findInFilesGitGrepTypeIndex
        let usingInputBox = type != 0
        let usingDialog = type != 1
        let isVisible = (!usingInputBox || !grepBox.isHidden) && (!usingDialog || grepWindow?.window?.isVisible == true)
        let setVisible = !fromButton || !isVisible
        let inputBoxVisible = setVisible && usingInputBox
        updatePreferences { $0.showFindInCommitFilesGitGrep = inputBoxVisible }
        setGrepBoxVisible(inputBoxVisible, focus: true)
        if !inputBoxVisible { view.window?.makeFirstResponder(outlineView) }
        if setVisible && usingDialog { showGrepDialog(text: "") } else { grepWindow?.close() }
    }

    private func setGrepBoxVisible(_ visible: Bool, focus: Bool) {
        guard canUseFindInCommitFilesGitGrep || !visible else { return }
        grepWindow?.setShowSearchBox(visible)
        let changed = grepBox.isHidden == visible
        grepBox.isHidden = !visible
        grepHeight?.constant = visible ? 23 : 0
        if visible, focus, changed { view.window?.makeFirstResponder(grepBox) }
        if !visible, grepWindow?.window?.isVisible != true, !grepBox.stringValue.isEmpty {
            grepBox.stringValue = ""
            setGrep("", delay: 0)
        }
    }


    func showGrepDialog(text: String) {
        guard canUseFindInCommitFilesGitGrep, let owner = view.window else { return }
        let window = grepWindow ?? FindInCommitFilesGitGrepWindowController(
            locate: { [weak self] text in
                guard let self else { return }
                grepBox.stringValue = text
                setGrep(text, delay: 0)
            },
            toggle: { [weak self] visible in self?.setGrepBoxVisible(visible, focus: true) },
            closed: { [weak self] in self?.grepWindow = nil })
        grepWindow = window
        window.present(owner: owner,
                       text: !text.isEmpty ? text : !grepText.isEmpty ? grepBox.stringValue : nil,
                       history: grepBox.objectValues.compactMap { $0 as? String },
                       showSearchBox: !grepBox.isHidden)
    }

    private func runGrep() { setGrep(grepBox.stringValue, delay: 0) }


    private func setGrep(_ text: String, delay: UInt64) {
        grepTask?.cancel()
        grepTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            grepText = text
            grepBox.backgroundColor = text.isEmpty ? .textBackgroundColor : Self.activeInputColor
            onRecalculate?()
            guard !text.isEmpty else { return }
            var history = grepBox.objectValues.compactMap { $0 as? String }
            history.removeAll { $0 == text }
            history.insert(text, at: 0)
            grepBox.removeAllItems()
            grepBox.addItems(withObjectValues: Array(history.prefix(30)))
            grepWindow?.setHistory(Array(history.prefix(30)))
        }
    }

    private static let activeInputColor = NSColor.systemYellow.withAlphaComponent(0.25)




    @objc private func editGitIgnore() { perform("file.editGitIgnore") }
    @objc private func editLocallyIgnoredFiles() { perform("file.editLocallyIgnored") }

    private func makeSettingsMenu() -> NSPopUpButton {
        let button = imagePullDown("Settings", tooltip: "Settings", width: 29)
        button.menu?.delegate = self
        settingsMenu = button.menu
        return button
    }


    private func populateSettingsMenu(_ menu: NSMenu) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let isWorktree = revisions.contains(.workingDirectory)
        func add(_ title: String, _ action: Selector?, state: Bool? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = state == true ? .on : .off
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
        }

        add("Show skip-worktree files", #selector(toggleShowSkipWorktree), state: showsSkipWorktreeFiles, enabled: isWorktree)
        add("Show untracked files", #selector(toggleShowUntracked), state: showsUntrackedFiles, enabled: isWorktree)
        menu.addItem(.separator())
        add("Edit ignored files", #selector(editGitIgnore))
        add("Edit locally ignored files", #selector(editLocallyIgnoredFiles))
        menu.addItem(.separator())
        add("Refresh artificial commits on form focus", #selector(toggleRefreshOnFocus), state: AppSettingsStore.shared.commitPreferences.refreshOnFocus)
        let allParents = NSMenuItem(title: "Show file differences for all parents", action: #selector(toggleShowDiffForAllParents), keyEquivalent: "")
        allParents.target = self
        allParents.state = preferences.showDiffForAllParents ? .on : .off
        allParents.toolTip = """
            Show all differences between the selected commits, not limiting to only one difference.

            - For a single selected commit, show the difference with its parent commit.
            - For a single selected merge commit, show the difference with all parents.
            - For two selected commits with a common ancestor (BASE), show the difference
            between the commits as well as the difference from BASE to the selected commits.
            See documentation for more details about icons and range diffs.
            - For multiple selected commits (up to four), show the difference for
            all the first selected with the last selected commit.
            """
        menu.addItem(allParents)
        menu.addItem(.separator())
        let toolbarItem = NSMenuItem(title: "Toolbar", action: nil, keyEquivalent: "")
        let toolbarMenu = NSMenu()
        let hidden = Set(preferences.hiddenToolbarItems)
        for (index, item) in toolbarItems.enumerated() {
            let title = item.name.hasPrefix("sep") && index + 1 < toolbarItems.count
                ? "Separator '\(toolbarItems[index + 1].title)'" : item.title
            let menuItem = NSMenuItem(title: title, action: #selector(toggleToolbarItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.name
            menuItem.state = hidden.contains(item.name) ? .off : .on
            menuItem.isEnabled = item.name != "btnSettings"
            toolbarMenu.addItem(menuItem)
        }
        toolbarItem.submenu = toolbarMenu
        menu.addItem(toolbarItem)
    }

    @objc private func toggleShowSkipWorktree() {
        showsSkipWorktreeFiles.toggle()
        onRecalculate?()
    }

    @objc private func toggleShowUntracked() {
        showsUntrackedFiles.toggle()
        onRecalculate?()
    }

    @objc private func toggleRefreshOnFocus() {
        var commit = AppSettingsStore.shared.commitPreferences
        commit.refreshOnFocus.toggle()
        AppSettingsStore.shared.saveCommitPreferences(commit)
    }

    @objc private func toggleShowDiffForAllParents() {
        updatePreferences { $0.showDiffForAllParents.toggle() }
        onRecalculate?()
    }

    @objc private func toggleToolbarItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        updatePreferences {
            if $0.hiddenToolbarItems.contains(name) { $0.hiddenToolbarItems.removeAll { $0 == name } }
            else { $0.hiddenToolbarItems.append(name) }
        }
        updateToolbar()
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
        if !imageName.isEmpty {
            button.item(at: 0)?.image = AppKitFactory.resourceImage(imageName, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
        }
        return button
    }




    func apply(files: [ChangedFile], scope: ChangedFileSelectionScope, comparisonTitle: String) {
        let selectedIDs = selectedFileIDs()
        selectionScope = scope
        plainFiles = files
        plainSections = nil
        plainTitle = comparisonTitle
        revisions = []
        reloadNodes(preferredIDs: selectedIDs, causedByFilter: true)
    }


    func apply(sections: [ChangedFileSection], scope: ChangedFileSelectionScope) {
        let selectedIDs = selectedFileIDs()
        selectionScope = scope
        plainFiles = sections.flatMap(\.files)
        plainSections = sections
        plainTitle = "Changes"
        revisions = []
        reloadNodes(preferredIDs: selectedIDs, causedByFilter: true)
    }


    func apply(groups: [FileStatusGroup], revisions: [RevisionID], preferredPaths: [String] = []) {
        submoduleStatuses.removeAll()
        self.groups = groups
        self.revisions = revisions
        isLoading = false
        defer {
            if pendingFindFile {
                pendingFindFile = false
                DispatchQueue.main.async { [weak self] in self?.findFile() }
            }
        }
        itemsByNodeFileID = [:]
        for group in groups {
            for file in group.files {
                itemsByNodeFileID[group.id + "|" + file.id] = FileStatusListItem(group: group, file: file)
            }
        }
        reloadNodes(preferredIDs: [], causedByFilter: false, preferredPaths: preferredPaths)
    }

    func apply(submodule: FileStatusSubmodule, fileID: String) {
        guard itemsByNodeFileID[fileID] != nil else { return }
        submoduleStatuses[fileID] = submodule
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ChangedFileNode, node.file?.id == fileID {
                outlineView.reloadItem(node)
            }
        }
    }

    func currentlySelectedFiles() -> [ChangedFile] {
        mode == .plain ? selectedNodeFiles() : selectedItems().map(\.file)
    }

    var allItems: [FileStatusListItem] { groups.flatMap { group in group.files.map { FileStatusListItem(group: group, file: $0) } } }
    var firstGroupItems: [FileStatusListItem] { groups.first.map { group in group.files.map { FileStatusListItem(group: group, file: $0) } } ?? [] }


    func selectedItems() -> [FileStatusListItem] {
        selectedNodeFiles().compactMap { itemsByNodeFileID[$0.id] }
    }


    var selectedFolder: String? {
        let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }
        guard nodes.count == 1 else { return nil }
        return nodes[0].folderPath
    }

    var focusedItem: FileStatusListItem? {
        let items = selectedItems()
        return items.first { $0.group.id + "|" + $0.file.id == focusedFileID } ?? items.first
    }

    func focusList() { view.window?.makeFirstResponder(outlineView) }


    @discardableResult
    func selectFileOrFolder(_ path: String, firstGroupOnly: Bool = false, notify: Bool = true) -> Bool {
        var candidates: [(row: Int, node: ChangedFileNode)] = []
        func visit(_ nodes: [ChangedFileNode]) {
            for node in nodes {
                if node.file.map({ itemsByNodeFileID[$0.id]?.file.path ?? $0.path }) == path || node.folderPath == path {
                    if !firstGroupOnly || node.groupID == groups.first?.id || node.groupID == nil { candidates.append((0, node)) }
                }
                visit(node.children)
            }
        }
        visit(rootNodes)
        guard let target = candidates.first?.node else { return false }
        var ancestors: [ChangedFileNode] = []
        func findTrail(to node: ChangedFileNode, in nodes: [ChangedFileNode], trail: [ChangedFileNode]) -> Bool {
            for candidate in nodes {
                if candidate === node { ancestors = trail; return true }
                if findTrail(to: node, in: candidate.children, trail: trail + [candidate]) { return true }
            }
            return false
        }
        _ = findTrail(to: target, in: rootNodes, trail: [])
        ancestors.forEach { outlineView.expandItem($0) }
        let row = outlineView.row(forItem: target)
        guard row >= 0 else { return false }
        suppressSelectionEvents = !notify
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionEvents = false
        outlineView.scrollRowToVisible(row)
        if notify { notifySelection() }
        return true
    }

    func selectItems(_ items: [FileStatusListItem]) {
        let ids = Set(items.map { $0.group.id + "|" + $0.file.id })
        selectRows { ids.contains($0.id) }
    }

    func setFilter(_ value: String) {
        filterBox.stringValue = value
        applyFilterText(value)
    }



    private func reloadNodes(preferredIDs: Set<String>, causedByFilter: Bool, preferredPaths: [String] = []) {
        guard isViewLoaded else { _ = view; return reloadNodes(preferredIDs: preferredIDs, causedByFilter: causedByFilter, preferredPaths: preferredPaths) }
        let expandedStates: [ChangedFileNode: Bool]
        let showNoFiles: Bool
        if mode == .plain {
            rootNodes = makePlainNodes()
            expandedStates = Dictionary(uniqueKeysWithValues: rootNodes.map { ($0, true) })
            showNoFiles = false
        } else {
            let result = makeGroupNodes()
            rootNodes = result.nodes
            expandedStates = result.states
            showNoFiles = !result.filesPresent && groups.count <= 1 && mode != .fileTree
        }
        noFilesLabel.isHidden = !showNoFiles
        scrollView.isHidden = showNoFiles
        filterBox.isHidden = showNoFiles && grepText.isEmpty
        suppressSelectionEvents = true
        outlineView.reloadData()
        for node in rootNodes {
            switch expandedStates[node] {
            case true?: outlineView.expandItem(node, expandChildren: true)
            case false?:
                node.children.forEach { outlineView.expandItem($0, expandChildren: true) }
            case nil:
                outlineView.expandItem(node)
            }
        }
        var rows = IndexSet()
        if causedByFilter {
            for row in 0..<outlineView.numberOfRows {
                if let file = (outlineView.item(atRow: row) as? ChangedFileNode)?.file, preferredIDs.contains(file.id) { rows.insert(row) }
            }
        }
        suppressSelectionEvents = false
        updateToolbar()
        if !rows.isEmpty {
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
            notifySelection()
            return
        }
        for path in preferredPaths where selectFileOrFolder(path, firstGroupOnly: true) { return }
        if mode == .plain || !causedByFilter || outlineView.selectedRowIndexes.isEmpty {
            selectFirstVisibleItem()
        }
    }


    @discardableResult
    func selectAdjacentVisibleFile(forward: Bool) -> Bool {
        let current = outlineView.selectedRow
        let rows = (0..<outlineView.numberOfRows).filter { (outlineView.item(atRow: $0) as? ChangedFileNode)?.file != nil }
        let next = forward ? rows.first { $0 > current } : rows.last { $0 < current }
        guard let next else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        outlineView.scrollRowToVisible(next)
        notifySelection()
        return true
    }

    func selectFirstVisibleItem() {
        guard let row = (0..<outlineView.numberOfRows).first(where: { (outlineView.item(atRow: $0) as? ChangedFileNode)?.file != nil }) else {
            outlineView.deselectAll(nil)
            notifySelection()
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        notifySelection()
    }

    private func makePlainNodes() -> [ChangedFileNode] {
        if let plainSections {
            return plainSections.compactMap { section in
                let sectionFiles = section.files.filter(isFilterMatch)
                guard !sectionFiles.isEmpty else { return nil }
                let children = ChangedFileListTreeBuilder.build(files: sectionFiles, grouping: grouping, isTreeMode: isTreeMode,
                                                                usesDenseTree: usesDenseTree, showsGroupNodesInFlatList: showsGroupNodesInFlatList)
                return ChangedFileNode(id: "section:\(section.id)", title: "(\(sectionFiles.count)) \(section.title)",
                                       imageName: section.imageName, children: children)
            }
        }
        var files = plainFiles.filter(isFilterMatch)
        if selectionScope == .workingTree, !AppSettingsStore.shared.fileStatusListPreferences.showsUntrackedFiles {
            files.removeAll { $0.changeType == .added }
        }
        let leaves = ChangedFileListTreeBuilder.build(files: files, grouping: grouping, isTreeMode: isTreeMode,
                                                      usesDenseTree: usesDenseTree, showsGroupNodesInFlatList: showsGroupNodesInFlatList)
        guard isTreeMode, !leaves.isEmpty else { return leaves }
        return [ChangedFileNode(id: "diff-root", title: "(\(files.count)) \(plainTitle)", imageName: "Diff", children: leaves)]
    }

    private func makeGroupNodes() -> (nodes: [ChangedFileNode], states: [ChangedFileNode: Bool], filesPresent: Bool) {
        let groupByRevision = mode == .diff
        let filesPresent = groups.contains { !$0.files.isEmpty }
        let hasGrepGroup = !grepText.isEmpty || groups.contains(where: \.isGrep)
        let showDiffGroups = groups.count > 1 || (groupByRevision && !(groups.count == 1 && groups[0].files.isEmpty))
        let showGroupLabel = (filesPresent && (groups.count > 1 || groupByRevision)) || hasGrepGroup
        var nodes: [ChangedFileNode] = []
        var states: [ChangedFileNode: Bool] = [:]
        for group in groups {
            let emptyGroup = showGroupLabel && group.files.isEmpty
            let groupNode: ChangedFileNode
            var shownCount = 0
            if group.files.count == 1, group.files[0].isRangeDiff {
                groupNode = node(for: group.files[0], group: group, title: group.files[0].path)
                shownCount = 1
            } else {
                var files = emptyGroup ? [Self.noChangesItem] : group.files.filter(isFilterMatch)
                shownCount = emptyGroup ? 0 : files.count
                files = files.map { original in
                    var file = original
                    file.id = group.id + "|" + original.id
                    return file
                }
                var children = ChangedFileListTreeBuilder.build(files: files, grouping: grouping, isTreeMode: isTreeMode,
                                                                usesDenseTree: usesDenseTree, showsGroupNodesInFlatList: showsGroupNodesInFlatList,
                                                                imageName: { [itemsByNodeFileID] file in
                    Self.imageName(for: itemsByNodeFileID[file.id]?.file ?? file, isGrep: group.isGrep)
                }, title: { file in
                    let original = self.itemsByNodeFileID[file.id]?.file ?? file
                    return AppSettingsStore.shared.preferences.truncatePathMethod.title(path: original.path, oldPath: original.oldPath)
                })
                if grouping != .path, children.count == 1, !children[0].children.isEmpty, children[0].file == nil {
                    children = children[0].children
                }
                children.forEach { $0.assignGroup(group.id) }
                let shown = shownCount >= group.files.count ? "" : "\(shownCount)/"
                groupNode = ChangedFileNode(id: "group:\(group.id)", title: "(\(shown)\(group.files.count)) \(group.summary)",
                                            imageName: Self.groupImageName(group), children: children)
                groupNode.isDiffGroup = true
                groupNode.groupID = group.id
            }

            let expanded: Bool
            if emptyGroup {
                expanded = false
            } else if hasGrepGroup {
                expanded = group.isGrep && (mode != .fileTree || filter != nil || !grepText.isEmpty) && shownCount < 100
            } else {
                expanded = ((group.files.count <= 7 && group.kind == .diff) || groups.count < 3 || group.id == groups.first?.id) && !group.files.isEmpty
            }
            if showDiffGroups {
                nodes.append(groupNode)
                states[groupNode] = expanded
            } else {
                for child in groupNode.children {
                    nodes.append(child)
                    states[child] = expanded
                }
                if groupNode.file != nil {
                    nodes.append(groupNode)
                    states[groupNode] = true
                }
            }
        }
        return (nodes, states, filesPresent)
    }

    private static let noChangesItem: ChangedFile = {
        var file = ChangedFile(id: "status:no-changes", path: "- No changes -", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
        file.isStatusOnly = true
        return file
    }()

    private func node(for file: ChangedFile, group: FileStatusGroup, title: String) -> ChangedFileNode {
        var qualified = file
        qualified.id = group.id + "|" + file.id
        let node = ChangedFileNode(id: "file:\(qualified.id)", title: title, imageName: Self.imageName(for: file, isGrep: group.isGrep), file: qualified)
        node.groupID = group.id
        return node
    }


    static func groupImageName(_ group: FileStatusGroup) -> String {
        switch group.kind {
        case .diff: "Diff"
        case .diffA: "DiffA"
        case .diffB: "DiffB"
        case .combined: "DiffC"
        case .range: "DiffR"
        case .grep: "ViewFile"
        }
    }


    static func imageName(for file: ChangedFile, isGrep: Bool) -> String {
        if file.isStatusOnly && !file.isRangeDiff { return file.id == noChangesItem.id ? "FileStatusCopiedSame" : "FileStatusUnknown" }
        if isGrep { return file.isSubmodule ? (file.submoduleIsDirty ? "SubmoduleDirty" : "SubmodulesManage") : "File" }
        func suffix() -> String {
            switch file.diffStatus {
            case .onlyA: "OnlyA"
            case .onlyB: "OnlyB"
            case .same: "Same"
            case .unequal: "Unequal"
            case .unknown: ""
            }
        }
        if file.changeType == .deleted { return "FileStatusRemoved" + suffix() }
        if file.isRangeDiff { return "DiffR" }
        if file.grepString?.isEmpty == false { return "File" }
        if file.changeType == .added || !file.isTracked { return "FileStatusAdded" + suffix() }
        if file.isConflict { return "Unmerged" }
        if file.isSubmodule { return file.submoduleIsDirty ? "SubmoduleDirty" : "SubmodulesManage" }
        if file.changeType == .modified || file.isTypeChanged || (file.changeType == .renamed && file.renameCopyPercentage != "100") {
            return "FileStatusModified" + suffix()
        }
        if file.changeType == .renamed { return "FileStatusRenamed" + suffix() }
        if file.changeType == .copied { return "FileStatusCopied" + suffix() }
        return "FileStatusUnknown"
    }



    func controlTextDidChange(_ obj: Notification) {
        guard let box = obj.object as? NSComboBox else { return }
        if box === filterBox {
            let text = filterBox.stringValue
            filterTask?.cancel()
            filterTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                applyFilterText(text)
            }
        } else if box === grepBox {
            setGrep(grepBox.stringValue, delay: 200_000_000)
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if box === filterBox { applyFilterText(filterBox.stringValue) }
            else if box === grepBox { setGrep(grepBox.stringValue, delay: 0) }
        }
    }


    private func applyFilterText(_ text: String) {
        let path = repositoryURL.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        var value = text
        if let path, value.count > path.count, value.lowercased().hasPrefix(path.lowercased()) {
            value = String(value.dropFirst(path.count))
            filterBox.stringValue = value
        }
        if value.isEmpty {
            filter = nil
            filterBox.backgroundColor = .textBackgroundColor
            filterBox.toolTip = nil
        } else {
            do {
                filter = try NSRegularExpression(pattern: value, options: [.caseInsensitive])
                filterBox.backgroundColor = Self.activeInputColor
                filterBox.toolTip = nil
            } catch {
                filterBox.toolTip = error.localizedDescription
                return
            }
        }
        reloadNodes(preferredIDs: selectedFileIDs(), causedByFilter: true)
        if !value.isEmpty, outlineView.numberOfRows > 0, !filterBox.objectValues.contains(where: { ($0 as? String) == value }) {
            if filterBox.numberOfItems == 10 { filterBox.removeItem(at: 9) }
            filterBox.insertItem(withObjectValue: value, at: 0)
        }
    }


    private func isFilterMatch(_ file: ChangedFile) -> Bool {
        if file.isRangeDiff { return true }
        if file.diffStatus != .unknown, !diffStatusFilter.contains(file.diffStatus) { return false }
        guard let filter else { return true }
        return AppSettingsStore.shared.preferences.truncatePathMethod.filterKeys(path: file.path, oldPath: file.oldPath).contains { name in
            filter.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }



    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ChangedFileNode)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ChangedFileNode)?.children[index] ?? rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? ChangedFileNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GitExtensionsSelectionRowView()
    }


    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let file = (item as? ChangedFileNode)?.file, !file.isStatusOnly, let repositoryURL else { return nil }
        let path = itemsByNodeFileID[file.id]?.file.path ?? file.path
        return repositoryURL.appendingPathComponent(path) as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ChangedFileNode, let identifier = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ChangedFileCellView) ?? ChangedFileCellView()
        cell.identifier = identifier
        cell.apply(node: node, submodule: node.file.flatMap { submoduleStatuses[$0.id] })
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionEvents else { return }
        notifySelection()
    }

    private func notifySelection() {
        if mode == .plain {
            if let first = selectedNodeFiles().first { onSelection?(first) }
            return
        }
        onSelectionChanged?(selectedItems(), selectedFolder)
    }

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ChangedFileNode else { return }
        if let file = node.file {
            if mode == .plain { return }
            if let item = itemsByNodeFileID[file.id], item.file.isTracked { onDoubleClick?(item) }
        } else if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }


    @objc private func collapseGroups() {
        var collapsed = false
        func collapseGroupKeys(_ nodes: [ChangedFileNode]) {
            for node in nodes where node.isGroupKey && outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node, collapseChildren: true)
                collapsed = true
            }
        }
        if rootNodes.contains(where: \.isDiffGroup) {
            for group in rootNodes {
                collapseGroupKeys(group.children)
                if outlineView.isItemExpanded(group) {
                    outlineView.collapseItem(group, collapseChildren: true)
                    collapsed = true
                }
            }
        } else {
            collapseGroupKeys(rootNodes)
        }
        if collapsed {
            var node = outlineView.item(atRow: outlineView.selectedRow) as? ChangedFileNode
            while let parent = node.flatMap({ outlineView.parent(forItem: $0) as? ChangedFileNode }) { node = parent }
            let row = node.map { outlineView.row(forItem: $0) } ?? 0
            if row >= 0, outlineView.numberOfRows > 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else if let node = outlineView.item(atRow: outlineView.selectedRow) {
            outlineView.expandItem(node)
        }
    }



    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === grepMenu { populateGrepMenu(menu); return }
        if menu === settingsMenu { populateSettingsMenu(menu); return }
        let row = outlineView.clickedRow
        if row >= 0, !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if row >= 0, let file = (outlineView.item(atRow: row) as? ChangedFileNode)?.file { focusedFileID = file.id }
        populateFileMenu(menu)
    }


    func menuContext() -> ChangedFileContextMenuContext {
        if mode == .plain {
            var context = ChangedFileContextMenuContext(selectedFiles: selectedNodeFiles())
            context.isBareRepository = isBareRepository
            return context
        }
        let items = selectedItems()
        var context = ChangedFileContextMenuContext(selectedFiles: items.map(\.file), firstRevisions: items.map(\.first), secondRevisions: items.map(\.second))
        context.selectedFolder = selectedFolder
        context.isBareRepository = isBareRepository
        context.isFileTreeMode = mode == .fileTree
        context.isCombinedDiff = items.contains { $0.group.kind == .combined }
        context.supportLinePatching = items.count == 1 && supportLinePatching()
        context.canShowInFileTree = canShowInFileTree
        context.canFilterInGrid = canFilterInGrid
        context.canBlame = canBlame
        context.canFileHistory = canFileHistory
        context.blameInFileTree = !context.isFileTreeMode && !AppSettingsStore.shared.blamePreferences.useDiffViewerForBlame
        context.isBlameShown = isBlameShown
        context.canCherryPick = canCherryPick
        context.canUseGrep = canUseFindInCommitFilesGitGrep
        context.diffTools = diffTools
        let fileManager = FileManager.default
        var allFiles = !items.isEmpty, allDirectories = !items.isEmpty, allFilesOrUntrackedDirectories = !items.isEmpty
        var anyExists = false
        for item in items {
            guard let url = repositoryURL?.appendingPathComponent(item.file.path) else { allFiles = false; allDirectories = false; allFilesOrUntrackedDirectories = false; break }
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let fileExists = exists && !isDirectory.boolValue
            let directoryExists = exists && isDirectory.boolValue
            allFiles = allFiles && fileExists
            allDirectories = allDirectories && directoryExists
            allFilesOrUntrackedDirectories = allFilesOrUntrackedDirectories && (fileExists || (!item.file.isTracked && allDirectories))
            if exists || fileManager.fileExists(atPath: url.deletingLastPathComponent().path) { anyExists = true }
        }
        context.allFilesExist = allFiles
        context.allDirectoriesExist = allDirectories
        context.allFilesOrUntrackedDirectoriesExist = allFilesOrUntrackedDirectories
        context.anyFileOrParentExists = anyExists

        func describeAll(_ revisions: [RevisionID?]) -> String {
            var seen: [RevisionID?] = []
            for revision in revisions where !seen.contains(revision) { seen.append(revision) }
            return seen.count == 1 ? describe(seen[0]) : seen.count > 1 ? "<multiple>" : ""
        }
        context.secondDescription = describeAll(items.map { Optional($0.second) })
        context.firstDescription = describeAll(items.map(\.first))
        context.resetSecondDescription = items.first.map { describe($0.second) } ?? ""
        context.resetFirstDescription = items.first.map { describe($0.first) } ?? ""

        let selectedRevision = context.selectedRevision
        let firstIDs = items.map(\.first)
        let localExists = items.contains { !$0.file.isTracked }
            || items.contains { item in repositoryURL.map { fileManager.fileExists(atPath: $0.appendingPathComponent(item.file.path).path) } ?? false }
        let allAreNew = !items.isEmpty && items.allSatisfy { $0.file.changeType == .added || !$0.file.isTracked }
        let allAreDeleted = !items.isEmpty && items.allSatisfy { $0.file.changeType == .deleted }
        let firstIsParent = selectedRevision.map { selected in
            let parents = parentsOf(selected)
            return firstIDs.allSatisfy { $0.map(parents.contains) == true }
        } ?? false
        context.hideToLocal = (selectedRevision == .workingDirectory && firstIDs.allSatisfy { $0 == .index })
            || (selectedRevision == .index && firstIDs.allSatisfy { $0 == .workingDirectory })
        context.firstToSelectedEnabled = selectedRevision != nil
        context.firstToLocalEnabled = selectedRevision != nil && localExists && (!firstIsParent || !allAreNew) && !firstIDs.contains(.workingDirectory)
        context.selectedToLocalEnabled = selectedRevision != nil && localExists && !allAreDeleted && selectedRevision != .workingDirectory

        let files = items.map { RememberedDiffFile(item: $0) }
        if files.count == 2 {
            let firstIndex = focusedItem == items[0] ? 1 : 0
            context.diffTwoSelectedEnabled = files[firstIndex].canUseAsFirst && files[1 - firstIndex].canUseAsSecond
        }
        if let remembered = Self.remembered {
            context.rememberedName = remembered.path
            context.diffWithRememberedEnabled = files.count == 1 && files[0] != remembered && files[0].canUseAsSecond
        }
        if files.count == 1 {
            context.rememberSecondEnabled = files[0].canUseAsFirst(secondRevision: true)
            context.rememberFirstEnabled = files[0].canUseAsFirst(secondRevision: false)
        }

        let selectedNodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }
        context.hasSubnodes = selectedNodes.contains { !$0.children.isEmpty }
        context.canCollapseRootFolders = mode == .fileTree && rootNodes.contains { outlineView.isItemExpanded($0) }
        context.showOpenSubmodule = canOpenSubmodule && items.count == 1 && items[0].file.isSubmodule
        context.showSortBy = mode == .diff
        return context
    }

    private func populateFileMenu(_ menu: NSMenu) {
        let items = selectedItems()

        if mode != .plain, items.count == 1, items[0].file.isStatusOnly, !items[0].file.isRangeDiff {
            menu.removeAllItems()
            return
        }
        let context = menuContext()
        populatePlaceholderMenu(menu, with: ChangedFileContextMenuBuilder.build(context))
        func bind(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { bind(submenu); continue }
                guard let id = item.identifier?.rawValue, item.isEnabled else { continue }
                if mode == .plain {

                    if id == "file.copyPaths" || id == "file.find" || id.hasPrefix("tree.") {
                        item.target = self
                        item.action = #selector(performMenuItem(_:))
                    } else {
                        item.isEnabled = false
                    }
                    continue
                }
                item.target = self
                item.action = #selector(performMenuItem(_:))
            }
        }
        bind(menu)
        if mode != .plain {
            menuItem(withIdentifier: "file.skipWorktree", in: menu)?.state = items.contains(where: \.file.isSkipWorktree) ? .on : .off
            menuItem(withIdentifier: "file.assumeUnchanged", in: menu)?.state = items.contains(where: \.file.isAssumeUnchanged) ? .on : .off
            menuItem(withIdentifier: "file.showFindCommit", in: menu)?.state = grepBox.isHidden ? .off : .on
            menuItem(withIdentifier: "file.blame", in: menu)?.state = isBlameShown ? .on : .off
            menuItem(withIdentifier: "file.skipWorktree", in: menu)?.toolTip = "Hide already tracked files that will change but that you don't want to commit.\nTo see these files, use the \"Show skip-worktree files\" option."
            menuItem(withIdentifier: "file.assumeUnchanged", in: menu)?.toolTip = "Tell git to not check the status of this file for performance benefits.\nUse this feature when a file is big and never change.\nGit will never check if the file has changed that will improve status check performance."
            for (id, _) in ChangedFileContextMenuBuilder.sortByEntries {
                let tag: Int = ["sort.pathTree": 0, "sort.pathFlat": 1, "sort.extensionTree": 2, "sort.extensionFlat": 3, "sort.statusTree": 4, "sort.statusFlat": 5][id] ?? 0
                let itemGrouping: FileStatusGrouping = tag < 2 ? .path : tag < 4 ? .fileExtension : .status
                menuItem(withIdentifier: id, in: menu)?.state = itemGrouping == grouping && tag.isMultiple(of: 2) == isTreeMode ? .on : .off
            }
            for id in ["file.stage", "file.unstage", "file.difftool", "file.reset.first"] {
                if let item = menuItem(withIdentifier: id, in: menu) {
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
                }
            }
            applyShortcutTitles(menu)
        }
        if onScript != nil, mode != .plain {
            let scripts = NSMenuItem(title: "Run script", action: nil, keyEquivalent: "")
            scripts.submenu = ApplicationScriptsMenu(placement: .files, execute: { [weak self] in self?.onScript?($0) })
            if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "tree.collapseRootFolders" || $0.identifier?.rawValue == "sort.menu" }) {
                menu.insertItem(.separator(), at: index)
                menu.insertItem(scripts, at: index)
            } else {
                menu.addItem(.separator())
                menu.addItem(scripts)
            }
        }
    }


    private func applyShortcutTitles(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { applyShortcutTitles(submenu) }
            guard let id = item.identifier?.rawValue, let chord = ApplicationHotkeys.shared.chord(for: id),
                  ApplicationHotkeys.definitions.contains(where: { $0.id == id && $0.category == "File status list" }) else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: chord.modifiers)
            if chord.key.count == 1, chord.key.unicodeScalars.first.map({ $0.value < 0xF700 }) == true, chord.key != "\u{7f}" {
                item.keyEquivalent = chord.key
                item.keyEquivalentModifierMask = flags
            } else {
                item.toolTip = [item.toolTip, chord.title].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        perform(id)
    }


    func perform(_ identifier: String) {
        var id = identifier
        var tool: String?
        if let range = id.range(of: ".tool:") {
            tool = String(id[range.upperBound...])
            id = String(id[..<range.lowerBound])
        }
        switch id {
        case "tree.selectAll": selectAllDescendants(); return
        case "tree.collapseAll": outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }.forEach { outlineView.collapseItem($0, collapseChildren: true) }; return
        case "tree.expandAll": outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }.forEach { outlineView.expandItem($0, expandChildren: true) }; return
        case "tree.collapseRootFolders": collapseRootFolders(); return
        case "file.copyPaths": copyPaths(); return
        case "file.difftool.disableTools":
            var viewer = AppSettingsStore.shared.fileViewerPreferences
            viewer.showAvailableDiffTools = false
            AppSettingsStore.shared.saveFileViewerPreferences(viewer)
            diffTools = []
            return
        case "file.find": findFile(); return
        case "file.findCommit": showGrepDialog(text: selectedText()); return
        case "file.showFindCommit":
            let visible = grepBox.isHidden
            updatePreferences { $0.showFindInCommitFilesGitGrep = visible }
            setGrepBoxVisible(visible, focus: true)
            return
        case "file.difftool.rememberSecond":
            if let item = selectedItems().first { Self.remembered = RememberedDiffFile(item: item) }
            return
        case "file.difftool.rememberFirst":
            if let item = selectedItems().first { Self.remembered = RememberedDiffFile(firstOf: item) }
            return
        case let sort where sort.hasPrefix("sort."):
            let tag = ["sort.pathTree": 0, "sort.pathFlat": 1, "sort.extensionTree": 2, "sort.extensionFlat": 3, "sort.statusTree": 4, "sort.statusFlat": 5][sort] ?? 0
            let item = NSMenuItem()
            item.tag = tag
            chooseViewMode(item)
            return
        default: break
        }
        onCommand?(FileStatusListCommand(identifier: id, items: selectedItems(), folder: selectedFolder, tool: tool,
                                         focused: focusedItem, remembered: Self.remembered,
                                         lineNumber: ["file.edit.local", "file.blame"].contains(id) ? currentLineNumber() : nil))
    }


    private func performShortcut(_ command: String) -> Bool {
        guard mode != .plain else { return false }
        switch command {
        case "file.selectFirstGroup":
            selectItems(firstGroupItems)
            return true
        case "file.findCommit" where mode == .fileTree, "file.findCommitFileTree" where mode == .diff:
            return false
        case "file.findCommitFileTree":
            perform("file.findCommit")
            return true
        case "file.goToFirstParent", "file.goToLastParent", "file.find":
            perform(command)
            return true
        case "file.reset.first":

            let context = menuContext()
            if ChangedFileContextMenuBuilder.canResetToFirst(context) && ChangedFileContextMenuBuilder.showReset(context) { perform(command) }
            return true
        default:
            return performIfEnabled(command)
        }
    }


    @discardableResult
    func performIfEnabled(_ command: String) -> Bool {
        let menu = NSMenu()
        populateFileMenu(menu)
        guard let item = menuItem(withIdentifier: command, in: menu) else { return false }
        if item.isEnabled { perform(command) }
        return true
    }

    private func copyPaths() {
        let paths = selectedFolder.map { [$0] } ?? currentlySelectedFiles().map(\.path)
        let base = repositoryURL
        let value = paths.map { path in base.map { $0.appendingPathComponent(path).path } ?? path }.joined(separator: "\n")
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }


    private func findFile() {
        guard !isLoading else { pendingFindFile = true; return }
        guard let window = view.window else { return }
        let candidates: [ChangedFile] = mode == .plain ? plainFiles : groups.flatMap(\.files)
        let workingDirectory = repositoryURL?.path ?? ""
        FileSearchWindow.present(owner: window, candidates: { pattern in
            let predicate = FileSearchWindow.predicate(pattern, workingDirectory: workingDirectory)
            return candidates.filter { predicate($0.path) || predicate($0.oldPath) }
        }) { [weak self] file in
            guard let self else { return }
            if mode == .plain {
                selectRows { $0.path == file.path }
            } else if let item = allItems.first(where: { $0.file.id == file.id }) {
                selectItems([item])
            }
            outlineView.scrollRowToVisible(outlineView.selectedRow)
        }
    }

    private func selectAllDescendants() {
        let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }
        nodes.forEach { outlineView.expandItem($0, expandChildren: true) }
        let ids = Set(nodes.flatMap(\.descendantFiles).map(\.id))
        selectRows { ids.contains($0.id) }
    }

    private func collapseRootFolders() {
        var node = outlineView.item(atRow: outlineView.selectedRow) as? ChangedFileNode
        while let parent = node.flatMap({ outlineView.parent(forItem: $0) as? ChangedFileNode }) { node = parent }
        rootNodes.forEach { outlineView.collapseItem($0, collapseChildren: true) }
        if let node { outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: node)), byExtendingSelection: false) }
    }

    private func selectRows(_ predicate: (ChangedFile) -> Bool) {
        func visit(_ nodes: [ChangedFileNode]) -> Bool {
            var found = false
            for node in nodes {
                if let file = node.file, predicate(file) { found = true }
                if visit(node.children) {
                    outlineView.expandItem(node)
                    found = true
                }
            }
            return found
        }
        _ = visit(rootNodes)
        var rows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let file = (outlineView.item(atRow: row) as? ChangedFileNode)?.file, predicate(file) { rows.insert(row) }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outlineView.scrollRowToVisible(first) }
    }

    private func selectedNodeFiles() -> [ChangedFile] {
        var seen: Set<String> = []
        return outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ChangedFileNode }
            .flatMap(\.descendantFiles).filter { seen.insert($0.id).inserted && !($0.isStatusOnly && $0.id == Self.noChangesItem.id) }
    }

    private func selectedFileIDs() -> Set<String> { Set(selectedNodeFiles().map(\.id)) }
}


enum FileSearchWindow {

    static func predicate(_ pattern: String, workingDirectory: String) -> (String?) -> Bool {
        let directory = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
        if !directory.isEmpty, pattern.lowercased().hasPrefix(directory.lowercased()) {
            var relative = String(pattern.dropFirst(directory.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            return { $0?.lowercased().hasPrefix(relative.lowercased()) == true }
        }
        return { $0?.range(of: pattern, options: .caseInsensitive) != nil }
    }

    @MainActor
    static func present(owner: NSWindow, standalone: Bool = false, candidates: @escaping (String) -> [ChangedFile], selected: @escaping (ChangedFile) -> Void, onClose: (() -> Void)? = nil) {
        let controller = FileSearchController(candidates: candidates, selected: selected, onClose: onClose)
        let panel = (standalone ? NSWindow.self : NSPanel.self).init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Find file"
        panel.contentViewController = controller
        controller.panel = panel
        guard standalone else { owner.beginSheet(panel); return }
        panel.isReleasedWhenClosed = false
        controller.standalonePanel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        owner.orderOut(nil)
    }

    private final class FileSearchController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
        let candidates: (String) -> [ChangedFile]
        let selected: (ChangedFile) -> Void
        let onClose: (() -> Void)?
        var didClose = false
        weak var panel: NSWindow?
        var standalonePanel: NSWindow?
        private let field = NSTextField()
        private let table = NSTableView()
        private let scroll = NSScrollView()
        private var results: [ChangedFile] = []
        private var tableHeight: NSLayoutConstraint?

        init(candidates: @escaping (String) -> [ChangedFile], selected: @escaping (ChangedFile) -> Void, onClose: (() -> Void)?) {
            self.candidates = candidates
            self.selected = selected
            self.onClose = onClose
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func loadView() {
            let root = NSView()
            let label = NSTextField(labelWithString: "Enter File Name")
            field.delegate = self
            let column = NSTableColumn(identifier: .init("path"))
            table.addTableColumn(column)
            table.headerView = nil
            table.dataSource = self
            table.delegate = self
            table.doubleAction = #selector(choose)
            table.target = self
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            for view in [label, field, scroll] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(view)
            }
            let height = scroll.heightAnchor.constraint(equalToConstant: 0)
            tableHeight = height
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
                label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
                scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 2),
                scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
                height,
                scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
            ])
            view = root
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            panel?.delegate = self
            view.window?.makeFirstResponder(field)
        }

        func controlTextDidChange(_ obj: Notification) {
            results = Array(candidates(field.stringValue).prefix(20))
            table.reloadData()
            if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            tableHeight?.constant = results.isEmpty ? 0 : min(400, CGFloat(results.count + 1) * table.rowHeight)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): choose(); return true
            case #selector(NSResponder.cancelOperation(_:)): close(nil); return true
            case #selector(NSResponder.moveDown(_:)):
                if results.count > 1 { table.selectRowIndexes(IndexSet(integer: (table.selectedRow + 1) % results.count), byExtendingSelection: false) }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if results.count > 1 { table.selectRowIndexes(IndexSet(integer: (table.selectedRow - 1 + results.count) % results.count), byExtendingSelection: false) }
                return true
            default: return false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { results.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let label = NSTextField(labelWithString: results[row].path)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }

        @objc private func choose() {
            let row = table.selectedRow
            close(row >= 0 && row < results.count ? results[row] : nil)
        }

        private func close(_ file: ChangedFile?) {
            guard let panel, !didClose else { return }
            didClose = true
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
            standalonePanel = nil
            if let file { selected(file) }
            onClose?()
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool { close(nil); return true }
    }
}


final class FindInCommitFilesGitGrepWindowController: NSWindowController, NSWindowDelegate {
    private let locate: (String) -> Void
    private let toggle: (Bool) -> Void
    private let closed: () -> Void
    private let findBox = NSComboBox()
    private let optionsField = NSTextField()
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Match whole word", target: nil, action: nil)
    private let showSearchBox = NSButton(checkboxWithTitle: "Show 'Find in commit files using git-grep'", target: nil, action: nil)
    private var hasLoaded = false

    init(locate: @escaping (String) -> Void, toggle: @escaping (Bool) -> Void, closed: @escaping () -> Void) {
        self.locate = locate
        self.toggle = toggle
        self.closed = closed
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 425, height: 144), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Find in commit files using git-grep"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(panel)
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent(_ panel: NSPanel) {
        let root = NSView()
        let findLabel = NSTextField(labelWithString: "Find what:")
        let optionsLabel = NSTextField(labelWithString: "Options:")
        let find = NSButton(title: "Find", target: self, action: #selector(search))
        find.keyEquivalent = "\r"
        findBox.completes = false
        findBox.setAccessibilityIdentifier("GitGrepFindWhat")
        optionsField.target = self
        optionsField.action = #selector(optionsChanged)
        matchCase.target = self
        matchCase.action = #selector(matchCaseChanged)
        wholeWord.target = self
        wholeWord.action = #selector(wholeWordChanged)
        showSearchBox.target = self
        showSearchBox.action = #selector(showSearchBoxChanged)
        let grid = NSGridView(views: [[findLabel, findBox], [optionsLabel, optionsField], [NSGridCell.emptyContentView, NSStackView(views: [matchCase, wholeWord])]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        let bottom = NSStackView(views: [showSearchBox, NSView(), find])
        for view in [grid, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            findBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 323),
            bottom.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        panel.contentView = root
    }

    func present(owner: NSWindow, text: String?, history: [String], showSearchBox visible: Bool) {
        setHistory(history)
        if let text { findBox.stringValue = text }
        let preferences = AppSettingsStore.shared.fileStatusListPreferences
        optionsField.stringValue = preferences.gitGrepUserArguments
        matchCase.state = preferences.gitGrepIgnoreCase ? .off : .on
        wholeWord.state = preferences.gitGrepMatchWholeWord ? .on : .off
        showSearchBox.state = visible ? .on : .off
        if window?.isVisible != true, let window {

            window.setFrameTopLeftPoint(NSPoint(x: owner.frame.minX + 90, y: owner.frame.maxY - 110))
        }
        owner.addChildWindow(window!, ordered: .above)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(findBox)
        hasLoaded = true
    }

    func setHistory(_ history: [String]) {
        let text = findBox.stringValue
        findBox.removeAllItems()
        findBox.addItems(withObjectValues: history)
        findBox.stringValue = text
    }

    func setShowSearchBox(_ visible: Bool) { showSearchBox.state = visible ? .on : .off }

    @objc private func search() { locate(findBox.stringValue) }

    private func update(_ change: (inout FileStatusListPreferences) -> Void) {
        var preferences = AppSettingsStore.shared.fileStatusListPreferences
        change(&preferences)
        AppSettingsStore.shared.saveFileStatusListPreferences(preferences)
    }

    @objc private func optionsChanged() { update { $0.gitGrepUserArguments = optionsField.stringValue } }
    @objc private func matchCaseChanged() { update { $0.gitGrepIgnoreCase = matchCase.state != .on } }
    @objc private func wholeWordChanged() { update { $0.gitGrepMatchWholeWord = wholeWord.state == .on } }
    @objc private func showSearchBoxChanged() {
        update { $0.showFindInCommitFilesGitGrep = showSearchBox.state == .on }
        guard hasLoaded else { return }
        toggle(showSearchBox.state == .on)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        update { $0.gitGrepUserArguments = optionsField.stringValue }

        if findBox.stringValue.isEmpty || showSearchBox.state != .on { locate("") }
        window?.parent?.removeChildWindow(window!)
        closed()
    }
}
