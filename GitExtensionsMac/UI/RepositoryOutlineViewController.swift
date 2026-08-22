import AppKit

final class RepositoryTreeNode: NSObject {
    enum Kind {
        case group
        case branch(Branch)
        case remote(Remote)
        case remoteBranch(Branch)
        case tag(Tag)
        case stash(Stash)
        case worktree(Worktree)
        case submodule(Submodule)
        case folder
    }

    let title: String
    let kind: Kind
    let symbolName: String
    var children: [RepositoryTreeNode]

    init(title: String, kind: Kind, symbolName: String, children: [RepositoryTreeNode] = []) {
        self.title = title
        self.kind = kind
        self.symbolName = symbolName
        self.children = children
    }
}

final class RepositoryOutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    var onSelection: ((RepositoryTreeNode) -> Void)?
    var onCommand: ((String, RepositoryTreeNode) -> Void)?

    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private var allRoots: [RepositoryTreeNode] = []
    private var visibleRoots: [RepositoryTreeNode] = []
    private var hiddenRootTitles: Set<String> = []
    private var isFiltering = false
    private var menuFocusedNode: RepositoryTreeNode?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = AppKitFactory.toolbarBackground()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let toolbarStack = NSStackView()
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 1
        toolbarStack.alignment = .centerY
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        let collapse = AppKitFactory.resourceButton("CollapseAll", tooltip: "Collapse all", width: 29, target: self, action: #selector(collapseAll))
        toolbarStack.addArrangedSubview(collapse)
        for (index, item) in [
            ("LocalBranchRoot", "Branches"),
            ("RemoteBranchRoot", "Remotes"),
            ("WorkTree", "Worktrees"),
            ("TagHorizontal", "Tags"),
            ("FolderSubmodule", "Submodules"),
            ("stash", "Stashes")
        ].enumerated() {
            let button = AppKitFactory.resourceButton(item.0, tooltip: item.1, width: 29, target: self, action: #selector(toggleRootVisibility(_:)))
            button.tag = index
            button.state = .on
            button.setButtonType(.toggle)
            toolbarStack.addArrangedSubview(button)
        }
        toolbar.addSubview(toolbarStack)

        searchField.placeholderString = "Search"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.bezelStyle = .squareBezel
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RepositoryObject"))
        column.title = "Repository objects"
        column.minWidth = 180
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 18
        outlineView.indentationPerLevel = 19
        outlineView.style = .plain
        outlineView.focusRingType = .none
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.intercellSpacing = .zero
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.delegate = self
        outlineView.dataSource = self

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(searchField)
        root.addSubview(scrollView)

        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 27)
        toolbarHeight.priority = .defaultHigh
        let searchHeight = searchField.heightAnchor.constraint(equalToConstant: 26)
        searchHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarHeight,

            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 3),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            searchField.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchHeight,

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
    }

    func apply(snapshot: RepositorySnapshot) {
        let localBranches = buildBranchTree(snapshot.branches, isRemote: false)
        let branchesRoot = RepositoryTreeNode(title: "Branches", kind: .group, symbolName: "LocalBranchRoot", children: localBranches)

        let remoteNodes = snapshot.remotes.map { remote in
            RepositoryTreeNode(
                title: remote.name,
                kind: .remote(remote),
                symbolName: "Remotes",
                children: buildBranchTree(remote.branches, isRemote: true)
            )
        }
        let remotesRoot = RepositoryTreeNode(title: "Remotes", kind: .group, symbolName: "RemoteBranchRoot", children: remoteNodes)

        let worktreesRoot = RepositoryTreeNode(
            title: "Worktrees",
            kind: .group,
            symbolName: "WorkTree",
            children: snapshot.worktrees.map {
                RepositoryTreeNode(
                    title: $0.name,
                    kind: .worktree($0),
                    symbolName: "WorkTree"
                )
            }
        )

        let tagsRoot = RepositoryTreeNode(
            title: "Tags",
            kind: .group,
            symbolName: "TagHorizontal",
            children: snapshot.tags.map { RepositoryTreeNode(title: $0.name, kind: .tag($0), symbolName: "Tag") }
        )

        let submoduleRoot = RepositoryTreeNode(
            title: "Submodules",
            kind: .group,
            symbolName: "FolderSubmodule",
            children: snapshot.submodules.map { submodule in
                let suffix: String = switch submodule.state {
                case .clean: ""
                case .uninitialized: " (not initialized)"
                case .modified: " (modified)"
                case .conflicted: " (conflict)"
                case .unknown: " (unknown)"
                }
                return RepositoryTreeNode(
                    title: submodule.path + suffix,
                    kind: .submodule(submodule),
                    symbolName: "FolderSubmodule"
                )
            }
        )

        let stashesRoot = RepositoryTreeNode(
            title: "Stashes",
            kind: .group,
            symbolName: "stash",
            children: snapshot.stashes.map {
                RepositoryTreeNode(title: "\($0.selector): \($0.subject)", kind: .stash($0), symbolName: "stash")
            }
        )

        allRoots = [branchesRoot, remotesRoot, worktreesRoot, tagsRoot, submoduleRoot, stashesRoot]
        visibleRoots = allRoots
        reloadAndExpand()
    }

    private func buildBranchTree(_ branches: [Branch], isRemote: Bool) -> [RepositoryTreeNode] {
        var roots: [RepositoryTreeNode] = []

        for branch in branches {
            let parts = branch.name.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }

            var children = roots
            var parent: RepositoryTreeNode?
            for (index, part) in parts.enumerated() {
                let isLeaf = index == parts.count - 1
                if isLeaf {
                    let suffix: String
                    if branch.isCurrent {
                        suffix = branch.ahead > 0 || branch.behind > 0 ? " (↑\(branch.ahead) ↓\(branch.behind))" : ""
                    } else if branch.ahead > 0 || branch.behind > 0 {
                        suffix = " (↑\(branch.ahead) ↓\(branch.behind))"
                    } else {
                        suffix = ""
                    }
                    let node = RepositoryTreeNode(
                        title: part + suffix,
                        kind: isRemote ? .remoteBranch(branch) : .branch(branch),
                        symbolName: isRemote ? "BranchRemote" : "BranchLocal"
                    )
                    if let parent {
                        parent.children.append(node)
                    } else {
                        roots.append(node)
                    }
                } else {
                    let existing = children.first { $0.title == part && $0.isFolder }
                    let folder = existing ?? RepositoryTreeNode(title: part, kind: .folder, symbolName: "FolderClosed")
                    if existing == nil {
                        if let parent {
                            parent.children.append(folder)
                        } else {
                            roots.append(folder)
                        }
                    }
                    parent = folder
                    children = folder.children
                }
            }
        }
        return roots
    }

    @objc private func collapseAll() {
        outlineView.collapseItem(nil, collapseChildren: true)
        BrowserCommandCenter.perform(.showStatus("Collapsed repository objects"))
    }

    @objc private func toggleRootVisibility(_ sender: NSButton) {
        let rootTitles = ["Branches", "Remotes", "Worktrees", "Tags", "Submodules", "Stashes"]
        guard sender.tag >= 0, sender.tag < rootTitles.count else { return }
        let title = rootTitles[sender.tag]
        if sender.state == .on {
            hiddenRootTitles.remove(title)
        } else {
            hiddenRootTitles.insert(title)
        }
        applyTreeFilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        let criterion = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isFiltering = !criterion.isEmpty
        applyTreeFilter()
    }

    private func applyTreeFilter() {
        let criterion = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabledRoots = allRoots.filter { !hiddenRootTitles.contains($0.title) }
        visibleRoots = criterion.isEmpty
            ? enabledRoots
            : enabledRoots.compactMap { filteredCopy(of: $0, matching: criterion) }
        reloadAndExpand()
    }

    private func filteredCopy(of node: RepositoryTreeNode, matching criterion: String) -> RepositoryTreeNode? {
        let matchingChildren = node.children.compactMap { filteredCopy(of: $0, matching: criterion) }
        guard node.title.localizedCaseInsensitiveContains(criterion) || !matchingChildren.isEmpty else { return nil }
        return RepositoryTreeNode(title: node.title, kind: node.kind, symbolName: node.symbolName, children: matchingChildren)
    }

    private func reloadAndExpand() {
        outlineView.reloadData()
        if isFiltering {
            visibleRoots.forEach { outlineView.expandItem($0, expandChildren: true) }
            return
        }

        if let branches = visibleRoots.first(where: { $0.title == "Branches" }) {
            outlineView.expandItem(branches)
            if let current = firstNode(in: branches, matching: { node in
                if case .branch(let branch) = node.kind { return branch.isCurrent }
                return false
            }) {
                expandAncestors(of: current, beneath: branches)
                let row = outlineView.row(forItem: current)
                if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
        }
    }

    private func firstNode(in node: RepositoryTreeNode, matching predicate: (RepositoryTreeNode) -> Bool) -> RepositoryTreeNode? {
        if predicate(node) { return node }
        for child in node.children {
            if let match = firstNode(in: child, matching: predicate) { return match }
        }
        return nil
    }

    @discardableResult
    private func expandAncestors(of target: RepositoryTreeNode, beneath node: RepositoryTreeNode) -> Bool {
        if node === target { return true }
        for child in node.children where expandAncestors(of: target, beneath: child) {
            outlineView.expandItem(node)
            return true
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? RepositoryTreeNode)?.children.count ?? visibleRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? RepositoryTreeNode)?.children[index] ?? visibleRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? RepositoryTreeNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        GitExtensionsSelectionRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? RepositoryTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RepositoryTreeCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = node.title
        let image = AppKitFactory.resourceImage(node.symbolName, accessibilityDescription: node.title)
            ?? NSImage(systemSymbolName: node.symbolName, accessibilityDescription: node.title)
        image?.isTemplate = false
        cell.imageView?.image = image
        cell.imageView?.contentTintColor = nil

        switch node.kind {
        case .branch(let branch) where branch.isCurrent:
            cell.textField?.font = .boldSystemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
        case .worktree(let worktree) where worktree.isCurrent:
            cell.textField?.font = .boldSystemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
        case .remoteBranch:
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
        case .tag:
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
        default:
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = image
        cell.textField = text
        cell.addSubview(image)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 3),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? RepositoryTreeNode else { return }
        onSelection?(node)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? RepositoryTreeNode else {
            menu.removeAllItems()
            return
        }
        if !outlineView.selectedRowIndexes.contains(outlineView.clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.clickedRow), byExtendingSelection: false)
        }

        let selectedNodes = outlineView.selectedRowIndexes.compactMap { index in
            outlineView.item(atRow: index) as? RepositoryTreeNode
        }
        let parents = selectedNodes.filter { !$0.children.isEmpty }
        let context = RepositoryContextMenuContext(
            focused: node.menuKind,
            selected: selectedNodes.map(\.menuKind),
            selectedHaveChildren: !parents.isEmpty,
            selectedHaveExpandableChildren: parents.contains { !outlineView.isItemExpanded($0) },
            selectedHaveCollapsibleChildren: parents.contains { outlineView.isItemExpanded($0) }
        )
        populatePlaceholderMenu(menu, with: RepositoryContextMenuBuilder.build(context))
        menuFocusedNode = node
        let mutationCommands: Set<String> = [
            "repository.branch.checkout",
            "repository.branch.push",
            "repository.remoteBranch.checkout",
            "repository.remoteBranch.delete",
            "repository.tag.checkout",
            "repository.branch.rebase",
            "repository.remoteBranch.rebase",
            "repository.tag.rebase",
            "repository.stash.apply",
            "repository.stash.pop",
            "repository.stash.drop",
            "repository.stashes.create",
            "repository.stashes.staged"
        ]
        retargetMenuItems(in: menu, where: { mutationCommands.contains($0) }, target: self, action: #selector(performMenuCommand(_:)))
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue, let menuFocusedNode else { return }
        onCommand?(identifier, menuFocusedNode)
    }
}

private extension RepositoryTreeNode {
    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var menuKind: RepositoryMenuNodeKind {
        switch kind {
        case .group:
            return .group(RepositoryMenuNodeKind.Group(rawValue: title) ?? .other)
        case .branch(let branch):
            return .localBranch(isCurrent: branch.isCurrent)
        case .remote(let remote):
            let normalizedURL = remote.fetchURL.lowercased()
            return .remote(
                enabled: true,
                hasHTTPURL: normalizedURL.hasPrefix("http://") || normalizedURL.hasPrefix("https://")
            )
        case .remoteBranch:
            return .remoteBranch
        case .tag:
            return .tag
        case .stash:
            return .stash
        case .worktree(let worktree):
            return .worktree(
                isCurrent: worktree.isCurrent,
                pathExists: FileManager.default.fileExists(atPath: worktree.path)
            )
        case .submodule:
            return .submodule
        case .folder:
            return .folder
        }
    }
}
