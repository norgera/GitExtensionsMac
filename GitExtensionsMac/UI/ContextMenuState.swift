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
    var buildStatus: BuildInfo?
    var hasComparisonBase = false

    var clickedReference: RevisionReference?

    var refFocused = false

    var scripts: [(id: String, title: String, direct: Bool)] = []

    var gridMenuState = RevisionGridMenuModel.State()
}


enum RevisionContextMenuBuilder {
    static func build(_ context: RevisionContextMenuContext) -> [ContextMenuEntry] {
        let revision = context.focusedCommit
        let selected = context.selectedCommits.isEmpty ? [revision] : context.selectedCommits
        let bareOrArtificial = context.isBareRepository || revision.isArtificial

        let refs = revision.references.filter { context.clickedReference == nil || $0.id == context.clickedReference?.id }
        let allBranches = refs.filter { [.currentBranch, .localBranch, .remoteBranch].contains($0.kind) }
        let localBranches = allBranches.filter { $0.kind != .remoteBranch }
        let tags = refs.filter { $0.kind == .tag }
        let noIdenticalRemotes = allBranches.filter { branch in
            branch.kind != .remoteBranch || !localBranches.contains { $0.tracks(branch) }
        }
        func isCurrent(_ reference: RevisionReference) -> Bool {
            reference.kind == .currentBranch || (reference.kind == .localBranch && reference.name == context.currentBranchName)
        }
        let currentBranchPointsToRevision = !revision.isArtificial && noIdenticalRemotes.contains(where: isCurrent)
        let isHeadOfCurrentBranch = localBranches.contains(where: isCurrent)
        let selectedCount = selected.count

        var top: [(ContextMenuEntry, Bool)] = []
        func add(_ entry: ContextMenuEntry, advanced: Bool = false) { top.append((entry, advanced)) }

        if revision.isArtificial {
            add(command("revision.artificial.resetChanges", "Reset changes"))
            add(command("revision.artificial.commit", "Commit"))
        }
        if context.isCherryPicking {
            add(command("revision.cherryPick.continue", "Continue cherry-pick", enabled: !context.cherryPickHasConflicts))
            add(command("revision.cherryPick.abort", "Abort cherry-pick…"))
            add(.separator)
        }
        if context.isRebasing {
            add(command("revision.rebase.continue", "Continue rebase", enabled: !context.rebaseHasConflicts))
            add(command("revision.rebase.skip", "Skip current patch"))
            add(command("revision.rebase.abort", "Abort rebase…"))
            add(.separator)
        }
        if context.isBisecting {
            add(command("revision.bisect.bad", "Mark revision as bad", enabled: !revision.isArtificial))
            add(command("revision.bisect.good", "Mark revision as good", enabled: !revision.isArtificial))
            add(command("revision.bisect.skip", "Skip revision", enabled: !revision.isArtificial))
            add(command("revision.bisect.stop", "Stop bisect"))
        }
        add(.separator)
        if !revision.isArtificial { add(copyMenu(selected, filter: context.clickedReference)) }
        add(.separator)
        if !bareOrArtificial && revision.references.contains(where: { $0.kind == .stash }) {
            add(command("revision.stash.apply", "Apply stash"))
            add(command("revision.stash.pop", "Pop stash"))
            add(command("revision.stash.drop", "Drop stash…"))
        }
        add(.separator)

        if !bareOrArtificial {

            let checkout = allBranches.filter { !isCurrent($0) }
            let locals = checkout.filter { $0.kind != .remoteBranch }, remotes = checkout.filter { $0.kind == .remoteBranch }
            let checkoutItems = refCommands(prefix: "revision.branch.checkout", refs: locals)
                + (locals.isEmpty || remotes.isEmpty ? [] : [.separator])
                + refCommands(prefix: "revision.branch.checkout", refs: remotes)
            if !checkoutItems.isEmpty { add(submenu("revision.branch.checkout", "Checkout branch…", children: checkoutItems)) }
            if !localBranches.isEmpty { add(refSubmenu(id: "revision.branch.push", title: "Push branch…", refs: localBranches)) }
            var mergeItems = refCommands(prefix: "revision.branch.merge", refs: tags + noIdenticalRemotes.filter { !isCurrent($0) })
            if mergeItems.isEmpty && !currentBranchPointsToRevision {
                mergeItems = [command("revision.branch.merge.commit", revision.id.description)]
            }
            if !mergeItems.isEmpty { add(submenu("revision.branch.merge", "Merge into current branch…", children: mergeItems)) }

            let canRebase = !currentBranchPointsToRevision
            add(submenu("revision.branch.rebase", "Rebase current branch on", children: [
                command("revision.branch.rebase.selected", "Selected commit", enabled: canRebase && selectedCount == 1),
                command("revision.branch.rebase.interactive", "Selected commit interactively…", enabled: canRebase && selectedCount == 1),
                .separator,
                command("revision.branch.rebase.advanced", "Selected commit with advanced options…",
                        enabled: canRebase && (selectedCount == 1 || (selectedCount == 2 && selected.allSatisfy { !$0.isArtificial })))
            ], enabled: true))
            add(command("revision.branch.resetCurrent", "Reset current branch to here…"))
        }
        add(.separator)

        let leftPanelRefs = tags + allBranches
        if leftPanelRefs.count == 1 {
            add(command("revision.selectInLeftPanel.ref.\(leftPanelRefs[0].id)", "Select in left panel"))
        } else if leftPanelRefs.count > 1 {
            add(refSubmenu(id: "revision.selectInLeftPanel", title: "Select in left panel", refs: leftPanelRefs))
        }
        if !bareOrArtificial {
            add(command("revision.branch.create", "Create new branch here…"))
            add(command("revision.branch.resetOther", "Reset another branch to here…"), advanced: true)
        }
        if !localBranches.isEmpty { add(refSubmenu(id: "revision.branch.rename", title: "Rename branch…", refs: localBranches)) }
        let deleteLocals = localBranches.filter { !isCurrent($0) }, deleteRemotes = allBranches.filter { $0.kind == .remoteBranch }
        let deleteItems = refCommands(prefix: "revision.branch.delete", refs: deleteLocals)
            + (deleteLocals.isEmpty || deleteRemotes.isEmpty ? [] : [.separator])
            + refCommands(prefix: "revision.branch.delete", refs: deleteRemotes)
        if !deleteItems.isEmpty && !context.isBareRepository {
            add(submenu("revision.branch.delete", "Delete branch…", children: deleteItems))
        } else if isHeadOfCurrentBranch {
            add(command("revision.branch.delete", "Delete branch…", enabled: false))
        }
        add(.separator)
        if !revision.isArtificial { add(command("revision.tag.create", "Create new tag here…"), advanced: true) }
        if !tags.isEmpty { add(refSubmenu(id: "revision.tag.delete", title: "Delete tag…", refs: tags)) }

        add(.separator, advanced: true)
        let realSelection = selected.allSatisfy { !$0.isArtificial }
        if !bareOrArtificial {
            add(command("revision.commit.checkout", "Checkout this commit…"), advanced: true)
            add(command("revision.commit.revert", "Revert this commit…", enabled: realSelection), advanced: true)
            add(command("revision.commit.cherryPick", "Cherry pick this commit…", enabled: realSelection), advanced: true)
        }
        if !revision.isArtificial {
            add(command("revision.commit.archive", "Archive this commit…", enabled: (1...2).contains(selectedCount) && realSelection), advanced: true)

            add(command("revision.other.formatPatch", "Format patch…", enabled: !context.isBareRepository && realSelection), advanced: true)
        }
        if !bareOrArtificial {
            add(submenu("revision.commit.advanced", "Advanced", children: [
                command("revision.commit.edit", "Edit commit", enabled: selectedCount == 1),
                command("revision.commit.reword", "Reword commit", enabled: selectedCount == 1),
                command("revision.commit.fixup", "Create a fixup commit…", enabled: selectedCount == 1),
                command("revision.commit.squash", "Create a squash commit…", enabled: selectedCount == 1),
                command("revision.commit.amend", "Create an amend commit…", enabled: selectedCount == 1),
                command("revision.commit.advancedHelp", "Get help on how to use these features")
            ]), advanced: true)
        }
        add(.separator)
        add(compareMenu(context, selected: selected))
        add(.separator, advanced: true)
        add(modelSubmenu("revision.navigate", "Navigate", RevisionGridMenuModel.navigate(context.gridMenuState)), advanced: true)
        add(modelSubmenu("revision.view", "View", RevisionGridMenuModel.view(context.gridMenuState)), advanced: true)
        let hostScripts = context.scripts.filter { !$0.direct }
        if !hostScripts.isEmpty {
            add(submenu("revision.script", "Run script", children: hostScripts.map { command("revision.script.run.\($0.id)", $0.title) }))
        }
        for script in context.scripts where script.direct { add(command("revision.script.run.\(script.id)", script.title)) }
        if context.buildStatus?.url != nil { add(command("revision.buildReport", "View build report in a browser"), advanced: true) }
        if context.buildStatus?.pullRequestURL != nil { add(command("revision.pullRequestPage", "View pull request in a browser"), advanced: true) }

        guard context.refFocused else { return top.map(\.0).normalizedMenuSeparators() }
        let other = top.filter(\.1).map(\.0).normalizedMenuSeparators()
        var entries = top.filter { !$0.1 }.map(\.0)
        if !other.isEmpty { entries.append(submenu("revision.otherActions", "Other actions", children: other)) }
        return entries.normalizedMenuSeparators()
    }


    static func copyMenu(_ selected: [Commit], filter: RevisionReference? = nil) -> ContextMenuEntry {
        let refs = selected.flatMap(\.references).filter { filter == nil || $0.id == filter?.id }
        let branchNames = refs.filter { [.currentBranch, .localBranch, .remoteBranch].contains($0.kind) }.map(\.name)
        let tagNames = refs.filter { $0.kind == .tag }.map(\.name)
        var children: [ContextMenuEntry] = []
        var number = 0
        func numbered(_ name: String) -> String {
            number += 1
            return number > 10 ? name : "\(number % 10):   \(name)"
        }
        if !branchNames.isEmpty {
            children.append(command("revision.copy.caption.branches", "Branches", enabled: false))
            children += branchNames.map { command("revision.copy.value.\($0)", numbered($0)) }
            children.append(.separator)
        }
        if !tagNames.isEmpty {
            children.append(command("revision.copy.caption.tags", "Tags", enabled: false))
            children += tagNames.map { command("revision.copy.value.\($0)", numbered($0)) }
            children.append(.separator)
        }
        let count = selected.count
        func item(_ id: String, _ title: String, _ values: [String]) {
            children.append(command(id, "\(title):   \(copyPreview(values))"))
        }
        item("revision.copy.hash", count == 1 ? "Commit hash" : "Commit hashes", copyValues(selected, \.id.description))
        item("revision.copy.message", count == 1 ? "Message" : "Messages", copyValues(selected) { $0.body.isEmpty ? $0.subject : $0.subject + "\n" + $0.body })
        item("revision.copy.author", count == 1 ? "Author" : "Authors", copyValues(selected) { "\($0.authorName) <\($0.authorEmail)>" })
        if count == 1 && selected[0].authorDate == selected[0].commitDate {
            item("revision.copy.date", "Date", copyValues(selected) { copyDate($0.authorDate) })
        } else {
            item("revision.copy.authorDate", count == 1 ? "Author date" : "Author dates", copyValues(selected) { copyDate($0.authorDate) })
            item("revision.copy.commitDate", count == 1 ? "Commit date" : "Commit dates", copyValues(selected) { copyDate($0.commitDate) })
        }
        return submenu("revision.copy", "Copy to clipboard", children: children, enabled: true)
    }


    static func copyValues(_ selected: [Commit], _ extract: (Commit) -> String) -> [String] {
        var seen = Set<String>()
        return selected.map(extract).filter { seen.insert($0).inserted }
    }

    static func copyPreview(_ values: [String]) -> String {
        let text = values.map { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
            .joined(separator: ", ")
        return text.count > 40 ? String(text.prefix(37)) + "..." : text
    }
    static func copyDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }


    private static func compareMenu(_ context: RevisionContextMenuContext, selected: [Commit]) -> ContextMenuEntry {
        let latest = selected.first ?? context.focusedCommit

        let hasFirst = selected.count > 1 || !latest.graphParentIDs.isEmpty || latest.isArtificial
        return submenu("revision.compare", "Compare", children: [
            command("revision.compare.difftool", "Open selected commits with difftool", enabled: hasFirst),
            .separator,
            command("revision.compare.branch", "Compare to branch…"),
            command("revision.compare.current", "Compare with current branch", enabled: context.currentBranchName != nil),
            command("revision.compare.setBase", "Select as BASE to compare"),
            command("revision.compare.base", "Compare to BASE", enabled: context.hasComparisonBase),
            command("revision.compare.worktree", "Compare to working directory", enabled: !context.isBareRepository && latest.kind != .workingDirectory),
            command("revision.compare.selected", "Compare selected commits", enabled: hasFirst)
        ], enabled: true)
    }

    private static func modelSubmenu(_ id: String, _ title: String, _ commands: [RevisionGridMenuCommand]) -> ContextMenuEntry {
        submenu(id, title, children: commands.map { item in
            switch item.kind {
            case .separator: .separator
            case .header: command("\(id).header.\(item.title)", item.title, enabled: false)
            case .command: command(item.id, item.title, enabled: item.enabled)
            }
        }, enabled: true)
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
    case worktree(isCurrent: Bool, pathExists: Bool, isMain: Bool = false)
    case submodule(isInitialized: Bool = false, isCurrent: Bool = false)
    case branchFolder
    case remoteBranchFolder
    case tagFolder

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
    var focusedRootCanMoveUp = false
    var focusedRootCanMoveDown = false

    var focusedRevisionVisible = true

    var copyRevisions: [Commit] = []

    var scripts: [(id: String, title: String, direct: Bool)] = []

    var sortByIsGitDefault = true
}

enum RepositoryContextMenuBuilder {
    static func build(_ context: RepositoryContextMenuContext) -> [ContextMenuEntry] {
        let selection = context.selected.isEmpty ? [context.focused] : context.selected
        let isSingle = selection.count == 1
        var entries: [ContextMenuEntry] = []

        if isSingle && context.focused.supportsCopy && context.focusedRevisionVisible && !context.copyRevisions.isEmpty {
            entries.append(RevisionContextMenuBuilder.copyMenu(context.copyRevisions))
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
                command("repository.collapse", "Collapse all", enabled: context.selectedHaveCollapsibleChildren),
                command("repository.expand", "Expand all", enabled: context.selectedHaveExpandableChildren)
            ]
        }

        if isSingle, case .group = context.focused {
            entries += [
                .separator,
                command("repository.root.moveUp", "Move up", enabled: context.focusedRootCanMoveUp),
                command("repository.root.moveDown", "Move down", enabled: context.focusedRootCanMoveDown)
            ]
        }

        if isSingle && context.focused.isRef {
            entries += [
                .separator,
                submenu("repository.sortBy", "Sort by", children: [
                    command("repository.sortBy.gitDefault", "Git default"),
                    command("repository.sortBy.authorDate", "Author date"),
                    command("repository.sortBy.committerDate", "Committer date"),
                    command("repository.sortBy.creatorDate", "Creator date"),
                    command("repository.sortBy.taggerDate", "Tagger date"),
                    command("repository.sortBy.alphaNumeric", "Alpha-numeric"),
                    command("repository.sortBy.version", "Version"),
                    command("repository.sortBy.objectSize", "Object size"),
                    command("repository.sortBy.originatingRemote", "Originating remote")
                ]),
            ]
            if !context.sortByIsGitDefault {
                entries.append(submenu("repository.sortOrder", "Sort order", children: [
                    command("repository.sortOrder.ascending", "A ↓ Z"),
                    command("repository.sortOrder.descending", "Z ↑ A")
                ]))
            }
        }


        if isSingle, case .localBranch = context.focused, context.focusedRevisionVisible {
            let hosted = context.scripts.filter { !$0.direct }
            entries.append(.separator)
            if !hosted.isEmpty {
                entries.append(submenu("repository.script", "Run script", children: hosted.map { command("repository.script.run.\($0.id)", $0.title) }))
            }
            entries += context.scripts.filter(\.direct).map { command("repository.script.run.\($0.id)", $0.title) }
        }

        return entries.normalizedMenuSeparators()
    }

    private static func commands(
        for kind: RepositoryMenuNodeKind,
        isBareRepository: Bool
    ) -> [ContextMenuEntry] {
        switch kind {
        case .localBranch(let isCurrent):

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

            var items = [command("repository.remote.manage", "Manage…")]
            if enabled {
                items += [command("repository.remote.disable", "Disable remote"),
                          command("repository.remote.fetch", "Fetch all branches"),
                          command("repository.remote.prune", "Fetch and prune branches")]
            } else {
                items += [command("repository.remote.enable", "Enable remote"),
                          command("repository.remote.enableFetch", "Enable remote and fetch")]
            }
            if hasHTTPURL { items.append(command("repository.remote.openURL", "Open remote URL in browser")) }
            return items

        case .remoteBranch:
            return [
                command("repository.remoteBranch.checkout", "Checkout remote branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.merge", "Merge into current branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.rebase", "Rebase current branch on this remote branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.create", "Create branch…", enabled: !isBareRepository),
                command("repository.remoteBranch.reset", "Reset current branch to here…", enabled: !isBareRepository),
                .separator,
                command("repository.remoteBranch.delete", "Delete remote branch…"),
                .separator,
                command("repository.remoteBranch.fetchCheckout", "Fetch and checkout", enabled: !isBareRepository),
                command("repository.remoteBranch.pull", "Pull from remote branch", enabled: !isBareRepository),
                command("repository.remoteBranch.fetchRebase", "Fetch and rebase", enabled: !isBareRepository),
                command("repository.remoteBranch.fetchCreate", "Fetch and create branch", enabled: !isBareRepository),
                command("repository.remoteBranch.fetch", "Fetch branch")
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

            guard !isBareRepository else { return [] }
            return [
                command("repository.stash.open", "Open stash"),
                command("repository.stash.apply", "Apply stash"),
                command("repository.stash.pop", "Pop stash"),
                command("repository.stash.drop", "Drop stash…")
            ]

        case .worktree(let isCurrent, let pathExists, let isMain):
            return [
                command("repository.worktree.open", "Open worktree", enabled: !isCurrent && pathExists),
                command("repository.worktree.delete", "Delete worktree…", enabled: !isCurrent && pathExists && !isMain),
                .separator,
                command("repository.worktree.copyPath", "Copy worktree path"),
                command("repository.worktree.show", "Show worktree in Finder", enabled: pathExists)
            ]

        case .submodule(_, let isCurrent):

            var items: [ContextMenuEntry] = []
            if !isCurrent { items.append(command("repository.submodule.open", "Open submodule")) }
            items.append(command("repository.submodule.openGE", "Open in Git Extensions"))
            let manages = isCurrent && !isBareRepository
            if manages { items.append(command("repository.submodules.manage", "Manage…")) }
            items.append(command("repository.submodule.update", "Update submodule"))
            if manages { items.append(command("repository.submodules.synchronize", "Synchronize")) }
            if !isBareRepository {
                items += [command("repository.submodule.reset", "Reset submodule"),
                          command("repository.submodule.stash", "Stash submodule"),
                          command("repository.submodule.commit", "Commit submodule")]
            }
            return items

        case .branchFolder:
            return [
                command("repository.folder.create", "Create branch…", enabled: !isBareRepository),
                command("repository.folder.deleteAll", "Delete all branches…", enabled: !isBareRepository)
            ]

        case .remoteBranchFolder:
            return []

        case .tagFolder:
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
    var firstRevisions: [RevisionID?] = []
    var secondRevisions: [RevisionID] = []
    var selectedFolder: String?
    var isBareRepository = false

    var supportLinePatching = false
    var allFilesExist = false
    var allDirectoriesExist = false
    var allFilesOrUntrackedDirectoriesExist = false
    var anyFileOrParentExists = false
    var isFileTreeMode = false

    var canShowInFileTree = false
    var canFilterInGrid = false
    var canBlame = false
    var canFileHistory = false
    var blameInFileTree = false
    var isBlameShown = false
    var canCherryPick = false
    var canUseGrep = false

    var firstDescription = ""
    var secondDescription = ""
    var resetFirstDescription = ""
    var resetSecondDescription = ""
    var rememberedName: String?
    var diffTwoSelectedEnabled = false
    var diffWithRememberedEnabled = false
    var rememberSecondEnabled = false
    var rememberFirstEnabled = false
    var firstToSelectedEnabled = false
    var firstToLocalEnabled = false
    var selectedToLocalEnabled = false
    var hideToLocal = false
    var diffTools: [String] = []

    var hasSubnodes = false
    var canCollapseRootFolders = false
    var showOpenSubmodule = false
    var showSortBy = false

    init(selectedFiles: [ChangedFile], firstRevisions: [RevisionID?] = [], secondRevisions: [RevisionID] = []) {
        self.selectedFiles = selectedFiles
        self.firstRevisions = firstRevisions
        self.secondRevisions = secondRevisions
    }


    var selectedRevision: RevisionID? {
        let distinct = Set(secondRevisions)
        return distinct.count == 1 ? distinct.first : nil
    }
    var selectedIsArtificial: Bool { selectedRevision.map { $0.objectID == nil } ?? false }
    var isStatusOnly: Bool { selectedFiles.contains { $0.isRangeDiff || $0.isStatusOnly } }

    var isCombinedDiff = false
    var isDisplayOnlyDiff: Bool { isStatusOnly || isCombinedDiff }
    var count: Int { selectedFiles.count }
    var isAnyTracked: Bool { selectedFiles.contains { $0.isTracked } }
    var isAnyIndex: Bool { selectedFiles.contains { $0.staged == .index } }
    var isAnyWorkTree: Bool { selectedFiles.contains { $0.staged == .workTree } }
    var isDeleted: Bool { selectedFiles.contains { $0.changeType == .deleted } }
    var isAnySubmodule: Bool { selectedFiles.contains { $0.isSubmodule } }
}


enum ChangedFileContextMenuBuilder {

    static func showDifftool(_ c: ChangedFileContextMenuContext) -> Bool { c.count > 0 && !c.isDisplayOnlyDiff }
    static func showReset(_ c: ChangedFileContextMenuContext) -> Bool {
        c.count > 0 && !c.isBareRepository && c.isAnyTracked && !c.isDisplayOnlyDiff
            && !(c.isAnySubmodule && c.count == 1 && c.isAnyWorkTree)
    }
    static func showSaveAs(_ c: ChangedFileContextMenuContext) -> Bool {
        c.count > 0 && !c.isAnySubmodule && !c.selectedIsArtificial && !c.isDisplayOnlyDiff
    }
    static func showCherryPick(_ c: ChangedFileContextMenuContext) -> Bool { c.supportLinePatching && c.count == 1 && !c.isAnyWorkTree }
    static func showSubmoduleMenus(_ c: ChangedFileContextMenuContext) -> Bool {
        c.isAnySubmodule && c.selectedRevision == .workingDirectory && c.allDirectoriesExist
    }
    static func showEditWorkingDirectoryFile(_ c: ChangedFileContextMenuContext) -> Bool { c.count == 1 && c.allFilesExist }
    static func showDeleteFile(_ c: ChangedFileContextMenuContext) -> Bool { c.allFilesOrUntrackedDirectoriesExist && c.selectedIsArtificial }
    static func showMove(_ c: ChangedFileContextMenuContext) -> Bool {
        (c.count == 1 && c.isAnyTracked && !c.isAnySubmodule) || c.selectedFolder != nil
    }
    static func showOpenRevision(_ c: ChangedFileContextMenuContext) -> Bool {
        c.count == 1 && !c.isAnySubmodule && !c.isDisplayOnlyDiff && !c.selectedIsArtificial
    }
    static func showCopyFileName(_ c: ChangedFileContextMenuContext) -> Bool { c.count > 0 && !c.isStatusOnly }
    static func showShowInFileTree(_ c: ChangedFileContextMenuContext) -> Bool {
        (c.count == 1 && c.isAnyTracked && !c.isDeleted) || c.selectedFolder != nil
    }
    static func showFileHistory(_ c: ChangedFileContextMenuContext) -> Bool {
        (c.count == 1 || !(c.selectedFolder ?? "").isEmpty) && c.isAnyTracked
    }


    static func canResetToSecond(_ c: ChangedFileContextMenuContext) -> Bool { c.secondRevisions.first?.objectID != nil }
    static func canResetToFirst(_ c: ChangedFileContextMenuContext) -> Bool {
        guard let first = c.firstRevisions.first, let first else { return false }
        if first.objectID != nil { return true }
        return first == .index && c.secondRevisions.allSatisfy { $0 == .workingDirectory }
    }

    static let sortByEntries: [(id: String, title: String)] = [
        ("sort.pathTree", "File path - tree"), ("sort.pathFlat", "File path - flat"),
        ("sort.extensionTree", "File extension - tree"), ("sort.extensionFlat", "File extension - flat"),
        ("sort.statusTree", "File status - tree"), ("sort.statusFlat", "File status - flat")
    ]

    static func build(_ c: ChangedFileContextMenuContext) -> [ContextMenuEntry] {
        guard c.count > 0 || c.selectedFolder != nil else { return [] }
        var entries: [ContextMenuEntry] = []
        let isSubmodule = c.count == 1 && c.isAnySubmodule
        let isSingleFile = c.count == 1 && !isSubmodule

        if c.showOpenSubmodule { entries.append(command("file.openSubmodule", "Open with Git Extensions")) }
        if c.hasSubnodes {
            entries += [command("tree.selectAll", "Select all"), command("tree.collapseAll", "Collapse all"),
                        command("tree.expandAll", "Expand all"), .separator]
        }
        if showSubmoduleMenus(c) {
            entries += [command("file.submodule.update", "Update submodule"), command("file.submodule.reset", "Reset submodule changes"),
                        command("file.submodule.stash", "Stash submodule changes"), command("file.submodule.commit", "Commit submodule changes"),
                        .separator]
        }
        if c.isAnyWorkTree { entries.append(command("file.stage", "Stage selected")) }
        if c.isAnyIndex { entries.append(command("file.unstage", "Unstage selected")) }
        let resetToSecond = canResetToSecond(c), resetToFirst = canResetToFirst(c)
        var resetChildren: [ContextMenuEntry] = []
        if resetToSecond { resetChildren.append(command("file.reset.second", "Second: B \(c.resetSecondDescription)")) }
        if resetToFirst { resetChildren.append(command("file.reset.first", "First: A \(c.resetFirstDescription)")) }
        entries.append(submenu("file.reset", "Reset file(s) to", children: resetChildren,
                               enabled: (resetToSecond || resetToFirst) && showReset(c)))
        if c.isAnyWorkTree && isSingleFile {
            entries += [command("file.resetChunk", "Reset chunk of file…"), command("file.interactiveAdd", "Interactive add…")]
        }
        if c.canCherryPick && showCherryPick(c) { entries.append(command("file.cherryPick", "Cherry pick changes")) }
        entries.append(.separator)


        var difftool: [ContextMenuEntry] = []
        if !c.secondRevisions.isEmpty {
            difftool += [command("file.difftool.captionSecond", "Second: B \(c.secondDescription)", enabled: false),
                         command("file.difftool.captionFirst", "First: A \(c.firstDescription)", enabled: false)]
        }
        difftool.append(toolEntry("file.difftool", "First -> Second", tools: c.diffTools, enabled: c.firstToSelectedEnabled))
        if !c.hideToLocal {
            difftool.append(toolEntry("file.difftool.selectedToLocal", "Second -> Working directory", tools: c.diffTools, enabled: c.selectedToLocalEnabled))
            difftool.append(toolEntry("file.difftool.firstToLocal", "First -> Working directory", tools: c.diffTools, enabled: c.firstToLocalEnabled))
        }
        if c.count == 1 || c.count == 2 { difftool.append(.separator) }
        if c.count == 2 {
            difftool.append(toolEntry("file.difftool.twoSelected", "Diff the selected files", tools: c.diffTools, enabled: c.diffTwoSelectedEnabled))
        }
        if c.count == 1, let rememberedName = c.rememberedName {
            difftool.append(toolEntry("file.difftool.remembered", "Diff with \"\(rememberedName)\"", tools: c.diffTools, enabled: c.diffWithRememberedEnabled))
        }
        if c.count == 1 {
            difftool += [command("file.difftool.rememberSecond", "Remember Second for diff", enabled: c.rememberSecondEnabled),
                         command("file.difftool.rememberFirst", "Remember First for diff", enabled: c.rememberFirstEnabled)]
        }
        entries.append(.submenu(id: "file.difftool.menu", title: "Open with difftool", isEnabled: showDifftool(c),
                                children: difftool.normalizedMenuSeparators()))
        if c.count == 1 && c.allFilesExist {
            entries += [command("file.open.local", "Open working directory file"), command("file.open.localWith", "Open working directory file with…")]
        }
        if showOpenRevision(c) {
            let enabled = showShowInFileTree(c)
            entries += [command("file.open.revision", "Open this revision (temp file)", enabled: enabled),
                        command("file.open.revisionWith", "Open this revision with… (temp file)", enabled: enabled)]
        }
        if showEditWorkingDirectoryFile(c) { entries.append(command("file.edit.local", "Edit working directory file")) }
        if showSaveAs(c) { entries.append(command("file.save", "Save selected as…")) }
        if showMove(c) { entries.append(command("file.move", "Rename / move")) }
        if showDeleteFile(c) { entries.append(command("file.delete", c.count == 1 ? "Delete file" : "Delete files")) }
        entries.append(.separator)
        entries.append(command("file.copyPaths", "Copy path(s)", enabled: showCopyFileName(c)))
        if showCopyFileName(c) { entries.append(command("file.showFinder", "Show in Finder", enabled: c.anyFileOrParentExists)) }
        entries.append(.separator)
        if !c.isFileTreeMode && c.canShowInFileTree && showShowInFileTree(c) { entries.append(command("file.showFileTree", "Show in File tree")) }
        if c.canFilterInGrid { entries.append(command("file.filterGrid", "Filter file in grid", enabled: showFileHistory(c))) }
        entries.append(command("file.history", "File history", enabled: c.canFileHistory && !c.isDisplayOnlyDiff && showFileHistory(c)))
        entries.append(command("file.blame", "Blame", enabled: c.canBlame && !c.isDisplayOnlyDiff &&
            (c.blameInFileTree ? showShowInFileTree(c) : showFileHistory(c) && !c.isAnySubmodule && c.selectedFolder == nil)))
        entries.append(command("file.find", "Find file…"))
        if c.canUseGrep {
            entries += [command("file.findCommit", "Find in commit files using git-grep…"),
                        command("file.showFindCommit", "Show 'Find in commit files using git-grep'")]
        }
        let canIgnoreFiles = c.isAnyWorkTree && !isSubmodule
        let canStopTracking = isSingleFile && c.isAnyTracked
        if canIgnoreFiles || canStopTracking { entries.append(.separator) }
        if canIgnoreFiles {
            entries += [command("file.ignore.gitignore", "Add file to .gitignore"),
                        command("file.ignore.exclude", "Add file to .git/info/exclude")]
            if c.isAnyTracked {
                entries += [command("file.skipWorktree", "Skip worktree"), command("file.assumeUnchanged", "Assume unchanged")]
            }
        }
        if canStopTracking { entries.append(command("file.stopTracking", "Stop tracking this file")) }
        if c.canCollapseRootFolders { entries += [.separator, command("tree.collapseRootFolders", "Collapse root folders")] }
        if c.showSortBy {
            entries += [.separator, submenu("sort.menu", "Sort and group by", children: sortByEntries.map { command($0.id, $0.title) })]
        }
        return entries.normalizedMenuSeparators()
    }


    private static func toolEntry(_ id: String, _ title: String, tools: [String], enabled: Bool) -> ContextMenuEntry {
        guard !tools.isEmpty else { return command(id, title, enabled: enabled) }
        return .submenu(id: id + ".tools", title: title, isEnabled: enabled,
                        children: [command(id, "Default difftool")] + tools.map { command(id + ".tool:" + $0, $0) })
    }
}
