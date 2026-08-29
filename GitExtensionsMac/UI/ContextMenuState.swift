import GitExtensionsCore
import GitCommands
import Foundation

indirect enum ContextMenuEntry: Hashable, Sendable {
    case command(id: String, title: String, isEnabled: Bool)
    case submenu(id: String, title: String, isEnabled: Bool, children: [ContextMenuEntry])
    case separator

    var id: String? {
        switch self {
        case .command(let id, _, _), .submenu(let id, _, _, _): id
        case .separator: nil
        }
    }

    var isEnabled: Bool {
        switch self {
        case .command(_, _, let isEnabled), .submenu(_, _, let isEnabled, _): isEnabled
        case .separator: false
        }
    }

    var children: [ContextMenuEntry] {
        guard case .submenu(_, _, _, let children) = self else { return [] }
        return children
    }
}

extension Array where Element == ContextMenuEntry {
    func normalizedMenuSeparators() -> [ContextMenuEntry] {
        var result: [ContextMenuEntry] = []
        for entry in self {
            if case .separator = entry {
                guard !result.isEmpty, result.last != .separator else { continue }
            }
            result.append(entry)
        }
        while result.last == .separator { result.removeLast() }
        return result
    }

    func entry(id: String) -> ContextMenuEntry? {
        for entry in self {
            if entry.id == id { return entry }
            if let nested = entry.children.entry(id: id) { return nested }
        }
        return nil
    }
}

private func command(_ id: String, _ title: String, enabled: Bool = true) -> ContextMenuEntry {
    .command(id: id, title: title, isEnabled: enabled)
}

private func submenu(
    _ id: String,
    _ title: String,
    children: [ContextMenuEntry],
    enabled: Bool? = nil
) -> ContextMenuEntry {
    let normalized = children.normalizedMenuSeparators()
    return .submenu(
        id: id,
        title: title,
        isEnabled: enabled ?? normalized.contains(where: \.isEnabled),
        children: normalized
    )
}

struct RevisionContextMenuContext: Sendable {
    let focusedCommit: Commit
    let selectedCommits: [Commit]
    let history: [Commit]
    let currentBranchName: String?
    var isBisecting = false
    var isBareRepository = false
    var isCherryPicking = false
    var cherryPickHasConflicts = false
    var isRebasing = false
    var rebaseHasConflicts = false
}

enum RevisionContextMenuBuilder {
    static func build(_ context: RevisionContextMenuContext) -> [ContextMenuEntry] {
        let revision = context.focusedCommit
        let selected = context.selectedCommits.isEmpty ? [revision] : context.selectedCommits
        let refs = revision.references
        let localBranches = refs.filter { $0.kind == .currentBranch || $0.kind == .localBranch }
        let remoteBranches = refs.filter { $0.kind == .remoteBranch }
        let tags = refs.filter { $0.kind == .tag }
        let stashes = refs.filter { $0.kind == .stash }
        let allBranches = localBranches + remoteBranches
        let currentBranchPointsHere = localBranches.contains {
            $0.kind == .currentBranch || $0.name == context.currentBranchName
        }
        let checkoutBranches = allBranches.filter {
            $0.kind != .currentBranch && $0.name != context.currentBranchName
        }
        let deletableBranches = localBranches.filter {
            $0.kind != .currentBranch && $0.name != context.currentBranchName
        } + remoteBranches
        let mergeRefs = (tags + allBranches).filter {
            $0.kind != .currentBranch && $0.name != context.currentBranchName
        }
        let rebaseTargetExists = !revision.isArtificial
            && !context.isBareRepository
            && (!mergeRefs.isEmpty || !currentBranchPointsHere)
        let hasParentComparison = selected.count > 1 || !revision.parentIDs.isEmpty
        let selectedCount = selected.count

        var entries: [ContextMenuEntry] = []

        if context.isCherryPicking {
            entries += [
                command("revision.cherryPick.continue", "Continue cherry-pick", enabled: !context.cherryPickHasConflicts),
                command("revision.cherryPick.abort", "Abort cherry-pick…"),
                .separator
            ]
        }

        if context.isRebasing {
            entries += [
                command("revision.rebase.continue", "Continue rebase", enabled: !context.rebaseHasConflicts),
                command("revision.rebase.skip", "Skip current patch"),
                command("revision.rebase.abort", "Abort rebase…"),
                .separator
            ]
        }

        if context.isBisecting {
            entries += [
                command("revision.bisect.bad", "Mark revision as bad"),
                command("revision.bisect.good", "Mark revision as good"),
                command("revision.bisect.skip", "Skip revision"),
                command("revision.bisect.stop", "Stop bisect"),
                .separator
            ]
        }

        entries.append(copyMenu(selected))
        entries.append(.separator)

        if !stashes.isEmpty && !context.isBareRepository {
            entries += [
                command("revision.stash.apply", "Apply stash"),
                command("revision.stash.pop", "Pop stash"),
                command("revision.stash.drop", "Drop stash…"),
                .separator
            ]
        }

        if !checkoutBranches.isEmpty && !context.isBareRepository {
            entries.append(refSubmenu(
                id: "revision.branch.checkout",
                title: "Checkout branch…",
                refs: checkoutBranches
            ))
        }
        if !localBranches.isEmpty && !context.isBareRepository {
            entries.append(refSubmenu(
                id: "revision.branch.push",
                title: "Push branch…",
                refs: localBranches
            ))
        }
        if !revision.isArtificial,
           !context.isBareRepository,
           (!mergeRefs.isEmpty || !currentBranchPointsHere) {
            let targets = mergeRefs.isEmpty
                ? [command("revision.branch.merge.commit", revision.shortID)]
                : refCommands(prefix: "revision.branch.merge", refs: mergeRefs)
            entries.append(submenu("revision.branch.merge", "Merge into current branch…", children: targets))
        }
        if rebaseTargetExists {
            entries.append(submenu(
                "revision.branch.rebase",
                "Rebase current branch on",
                children: [
                    command("revision.branch.rebase.selected", "Selected commit", enabled: selectedCount == 1),
                    command("revision.branch.rebase.interactive", "Selected commit interactively…", enabled: selectedCount == 1),
                    .separator,
                    command(
                        "revision.branch.rebase.advanced",
                        "Selected commit with advanced options…",
                        enabled: (selectedCount == 1 || selectedCount == 2) && selected.allSatisfy { !$0.isArtificial }
                    )
                ]
            ))
        }
        if !context.isBareRepository {
            entries.append(command("revision.branch.resetCurrent", "Reset current branch to here…"))
        }
        entries.append(.separator)

        if !revision.isArtificial && !context.isBareRepository {
            entries.append(command("revision.branch.create", "Create new branch here…"))
            entries.append(command("revision.branch.resetOther", "Reset another branch to here…"))
        }
        if !localBranches.isEmpty {
            entries.append(refSubmenu(
                id: "revision.branch.rename",
                title: "Rename branch…",
                refs: localBranches
            ))
        }
        if !allBranches.isEmpty && !context.isBareRepository {
            if deletableBranches.isEmpty {
                entries.append(command("revision.branch.delete", "Delete branch…", enabled: false))
            } else {
                entries.append(refSubmenu(
                    id: "revision.branch.delete",
                    title: "Delete branch…",
                    refs: deletableBranches
                ))
            }
        }
        entries.append(.separator)

        entries.append(command("revision.tag.create", "Create new tag here…"))
        if !tags.isEmpty {
            entries.append(refSubmenu(id: "revision.tag.delete", title: "Delete tag…", refs: tags))
        }
        entries.append(.separator)

        if !context.isBareRepository {
            entries += [
                command("revision.commit.checkout", "Checkout this commit…"),
                command("revision.commit.revert", "Revert this commit…"),
                command(
                    "revision.commit.cherryPick",
                    "Cherry pick this commit…",
                    enabled: !revision.isArtificial && selected.allSatisfy { !$0.isArtificial }
                )
            ]
        }
        entries.append(command("revision.commit.archive", "Archive this commit…"))
        if !context.isBareRepository {
            entries.append(submenu(
                "revision.commit.advanced",
                "Advanced",
                children: [
                    command("revision.commit.edit", "Edit commit", enabled: selectedCount == 1),
                    command("revision.commit.reword", "Reword commit", enabled: selectedCount == 1),
                    command("revision.commit.fixup", "Create a fixup commit…", enabled: selectedCount == 1),
                    command("revision.commit.squash", "Create a squash commit…", enabled: selectedCount == 1),
                    command("revision.commit.amend", "Create an amend commit…", enabled: selectedCount == 1),
                    command("revision.commit.advancedHelp", "Get help on how to use these features")
                ]
            ))
        }
        entries.append(.separator)

        entries.append(submenu(
            "revision.compare",
            "Compare",
            children: [
                command("revision.compare.difftool", "Open selected commits with difftool", enabled: hasParentComparison),
                .separator,
                command("revision.compare.branch", "Compare to branch…"),
                command("revision.compare.current", "Compare with current branch", enabled: context.currentBranchName != nil),
                command("revision.compare.setBase", "Select as BASE to compare", enabled: selectedCount == 1),
                command("revision.compare.base", "Compare to BASE", enabled: false),
                command("revision.compare.worktree", "Compare to working directory"),
                command("revision.compare.selected", "Compare selected commits", enabled: hasParentComparison)
            ]
        ))
        entries.append(.separator)

        entries.append(navigateMenu(context))
        if !refs.isEmpty {
            entries.append(refSubmenu(id: "revision.selectInLeftPanel", title: "Select in left panel", refs: refs))
        }
        entries.append(submenu(
            "revision.view",
            "View",
            children: [
                command("revision.view.commit", "View commit"),
                command("revision.view.details", "View commit details"),
                command("revision.view.diff", "View diff"),
                command("revision.view.fileTree", "View file tree")
            ]
        ))
        entries.append(command("revision.script", "Run script", enabled: false))
        entries.append(submenu(
            "revision.other",
            "Other actions",
            children: [
                command("revision.other.createPatch", "Create patch…"),
                command("revision.other.formatPatch", "Format patch…"),
                command("revision.other.reflog", "Show reflog"),
                command("revision.other.object", "Show object information")
            ]
        ))

        return entries.normalizedMenuSeparators()
    }

    private static func copyMenu(_ selected: [Commit]) -> ContextMenuEntry {
        let hasRefs = selected.contains { !$0.references.isEmpty }
        return submenu(
            "revision.copy",
            "Copy to clipboard",
            children: [
                command("revision.copy.id", "Copy commit ID"),
                command("revision.copy.message", "Copy commit message"),
                command("revision.copy.author", "Copy author"),
                command("revision.copy.refs", "Copy branch or tag name", enabled: hasRefs),
                command("revision.copy.information", "Copy commit information")
            ]
        )
    }

    private static func navigateMenu(_ context: RevisionContextMenuContext) -> ContextMenuEntry {
        let commit = context.focusedCommit
        let children = context.history.filter { $0.graphParentIDs.contains(commit.id) }
        return submenu(
            "revision.navigate",
            "Navigate",
            children: [
                command("revision.navigate.child", "Go to child commit", enabled: !children.isEmpty),
                command("revision.navigate.parent", "Go to parent commit", enabled: !commit.parentIDs.isEmpty),
                command("revision.navigate.firstParent", "Go to first parent commit", enabled: !commit.parentIDs.isEmpty),
                command("revision.navigate.lastParent", "Go to last parent commit", enabled: commit.parentIDs.count > 1),
                command("revision.navigate.mergeBase", "Go to common ancestor (merge base)", enabled: !context.selectedCommits.isEmpty),
                .separator,
                command("revision.navigate.current", "Go to current revision", enabled: context.currentBranchName != nil),
                command("revision.navigate.commit", "Go to commit…")
            ]
        )
    }

    private static func refSubmenu(
        id: String,
        title: String,
        refs: [RevisionReference]
    ) -> ContextMenuEntry {
        submenu(id, title, children: refCommands(prefix: id, refs: refs))
    }

    private static func refCommands(prefix: String, refs: [RevisionReference]) -> [ContextMenuEntry] {
        var seen = Set<String>()
        return refs.compactMap { reference in
            guard seen.insert(reference.id).inserted else { return nil }
            return command("\(prefix).ref.\(reference.id)", reference.name)
        }
    }
}

enum RevisionNavigationResolver {
    static func childID(of commit: Commit, in history: [Commit]) -> RevisionID? {
        history.first(where: { $0.graphParentIDs.contains(commit.id) })?.id
    }

    static func parentID(of commit: Commit, last: Bool = false) -> RevisionID? {
        (last ? commit.parentIDs.last : commit.parentIDs.first).map(RevisionID.object)
    }

    static func mergeBaseID(
        selectedCommits: [Commit],
        history: [Commit],
        headCommit: Commit?
    ) -> RevisionID? {
        var selected = selectedCommits
        if selected.count == 1,
           let headCommit,
           headCommit.id != selected[0].id {
            selected.append(headCommit)
        }
        guard !selected.isEmpty else { return nil }

        let commitsByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        let ancestorSets = selected.map { commit -> Set<RevisionID> in
            var ancestors = Set<RevisionID>()
            var pending = [commit.id]
            while let id = pending.popLast() {
                guard ancestors.insert(id).inserted else { continue }
                pending.append(contentsOf: commitsByID[id]?.graphParentIDs ?? [])
            }
            return ancestors
        }
        guard var common = ancestorSets.first else { return nil }
        for ancestors in ancestorSets.dropFirst() { common.formIntersection(ancestors) }
        return history.first(where: { common.contains($0.id) })?.id
    }
}

enum RepositoryMenuNodeKind: Hashable, Sendable {
    enum Group: String, Hashable, Sendable {
        case branches = "Branches"
        case remotes = "Remotes"
        case worktrees = "Worktrees"
        case tags = "Tags"
        case submodules = "Submodules"
        case stashes = "Stashes"
        case other
    }

    case group(Group)
    case localBranch(isCurrent: Bool)
    case remote(enabled: Bool, hasHTTPURL: Bool)
    case remoteBranch
    case tag
    case stash
    case worktree(isCurrent: Bool, pathExists: Bool)
    case submodule
    case branchFolder
    case remoteBranchFolder

    var isRef: Bool {
        switch self {
        case .localBranch, .remoteBranch, .tag: true
        default: false
        }
    }

    var supportsCopy: Bool {
        switch self {
        case .localBranch, .remoteBranch, .stash: true
        default: false
        }
    }
}

struct RepositoryContextMenuContext: Sendable {
    let focused: RepositoryMenuNodeKind
    let selected: [RepositoryMenuNodeKind]
    let selectedHaveChildren: Bool
    let selectedHaveExpandableChildren: Bool
    let selectedHaveCollapsibleChildren: Bool
    var isBareRepository = false
}

enum RepositoryContextMenuBuilder {
    static func build(_ context: RepositoryContextMenuContext) -> [ContextMenuEntry] {
        let selection = context.selected.isEmpty ? [context.focused] : context.selected
        let isSingle = selection.count == 1
        var entries: [ContextMenuEntry] = []

        if isSingle && context.focused.supportsCopy {
            entries.append(command("repository.copy", "Copy to clipboard"))
        }
        if selection.contains(where: \.isRef) {
            entries.append(command("repository.filter", "Filter for selected"))
        }
        if !entries.isEmpty { entries.append(.separator) }

        if isSingle {
            entries += commands(for: context.focused, isBareRepository: context.isBareRepository)
        }

        if context.selectedHaveChildren {
            entries += [
                .separator,
                command("repository.expand", "Expand all", enabled: context.selectedHaveExpandableChildren),
                command("repository.collapse", "Collapse all", enabled: context.selectedHaveCollapsibleChildren)
            ]
        }

        if isSingle && context.focused.isRef {
            entries += [
                .separator,
                submenu("repository.sortBy", "Sort by", children: [
                    command("repository.sortBy.name", "Name"),
                    command("repository.sortBy.date", "Commit date"),
                    command("repository.sortBy.author", "Author")
                ]),
                submenu("repository.sortOrder", "Sort order", children: [
                    command("repository.sortOrder.ascending", "Ascending"),
                    command("repository.sortOrder.descending", "Descending")
                ])
            ]
        }

        if isSingle, case .localBranch = context.focused {
            entries.append(command("repository.script", "Run script", enabled: false))
        }

        return entries.normalizedMenuSeparators()
    }

    private static func commands(
        for kind: RepositoryMenuNodeKind,
        isBareRepository: Bool
    ) -> [ContextMenuEntry] {
        switch kind {
        case .localBranch(let isCurrent):
            if isCurrent {
                return [
                    command("repository.branch.create", "Create branch…", enabled: !isBareRepository),
                    .separator,
                    command("repository.branch.rename", "Rename branch…")
                ]
            }
            let canMoveHEAD = !isCurrent && !isBareRepository
            return [
                command("repository.branch.checkout", "Checkout branch…", enabled: canMoveHEAD),
                command("repository.branch.merge", "Merge into current branch…", enabled: canMoveHEAD),
                command("repository.branch.rebase", "Rebase current branch on this branch…", enabled: canMoveHEAD),
                command("repository.branch.create", "Create branch…", enabled: !isBareRepository),
                command("repository.branch.reset", "Reset current branch to here…", enabled: canMoveHEAD),
                .separator,
                command("repository.branch.rename", "Rename branch…"),
                command("repository.branch.delete", "Delete branch…", enabled: canMoveHEAD)
            ]

        case .remote(let enabled, let hasHTTPURL):
            return [
                command("repository.remote.manage", "Manage…"),
                command("repository.remote.fetch", "Fetch all branches", enabled: enabled),
                command("repository.remote.prune", "Fetch and prune branches", enabled: enabled),
                command("repository.remote.openURL", "Open remote URL in browser", enabled: hasHTTPURL),
                command("repository.remote.disable", "Disable remote", enabled: enabled),
                command("repository.remote.enable", "Enable remote", enabled: !enabled),
                command("repository.remote.enableFetch", "Enable remote and fetch", enabled: !enabled)
            ]

        case .remoteBranch:
            return [
                command("repository.remoteBranch.checkout", "Checkout remote branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.merge", "Merge into current branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.rebase", "Rebase current branch on this remote branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.create", "Create branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.reset", "Reset current branch to here…", enabled: !isBareRepository),
                .separator,
                command("repository.remoteBranch.fetch", "Fetch branch"),
                command("repository.remoteBranch.pull", "Pull from remote branch", enabled: !isBareRepository),
                command("repository.remoteBranch.fetchCheckout", "Fetch and checkout", enabled: !isBareRepository),
                command("repository.remoteBranch.fetchCreate", "Fetch and create branch", enabled: !isBareRepository),
                command("repository.remoteBranch.fetchRebase", "Fetch and rebase", enabled: !isBareRepository),
                .separator,
                command("repository.remoteBranch.delete", "Delete remote branch…")
            ]

        case .tag:
            return [
                command("repository.tag.checkout", "Checkout tag revision…", enabled: !isBareRepository),
                command("repository.tag.merge", "Merge into current branch…", enabled: !isBareRepository),
                command("repository.tag.rebase", "Rebase current branch on this tag revision…", enabled: !isBareRepository),
                command("repository.tag.createBranch", "Create branch…", enabled: !isBareRepository),
                command("repository.tag.reset", "Reset current branch to here…", enabled: !isBareRepository),
                .separator,
                command("repository.tag.delete", "Delete tag…")
            ]

        case .stash:
            return [
                command("repository.stash.open", "Open stash", enabled: !isBareRepository),
                command("repository.stash.apply", "Apply stash", enabled: !isBareRepository),
                command("repository.stash.pop", "Pop stash", enabled: !isBareRepository),
                command("repository.stash.drop", "Drop stash…", enabled: !isBareRepository)
            ]

        case .worktree(let isCurrent, let pathExists):
            return [
                command("repository.worktree.open", "Open worktree", enabled: !isCurrent),
                command("repository.worktree.delete", "Delete worktree…", enabled: !isCurrent),
                command("repository.worktree.copyPath", "Copy worktree path"),
                command("repository.worktree.show", "Show worktree in Finder", enabled: pathExists)
            ]

        case .submodule:
            return [
                command("repository.submodule.open", "Open submodule"),
                command("repository.submodule.openGE", "Open in Git Extensions"),
                command("repository.submodule.update", "Update submodule"),
                command("repository.submodule.synchronize", "Synchronize submodule", enabled: !isBareRepository),
                command("repository.submodule.reset", "Reset submodule", enabled: !isBareRepository),
                command("repository.submodule.stash", "Stash submodule", enabled: !isBareRepository),
                command("repository.submodule.commit", "Commit submodule", enabled: !isBareRepository)
            ]

        case .branchFolder:
            return [
                command("repository.folder.create", "Create branch…", enabled: !isBareRepository),
                command("repository.folder.deleteAll", "Delete all branches…", enabled: !isBareRepository)
            ]

        case .remoteBranchFolder:
            return []

        case .group(let group):
            switch group {
            case .remotes:
                return [
                    command("repository.remotes.manage", "Manage…"),
                    command("repository.remotes.fetch", "Fetch all remotes"),
                    command("repository.remotes.prune", "Fetch and prune all remotes")
                ]
            case .stashes:
                return [
                    command("repository.stashes.create", "Stash", enabled: !isBareRepository),
                    command("repository.stashes.staged", "Stash staged", enabled: !isBareRepository),
                    command("repository.stashes.manage", "Manage stashes…", enabled: !isBareRepository)
                ]
            case .worktrees:
                return [
                    command("repository.worktrees.create", "Create worktree…"),
                    command("repository.worktrees.prune", "Prune worktrees"),
                    command("repository.worktrees.manage", "Manage worktrees…")
                ]
            default:
                return []
            }
        }
    }
}

enum ChangedFileSelectionScope: Hashable, Sendable {
    case revision
    case workingTree
    case index
}

struct ChangedFileContextMenuContext: Sendable {
    let selectedFiles: [ChangedFile]
    let scope: ChangedFileSelectionScope
    var isDisplayOnlyDiff = false
    var isStatusOnly = false
    var isBareRepository = false
    var supportPatches = true
    var allFilesExist: Bool
    var anySubmodule = false
    var anyTracked = true
}

enum ChangedFileContextMenuBuilder {
    static func build(_ context: ChangedFileContextMenuContext) -> [ContextMenuEntry] {
        let count = context.selectedFiles.count
        guard count > 0 else { return [] }

        let isSingle = count == 1
        let anyDeleted = context.selectedFiles.contains { $0.changeType == .deleted }
        let isWorktree = context.scope == .workingTree
        let isIndex = context.scope == .index
        let isRevision = context.scope == .revision
        let supportsManipulation = !context.isBareRepository && !context.isDisplayOnlyDiff
        let canReset = supportsManipulation && context.anyTracked
            && !(context.anySubmodule && isSingle && isWorktree)
        let canPatch = context.supportPatches && isSingle && !isWorktree
        let canOpenLocal = isSingle && context.allFilesExist
        let canOpenRevision = isSingle && !context.anySubmodule
            && !context.isDisplayOnlyDiff && isRevision
        let canHistory = isSingle && context.anyTracked

        var entries: [ContextMenuEntry] = []

        if isWorktree {
            entries.append(command("file.stage", "Stage selected"))
            entries.append(command("file.stageAll", "Stage all"))
        }
        if isIndex {
            entries.append(command("file.unstage", "Unstage selected"))
            entries.append(command("file.unstageAll", "Unstage all"))
        }
        if canReset {
            entries.append(submenu(
                "file.reset",
                "Reset file(s) to",
                children: [
                    command("file.reset.first", "First revision"),
                    command("file.reset.selected", "Selected revision", enabled: isRevision)
                ]
            ))
        }
        if isWorktree && isSingle && !context.anySubmodule {
            entries.append(command("file.resetChunk", "Reset chunk of file…"))
            entries.append(command("file.interactiveAdd", "Interactive add…"))
        }
        if canPatch {
            entries.append(command("file.cherryPick", "Cherry pick changes"))
        }
        entries.append(.separator)

        entries.append(command(
            "file.difftool",
            "Open with difftool",
            enabled: !context.isDisplayOnlyDiff
        ))
        if canOpenLocal {
            entries.append(command("file.open.local", "Open working directory file"))
            entries.append(command("file.open.localWith", "Open working directory file with…"))
            entries.append(command("file.edit.local", "Edit working directory file"))
        }
        if canOpenRevision {
            entries.append(command("file.open.revision", "Open this revision (temp file)"))
            entries.append(command("file.open.revisionWith", "Open this revision with… (temp file)"))
        }
        entries.append(.separator)

        if !context.anySubmodule && isRevision && !context.isDisplayOnlyDiff {
            entries.append(command("file.save", "Save selected as…"))
        }
        if (isSingle && context.anyTracked && !context.anySubmodule) {
            entries.append(command("file.move", "Move…"))
        }
        if isWorktree && context.allFilesExist {
            entries.append(command("file.delete", count == 1 ? "Delete file" : "Delete files"))
        }
        entries.append(.separator)

        entries.append(command("file.copyPaths", "Copy paths", enabled: !context.isStatusOnly))
        entries.append(command("file.showFinder", "Show in Finder", enabled: context.allFilesExist && !context.isStatusOnly))
        if isSingle && context.anyTracked && !anyDeleted {
            entries.append(command("file.showFileTree", "Show in File tree"))
        }
        entries.append(command("file.filterGrid", "Filter file in grid", enabled: canHistory))
        entries.append(command("file.history", "File history", enabled: canHistory))
        entries.append(command("file.blame", "Blame", enabled: canHistory && !context.anySubmodule))
        entries.append(command("file.find", "Find file"))
        entries.append(command("file.findCommit", "Find in commit files"))

        if isWorktree && !context.anySubmodule {
            entries += [
                .separator,
                command("file.ignore.gitignore", "Add file to .gitignore"),
                command("file.ignore.exclude", "Add file to .git/info/exclude")
            ]
            if context.anyTracked {
                entries.append(command("file.skipWorktree", "Skip worktree"))
                entries.append(command("file.assumeUnchanged", "Assume unchanged"))
            }
        }
        if isSingle && context.anyTracked {
            entries += [
                .separator,
                command("file.stopTracking", "Stop tracking this file")
            ]
        }

        entries += [
            .separator,
            command("file.script", "Run script", enabled: false)
        ]

        return entries.normalizedMenuSeparators()
    }
}
