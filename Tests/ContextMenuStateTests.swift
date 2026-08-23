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
        testTreeMultiSelection()
        testCurrentWorktreeCommands()
        testStashTreeCommands()
        testHistoricalFileCommands()
        testMultipleHistoricalFiles()
        testWorktreeFileCommands()
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
        expect(menu.entry(id: "revision.compare.selected")?.isEnabled == true, "revision: a single commit compares with its parent")
        expect(menu.entry(id: "revision.navigate.parent")?.isEnabled == true, "revision: parent navigation follows topology")
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
        expect(menu.entry(id: "revision.branch.merge") == nil, "revision: artificial revisions cannot be merged")
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

        expect(RevisionNavigationResolver.parentID(of: topic) == "base", "navigation: first parent follows commit topology")
        expect(RevisionNavigationResolver.childID(of: base, in: history) == "head", "navigation: first visible child follows history order")
        expect(
            RevisionNavigationResolver.mergeBaseID(selectedCommits: [topic], history: history, headCommit: head) == "base",
            "navigation: single selection uses HEAD for merge base"
        )
        expect(
            RevisionNavigationResolver.mergeBaseID(selectedCommits: [head, topic], history: history, headCommit: head) == "base",
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
        expect(menu.entry(id: "repository.branch.checkout")?.isEnabled == false, "tree: current branch checkout disabled")
        expect(menu.entry(id: "repository.branch.merge")?.isEnabled == false, "tree: current branch self-merge disabled")
        expect(menu.entry(id: "repository.branch.create")?.isEnabled == true, "tree: create from current branch enabled")
        expect(menu.entry(id: "repository.branch.rename")?.isEnabled == true, "tree: current branch rename enabled")
        expect(menu.entry(id: "repository.branch.delete")?.isEnabled == false, "tree: current branch delete disabled")
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
            expect(menu.entry(id: identifier)?.isEnabled == true, "tree: \(identifier) is available in a working repository")
            context.isBareRepository = true
            menu = RepositoryContextMenuBuilder.build(context)
            expect(menu.entry(id: identifier)?.isEnabled == false, "tree: \(identifier) is disabled in a bare repository")
        }
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
            id: id,
            shortID: id,
            subject: id,
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: parents,
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

        expect(relations.parentIDs == ["parent"], "commit detail: parents are retained")
        expect(relations.childIDs == ["child-one", "child-two"], "commit detail: direct children follow history order")
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
            id: "$working-directory",
            shortID: "",
            subject: "Working directory",
            body: "",
            authorName: "",
            authorEmail: "",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "",
            committerEmail: "",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: ["$index"],
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
            id: id,
            shortID: id,
            subject: id,
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: parents,
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
