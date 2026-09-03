@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum ContextMenuStateTests {
    static func run() {
        testSeparatorNormalization()
        testCurrentRevisionRefCommands()
        testNonCurrentRevisionRefCommands()
        testMultipleRevisionSelection()
        testArtificialRevisionCherryPickState()
        testRevisionStashCommands()
        testSequencerCommands()
        testRevisionNavigation()
        testCurrentBranchTreeCommands()
        testMergeTreeCommands()
        testCheckoutBranchTreeCommands()
        testRemoteManagementTreeCommands()
        testTreeMultiSelection()
        testCurrentWorktreeCommands()
        testUnavailableFutureTreeCommands()
        testRepositoryTreeStructure()
        testRepositoryTreeVisibilityAndOrdering()
        testRepositoryTreeRefSorting()
        testStashTreeCommands()
        testHistoricalFileCommands()
        testMultipleHistoricalFiles()
        testWorktreeFileCommands()
        testConflictResolverActions()
    }

    private static func testConflictResolverActions() {
        let version = RepositoryConflictVersion(
            objectID: testObjectID("conflict-version"),
            mode: "100644",
            path: "conflict.txt"
        )
        let conflict = RepositoryConflict(
            path: "conflict.txt",
            base: version,
            local: nil,
            remote: version,
            kind: .deletedLocally
        )

        var actions = ConflictResolverActionState(
            selectedConflicts: [],
            conflictCount: 1,
            mergeToolConfiguration: RepositoryMergeToolConfiguration(name: "opendiff", usesGUISetting: true)
        )
        expect(!actions.canResolveSelection, "conflicts: actions require a selection")
        expect(actions.canRunAllMergeTool, "conflicts: configured mergetool can run over all conflicts")

        actions = ConflictResolverActionState(
            selectedConflicts: [conflict],
            conflictCount: 1,
            mergeToolConfiguration: RepositoryMergeToolConfiguration(name: "opendiff", usesGUISetting: true)
        )
        expect(actions.canResolveSelection, "conflicts: selected conflict can be resolved")
        expect(actions.canRunSelectedMergeTool, "conflicts: configured mergetool accepts the selection")
        expect(actions.hasBaseVersion && actions.hasRemoteVersion, "conflicts: available index stages enable inspection")
        expect(!actions.hasLocalVersion, "conflicts: a deleted side disables unavailable content actions")
        expect(actions.canInspectWorkingFile, "conflicts: one selection enables working-file actions")

        actions = ConflictResolverActionState(
            selectedConflicts: [conflict, conflict],
            conflictCount: 2,
            mergeToolConfiguration: nil
        )
        expect(!actions.canRunSelectedMergeTool, "conflicts: absent mergetool disables launch")
        expect(!actions.canInspectWorkingFile, "conflicts: version and working-file actions require one selection")
        expect(!actions.hasBaseVersion && !actions.hasRemoteVersion, "conflicts: multi-selection hides single-file stage actions")
    }

    private static func testSeparatorNormalization() {
        let entries: [ContextMenuEntry] = [
            .separator,
            item("one"),
            .separator,
            .separator,
            item("two"),
            .separator
        ]
        let normalized = entries.normalizedMenuSeparators()
        expect(normalized.count == 3, "menus: redundant separators removed")
        expect(normalized.first?.id == "one" && normalized.last?.id == "two", "menus: no outer separators")
    }

    private static func testCurrentRevisionRefCommands() {
        let head = RevisionReference(id: "head", name: "main", kind: .currentBranch)
        let focused = commit("head", parents: ["parent"], refs: [head])
        let parent = commit("parent")
        let menu = RevisionContextMenuBuilder.build(.init(
            focusedCommit: focused,
            selectedCommits: [focused],
            history: [focused, parent],
            currentBranchName: "main"
        ))

        expect(menu.entry(id: "revision.branch.checkout") == nil, "revision: current branch is not offered for checkout")
        expect(menu.entry(id: "revision.branch.merge") == nil, "revision: current branch is not offered for self-merge")
        expect(menu.entry(id: "revision.branch.rebase") == nil, "revision: current branch is not offered for self-rebase")
        expect(menu.entry(id: "revision.branch.delete")?.isEnabled == false, "revision: deleting the current branch remains visible but disabled")
        expect(menu.entry(id: "revision.branch.rename")?.isEnabled == true, "revision: current branch can be renamed")
        expect(menu.entry(id: "revision.branch.push")?.isEnabled == true, "revision: current branch can be pushed")
        expect(menu.entry(id: "revision.branch.resetCurrent")?.isEnabled == true, "revision: real commit can reset current branch")
        expect(menu.entry(id: "revision.branch.resetOther")?.isEnabled == true, "revision: real commit can reset another branch")
        expect(menu.entry(id: "revision.commit.revert")?.isEnabled == true, "revision: real commit can be reverted")
        expect(menu.entry(id: "revision.compare.selected")?.isEnabled == true, "revision: a single commit compares with its parent")
        expect(menu.entry(id: "revision.navigate.parent")?.isEnabled == true, "revision: parent navigation follows topology")

        var bareContext = RevisionContextMenuContext(
            focusedCommit: focused,
            selectedCommits: [focused],
            history: [focused, parent],
            currentBranchName: "main"
        )
        bareContext.isBareRepository = true
        let bareMenu = RevisionContextMenuBuilder.build(bareContext)
        expect(bareMenu.entry(id: "revision.branch.resetCurrent") == nil, "revision: bare repositories cannot reset current branch")
        expect(bareMenu.entry(id: "revision.branch.resetOther") == nil, "revision: bare repositories cannot reset another branch")
        expect(bareMenu.entry(id: "revision.commit.revert") == nil, "revision: bare repositories cannot revert commits")
    }

    private static func testNonCurrentRevisionRefCommands() {
        let branch = RevisionReference(id: "topic", name: "topic", kind: .localBranch)
        let tag = RevisionReference(id: "tag", name: "v1", kind: .tag)
        let focused = commit("topic", parents: ["base"], refs: [branch, tag])
        let menu = RevisionContextMenuBuilder.build(.init(
            focusedCommit: focused,
            selectedCommits: [focused],
            history: [focused, commit("base")],
            currentBranchName: "main"
        ))

        expect(menu.entry(id: "revision.branch.checkout")?.isEnabled == true, "revision: non-current branch checkout appears")
        expect(menu.entry(id: "revision.branch.merge")?.isEnabled == true, "revision: non-current refs can be merged")
        expect(menu.entry(id: "revision.branch.rebase")?.isEnabled == true, "revision: non-current revision can be a rebase target")
        expect(menu.entry(id: "revision.branch.delete")?.isEnabled == true, "revision: non-current branch can be deleted")
        expect(menu.entry(id: "revision.tag.delete")?.isEnabled == true, "revision: tag deletion appears only when a tag exists")
        expect(menu.entry(id: "revision.selectInLeftPanel")?.children.count == 2, "revision: left-panel submenu carries every ref")
    }

    private static func testMultipleRevisionSelection() {
        let first = commit("first", parents: ["base"])
        let second = commit("second", parents: ["base"])
        let menu = RevisionContextMenuBuilder.build(.init(
            focusedCommit: first,
            selectedCommits: [first, second],
            history: [first, second, commit("base")],
            currentBranchName: "main"
        ))

        expect(menu.entry(id: "revision.branch.rebase.selected")?.isEnabled == false, "revision: ordinary rebase requires one revision")
        expect(menu.entry(id: "revision.branch.rebase.advanced")?.isEnabled == true, "revision: advanced rebase accepts two real revisions")
        expect(menu.entry(id: "revision.compare.selected")?.isEnabled == true, "revision: selected revisions can be compared")
        expect(menu.entry(id: "revision.commit.edit")?.isEnabled == false, "revision: edit is disabled for multi-selection")
        expect(menu.entry(id: "revision.commit.cherryPick")?.isEnabled == true, "revision: real multi-selection can be cherry-picked")
        expect(menu.entry(id: "revision.commit.revert")?.isEnabled == true, "revision: real multi-selection can be reverted")
    }

    private static func testArtificialRevisionCherryPickState() {
        let worktree = commit("$working-directory", kind: .workingDirectory)
        let menu = RevisionContextMenuBuilder.build(.init(
            focusedCommit: worktree,
            selectedCommits: [worktree],
            history: [worktree, commit("head")],
            currentBranchName: "main"
        ))

        expect(
            menu.entry(id: "revision.commit.cherryPick")?.isEnabled == false,
            "revision: artificial revisions cannot be cherry-picked"
        )
        expect(menu.entry(id: "revision.commit.revert")?.isEnabled == false, "revision: artificial revisions cannot be reverted")
        expect(menu.entry(id: "revision.branch.merge") == nil, "revision: artificial revisions cannot be merged")
        expect(menu.entry(id: "revision.branch.create") == nil, "revision: artificial revisions cannot create branches")
        expect(menu.entry(id: "revision.branch.resetCurrent") == nil, "revision: artificial revisions cannot reset current branch")
        expect(menu.entry(id: "revision.branch.resetOther") == nil, "revision: artificial revisions cannot reset another branch")
    }

    private static func testRevisionStashCommands() {
        let stashReference = RevisionReference(id: "stash-0", name: "stash@{0}", kind: .stash)
        let stash = commit("stash", refs: [stashReference])
        var context = RevisionContextMenuContext(
            focusedCommit: stash,
            selectedCommits: [stash],
            history: [stash],
            currentBranchName: "main"
        )
        var menu = RevisionContextMenuBuilder.build(context)
        expect(menu.entry(id: "revision.stash.apply")?.isEnabled == true, "revision stash: apply is available on a stash revision")
        expect(menu.entry(id: "revision.stash.pop")?.isEnabled == true, "revision stash: pop is available on a stash revision")
        expect(menu.entry(id: "revision.stash.drop")?.isEnabled == true, "revision stash: drop is available on a stash revision")

        context.isBareRepository = true
        menu = RevisionContextMenuBuilder.build(context)
        expect(menu.entry(id: "revision.stash.apply") == nil, "revision stash: mutating actions are absent in a bare repository")

        let regular = commit("regular")
        menu = RevisionContextMenuBuilder.build(.init(
            focusedCommit: regular,
            selectedCommits: [regular],
            history: [regular],
            currentBranchName: "main"
        ))
        expect(menu.entry(id: "revision.stash.apply") == nil, "revision stash: actions are absent on ordinary commits")
    }

    private static func testSequencerCommands() {
        let focused = commit("head", parents: ["base"])
        var context = RevisionContextMenuContext(
            focusedCommit: focused,
            selectedCommits: [focused],
            history: [focused, commit("base")],
            currentBranchName: "main",
            isCherryPicking: true,
            cherryPickHasConflicts: true,
            isRebasing: true,
            rebaseHasConflicts: true
        )
        var menu = RevisionContextMenuBuilder.build(context)
        expect(menu.entry(id: "revision.cherryPick.continue")?.isEnabled == false, "revision: conflicted cherry-pick disables continue")
        expect(menu.entry(id: "revision.cherryPick.abort")?.isEnabled == true, "revision: conflicted cherry-pick keeps abort enabled")
        expect(menu.entry(id: "revision.rebase.continue")?.isEnabled == false, "revision: conflicted rebase disables continue")
        expect(menu.entry(id: "revision.rebase.skip")?.isEnabled == true, "revision: conflicted rebase keeps skip enabled")
        expect(menu.entry(id: "revision.rebase.abort")?.isEnabled == true, "revision: conflicted rebase keeps abort enabled")

        context.cherryPickHasConflicts = false
        context.rebaseHasConflicts = false
        menu = RevisionContextMenuBuilder.build(context)
        expect(menu.entry(id: "revision.cherryPick.continue")?.isEnabled == true, "revision: resolved cherry-pick enables continue")
        expect(menu.entry(id: "revision.rebase.continue")?.isEnabled == true, "revision: resolved rebase enables continue")
    }

    private static func testRevisionNavigation() {
        let root = commit("root")
        let base = commit("base", parents: ["root"])
        let head = commit(
            "head",
            parents: ["base"],
            refs: [RevisionReference(id: "head-ref", name: "main", kind: .currentBranch)]
        )
        let topic = commit("topic", parents: ["base"])
        let history = [head, topic, base, root]

        expect(RevisionNavigationResolver.parentID(of: topic) == testRevisionID("base"), "navigation: first parent follows commit topology")
        expect(RevisionNavigationResolver.childID(of: base, in: history) == testRevisionID("head"), "navigation: first visible child follows history order")
        expect(
            RevisionNavigationResolver.mergeBaseID(selectedCommits: [topic], history: history, headCommit: head) == testRevisionID("base"),
            "navigation: single selection uses HEAD for merge base"
        )
        expect(
            RevisionNavigationResolver.mergeBaseID(selectedCommits: [head, topic], history: history, headCommit: head) == testRevisionID("base"),
            "navigation: multi-selection resolves newest common ancestor"
        )
    }

    private static func testCurrentBranchTreeCommands() {
        let kind = RepositoryMenuNodeKind.localBranch(isCurrent: true)
        let menu = RepositoryContextMenuBuilder.build(.init(
            focused: kind,
            selected: [kind],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        ))

        expect(menu.entry(id: "repository.copy")?.isEnabled == true, "tree: branch copy appears")
        expect(menu.entry(id: "repository.filter")?.isEnabled == true, "tree: branch filtering appears")
        expect(menu.entry(id: "repository.branch.checkout") == nil, "tree: current branch checkout is omitted")
        expect(menu.entry(id: "repository.branch.merge") == nil, "tree: current branch self-merge is omitted")
        expect(menu.entry(id: "repository.branch.create")?.isEnabled == true, "tree: create from current branch enabled")
        expect(menu.entry(id: "repository.branch.reset")?.isEnabled == true, "tree: current branch can reset tracked changes at HEAD")
        expect(menu.entry(id: "repository.branch.rename")?.isEnabled == true, "tree: current branch rename enabled")
        expect(menu.entry(id: "repository.branch.delete") == nil, "tree: current branch delete is omitted")
        expect(menu.entry(id: "repository.branch.push") == nil, "tree: current branch push is omitted")
    }

    private static func testMergeTreeCommands() {
        for (kind, identifier) in [
            (RepositoryMenuNodeKind.localBranch(isCurrent: false), "repository.branch.merge"),
            (.remoteBranch, "repository.remoteBranch.merge"),
            (.tag, "repository.tag.merge")
        ] {
            var context = RepositoryContextMenuContext(
                focused: kind,
                selected: [kind],
                selectedHaveChildren: false,
                selectedHaveExpandableChildren: false,
                selectedHaveCollapsibleChildren: false
            )
            var menu = RepositoryContextMenuBuilder.build(context)
            if kind == .tag {
                expect(menu.entry(id: "repository.tag.delete")?.isEnabled == true, "tag tree: local deletion is available")
            }
            expect(menu.entry(id: identifier)?.isEnabled == true, "tree: \(identifier) is available in a working repository")
            context.isBareRepository = true
            menu = RepositoryContextMenuBuilder.build(context)
            if kind == .tag {
                expect(menu.entry(id: "repository.tag.delete")?.isEnabled == true, "tag tree: local deletion remains available in bare repositories")
            }
            expect(menu.entry(id: identifier)?.isEnabled == false, "tree: \(identifier) is disabled in a bare repository")
        }

        for (kind, identifier) in [
            (RepositoryMenuNodeKind.localBranch(isCurrent: false), "repository.branch.reset"),
            (.remoteBranch, "repository.remoteBranch.reset"),
            (.tag, "repository.tag.reset")
        ] {
            var context = RepositoryContextMenuContext(
                focused: kind,
                selected: [kind],
                selectedHaveChildren: false,
                selectedHaveExpandableChildren: false,
                selectedHaveCollapsibleChildren: false
            )
            var menu = RepositoryContextMenuBuilder.build(context)
            expect(menu.entry(id: identifier)?.isEnabled == true, "tree reset: \(identifier) is available")
            context.isBareRepository = true
            menu = RepositoryContextMenuBuilder.build(context)
            expect(menu.entry(id: identifier)?.isEnabled == false, "tree reset: \(identifier) is disabled when bare")
        }
    }

    private static func testCheckoutBranchTreeCommands() {
        var remoteContext = RepositoryContextMenuContext(
            focused: .remoteBranch,
            selected: [.remoteBranch],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        )
        var menu = RepositoryContextMenuBuilder.build(remoteContext)
        expect(menu.entry(id: "repository.remoteBranch.checkout")?.isEnabled == true, "tree: remote branch checkout is enabled")
        expect(menu.entry(id: "repository.remoteBranch.create")?.isEnabled == true, "tree: create from remote branch is enabled")
        expect(menu.entry(id: "repository.remoteBranch.fetchCheckout")?.isEnabled == true, "tree: fetch-and-checkout is enabled")
        expect(menu.entry(id: "repository.remoteBranch.fetchCreate")?.isEnabled == true, "tree: fetch-and-create is enabled")
        remoteContext.isBareRepository = true
        menu = RepositoryContextMenuBuilder.build(remoteContext)
        expect(menu.entry(id: "repository.remoteBranch.checkout")?.isEnabled == false, "tree: remote checkout is disabled in bare repositories")
        expect(menu.entry(id: "repository.remoteBranch.create")?.isEnabled == false, "tree: remote create is disabled in bare repositories")

        var folderContext = RepositoryContextMenuContext(
            focused: .branchFolder,
            selected: [.branchFolder],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false
        )
        menu = RepositoryContextMenuBuilder.build(folderContext)
        expect(menu.entry(id: "repository.folder.create")?.isEnabled == true, "tree: local branch folder can create with a prefix")
        expect(menu.entry(id: "repository.folder.deleteAll")?.isEnabled == true, "tree: local branch folder can delete descendants")
        folderContext.isBareRepository = true
        menu = RepositoryContextMenuBuilder.build(folderContext)
        expect(menu.entry(id: "repository.folder.create")?.isEnabled == false, "tree: local branch folder creation is disabled when bare")

        let remoteFolder = RepositoryMenuNodeKind.remoteBranchFolder
        menu = RepositoryContextMenuBuilder.build(.init(
            focused: remoteFolder,
            selected: [remoteFolder],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.folder.create") == nil, "tree: remote path folders do not expose local-folder commands")
    }

    private static func testRemoteManagementTreeCommands() {
        var menu = RepositoryContextMenuBuilder.build(.init(
            focused: .remote(enabled: true, hasHTTPURL: true),
            selected: [.remote(enabled: true, hasHTTPURL: true)],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.remote.manage")?.isEnabled == true, "remotes: management is available for active remotes")
        expect(menu.entry(id: "repository.remote.fetch")?.isEnabled == true, "remotes: active remotes can fetch")
        expect(menu.entry(id: "repository.remote.prune")?.isEnabled == true, "remotes: active remotes can prune")
        expect(menu.entry(id: "repository.remote.openURL")?.isEnabled == true, "remotes: HTTP remotes can open in a browser")
        expect(menu.entry(id: "repository.remote.disable")?.isEnabled == true, "remotes: active remotes can be disabled")
        expect(menu.entry(id: "repository.remote.enable")?.isEnabled == false, "remotes: active remotes are not offered Enable")

        menu = RepositoryContextMenuBuilder.build(.init(
            focused: .remote(enabled: false, hasHTTPURL: false),
            selected: [.remote(enabled: false, hasHTTPURL: false)],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.remote.fetch")?.isEnabled == false, "remotes: inactive remotes cannot fetch")
        expect(menu.entry(id: "repository.remote.openURL")?.isEnabled == false, "remotes: non-HTTP URLs do not open in a browser")
        expect(menu.entry(id: "repository.remote.enable")?.isEnabled == true, "remotes: inactive remotes can be enabled")
        expect(menu.entry(id: "repository.remote.enableFetch")?.isEnabled == true, "remotes: inactive remotes can enable and fetch")

        menu = RepositoryContextMenuBuilder.build(.init(
            focused: .group(.remotes),
            selected: [.group(.remotes)],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.remotes.manage")?.isEnabled == true, "remotes: root opens management")
        expect(menu.entry(id: "repository.remotes.fetch")?.isEnabled == true, "remotes: root can fetch all")
        expect(menu.entry(id: "repository.remotes.prune")?.isEnabled == true, "remotes: root can prune all")
    }

    private static func testTreeMultiSelection() {
        let local = RepositoryMenuNodeKind.localBranch(isCurrent: false)
        let remote = RepositoryMenuNodeKind.remoteBranch
        let menu = RepositoryContextMenuBuilder.build(.init(
            focused: local,
            selected: [local, remote],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false
        ))

        expect(menu.entry(id: "repository.filter")?.isEnabled == true, "tree: multi-ref selection can filter")
        expect(menu.entry(id: "repository.branch.checkout") == nil, "tree: single-node operations are absent for multi-selection")
        expect(menu.entry(id: "repository.expand")?.isEnabled == true, "tree: multi-selection expansion follows child state")
        expect(menu.entry(id: "repository.collapse")?.isEnabled == false, "tree: collapse disabled when no selected parent is expanded")
    }

    private static func testCurrentWorktreeCommands() {
        let kind = RepositoryMenuNodeKind.worktree(isCurrent: true, pathExists: true)
        let menu = RepositoryContextMenuBuilder.build(.init(
            focused: kind,
            selected: [kind],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        ))

        expect(menu.entry(id: "repository.worktree.open")?.isEnabled == false, "tree: current worktree cannot be opened again")
        expect(menu.entry(id: "repository.worktree.delete")?.isEnabled == false, "tree: current worktree cannot be deleted")
        expect(menu.entry(id: "repository.worktree.copyPath")?.isEnabled == true, "tree: current worktree path can be copied")
        expect(menu.entry(id: "repository.worktree.show")?.isEnabled == true, "tree: existing worktree can be shown")
    }

    private static func testUnavailableFutureTreeCommands() {
        var menu = RepositoryContextMenuBuilder.build(.init(
            focused: .worktree(isCurrent: false, pathExists: true),
            selected: [.worktree(isCurrent: false, pathExists: true)],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.worktree.open")?.isEnabled == false, "tree: unfinished worktree opening is not an enabled placeholder")
        expect(menu.entry(id: "repository.worktree.delete")?.isEnabled == false, "tree: unfinished worktree deletion is not an enabled placeholder")

        menu = RepositoryContextMenuBuilder.build(.init(
            focused: .submodule,
            selected: [.submodule],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.submodule.open")?.isEnabled == false, "tree: unfinished submodule actions remain visible but disabled")

        menu = RepositoryContextMenuBuilder.build(.init(
            focused: .group(.branches),
            selected: [.group(.branches)],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false,
            focusedRootCanMoveUp: false,
            focusedRootCanMoveDown: true
        ))
        expect(menu.entry(id: "repository.root.moveUp")?.isEnabled == false, "tree: first root cannot move up")
        expect(menu.entry(id: "repository.root.moveDown")?.isEnabled == true, "tree: roots can be reordered")
        expect(menu.entry(id: "repository.sortBy.creatorDate") == nil, "tree: sort choices are scoped to ref nodes")
    }

    private static func testRepositoryTreeStructure() {
        let mainID = testObjectID("main")
        let topicID = testObjectID("topic")
        let branches = [
            Branch(id: "topic", name: "feature/ui/topic", commitID: topicID, isCurrent: false, isRemote: false, remoteName: nil, ahead: 1, behind: 2),
            Branch(id: "main", name: "main", commitID: mainID, isCurrent: true, isRemote: false, remoteName: "origin", ahead: 0, behind: 0)
        ]
        let remoteBranch = Branch(id: "remote-topic", name: "feature/ui/topic", commitID: topicID, isCurrent: false, isRemote: true, remoteName: "origin", ahead: 0, behind: 0)
        let references = RepositoryReferenceState(
            branches: branches,
            tags: [Tag(id: "tag", name: "release/v1", commitID: mainID)],
            referencesByCommit: [:]
        )
        let navigation = RepositoryNavigationState(
            remotes: [
                Remote(id: "disabled", name: "archive", fetchURL: "https://example.invalid/archive", branches: [], isDisabled: true),
                Remote(id: "origin", name: "origin", fetchURL: "https://github.com/example/repo", branches: [remoteBranch])
            ],
            stashes: [Stash(id: "stash", selector: "stash@{0}", subject: "WIP", branchName: "main", commitID: topicID)],
            worktrees: [],
            submodules: []
        )
        let roots = RepositoryTreeBuilder.build(
            references: references,
            navigation: navigation,
            preferences: RepositoryTreePreferences()
        )
        expect(roots.map(\.title) == ["Branches", "Remotes", "Worktrees", "Tags", "Submodules", "Stashes"], "tree: default root order matches upstream")
        let all = roots.flatMap(flatten)
        expect(all.contains(where: { $0.id == "branch:main" }), "tree: current local branch has stable identity")
        expect(all.contains(where: { $0.id == "branch-folder:local:feature/ui" }), "tree: slash-separated branches form nested path nodes")
        expect(all.contains(where: { $0.id == "tag-folder:release" }), "tree: slash-separated tags form path nodes")
        expect(all.contains(where: { $0.id == "remote-folder:inactive" }), "tree: inactive remotes are grouped separately")
        expect(roots[0].children.first?.id == "branch:main", "tree: main/master priority precedes ordinary branches")
        let restored = RepositoryTreeStateResolver.survivingIDs(
            ["branch:main", "branch:deleted", "tag:release/v1"],
            in: roots
        )
        expect(restored == ["branch:main", "tag:release/v1"], "tree: refresh restores surviving selections and drops stale refs")
    }

    private static func testRepositoryTreeVisibilityAndOrdering() {
        let state = RepositoryReferenceState(branches: [], tags: [], referencesByCommit: [:])
        let navigation = RepositoryNavigationState(remotes: [], stashes: [], worktrees: [], submodules: [])
        var preferences = RepositoryTreePreferences()
        preferences.visibleRoots.remove(.worktrees)
        preferences.rootOrder = [.tags, .branches, .remotes, .worktrees, .submodules, .stashes]
        let roots = RepositoryTreeBuilder.build(references: state, navigation: navigation, preferences: preferences)
        expect(roots.map(\.title) == ["Tags", "Branches", "Remotes", "Submodules", "Stashes"], "tree: visibility and persisted root order are honored")
    }

    private static func testRepositoryTreeRefSorting() {
        let oldID = testObjectID("old-tag")
        let newID = testObjectID("new-tag")
        let references = RepositoryReferenceState(
            branches: [],
            tags: [
                Tag(id: "v10", name: "v10", commitID: newID, sortMetadata: .init(creatorDate: 20, objectSize: 200)),
                Tag(id: "v2", name: "v2", commitID: oldID, sortMetadata: .init(creatorDate: 10, objectSize: 100))
            ],
            referencesByCommit: [:]
        )
        let navigation = RepositoryNavigationState(remotes: [], stashes: [], worktrees: [], submodules: [])
        var preferences = RepositoryTreePreferences()
        preferences.sortBy = .creatorDate
        var tags = RepositoryTreeBuilder.build(references: references, navigation: navigation, preferences: preferences)
            .first(where: { $0.id == "root:tags" })?.children ?? []
        expect(tags.map(\.title) == ["v2", "v10"], "tree: upstream creator-date metadata sorts refs")

        preferences.sortBy = .version
        preferences.sortOrder = .descending
        tags = RepositoryTreeBuilder.build(references: references, navigation: navigation, preferences: preferences)
            .first(where: { $0.id == "root:tags" })?.children ?? []
        expect(tags.map(\.title) == ["v10", "v2"], "tree: version-aware descending sort matches ref-name semantics")

        preferences.sortBy = .gitDefault
        tags = RepositoryTreeBuilder.build(references: references, navigation: navigation, preferences: preferences)
            .first(where: { $0.id == "root:tags" })?.children ?? []
        expect(tags.map(\.title) == ["v10", "v2"], "tree: Git-default ordering ignores the stored explicit direction")

        let menu = RepositoryContextMenuBuilder.build(.init(
            focused: .tag,
            selected: [.tag],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        ))
        expect(menu.entry(id: "repository.sortBy.creatorDate")?.isEnabled == true, "tree: real metadata sort modes are exposed on refs")
        expect(menu.entry(id: "repository.sortBy.originatingRemote")?.isEnabled == true, "tree: originating-remote sorting is exposed on refs")
    }

    private static func flatten(_ node: RepositoryTreeNode) -> [RepositoryTreeNode] {
        [node] + node.children.flatMap(flatten)
    }

    private static func testStashTreeCommands() {
        var context = RepositoryContextMenuContext(
            focused: .stash,
            selected: [.stash],
            selectedHaveChildren: false,
            selectedHaveExpandableChildren: false,
            selectedHaveCollapsibleChildren: false
        )
        var menu = RepositoryContextMenuBuilder.build(context)
        expect(menu.entry(id: "repository.stash.open")?.isEnabled == true, "stash tree: a stash node can open FormStash")
        expect(menu.entry(id: "repository.stash.apply")?.isEnabled == true, "stash tree: apply is enabled")
        expect(menu.entry(id: "repository.stash.pop")?.isEnabled == true, "stash tree: pop is enabled")
        expect(menu.entry(id: "repository.stash.drop")?.isEnabled == true, "stash tree: drop is enabled")

        context.isBareRepository = true
        menu = RepositoryContextMenuBuilder.build(context)
        expect(menu.entry(id: "repository.stash.open")?.isEnabled == false, "stash tree: stash actions are disabled for bare repositories")
        expect(menu.entry(id: "repository.stash.drop")?.isEnabled == false, "stash tree: destructive actions are disabled for bare repositories")

        context = RepositoryContextMenuContext(
            focused: .group(.stashes),
            selected: [.group(.stashes)],
            selectedHaveChildren: true,
            selectedHaveExpandableChildren: true,
            selectedHaveCollapsibleChildren: false
        )
        menu = RepositoryContextMenuBuilder.build(context)
        expect(menu.entry(id: "repository.stashes.create")?.isEnabled == true, "stash root: quick stash is enabled")
        expect(menu.entry(id: "repository.stashes.staged")?.isEnabled == true, "stash root: staged-only stash is enabled")
        expect(menu.entry(id: "repository.stashes.manage")?.isEnabled == true, "stash root: manager is enabled")

        context.isBareRepository = true
        menu = RepositoryContextMenuBuilder.build(context)
        expect(menu.entry(id: "repository.stashes.create")?.isEnabled == false, "stash root: quick stash is disabled for bare repositories")
        expect(menu.entry(id: "repository.stashes.manage")?.isEnabled == false, "stash root: manager is disabled for bare repositories")
    }

    private static func testHistoricalFileCommands() {
        let file = changedFile("source", type: .modified)
        let menu = ChangedFileContextMenuBuilder.build(.init(
            selectedFiles: [file],
            scope: .revision,
            allFilesExist: true
        ))

        expect(menu.entry(id: "file.stage") == nil && menu.entry(id: "file.unstage") == nil, "files: historical revision has no stage commands")
        expect(menu.entry(id: "file.reset")?.isEnabled == true, "files: tracked revision file can be reset")
        expect(menu.entry(id: "file.cherryPick")?.isEnabled == true, "files: single revision file supports a patch")
        expect(menu.entry(id: "file.open.revision")?.isEnabled == true, "files: historical blob can be opened")
        expect(menu.entry(id: "file.ignore.gitignore") == nil, "files: historical revision has no worktree ignore commands")
        expect(menu.entry(id: "file.delete") == nil, "files: historical revision cannot delete the working file")
    }

    private static func testMultipleHistoricalFiles() {
        let menu = ChangedFileContextMenuBuilder.build(.init(
            selectedFiles: [changedFile("one", type: .modified), changedFile("two", type: .added)],
            scope: .revision,
            allFilesExist: true
        ))

        expect(menu.entry(id: "file.cherryPick") == nil, "files: patch command requires one file")
        expect(menu.entry(id: "file.open.local") == nil && menu.entry(id: "file.open.revision") == nil, "files: open commands require one file")
        expect(menu.entry(id: "file.move") == nil, "files: move requires one tracked file")
        expect(menu.entry(id: "file.history")?.isEnabled == false, "files: multi-file history remains present but disabled")
    }

    private static func testWorktreeFileCommands() {
        let menu = ChangedFileContextMenuBuilder.build(.init(
            selectedFiles: [changedFile("source", type: .modified)],
            scope: .workingTree,
            allFilesExist: true
        ))

        expect(menu.entry(id: "file.stage")?.isEnabled == true, "files: worktree file can be staged")
        expect(menu.entry(id: "file.resetChunk")?.isEnabled == true, "files: worktree file supports interactive reset")
        expect(menu.entry(id: "file.ignore.gitignore")?.isEnabled == true, "files: worktree file exposes ignore commands")
        expect(menu.entry(id: "file.delete")?.isEnabled == true, "files: existing worktree file can be deleted")
        expect(menu.entry(id: "file.open.revision") == nil, "files: worktree file has no historical temp-file command")
        expect(menu.entry(id: "file.cherryPick") == nil, "files: worktree changes are not cherry-picked from themselves")
    }

    private static func item(_ id: String) -> ContextMenuEntry {
        .command(id: id, title: id, isEnabled: true)
    }

    private static func commit(
        _ id: String,
        parents: [String] = [],
        refs: [RevisionReference] = [],
        kind: Commit.Kind = .revision
    ) -> Commit {
        Commit(
            id: kind == .workingDirectory ? .workingDirectory : kind == .index ? .index : testRevisionID(id),
            shortID: id,
            subject: id,
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: parents.filter { !$0.hasPrefix("$") }.map(testObjectID),
            references: refs,
            kind: kind
        )
    }

    private static func changedFile(_ id: String, type: FileChangeType) -> ChangedFile {
        ChangedFile(
            id: id,
            path: "Sources/\(id).swift",
            oldPath: nil,
            changeType: type,
            additions: 1,
            deletions: 0
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("RevisionGraphLayoutTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}

enum RepositoryDetailModelTests {
    static func run() {
        testFileTreeHierarchyAndSorting()
        testFileTreeSelectionRestoration()
        testCommitRelations()
        testGPGPresentation()
        testRevisionDiffSummary()
    }

    private static func testFileTreeHierarchyAndSorting() {
        let files = [
            RepositoryFileEntry(path: "README.md", content: "readme"),
            RepositoryFileEntry(path: "src/zeta.swift", content: "zeta"),
            RepositoryFileEntry(path: "src/App/main.swift", content: "main"),
            RepositoryFileEntry(path: "assets/icon.png", content: "icon")
        ]
        let roots = RepositoryFileTreeBuilder.build(files: files)

        expect(roots.map(\.name) == ["assets", "src", "README.md"], "detail tree: folders sort before files")
        let src = roots.first { $0.path == "src" }
        expect(src?.children.map(\.name) == ["App", "zeta.swift"], "detail tree: nested folders sort before files")
        let main = src?.children.first?.children.first
        expect(main?.path == "src/App/main.swift" && main?.file?.content == "main", "detail tree: leaf retains revision file data")
    }

    private static func testFileTreeSelectionRestoration() {
        let files = [
            RepositoryFileEntry(path: "src/B.swift", content: "B"),
            RepositoryFileEntry(path: "README.md", content: "readme"),
            RepositoryFileEntry(path: "src/A.swift", content: "A")
        ]

        expect(
            FileTreeSelectionResolver.selectedPath(previousPath: "src/B.swift", files: files) == "src/B.swift",
            "detail tree: an existing explicit selection survives a revision change"
        )
        expect(
            FileTreeSelectionResolver.selectedPath(previousPath: "missing.swift", files: files) == "README.md",
            "detail tree: missing selection falls back deterministically"
        )
        expect(
            FileTreeSelectionResolver.selectedPath(previousPath: nil, files: []) == nil,
            "detail tree: empty revision has no selected file"
        )
    }

    private static func testCommitRelations() {
        let branch = RevisionReference(id: "branch", name: "main", kind: .currentBranch)
        let tag = RevisionReference(id: "tag", name: "v1.0", kind: .tag)
        let selected = commit("selected", parents: ["parent"], refs: [branch, tag])
        let relations = CommitRelationsResolver.resolve(
            commit: selected,
            history: [commit("child-one", parents: ["selected"]), selected, commit("child-two", parents: ["selected"])]
        )

        expect(relations.parentIDs == [testObjectID("parent")], "commit detail: parents are retained")
        expect(relations.childIDs == [testObjectID("child-one"), testObjectID("child-two")], "commit detail: direct children follow history order")
        expect(relations.branchNames == ["main"], "commit detail: branch refs are separate")
        expect(relations.tagNames == ["v1.0"], "commit detail: tag refs are separate")
    }

    private static func testGPGPresentation() {
        let unsigned = RevisionGPGPresentationResolver.resolve(info: nil)
        expect(unsigned.commit.message == "Commit is not signed" && unsigned.commit.indicator == .none, "gpg: absent result is unsigned")
        expect(unsigned.tag == nil, "gpg: absent tag hides its row")

        let unsignedTag = RevisionGPGPresentationResolver.resolve(info: RevisionGPGInfo(
            commitStatus: .missingPublicKey,
            commitVerificationMessage: "No public key",
            tagStatus: .tagNotSigned,
            tagVerificationMessage: "ignored"
        ))
        expect(unsignedTag.commit.indicator == .warning, "gpg: missing commit key uses warning state")
        expect(unsignedTag.tag == SignatureRowPresentation(message: "Tag is not signed", indicator: .none), "gpg: unsigned tag remains visible without an icon")

        let signed = RevisionGPGPresentationResolver.resolve(info: RevisionGPGInfo(
            commitStatus: .goodSignature,
            commitVerificationMessage: "Good commit signature",
            tagStatus: .oneBad,
            tagVerificationMessage: "Bad tag signature"
        ))
        expect(signed.commit.indicator == .good, "gpg: good commit status is preserved")
        expect(signed.tag?.indicator == .error, "gpg: bad tag status is independent from commit status")
    }

    private static func testRevisionDiffSummary() {
        let selected = commit("dea544dd", parents: ["b5702ba5"])
        let comparison = commit("b5702ba5")
        expect(
            RevisionDiffSummaryResolver.summary(selected: selected, comparison: comparison)
                == "Diff with A b5702ba5: b5702ba5",
            "revision diff: the comparison parent is identified as A"
        )

        let root = commit("root")
        expect(
            RevisionDiffSummaryResolver.summary(selected: root, comparison: nil)
                == "Diff with empty tree",
            "revision diff: a root commit compares with the empty tree"
        )

        let artificial = Commit(
            id: .workingDirectory,
            shortID: "",
            subject: "Working directory",
            body: "",
            authorName: "",
            authorEmail: "",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "",
            committerEmail: "",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: [],
            references: [],
            kind: .workingDirectory
        )
        expect(
            RevisionDiffSummaryResolver.summary(selected: artificial, comparison: comparison)
                == "Diff with A b5702ba5: b5702ba5",
            "revision diff: artificial revisions use the same parent comparison caption"
        )
    }

    private static func commit(
        _ id: String,
        parents: [String] = [],
        refs: [RevisionReference] = []
    ) -> Commit {
        Commit(
            id: testRevisionID(id),
            shortID: id,
            subject: id,
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: parents.map(testObjectID),
            references: refs
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("RevisionGraphLayoutTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
