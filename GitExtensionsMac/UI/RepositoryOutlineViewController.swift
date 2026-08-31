import GitExtensionsCore
import GitCommands
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
        case folder(prefix: String, isRemote: Bool)
        case tagFolder(prefix: String)
    }

    let id: String
    let title: String
    let kind: Kind
    let symbolName: String
    let toolTip: String
    var children: [RepositoryTreeNode]
    var isRevisionVisible = true
    var isMerged = false

    init(
        id: String,
        title: String,
        kind: Kind,
        symbolName: String,
        toolTip: String? = nil,
        children: [RepositoryTreeNode] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.symbolName = symbolName
        self.toolTip = toolTip ?? title
        self.children = children
    }
}

enum RepositoryTreeBuilder {
    static func build(
        references: RepositoryReferenceState,
        navigation: RepositoryNavigationState,
        preferences: RepositoryTreePreferences
    ) -> [RepositoryTreeNode] {
        let effectiveSortOrder: RepositoryTreeSortOrder = preferences.sortBy == .gitDefault
            ? .ascending
            : preferences.sortOrder
        let localBranches = buildBranchTree(
            references.branches,
            isRemote: false,
            namespace: "local",
            sortBy: preferences.sortBy,
            sortOrder: effectiveSortOrder
        )
        let branchesRoot = root(.branches, symbol: "LocalBranchRoot", children: localBranches)

        let activeRemoteNodes = prioritizedRemotes(navigation.remotes.filter { !$0.isDisabled }, order: effectiveSortOrder).map { remote in
            RepositoryTreeNode(
                id: "remote:\(remote.name)",
                title: remote.name,
                kind: .remote(remote),
                symbolName: remoteSymbol(for: remote),
                toolTip: remote.fetchURL,
                children: buildBranchTree(
                    remote.branches,
                    isRemote: true,
                    namespace: remote.name,
                    sortBy: preferences.sortBy,
                    sortOrder: effectiveSortOrder
                )
            )
        }
        let inactiveRemoteNodes = prioritizedRemotes(navigation.remotes.filter(\.isDisabled), order: effectiveSortOrder).map { remote in
            RepositoryTreeNode(
                id: "inactive-remote:\(remote.name)",
                title: remote.name,
                kind: .remote(remote),
                symbolName: "Remotes",
                toolTip: "Inactive remote\n\(remote.fetchURL)"
            )
        }
        let remoteNodes = inactiveRemoteNodes.isEmpty
            ? activeRemoteNodes
            : activeRemoteNodes + [RepositoryTreeNode(
                id: "remote-folder:inactive",
                title: "Inactive",
                kind: .folder(prefix: "", isRemote: true),
                symbolName: "FolderClosed",
                toolTip: "Inactive remotes",
                children: inactiveRemoteNodes
            )]
        let remotesRoot = root(.remotes, symbol: "RemoteBranchRoot", children: remoteNodes)

        let worktreesRoot = root(
            .worktrees,
            symbol: "WorkTree",
            children: navigation.worktrees.map { worktree in
                RepositoryTreeNode(
                    id: "worktree:\(worktree.path)",
                    title: worktree.name,
                    kind: .worktree(worktree),
                    symbolName: "WorkTree",
                    toolTip: "\(worktree.path)\(worktree.isCurrent ? " (current)" : "")\nBranch: \(worktree.branchName)"
                )
            }
        )

        let tagsRoot = root(
            .tags,
            symbol: "TagHorizontal",
            children: buildTagTree(
                references.tags,
                sortBy: preferences.sortBy,
                sortOrder: effectiveSortOrder
            )
        )

        let submodulesRoot = root(
            .submodules,
            symbol: "FolderSubmodule",
            children: navigation.submodules.map { submodule in
                let suffix: String = switch submodule.state {
                case .clean: ""
                case .uninitialized: " (not initialized)"
                case .modified: " (modified)"
                case .conflicted: " (conflict)"
                case .unknown: " (unknown)"
                }
                return RepositoryTreeNode(
                    id: "submodule:\(submodule.path)",
                    title: submodule.path + suffix,
                    kind: .submodule(submodule),
                    symbolName: submodule.state == .clean ? "FolderSubmodule" : "FileStatusModified",
                    toolTip: "\(submodule.path)\n\(submodule.state.rawValue)\(submodule.description.map { "\n\($0)" } ?? "")"
                )
            }
        )

        let stashesRoot = root(
            .stashes,
            symbol: "stash",
            children: navigation.stashes.map { stash in
                RepositoryTreeNode(
                    id: "stash:\(stash.selector)",
                    title: "\(stash.selector): \(stash.subject)",
                    kind: .stash(stash),
                    symbolName: "stash",
                    toolTip: "\(stash.selector) on \(stash.branchName)\n\(stash.subject)"
                )
            }
        )

        let roots: [RepositoryTreeRoot: RepositoryTreeNode] = [
            .branches: branchesRoot,
            .remotes: remotesRoot,
            .worktrees: worktreesRoot,
            .tags: tagsRoot,
            .submodules: submodulesRoot,
            .stashes: stashesRoot
        ]
        return preferences.rootOrder.compactMap { root in
            preferences.visibleRoots.contains(root) ? roots[root] : nil
        }
    }

    private static func root(
        _ root: RepositoryTreeRoot,
        symbol: String,
        children: [RepositoryTreeNode]
    ) -> RepositoryTreeNode {
        RepositoryTreeNode(
            id: "root:\(root.rawValue)",
            title: root.title,
            kind: .group,
            symbolName: symbol,
            children: children
        )
    }

    private static func buildBranchTree(
        _ branches: [Branch],
        isRemote: Bool,
        namespace: String,
        sortBy: RepositoryTreeSortBy,
        sortOrder: RepositoryTreeSortOrder
    ) -> [RepositoryTreeNode] {
        var roots: [RepositoryTreeNode] = []
        for branch in sortedBranches(branches, by: sortBy, order: sortOrder) {
            let parts = branch.name.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var parent: RepositoryTreeNode?
            for (index, part) in parts.enumerated() {
                let prefix = parts.prefix(index + 1).joined(separator: "/")
                if index == parts.count - 1 {
                    let aheadBehind = branch.ahead > 0 || branch.behind > 0
                        ? " (↑\(branch.ahead) ↓\(branch.behind))"
                        : ""
                    let fullName = isRemote ? "\(namespace)/\(branch.name)" : branch.name
                    let state = [
                        branch.isCurrent ? "current" : nil,
                        branch.remoteName.map { "tracks \($0)" },
                        aheadBehind.isEmpty ? nil : "ahead \(branch.ahead), behind \(branch.behind)"
                    ].compactMap { $0 }.joined(separator: ", ")
                    let node = RepositoryTreeNode(
                        id: "\(isRemote ? "remote-branch" : "branch"):\(fullName)",
                        title: part + aheadBehind,
                        kind: isRemote ? .remoteBranch(branch) : .branch(branch),
                        symbolName: isRemote ? "BranchRemote" : "BranchLocal",
                        toolTip: state.isEmpty ? fullName : "\(fullName)\n\(state)"
                    )
                    if let parent { parent.children.append(node) } else { roots.append(node) }
                } else {
                    let siblings = parent?.children ?? roots
                    let id = "\(isRemote ? "remote-folder" : "branch-folder"):\(namespace):\(prefix)"
                    if let existing = siblings.first(where: { $0.id == id }) {
                        parent = existing
                    } else {
                        let folder = RepositoryTreeNode(
                            id: id,
                            title: part,
                            kind: .folder(prefix: prefix, isRemote: isRemote),
                            symbolName: "FolderClosed",
                            toolTip: prefix
                        )
                        if let parent { parent.children.append(folder) } else { roots.append(folder) }
                        parent = folder
                    }
                }
            }
        }
        if sortBy == .alphaNumeric || sortBy == .version || sortBy == .gitDefault {
            sortRecursively(&roots, order: sortOrder, versionAware: sortBy == .version)
        }
        return roots
    }

    private static func buildTagTree(
        _ tags: [Tag],
        sortBy: RepositoryTreeSortBy,
        sortOrder: RepositoryTreeSortOrder
    ) -> [RepositoryTreeNode] {
        var roots: [RepositoryTreeNode] = []
        for tag in sortedTags(tags, by: sortBy, order: sortOrder) {
            let parts = tag.name.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var parent: RepositoryTreeNode?
            for (index, part) in parts.enumerated() {
                let prefix = parts.prefix(index + 1).joined(separator: "/")
                if index == parts.count - 1 {
                    let leaf = RepositoryTreeNode(
                        id: "tag:\(tag.name)",
                        title: part,
                        kind: .tag(tag),
                        symbolName: "TagHorizontal",
                        toolTip: "\(tag.name)\n\(tag.commitID.shortString)"
                    )
                    if let parent { parent.children.append(leaf) } else { roots.append(leaf) }
                } else {
                    let id = "tag-folder:\(prefix)"
                    let siblings = parent?.children ?? roots
                    if let existing = siblings.first(where: { $0.id == id }) {
                        parent = existing
                    } else {
                        let folder = RepositoryTreeNode(
                            id: id,
                            title: part,
                            kind: .tagFolder(prefix: prefix),
                            symbolName: "FolderClosed",
                            toolTip: prefix
                        )
                        if let parent { parent.children.append(folder) } else { roots.append(folder) }
                        parent = folder
                    }
                }
            }
        }
        if sortBy == .alphaNumeric || sortBy == .version || sortBy == .gitDefault {
            sortRecursively(&roots, order: sortOrder, versionAware: sortBy == .version)
        }
        return roots
    }

    private static func sortedBranches(
        _ branches: [Branch],
        by sortBy: RepositoryTreeSortBy,
        order: RepositoryTreeSortOrder
    ) -> [Branch] {
        branches.sorted { lhs, rhs in
            let lhsPriority = branchPriority(lhs.name)
            let rhsPriority = branchPriority(rhs.name)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return compare(
                name: lhs.name,
                metadata: lhs.sortMetadata,
                remote: lhs.remoteName,
                toName: rhs.name,
                metadata: rhs.sortMetadata,
                remote: rhs.remoteName,
                by: sortBy,
                order: order
            )
        }
    }

    private static func sortedTags(
        _ tags: [Tag],
        by sortBy: RepositoryTreeSortBy,
        order: RepositoryTreeSortOrder
    ) -> [Tag] {
        tags.sorted { lhs, rhs in
            compare(
                name: lhs.name,
                metadata: lhs.sortMetadata,
                remote: nil,
                toName: rhs.name,
                metadata: rhs.sortMetadata,
                remote: nil,
                by: sortBy,
                order: order
            )
        }
    }

    private static func compare(
        name lhsName: String,
        metadata lhs: RepositoryReferenceSortMetadata,
        remote lhsRemote: String?,
        toName rhsName: String,
        metadata rhs: RepositoryReferenceSortMetadata,
        remote rhsRemote: String?,
        by sortBy: RepositoryTreeSortBy,
        order: RepositoryTreeSortOrder
    ) -> Bool {
        let result: ComparisonResult = switch sortBy {
        case .gitDefault, .alphaNumeric:
            lhsName.caseInsensitiveCompare(rhsName)
        case .version:
            lhsName.localizedStandardCompare(rhsName)
        case .originatingRemote:
            compareOptionalStrings(lhsRemote, rhsRemote, fallbackLeft: lhsName, fallbackRight: rhsName)
        case .authorDate:
            compareOptionalIntegers(lhs.authorDate, rhs.authorDate, fallbackLeft: lhsName, fallbackRight: rhsName)
        case .committerDate:
            compareOptionalIntegers(lhs.committerDate, rhs.committerDate, fallbackLeft: lhsName, fallbackRight: rhsName)
        case .creatorDate:
            compareOptionalIntegers(lhs.creatorDate, rhs.creatorDate, fallbackLeft: lhsName, fallbackRight: rhsName)
        case .taggerDate:
            compareOptionalIntegers(lhs.taggerDate, rhs.taggerDate, fallbackLeft: lhsName, fallbackRight: rhsName)
        case .objectSize:
            compareOptionalIntegers(lhs.objectSize, rhs.objectSize, fallbackLeft: lhsName, fallbackRight: rhsName)
        }
        return order == .ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private static func compareOptionalIntegers(
        _ lhs: Int64?,
        _ rhs: Int64?,
        fallbackLeft: String,
        fallbackRight: String
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs: lhs < rhs ? .orderedAscending : .orderedDescending
        case (_?, nil): .orderedAscending
        case (nil, _?): .orderedDescending
        default: fallbackLeft.caseInsensitiveCompare(fallbackRight)
        }
    }

    private static func compareOptionalStrings(
        _ lhs: String?,
        _ rhs: String?,
        fallbackLeft: String,
        fallbackRight: String
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs: lhs.caseInsensitiveCompare(rhs)
        case (_?, nil): .orderedAscending
        case (nil, _?): .orderedDescending
        default: fallbackLeft.caseInsensitiveCompare(fallbackRight)
        }
    }

    private static func branchPriority(_ name: String) -> Int {
        if name.range(of: #"^main[^/]*$"#, options: .regularExpression) != nil { return 0 }
        if name.range(of: #"^master[^/]*$"#, options: .regularExpression) != nil { return 1 }
        if name.hasPrefix("release/") { return 2 }
        return 3
    }

    private static func prioritizedRemotes(
        _ remotes: [Remote],
        order: RepositoryTreeSortOrder
    ) -> [Remote] {
        sorted(remotes, by: \.name, order: order).sorted { lhs, rhs in
            let priorities = ["origin": 0, "upstream": 1]
            let lhsPriority = priorities[lhs.name] ?? 2
            let rhsPriority = priorities[rhs.name] ?? 2
            return lhsPriority == rhsPriority ? false : lhsPriority < rhsPriority
        }
    }

    private static func sorted<T>(
        _ values: [T],
        by keyPath: KeyPath<T, String>,
        order: RepositoryTreeSortOrder
    ) -> [T] {
        values.sorted { lhs, rhs in
            let result = lhs[keyPath: keyPath].localizedStandardCompare(rhs[keyPath: keyPath])
            return order == .ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func sortRecursively(
        _ nodes: inout [RepositoryTreeNode],
        order: RepositoryTreeSortOrder,
        versionAware: Bool
    ) {
        nodes.sort {
            let lhsPriority = nodePriority($0)
            let rhsPriority = nodePriority($1)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let result = versionAware
                ? $0.title.localizedStandardCompare($1.title)
                : $0.title.caseInsensitiveCompare($1.title)
            return order == .ascending ? result == .orderedAscending : result == .orderedDescending
        }
        for node in nodes { sortRecursively(&node.children, order: order, versionAware: versionAware) }
    }

    private static func nodePriority(_ node: RepositoryTreeNode) -> Int {
        switch node.kind {
        case .branch(let branch): branchPriority(branch.name)
        case .folder(let prefix, false): branchPriority(prefix + "/")
        default: 3
        }
    }

    private static func remoteSymbol(for remote: Remote) -> String {
        let url = remote.fetchURL.lowercased()
        if url.contains("github.com") { return "GitHub" }
        if url.contains("bitbucket.") { return "BitBucket" }
        if url.contains("visualstudio.com") || url.contains("dev.azure.com") { return "VisualStudioTeamServices" }
        return "Remotes"
    }
}

enum RepositoryTreeStateResolver {
    static func survivingIDs(_ requested: Set<String>, in roots: [RepositoryTreeNode]) -> Set<String> {
        func collect(_ node: RepositoryTreeNode) -> Set<String> {
            node.children.reduce(into: Set([node.id])) { result, child in
                result.formUnion(collect(child))
            }
        }
        let available = roots.reduce(into: Set<String>()) { result, root in
            result.formUnion(collect(root))
        }
        return requested.intersection(available)
    }
}

private final class RepositoryOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class RepositoryOutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    var onSelection: ((RepositoryTreeNode) -> Void)?
    var onCommand: ((String, RepositoryTreeNode) -> Void)?
    var onFilterReferences: (([String]) -> Void)?

    private let outlineView = RepositoryOutlineView()
    private let searchField = NSSearchField()
    private var allRoots: [RepositoryTreeNode] = []
    private var visibleRoots: [RepositoryTreeNode] = []
    private var isFiltering = false
    private var isBareRepository = false
    private var menuFocusedNode: RepositoryTreeNode?
    private var repositoryReferences: RepositoryReferenceState?
    private var repositoryNavigation: RepositoryNavigationState?
    private var expandedBeforeFiltering = Set<String>()
    private var selectedBeforeFiltering = Set<String>()
    private var hasAppliedRepositoryState = false

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
        let rootButtons: [(RepositoryTreeRoot, String)] = [
            (.branches, "LocalBranchRoot"),
            (.remotes, "RemoteBranchRoot"),
            (.worktrees, "WorkTree"),
            (.tags, "TagHorizontal"),
            (.submodules, "FolderSubmodule"),
            (.stashes, "stash")
        ]
        let treePreferences = AppSettingsStore.shared.repositoryTreePreferences
        for (index, item) in rootButtons.enumerated() {
            let button = AppKitFactory.resourceButton(item.1, tooltip: item.0.title, width: 29, target: self, action: #selector(toggleRootVisibility(_:)))
            button.tag = index
            let isVisible = treePreferences.visibleRoots.contains(item.0)
            button.state = isVisible ? .on : .off
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
        outlineView.target = self
        outlineView.doubleAction = #selector(openSelectedNode)
        outlineView.intercellSpacing = .zero
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.onReturn = { [weak self] in self?.openSelectedNodeFromKeyboard() }

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

    func apply(
        identity: RepositoryIdentityState,
        references: RepositoryReferenceState,
        navigation: RepositoryNavigationState
    ) {
        repositoryReferences = references
        repositoryNavigation = navigation
        isBareRepository = identity.currentRepository.isBare
        rebuildTree(preservingExpansion: hasAppliedRepositoryState)
        hasAppliedRepositoryState = true
    }

    @objc private func collapseAll() {
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    @objc private func toggleRootVisibility(_ sender: NSButton) {
        guard RepositoryTreeRoot.allCases.indices.contains(sender.tag) else { return }
        let root = RepositoryTreeRoot.allCases[sender.tag]
        var treePreferences = AppSettingsStore.shared.repositoryTreePreferences
        if sender.state == .on { treePreferences.visibleRoots.insert(root) }
        else { treePreferences.visibleRoots.remove(root) }
        AppSettingsStore.shared.saveRepositoryTreePreferences(treePreferences)
        if root == .stashes {
            var preferences = AppSettingsStore.shared.stashPreferences
            preferences.showStashesInRepositoryTree = sender.state == .on
            AppSettingsStore.shared.saveStashPreferences(preferences)
        } else if root == .tags {
            var preferences = AppSettingsStore.shared.tagPreferences
            preferences.showTagsInRepositoryTree = sender.state == .on
            AppSettingsStore.shared.saveTagPreferences(preferences)
        }
        rebuildTree(preservingExpansion: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        let criterion = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let willFilter = !criterion.isEmpty
        if willFilter && !isFiltering {
            expandedBeforeFiltering = expandedNodeIDs()
            selectedBeforeFiltering = selectedNodeIDs()
        }
        isFiltering = willFilter
        applyTreeFilter(preservingExpansion: true)
    }

    private func rebuildTree(preservingExpansion: Bool) {
        guard let repositoryReferences, let repositoryNavigation else { return }
        let expanded = preservingExpansion ? expandedNodeIDs() : []
        let selected = preservingExpansion ? selectedNodeIDs() : []
        var preferences = AppSettingsStore.shared.repositoryTreePreferences
        preferences.normalize()
        allRoots = RepositoryTreeBuilder.build(
            references: repositoryReferences,
            navigation: repositoryNavigation,
            preferences: preferences
        )
        applyTreeFilter(
            preservingExpansion: preservingExpansion,
            expandedIDs: expanded,
            selectedIDs: selected
        )
    }

    private func applyTreeFilter(
        preservingExpansion: Bool,
        expandedIDs: Set<String>? = nil,
        selectedIDs: Set<String>? = nil
    ) {
        let criterion = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleRoots = criterion.isEmpty
            ? allRoots
            : allRoots.compactMap { filteredCopy(of: $0, matching: criterion) }
        outlineView.reloadData()
        if isFiltering {
            visibleRoots.forEach { outlineView.expandItem($0, expandChildren: true) }
            restoreSelection(selectedIDs ?? selectedBeforeFiltering)
        } else if !expandedBeforeFiltering.isEmpty || !selectedBeforeFiltering.isEmpty {
            restore(expandedIDs: expandedBeforeFiltering, selectedIDs: selectedBeforeFiltering)
            expandedBeforeFiltering.removeAll()
            selectedBeforeFiltering.removeAll()
        } else if preservingExpansion {
            restore(expandedIDs: expandedIDs ?? [], selectedIDs: selectedIDs ?? [])
        } else {
            applyInitialExpansionAndSelection()
        }
    }

    private func filteredCopy(of node: RepositoryTreeNode, matching criterion: String) -> RepositoryTreeNode? {
        let matchingChildren = node.children.compactMap { filteredCopy(of: $0, matching: criterion) }
        guard node.title.localizedCaseInsensitiveContains(criterion) || !matchingChildren.isEmpty else { return nil }
        let copy = RepositoryTreeNode(
            id: node.id,
            title: node.title,
            kind: node.kind,
            symbolName: node.symbolName,
            toolTip: node.toolTip,
            children: matchingChildren
        )
        copy.isRevisionVisible = node.isRevisionVisible
        copy.isMerged = node.isMerged
        return copy
    }

    private func applyInitialExpansionAndSelection() {
        for root in visibleRoots {
            switch root.id {
            case "root:branches", "root:remotes": outlineView.expandItem(root)
            case "root:worktrees" where root.children.count > 1: outlineView.expandItem(root)
            case "root:submodules": outlineView.expandItem(root, expandChildren: true)
            default: break
            }
        }
        if let branches = visibleRoots.first(where: { $0.id == "root:branches" }) {
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

    private func restore(expandedIDs: Set<String>, selectedIDs: Set<String>) {
        let expandedIDs = RepositoryTreeStateResolver.survivingIDs(expandedIDs, in: visibleRoots)
        let selectedIDs = RepositoryTreeStateResolver.survivingIDs(selectedIDs, in: visibleRoots)
        for id in expandedIDs {
            if let node = node(withID: id) {
                expandAncestors(of: node)
                outlineView.expandItem(node)
            }
        }
        restoreSelection(selectedIDs)
        if outlineView.selectedRowIndexes.isEmpty,
           let current = allNodes().first(where: {
               if case .branch(let branch) = $0.kind { return branch.isCurrent }
               return false
           }) {
            selectNode(current)
        }
    }

    private func restoreSelection(_ ids: Set<String>) {
        let rows = IndexSet(ids.compactMap { id in
            guard let node = node(withID: id) else { return nil }
            expandAncestors(of: node)
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        })
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    private func expandedNodeIDs() -> Set<String> {
        Set(allNodes().filter { outlineView.isItemExpanded($0) }.map(\.id))
    }

    private func selectedNodeIDs() -> Set<String> {
        Set(outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? RepositoryTreeNode)?.id
        })
    }

    private func allNodes() -> [RepositoryTreeNode] {
        func flatten(_ node: RepositoryTreeNode) -> [RepositoryTreeNode] {
            [node] + node.children.flatMap(flatten)
        }
        return visibleRoots.flatMap(flatten)
    }

    private func node(withID id: String) -> RepositoryTreeNode? {
        allNodes().first(where: { $0.id == id })
    }

    private func selectNode(_ node: RepositoryTreeNode) {
        expandAncestors(of: node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func expandAncestors(of target: RepositoryTreeNode) {
        for root in visibleRoots where expandAncestors(of: target, beneath: root) { return }
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
        let symbolName: String = switch node.kind {
        case .branch where node.isMerged: "BranchLocalMerged"
        case .remoteBranch where node.isMerged: "BranchRemoteMerged"
        case .branch, .remoteBranch, .tag, .stash where !node.isRevisionVisible: "EyeClosed"
        case .remote(let remote) where remote.isDisabled: "EyeClosed"
        default: node.symbolName
        }
        let image = AppKitFactory.resourceImage(symbolName, accessibilityDescription: node.title)
            ?? NSImage(systemSymbolName: symbolName, accessibilityDescription: node.title)
        image?.isTemplate = false
        cell.imageView?.image = image
        cell.imageView?.contentTintColor = nil
        cell.toolTip = node.toolTip

        switch node.kind {
        case .branch(let branch) where branch.isCurrent:
            cell.textField?.font = .boldSystemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
        case .worktree(let worktree) where worktree.isCurrent:
            cell.textField?.font = .boldSystemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
        case .branch, .remoteBranch, .tag, .stash where !node.isRevisionVisible:
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .tertiaryLabelColor
        case .remote(let remote) where remote.isDisabled:
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
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
            selectedHaveCollapsibleChildren: parents.contains { outlineView.isItemExpanded($0) },
            isBareRepository: isBareRepository,
            focusedRootCanMoveUp: rootIndex(of: node).map { $0 > 0 } ?? false,
            focusedRootCanMoveDown: rootIndex(of: node).map { $0 < allRoots.count - 1 } ?? false
        )
        populatePlaceholderMenu(menu, with: RepositoryContextMenuBuilder.build(context))
        menuFocusedNode = node
        let mutationCommands: Set<String> = [
            "repository.branch.checkout",
            "repository.branch.create",
            "repository.branch.rename",
            "repository.branch.delete",
            "repository.branch.push",
            "repository.branch.merge",
            "repository.remoteBranch.checkout",
            "repository.remoteBranch.create",
            "repository.remoteBranch.fetch",
            "repository.remoteBranch.fetchCheckout",
            "repository.remoteBranch.fetchCreate",
            "repository.remoteBranch.merge",
            "repository.remoteBranch.delete",
            "repository.tag.checkout",
            "repository.tag.createBranch",
            "repository.folder.create",
            "repository.folder.deleteAll",
            "repository.tag.merge",
            "repository.branch.rebase",
            "repository.remoteBranch.rebase",
            "repository.tag.rebase",
            "repository.tag.delete",
            "repository.stash.apply",
            "repository.stash.pop",
            "repository.stash.drop",
            "repository.stash.open",
            "repository.stashes.create",
            "repository.stashes.staged",
            "repository.stashes.manage",
            "repository.copy",
            "repository.filter",
            "repository.expand",
            "repository.collapse",
            "repository.root.moveUp",
            "repository.root.moveDown",
            "repository.sortOrder.ascending",
            "repository.sortOrder.descending",
            "repository.worktree.copyPath",
            "repository.worktree.show"
        ]
        retargetMenuItems(
            in: menu,
            where: { mutationCommands.contains($0) || $0.hasPrefix("repository.sortBy.") },
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue, let menuFocusedNode else { return }
        switch identifier {
        case "repository.copy", "repository.worktree.copyPath":
            copyToClipboard(menuFocusedNode.copyValue)
            return
        case "repository.filter":
            let references = outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? RepositoryTreeNode)?.referenceName
            }
            onFilterReferences?(references)
            return
        case "repository.expand":
            selectedNodes().forEach { outlineView.expandItem($0, expandChildren: true) }
            return
        case "repository.collapse":
            selectedNodes().forEach { outlineView.collapseItem($0, collapseChildren: true) }
            return
        case "repository.root.moveUp":
            moveRoot(menuFocusedNode, offset: -1)
            return
        case "repository.root.moveDown":
            moveRoot(menuFocusedNode, offset: 1)
            return
        case "repository.sortOrder.ascending":
            setSortOrder(.ascending)
            return
        case "repository.sortOrder.descending":
            setSortOrder(.descending)
            return
        case "repository.worktree.show":
            if case .worktree(let worktree) = menuFocusedNode.kind {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
            }
            return
        default:
            let sortPrefix = "repository.sortBy."
            if identifier.hasPrefix(sortPrefix),
               let sortBy = RepositoryTreeSortBy(rawValue: String(identifier.dropFirst(sortPrefix.count))) {
                setSortBy(sortBy)
                return
            }
            break
        }
        onCommand?(identifier, menuFocusedNode)
    }

    private func selectedNodes() -> [RepositoryTreeNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? RepositoryTreeNode }
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func rootIndex(of node: RepositoryTreeNode) -> Int? {
        allRoots.firstIndex(where: { $0.id == node.id })
    }

    private func moveRoot(_ node: RepositoryTreeNode, offset: Int) {
        guard let root = node.repositoryTreeRoot else { return }
        var preferences = AppSettingsStore.shared.repositoryTreePreferences
        guard let index = preferences.rootOrder.firstIndex(of: root) else { return }
        let destination = index + offset
        guard preferences.rootOrder.indices.contains(destination) else { return }
        preferences.rootOrder.swapAt(index, destination)
        AppSettingsStore.shared.saveRepositoryTreePreferences(preferences)
        rebuildTree(preservingExpansion: true)
    }

    private func setSortOrder(_ order: RepositoryTreeSortOrder) {
        var preferences = AppSettingsStore.shared.repositoryTreePreferences
        preferences.sortOrder = order
        AppSettingsStore.shared.saveRepositoryTreePreferences(preferences)
        rebuildTree(preservingExpansion: true)
    }

    private func setSortBy(_ sortBy: RepositoryTreeSortBy) {
        var preferences = AppSettingsStore.shared.repositoryTreePreferences
        preferences.sortBy = sortBy
        AppSettingsStore.shared.saveRepositoryTreePreferences(preferences)
        rebuildTree(preservingExpansion: true)
    }

    @objc private func openSelectedNode() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? RepositoryTreeNode else { return }
        performDefaultAction(for: node)
    }

    private func openSelectedNodeFromKeyboard() {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? RepositoryTreeNode else { return }
        performDefaultAction(for: node)
    }

    private func performDefaultAction(for node: RepositoryTreeNode) {
        switch node.kind {
        case .branch:
            guard !isBareRepository else { return }
            onCommand?("repository.branch.checkout", node)
        case .remoteBranch:
            guard !isBareRepository else { return }
            onCommand?("repository.remoteBranch.checkout", node)
        case .tag:
            guard !isBareRepository else { return }
            onCommand?("repository.tag.createBranch", node)
        case .stash:
            guard !isBareRepository else { return }
            onCommand?("repository.stash.open", node)
        case .remote:
            onCommand?("repository.remote.manage", node)
        default:
            break
        }
    }

    func updateRevisionState(revisions: [Commit], selectedRevisionID: RevisionID?) {
        let visible = Set(revisions.map(\.id))
        let commitsByID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        var ancestors = Set<RevisionID>()
        var pending = selectedRevisionID.map { [$0] } ?? []
        while let id = pending.popLast() {
            guard ancestors.insert(id).inserted else { continue }
            pending.append(contentsOf: commitsByID[id]?.graphParentIDs ?? [])
        }
        for node in allNodes() {
            guard let objectID = node.objectID else { continue }
            let revisionID = RevisionID.object(objectID)
            node.isRevisionVisible = visible.contains(revisionID)
            switch node.kind {
            case .branch, .remoteBranch:
                node.isMerged = ancestors.contains(revisionID) && revisionID != selectedRevisionID
            default:
                node.isMerged = false
            }
        }
        outlineView.reloadData()
    }

    func select(reference: RevisionReference) {
        let node = allNodes().first { candidate in
            switch (reference.kind, candidate.kind) {
            case (.currentBranch, .branch(let branch)), (.localBranch, .branch(let branch)):
                return branch.name == reference.name
            case (.remoteBranch, .remoteBranch(let branch)):
                let fullName = branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
                return fullName == reference.name
            case (.tag, .tag(let tag)):
                return tag.name == reference.name
            case (.stash, .stash(let stash)):
                return stash.selector == reference.name
            default:
                return false
            }
        }
        if let node { selectNode(node) }
    }
}

private extension RepositoryTreeNode {
    var menuKind: RepositoryMenuNodeKind {
        switch kind {
        case .group:
            return .group(RepositoryMenuNodeKind.Group(rawValue: title) ?? .other)
        case .branch(let branch):
            return .localBranch(isCurrent: branch.isCurrent)
        case .remote(let remote):
            let normalizedURL = remote.fetchURL.lowercased()
            return .remote(
                enabled: !remote.isDisabled,
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
        case .folder(_, let isRemote):
            return isRemote ? .remoteBranchFolder : .branchFolder
        case .tagFolder:
            return .tagFolder
        }
    }

    var repositoryTreeRoot: RepositoryTreeRoot? {
        guard id.hasPrefix("root:") else { return nil }
        return RepositoryTreeRoot(rawValue: String(id.dropFirst("root:".count)))
    }

    var objectID: ObjectID? {
        switch kind {
        case .branch(let branch), .remoteBranch(let branch): branch.commitID
        case .tag(let tag): tag.commitID
        case .stash(let stash): stash.commitID
        default: nil
        }
    }

    var referenceName: String? {
        switch kind {
        case .branch(let branch): branch.name
        case .remoteBranch(let branch): branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
        case .tag(let tag): tag.name
        case .stash(let stash): stash.selector
        default: nil
        }
    }

    var copyValue: String {
        switch kind {
        case .worktree(let worktree): worktree.path
        default: referenceName ?? title
        }
    }
}
