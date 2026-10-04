@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit



enum RevisionGridTests {
    static func run() async throws {
        testFilterArguments()
        testTextFilterAndSummary()
        testAheadBehindParsing()
        testSuperprojectParsing()
        testPresentation()
        testMenuModel()
        testContextMenu()
        testCopyMenu()
        try await testReaderAgainstRepository()
        try await testAheadBehindAndMergeBase()
        try await testSuperprojectLabels()
        try await testGridCommandsAndNavigation()
        try await testIncrementalGraphScrolling()
        print("RevisionGridTests: passed")
    }



    private static func testFilterArguments() {
        let head = testObjectID("head")
        var filter = RevisionGridFilter()
        check(filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 100, showStashes: true, showGitNotes: false, showSessionRefs: false)
              == ["--max-count=100", "--exclude=refs/notes/commits", "--exclude=refs/agents/**", "--exclude=refs/sessions/**", "--exclude=refs/copilot/checkpoints/**", "--all"],
              "filter: all branches excludes notes/session refs and keeps stashes")
        check(filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: false, showGitNotes: true, showSessionRefs: true)
              == ["--exclude=refs/stash", "--all"], "filter: hidden stashes are excluded, notes/session refs included")

        filter.showCurrentBranchOnly = true
        check(filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: true, showGitNotes: false, showSessionRefs: false)
              == ["--glob=refs/stas[h]", head.string], "filter: current branch only reads HEAD plus stashes")

        filter = RevisionGridFilter()
        filter.setBranchFilter("main feat* ")
        check(filter.isShowFilteredBranchesChecked, "filter: a branch filter selects filtered mode")
        check(filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: false, showGitNotes: false, showSessionRefs: false)
              == ["main", "--branches=feat*"], "filter: wildcard branch filters use --branches")

        filter = RevisionGridFilter()
        filter.byAuthor = true; filter.author = "Ann"
        filter.byMessage = true; filter.message = "fix"
        filter.byDiffContent = true; filter.diffContent = "needle"
        filter.hideMergeCommits = true
        filter.showOnlyFirstParent = true
        filter.showReflogReferences = true
        filter.byCommitsLimit = true; filter.commitsLimit = 5
        check(filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 100, showStashes: true, showGitNotes: false, showSessionRefs: false)
              == ["--max-count=5", "--no-merges", "--author=Ann", "--regexp-ignore-case", "-Gneedle", "--grep=fix", "--parents",
                  "--first-parent", "--reflog", "--exclude=refs/notes/commits", "--exclude=refs/agents/**", "--exclude=refs/sessions/**",
                  "--exclude=refs/copilot/checkpoints/**", "--all", "--boundary"],
              "filter: upstream option order with boundary for message+diff filters")

        filter = RevisionGridFilter()
        filter.byMessage = true; filter.message = "--since=\"2 weeks\" --no-walk"
        let arguments = filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: true, showGitNotes: true, showSessionRefs: true)
        check(arguments.prefix(3) == ["--regexp-ignore-case", "--since=2 weeks", "--no-walk"], "filter: '--' messages are split into git-log options")

        filter = RevisionGridFilter()
        filter.byPathFilter = true; filter.pathFilter = "dir/"
        check(filter.pathArguments == ["dir/"] && !filter.followsRenames, "filter: directories are not followed")
        filter.pathFilter = "file.txt"
        check(filter.followsRenames, "filter: a single file path follows renames")
        filter.showFullHistory = true; filter.showSimplifyMerges = true
        check(filter.revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: true, showGitNotes: true, showSessionRefs: true)
              .prefix(3) == ["--parents", "--full-history", "--simplify-merges"], "filter: file-history simplification options")

        check(RevisionLogCommands.log(sortOrder: .topology, revisionArguments: ["--all"], paths: ["a"], notes: true).arguments
              == ["log", "-z", RevisionLogCommands.format(notes: true), "--topo-order", "--all", "--", "a"], "reader: topo order and paths")
        check(RevisionLogCommands.log(sortOrder: .authorDate, revisionArguments: [], paths: []).arguments.contains("--author-date-order"),
              "reader: author date order")
        check(RevisionLogCommands.format(notes: true).hasSuffix("%x00%N"), "reader: notes are appended to the format")

        check(RevisionDiffArguments.arguments(first: .object(head), second: .workingDirectory) == [head.string],
              "difftool: commit against the working directory")
        check(RevisionDiffArguments.arguments(first: .workingDirectory, second: .object(head)) == ["-R", head.string],
              "difftool: working directory as first revision reverses the diff")
        check(RevisionDiffArguments.arguments(first: .index, second: .workingDirectory) == [], "difftool: index vs worktree is the plain diff")
        check(RevisionDiffArguments.arguments(first: .object(head), second: .index) == ["--cached", head.string], "difftool: index is --cached")
        check(RevisionDiffArguments.dirDiff(first: .object(head), second: .object(testObjectID("x"))).arguments.prefix(6)
              == ["difftool", "--gui", "--find-renames", "--find-copies", "--no-prompt", "--dir-diff"], "difftool: dir-diff arguments")
        check(RevisionGridCommands.mergeBase(revisions: [head], head: testObjectID("h"), includesArtificial: false).arguments
              == ["merge-base", testObjectID("h").string, head.string], "merge base: one revision uses HEAD")
        check(RevisionGridCommands.mergeBase(revisions: [head, testObjectID("a"), testObjectID("b")], head: testObjectID("h"), includesArtificial: false)
              .arguments.contains("--octopus"), "merge base: more than two revisions use --octopus")
    }

    private static func testTextFilterAndSummary() {
        var filter = RevisionGridFilter()
        check(filter.apply(.init(text: "bob", message: false, committer: false, author: true, diffContent: false)), "text filter: first apply refreshes")
        check(!filter.apply(.init(text: "bob", message: false, committer: false, author: true, diffContent: false)), "text filter: identical apply is a no-op")
        check(filter.effectiveAuthor == "bob" && filter.hasRevisionFilter, "text filter: author filter is active")
        check(filter.summary.contains("Author: bob"), "text filter: summary lists the author")
        filter.resetAllFilters()
        check(!filter.hasFilter, "text filter: reset clears every filter")
    }

    private static func testAheadBehindParsing() {
        let output = ["ahead 2, behind 1", "ahead 2, behind 1", "refs/remotes/origin/main", "refs/remotes/origin/main", "main",
                      "", "", "", "refs/remotes/origin/gone", "gone-branch",
                      "", "gone", "", "refs/remotes/origin/old", "stale",
                      "", "", "", "refs/remotes/origin/same", "same",
                      "", "", "", "", "local-only"].joined(separator: "\0") + "\0\n"
        let data = AheadBehindData.parse(output)
        check(data["main"] == .init(branch: "main", remoteRef: "refs/remotes/origin/main", aheadCount: "2", behindCount: "1"), "ahead/behind: push counts")
        check(data["stale"]?.isGone == true, "ahead/behind: gone upstream")
        check(data["same"]?.aheadCount == "0" && data["same"]?.behindCount == "", "ahead/behind: in-sync branch")
        check(data["local-only"] == nil, "ahead/behind: branches without a remote are omitted")
        check(data["main"]!.display() == "2↑ 1↓" && data["main"]!.display(withCounts: false, reverse: true) == "↓↑",
              "ahead/behind: display and reversed virtual label")
        check(data["same"]!.display() == "0↑↓" && data["stale"]!.display() == "✗", "ahead/behind: in-sync and gone display")
        check(AheadBehindData.command.arguments.first == "for-each-ref" && !AheadBehindData.command.changesRepositoryState, "ahead/behind: read-only command")
    }

    private static func testSuperprojectParsing() {
        let id = testObjectID("sub")
        check(SuperprojectInfo.parseStatus("+\(id.string) sub (heads/main)\n")?.commit == id, "superproject: status commit")
        check(SuperprojectInfo.parseStatus("U\(id.string) sub\n")?.code == "U", "superproject: conflict status code")
        var info = SuperprojectInfo()
        info.applyConflict("160000 \(testObjectID("b").string) 1\tsub\0160000 \(testObjectID("l").string) 2\tsub\0160000 \(testObjectID("r").string) 3\tsub\0")
        check(info.conflictBase == testObjectID("b") && info.conflictLocal == testObjectID("l") && info.conflictRemote == testObjectID("r"),
              "superproject: conflict stages")
        check(SuperprojectInfo.parseTreeCommit("160000 commit \(id.string)\tsub\n") == id, "superproject: ls-tree gitlink")
        check(SuperprojectInfo.reference("refs/remotes/origin/main")?.name == "origin/main", "superproject: remote ref label")
        check(SuperprojectInfo.Commands.refs(branches: false, remoteBranches: false, tags: false) == nil, "superproject: no ref kinds, no query")
        check(SuperprojectInfo.Commands.refs(branches: true, remoteBranches: false, tags: true)!.arguments
              == ["for-each-ref", "--sort=-committerdate", "--count=100", "--format=%(refname)", "refs/heads/", "refs/tags/"],
              "superproject: GetRefs filter/sort/count")
    }



    private static func testPresentation() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        check(RevisionGridPresentation.relativeDate(now: now, date: now.addingTimeInterval(-30)) == "30 seconds ago", "date: seconds")
        check(RevisionGridPresentation.relativeDate(now: now, date: now.addingTimeInterval(-3 * 86_400)) == "3 days ago", "date: days")
        check(RevisionGridPresentation.relativeDate(now: now, date: now.addingTimeInterval(-45 * 86_400)) == "2 months ago", "date: months round")

        let local = RevisionReference(id: "refs/heads/main", name: "main", kind: .localBranch, trackingRemote: "origin", mergeWith: "main")
        let remote = RevisionReference(id: "refs/remotes/origin/main", name: "origin/main", kind: .remoteBranch)
        let data = AheadBehindData(branch: "main", remoteRef: "refs/remotes/origin/main", aheadCount: "1", behindCount: "")
        let lookup: (RevisionReference) -> AheadBehindData? = { $0.id == local.id || $0.id == remote.id ? data : nil }
        check(RevisionGridPresentation.referenceToolTip(.init(reference: local), aheadBehind: lookup, showTooltips: true)
              == "[main]   1↑\nis tracking [origin/main]", "tooltip: local branch ahead/behind")
        check(RevisionGridPresentation.referenceToolTip(.init(reference: remote), aheadBehind: lookup, showTooltips: true)
              == "[origin/main]\nis tracked by [main]   1↑", "tooltip: remote branch tracked by local")
        let tag = RevisionReference(id: "refs/tags/v1", name: "v1", kind: .tag)
        check(RevisionGridPresentation.referenceToolTip(.init(reference: tag), aheadBehind: lookup, showTooltips: false) == nil,
              "tooltip: disabled grid tooltips hide plain ref tooltips")
        let gone = AheadBehindData(branch: "main", remoteRef: "refs/remotes/origin/main", aheadCount: AheadBehindData.gone, behindCount: "")
        let virtual = RevisionReference(id: "refs/remotes/origin/main", name: "✗", kind: .remoteBranch, mergeWith: local.id)
        check(RevisionGridPresentation.referenceToolTip(.init(reference: virtual, virtualTarget: virtual.id, virtualSource: local),
                                                        aheadBehind: { _ in gone }, showTooltips: true)
              == "[main]\nwas tracking [origin/main], but the remote is gone", "tooltip: gone virtual label")

        let bisect = RevisionReference(id: "refs/bisect/bad", name: "bad", kind: .bisectBad)
        let current = RevisionReference(id: "refs/heads/cur", name: "cur", kind: .currentBranch)
        check(RevisionGridPresentation.sortedReferences([tag, remote, local, current, bisect]).map(\.id)
              == [bisect.id, current.id, local.id, remote.id, tag.id], "labels: SortRefs order")
        let commit = makeCommit("c", body: "body line", refs: [bisect, local])
        check(RevisionGridPresentation.messageToolTip(commit, notesInSeparateColumn: false, aheadBehind: lookup)
              == "c\nbody line\n\nMarked as bad in bisect\n[main]   1↑", "tooltip: message summary with ref lines")
        check(RevisionGridPresentation.bodyAndNotes("s", notes: "n1\nn2") == "s\n\nNotes:\n    n1\n    n2", "notes: FormatBodyAndNotes")
        check(RevisionGridPresentation.commitIDText(commit, width: 8 + 7 * 6, characterWidth: 6).count == 7, "commit id: width-based length")
        check(RevisionGridPresentation.hasAutosquashMarker("fixup! x") && !RevisionGridPresentation.hasAutosquashMarker("fix"), "autosquash marker")
    }



    private static func testMenuModel() {
        var state = RevisionGridMenuModel.State()
        state.sortOrder = .topology
        state.filter.showReflogReferences = true
        state.preferences.showSuperprojectBranches = true
        let view = RevisionGridMenuModel.view(state)
        func checked(_ id: String) -> Bool? { view.first { $0.id == id }?.checked }
        check(checked("revision.sort.topo") == true && checked("revision.sort.authorDate") == false, "view menu: sort order checks")
        check(checked("revision.other.reflog") == true && checked("revision.branches.all") == true, "view menu: filter checks")
        check(checked("revision.view.superprojectBranches") == true && checked("revision.view.superprojectTags") == false, "view menu: superproject labels")
        check(view.first { $0.id == "revision.view.highlightBranch" }?.enabled == true, "view menu: graph highlighting is available")
        check(view.filter { $0.kind == .header }.map(\.title) == ["Branches", "Commits", "Grid labels", "Grid info", "Columns", "Sorting", "Settings persistence"],
              "view menu: upstream group headers")
        let navigate = RevisionGridMenuModel.navigate(state)
        check(navigate.first { $0.id == "revision.navigate.backward" }?.enabled == false, "navigate menu: history availability")
        check(navigate.compactMap { $0.kind == .command ? $0.id : nil }.first == "revision.navigate.toggleArtificial", "navigate menu: upstream order")
    }

    private static func testContextMenu() {
        let local = RevisionReference(id: "refs/heads/topic", name: "topic", kind: .localBranch, trackingRemote: "origin", mergeWith: "topic")
        let remote = RevisionReference(id: "refs/remotes/origin/topic", name: "origin/topic", kind: .remoteBranch)
        let other = RevisionReference(id: "refs/remotes/origin/other", name: "origin/other", kind: .remoteBranch)
        let tag = RevisionReference(id: "refs/tags/v1", name: "v1", kind: .tag)
        let focused = makeCommit("topic", parents: ["base"], refs: [local, remote, other, tag])
        var context = RevisionContextMenuContext(focusedCommit: focused, selectedCommits: [focused], history: [focused], currentBranchName: "main")
        var menu = RevisionContextMenuBuilder.build(context)
        let checkout = menu.entry(id: "revision.branch.checkout")?.children ?? []
        check(checkout.contains(.separator) && checkout.first?.id == "revision.branch.checkout.ref.\(local.id)", "context: locals before remotes in checkout")
        let merge = (menu.entry(id: "revision.branch.merge")?.children ?? []).compactMap(\.id)
        check(merge == ["revision.branch.merge.ref.\(tag.id)", "revision.branch.merge.ref.\(local.id)", "revision.branch.merge.ref.\(other.id)"],
              "context: merge offers tags and branches without identical tracked remotes")
        check(menu.entry(id: "revision.selectInLeftPanel")?.children.count == 4, "context: left panel lists tags and branches")
        let topIDs = menu.compactMap(\.id)
        check(topIDs.firstIndex(of: "revision.copy")! < topIDs.firstIndex(of: "revision.branch.checkout")!
              && topIDs.firstIndex(of: "revision.branch.resetCurrent")! < topIDs.firstIndex(of: "revision.selectInLeftPanel")!
              && topIDs.firstIndex(of: "revision.compare")! < topIDs.firstIndex(of: "revision.navigate")!
              && topIDs.firstIndex(of: "revision.navigate")! < topIDs.firstIndex(of: "revision.view")!, "context: upstream item order")
        check(menu.entry(id: "revision.view.commit") == nil && menu.entry(id: "revision.other.object") == nil, "context: no invented view/object items")

        context.clickedReference = other
        context.refFocused = true
        menu = RevisionContextMenuBuilder.build(context)
        check(menu.entry(id: "revision.otherActions") != nil && !menu.compactMap(\.id).contains("revision.navigate"),
              "context: a clicked label moves advanced items into Other actions")
        check(menu.entry(id: "revision.otherActions")?.children.entry(id: "revision.branch.resetOther") != nil, "context: reset another is advanced")
        check((menu.entry(id: "revision.branch.checkout")?.children ?? []).compactMap(\.id) == ["revision.branch.checkout.ref.\(other.id)"],
              "context: ref dropdowns are filtered to the clicked ref")
        check(menu.entry(id: "revision.selectInLeftPanel.ref.\(other.id)") != nil, "context: one left-panel ref is a direct command")

        let head = RevisionReference(id: "refs/heads/main", name: "main", kind: .currentBranch)
        let current = makeCommit("head", parents: ["base"], refs: [head])
        menu = RevisionContextMenuBuilder.build(.init(focusedCommit: current, selectedCommits: [current], history: [current], currentBranchName: "main"))
        check(menu.entry(id: "revision.branch.merge") == nil, "context: nothing to merge when the current branch points here")
        check(menu.entry(id: "revision.branch.delete")?.isEnabled == false, "context: current branch delete is visible but disabled")
        let plain = makeCommit("plain", parents: ["base"])
        menu = RevisionContextMenuBuilder.build(.init(focusedCommit: plain, selectedCommits: [plain], history: [plain], currentBranchName: "main"))
        check(menu.entry(id: "revision.branch.merge.commit") != nil, "context: a plain commit can be merged by hash")
        check(menu.entry(id: "revision.selectInLeftPanel") == nil, "context: no left-panel entry without refs")

        var scripted = RevisionContextMenuContext(focusedCommit: plain, selectedCommits: [plain], history: [plain], currentBranchName: "main")
        scripted.scripts = [(id: "a", title: "Hosted", direct: false), (id: "b", title: "Direct", direct: true)]
        menu = RevisionContextMenuBuilder.build(scripted)
        let ids = menu.compactMap(\.id)
        check(menu.entry(id: "revision.script")?.children.compactMap(\.id) == ["revision.script.run.a"]
              && ids.firstIndex(of: "revision.script.run.b") == ids.firstIndex(of: "revision.script")! + 1, "context: user script placement")
    }

    private static func testCopyMenu() {
        let branch = RevisionReference(id: "refs/heads/topic", name: "topic", kind: .localBranch)
        let first = makeCommit("first", body: "second line", refs: [branch])
        let entries = RevisionContextMenuBuilder.copyMenu([first]).children
        check(entries.first?.id == "revision.copy.caption.branches" && entries.first?.isEnabled == false, "copy: branch caption")
        guard case .command(_, let hashTitle, _)? = entries.first(where: { $0.id == "revision.copy.hash" }) else {
            preconditionFailure("copy: hash item")
        }
        check(hashTitle.hasPrefix("Commit hash:   ") && hashTitle.count <= "Commit hash:   ".count + 40, "copy: hash preview")
        check(entries.contains { $0.id == "revision.copy.date" } && !entries.contains { $0.id == "revision.copy.commitDate" },
              "copy: identical author/commit dates use a single Date item")
        let second = makeCommit("second", commitDate: Date(timeIntervalSince1970: 99))
        let multi = RevisionContextMenuBuilder.copyMenu([first, second]).children
        check(multi.contains { $0.id == "revision.copy.authorDate" } && multi.contains { $0.id == "revision.copy.commitDate" }, "copy: plural dates")
        check(RevisionContextMenuBuilder.copyValues([first, first, second], \.authorName) == ["Test"], "copy: distinct values")
        check(RevisionContextMenuBuilder.copyPreview([String(repeating: "x", count: 60)]).count == 40, "copy: preview shortened to 40")
    }



    private static func testReaderAgainstRepository() async throws {
        let fixture = try GridFixture.make()
        defer { fixture.remove() }
        let url = try fixture.repository("Reader")
        try fixture.commit("a.txt", "one", "Base", in: url, author: "Ann <ann@example.com>")
        try fixture.git(["checkout", "-b", "feature"], in: url)
        try fixture.commit("b.txt", "two", "Feature work", in: url, author: "Bob <bob@example.com>")
        try fixture.git(["checkout", "main"], in: url)
        try fixture.git(["mv", "a.txt", "renamed.txt"], in: url)
        try fixture.git(["commit", "-m", "Rename"], in: url)
        try fixture.commit("renamed.txt", "three", "Edit renamed", in: url, author: "Ann <ann@example.com>")
        try fixture.git(["notes", "add", "-m", "note text", "HEAD"], in: url)
        try fixture.git(["tag", "-a", "v1", "-m", "annotated", "HEAD~1"], in: url)
        try fixture.git(["update-ref", "refs/bisect/bad", "HEAD"], in: url)
        try Data("dirty".utf8).write(to: url.appendingPathComponent("renamed.txt"))

        let module = GitRepositoryModule(repositoryURL: url, git: GitProcess())
        let state = try await module.loadRepositoryState()
        func read(_ configure: (inout RevisionReadOptions) -> Void) async throws -> [Commit] {
            var options = RevisionReadOptions()
            configure(&options)
            var result: [Commit] = []
            for try await batch in await state.revisionReadRequest.reader.read(state.revisionReadRequest.context.with(options)) {
                result += batch
            }
            return result
        }
        let all = try await read { _ in }
        check(all.contains { $0.subject == "Feature work" }, "reader: all branches")
        check(!all.contains { $0.subject.hasPrefix("Notes added by") }, "reader: refs/notes/commits is excluded unless git notes are shown")
        check(all.prefix(2).map(\.kind) == [.workingDirectory, .index], "reader: artificial rows precede HEAD")
        let headCommit = all.first { $0.isHEAD }
        check(all.first { $0.references.contains { $0.kind == .bisectBad } }?.id == headCommit?.id, "reader: refs/bisect/bad decorates HEAD")
        check(all.flatMap(\.references).first { $0.name == "v1" }?.isAnnotated == true, "reader: annotated tag")

        let current = try await read { $0.filter.showCurrentBranchOnly = true }
        check(!current.contains { $0.subject == "Feature work" }, "reader: current branch only")
        let authored = try await read { $0.filter.byAuthor = true; $0.filter.author = "bob"; $0.showArtificialCommits = false }
        check(authored.map(\.subject) == ["Feature work"], "reader: case-insensitive author filter")
        let noArtificial = try await read { $0.showArtificialCommits = false }
        check(!noArtificial.contains(where: \.isArtificial), "reader: artificial commits can be hidden")
        let notes = try await read { $0.loadNotes = true; $0.showArtificialCommits = false }
        check(notes.first?.notes == "note text", "reader: notes are loaded")
        let topo = try await read { $0.sortOrder = .topology; $0.showArtificialCommits = false }
        check(Set(topo.map(\.id)) == Set(noArtificial.map(\.id)), "reader: topo order reads the same revisions")
        let path = try await read { $0.filter.byPathFilter = true; $0.filter.pathFilter = "renamed.txt"; $0.showArtificialCommits = false }
        check(path.map(\.subject).contains("Base"), "reader: path filter follows renames")
        let limited = try await read { $0.filter.byCommitsLimit = true; $0.filter.commitsLimit = 1; $0.showArtificialCommits = false }
        check(limited.count == 1, "reader: commit limit")
        let mergedHidden = try await read { $0.filter.showCurrentBranchOnly = true; $0.filter.lastRevisionToDisplay = nil }
        check(mergedHidden.contains { $0.kind == .workingDirectory }, "reader: artificial rows follow HEAD in current-branch mode")

        let option = await module.resolveRevision("-h"), tagged = await module.resolveRevision("v1")
        check(option == nil && tagged != nil, "resolve: options are rejected, tags resolve")
    }

    private static func testAheadBehindAndMergeBase() async throws {
        let fixture = try GridFixture.make()
        defer { fixture.remove() }
        let origin = try fixture.repository("Origin")
        try fixture.commit("a.txt", "1", "Base", in: origin)
        let clone = fixture.root.appendingPathComponent("Clone", isDirectory: true)
        try fixture.git(["clone", origin.path, clone.path], in: fixture.root)
        try fixture.identity(clone)
        try fixture.commit("b.txt", "2", "Local", in: clone)
        try fixture.git(["checkout", "-b", "doomed", "--track", "origin/main"], in: clone)
        try fixture.git(["checkout", "main"], in: clone)
        let module = GitRepositoryModule(repositoryURL: clone, git: GitProcess())
        _ = try await module.loadRepositoryState()
        var data = await module.aheadBehindData()
        check(data["main"]?.aheadCount == "1" && data["main"]?.remoteRef == "refs/remotes/origin/main", "ahead/behind: real push counts")
        try fixture.git(["update-ref", "-d", "refs/remotes/origin/main"], in: clone)
        data = await module.aheadBehindData()
        check(data["doomed"]?.isGone == true, "ahead/behind: removed remote branch is gone")

        let base = try ObjectID.parse(fixture.git(["rev-parse", "HEAD~1"], in: clone).trimmingCharacters(in: .whitespacesAndNewlines))
        let head = try ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: clone).trimmingCharacters(in: .whitespacesAndNewlines))
        let single = try await module.mergeBase(of: [base], includesArtificial: false)
        check(single == base, "merge base: single selection with HEAD")
        try fixture.git(["checkout", "--orphan", "island"], in: clone)
        try fixture.commit("c.txt", "3", "Island", in: clone)
        let island = try ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: clone).trimmingCharacters(in: .whitespacesAndNewlines))
        let unrelated = try await module.mergeBase(of: [head, island], includesArtificial: false)
        check(unrelated == nil, "merge base: unrelated histories")
        let ancestors = await module.ancestors(of: head)
        check(ancestors == [head, base], "TryGetParents: rev-list lists the revision and its ancestors")
    }

    private static func testSuperprojectLabels() async throws {
        let fixture = try GridFixture.make()
        defer { fixture.remove() }
        let library = try fixture.repository("Library")
        try fixture.commit("lib.txt", "1", "Library", in: library)
        let superproject = try fixture.repository("Super")
        try fixture.commit("root.txt", "1", "Root", in: superproject)
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", library.path, "lib"], in: superproject)
        try fixture.git(["commit", "-m", "Add submodule"], in: superproject)
        try fixture.git(["tag", "release"], in: superproject)
        let submodule = superproject.appendingPathComponent("lib", isDirectory: true)
        let recorded = try ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: submodule).trimmingCharacters(in: .whitespacesAndNewlines))
        let module = GitRepositoryModule(repositoryURL: submodule, git: GitProcess())
        _ = try await module.loadRepositoryState()
        let info = await module.superprojectInfo(branches: true, remoteBranches: false, tags: true)
        check(info?.currentCommit == recorded, "superproject: recorded gitlink commit")
        check(Set(info?.refs[recorded]?.map(\.name) ?? []) == ["main", "release"], "superproject: branch and tag labels")
        let tagsOff = await module.superprojectInfo(branches: true, remoteBranches: false, tags: false)
        check(tagsOff?.refs[recorded]?.map(\.name) == ["main"], "superproject: label kinds follow the View menu")
        let plain = GitRepositoryModule(repositoryURL: library, git: GitProcess())
        _ = try await plain.loadRepositoryState()
        let none = await plain.superprojectInfo(branches: true, remoteBranches: true, tags: true)
        check(none == nil, "superproject: none outside a submodule")
    }



    @MainActor
    private static func testIncrementalGraphScrolling() async throws {
        let grid = RevisionGridViewController()
        let window = NSWindow(contentViewController: grid)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 500))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let revisions = (0..<2_000).map { makeCommit("scroll\($0)", parents: $0 == 1_999 ? [] : ["scroll\($0 + 1)"]) }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<500 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            check(false, "scroll cache: timed out waiting for \(label)")
        }
        grid.beginIncrementalLoad(preferredCommitID: revisions[10].id)
        grid.appendIncrementalBatch(Array(revisions.prefix(100)))
        try await wait("initial selection") { grid.selectedCommits.map(\.id) == [revisions[10].id] }
        grid.selectCommits(ids: [revisions[5].id, revisions[10].id])
        grid.appendIncrementalBatch(Array(revisions.dropFirst(100)))
        grid.finishLoading()
        try await wait("all identities") { grid.visibleCommitCount == revisions.count }
        check(grid.cachedGraphRowCount < 200, "scroll cache: all history IDs arrive without laying out the whole graph")
        check(Set(grid.selectedCommits.map(\.id)) == Set([revisions[5].id, revisions[10].id]), "scroll cache: appending/EOF preserves multiselection")
        var selections = 0
        grid.onSelection = { _ in selections += 1 }
        grid.selectCommit(id: revisions[500].id)
        try await wait("scrolled graph page") { grid.cachedGraphRowCount > 500 }
        let afterSelection = selections
        grid.selectCommit(id: revisions[10].id)
        try await Task.sleep(for: .milliseconds(100))
        check(grid.selectedCommits.map(\.id) == [revisions[10].id] && selections > afterSelection,
              "scroll cache: selecting/scrolling back uses correct repository revision")
        let stableSelections = selections
        grid.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        check(selections == stableSelections, "scroll cache: presentation/cache extension does not send duplicate details selections")

        grid.beginIncrementalLoad()
        grid.appendIncrementalBatch(revisions)
        grid.beginIncrementalLoad(preferredCommitID: revisions[0].id)
        grid.appendIncrementalBatch(Array(revisions.prefix(2)))
        grid.finishLoading()
        try await wait("restart") { grid.visibleCommitCount == 2 && grid.cachedGraphRowCount == 2 }
        check(grid.selectedCommits.map(\.id) == [revisions[0].id], "scroll cache: restarted reader cannot publish stale rows/selection")
    }

    @MainActor
    private static func testGridCommandsAndNavigation() async throws {
        let store = AppSettingsStore.shared
        let savedPreferences = store.revisionGridPreferences
        let savedRuntime = store.revisionGridRuntime
        let savedColors = store.colorPreferences
        defer {
            store.saveRevisionGridPreferences(savedPreferences)
            store.revisionGridRuntime = savedRuntime
            store.colorPreferences = savedColors
        }
        let grid = RevisionGridViewController()
        _ = grid.view
        var refreshes = 0, menuChanges = 0
        grid.onRefreshRequested = { refreshes += 1 }
        grid.onMenuStateChanged = { menuChanges += 1 }
        let base = makeCommit("base")
        let middle = makeCommit("middle", parents: ["base"])
        let top = makeCommit("top", parents: ["middle"], refs: [RevisionReference(id: "refs/heads/main", name: "main", kind: .currentBranch)])
        grid.beginIncrementalLoad()
        grid.appendIncrementalBatch([top, middle, base])
        grid.apply(commits: [top, middle, base])

        for _ in 0..<200 where grid.visibleCommitCount < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        check(grid.visibleCommitCount == 3 && grid.selectedCommits.map(\.id) == [top.id], "grid: load selects the first revision")
        grid.selectCommits(ids: [middle.id, base.id])
        check(grid.performGridCommand("revision.view.highlightBranch"), "graph: highlight command is implemented")
        try await Task.sleep(for: .milliseconds(100))
        check(Set(grid.selectedCommits.map(\.id)) == Set([middle.id, base.id]) && refreshes == 0,
              "graph: highlighting preserves multiselection without restarting the reader")
        grid.reloadAppearance()
        try await Task.sleep(for: .milliseconds(100))
        check(Set(grid.selectedCommits.map(\.id)) == Set([middle.id, base.id]), "graph: appearance redraw preserves multiselection")
        grid.setSelectedRevision(top.id)

        let before = store.revisionGridPreferences.showCommitBody
        check(grid.performGridCommand("revision.view.commitBody") && store.revisionGridPreferences.showCommitBody != before && refreshes == 0,
              "grid: commit body toggles without re-reading revisions")
        check(grid.performGridCommand("revision.view.stashes") && refreshes == 1, "grid: stashes toggle refreshes revisions")
        store.revisionGridRuntime.sortOrder = .gitDefault
        grid.performGridCommand("revision.sort.topo")
        check(store.revisionGridRuntime.sortOrder == .topology && refreshes == 2, "grid: topo order is a runtime toggle")
        grid.performGridCommand("revision.sort.topo")
        check(store.revisionGridRuntime.sortOrder == .gitDefault, "grid: toggling topo again restores Git order")
        grid.performGridCommand("revision.branches.current")
        check(grid.currentFilter.isShowCurrentBranchOnlyChecked && grid.readOptions.filter.showCurrentBranchOnly, "grid: current branch only")
        grid.performGridCommand("revision.branches.all")
        check(grid.currentFilter.isShowAllBranchesChecked, "grid: all branches")
        check(!grid.performGridCommand("revision.unknown"), "grid: unknown commands are not claimed")
        check(menuChanges > 0 && grid.menuState.sortOrder == .gitDefault, "grid: menu state is published")

        check(grid.setSelectedRevision(top.id), "navigation: select top")
        check(grid.setSelectedRevision(middle.id) && grid.setSelectedRevision(base.id), "navigation: select older revisions")
        check(grid.canNavigateBackward && !grid.canNavigateForward, "navigation: backward history")
        grid.navigateBackward()
        check(grid.selectedCommits.map(\.id) == [middle.id] && grid.canNavigateForward, "navigation: back selects the previous revision")
        grid.navigateForward()
        check(grid.selectedCommits.map(\.id) == [base.id], "navigation: forward returns")
        grid.goToChild()
        check(grid.selectedCommits.map(\.id) == [middle.id], "navigation: child")
        grid.goToParent()
        check(grid.selectedCommits.map(\.id) == [base.id], "navigation: parent history returns to the previous child")
        grid.selectCurrentRevision()
        check(grid.selectedCommits.map(\.id) == [top.id], "navigation: current revision")
        check(!grid.setSelectedRevision(testRevisionID("missing")), "navigation: filtered revisions report failure")
        check(grid.setSelectedRevision(base.id, toggle: true) && grid.selectedCommits.count == 2, "navigation: toggle extends the selection")


        grid.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        grid.view.layoutSubtreeIfNeeded()
        grid.fitMessageColumn()
        let otherWidths = ["Graph", "Notes", "Avatar", "Author Name", "Date", "Commit ID", "Build Status"].reduce(CGFloat(0)) { total, id in
            guard let column = (grid.view as? NSScrollView).flatMap({ ($0.documentView as? NSTableView)?.tableColumn(withIdentifier: .init(id)) }),
                  !column.isHidden else { return total }
            return total + column.width
        }
        let clip = (grid.view as? NSScrollView)?.contentView.bounds.width ?? 0
        check(clip > 0 && abs(grid.messageColumnWidth + otherWidths - clip) < 12, "columns: Message fills the remaining width")


        grid.showLoading(spinner: true)
        check(grid.isShowingLoading, "loading: spinner while reading")
        grid.finishLoading()
        check(!grid.isShowingLoading && grid.visiblePage == nil, "loading: revisions show the grid")
        grid.finishLoading(failed: true)
        check(grid.visiblePage == "revisionGrid.error", "loading: read failure shows ErrorControl")
        let empty = RevisionGridViewController()
        _ = empty.view
        empty.beginIncrementalLoad()
        empty.finishLoading()
        check(empty.visiblePage == "revisionGrid.empty", "loading: nothing read shows EmptyRepoControl")
        func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
        var editGitIgnoreRequested = false
        empty.onEmptyRepositoryEditGitIgnore = { editGitIgnoreRequested = true }
        let editGitIgnore = subviews(empty.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "revisionGrid.empty.editGitIgnore" }
        check(editGitIgnore?.isEnabled == true, "EmptyRepoControl: Edit .gitignore is available")
        empty.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let page = subviews(empty.view).first { $0.identifier?.rawValue == "revisionGrid.empty" }
        let order = empty.view.subviews
        check(page?.frame == empty.view.bounds && page.flatMap { order.firstIndex(of: $0) } ?? -1 > (order.firstIndex(of: (empty.view as! NSScrollView).contentView) ?? .max),
              "EmptyRepoControl covers the grid above its clip view")
        if let editGitIgnore { NSApp.sendAction(editGitIgnore.action!, to: editGitIgnore.target, from: editGitIgnore) }
        check(editGitIgnoreRequested, "EmptyRepoControl: Edit .gitignore starts FormGitIgnore")


        var messages: [String] = []
        let savedPresent = RevisionGridMessages.present
        RevisionGridMessages.present = { message, _ in messages.append(message) }
        defer { RevisionGridMessages.present = savedPresent }
        var applied: [URL] = []
        grid.onApplyPatch = { applied.append($0) }
        let patches = (0..<3).map { URL(fileURLWithPath: "/tmp/p\($0).patch") } + [URL(fileURLWithPath: "/tmp/notes.txt")]
        check(grid.dropPatchFiles(patches) && applied.count == 3, "drop: each .patch file starts Apply patch")
        applied = []
        check(grid.dropPatchFiles((0..<11).map { URL(fileURLWithPath: "/tmp/\($0).patch") }) && applied.isEmpty
              && messages.last == "For you own protection dropping more than 10 patch files at once is blocked!", "drop: more than 10 files are blocked")
        grid.dataSource = FakeGridSource(resolved: ["refs/remotes/origin/main": testObjectID("middle"), "refs/tags/hidden": testObjectID("hidden")])
        grid.goToRef("refs/remotes/origin/main", showNoRevisionMessage: true)
        for _ in 0..<100 where grid.selectedCommits.map(\.id) != [middle.id] { try await Task.sleep(nanoseconds: 10_000_000) }
        check(grid.selectedCommits.map(\.id) == [middle.id], "GoToRef: resolves and selects the related ref")
        grid.goToRef("refs/tags/hidden", showNoRevisionMessage: true)
        for _ in 0..<100 where !messages.contains(where: { $0.contains("is not visible in the revision grid") }) { try await Task.sleep(nanoseconds: 10_000_000) }
        check(messages.contains { $0.contains("is not visible in the revision grid") }, "GoToRef: filtered revisions are reported")
        grid.goToRef("nope", showNoRevisionMessage: true)
        for _ in 0..<100 where messages.last != "No revision found." { try await Task.sleep(nanoseconds: 10_000_000) }
        check(messages.last == "No revision found.", "GoToRef: unknown refs are reported")


        let toolbar = RevisionFilterToolbar()
        toolbar.grid = grid
        grid.onFilterChanged = { toolbar.filterChanged($0) }
        toolbar.references = { .init(local: ["main", "topic"], remote: ["origin/main"], tags: ["v1"]) }
        var warnings: [String] = []
        toolbar.warn = { warnings.append($0) }
        toolbar.resolveRevision = { $0 == "abc123" ? testObjectID("abc") : nil }
        toolbar.revisionCombo.stringValue = "needle"
        toolbar.applyRevisionFilter()
        check(grid.currentFilter.byMessage && grid.currentFilter.message == "needle", "toolbar: commit message filter by default")
        check(store.revisionGridPreferences.revisionFilterHistory.first == "needle", "toolbar: filter history")
        check(toolbar.branchSuggestions(for: "") == ["main", "topic"], "toolbar: Local branch type by default")
        check(toolbar.branchSuggestions(for: "zzz") == [RevisionFilterToolbar.noResultsFound], "toolbar: no results")
        toolbar.branchCombo.stringValue = "topic missing abc123 feat*"
        toolbar.applyCustomBranchFilter(checkBranch: true)
        for _ in 0..<200 where !grid.currentFilter.byBranchFilter { try await Task.sleep(nanoseconds: 10_000_000) }
        check(grid.currentFilter.branchFilter == "topic abc123 feat*" && warnings == ["missing"], "toolbar: nonexisting revisions are ignored")
        check(grid.currentFilter.isShowFilteredBranchesChecked, "toolbar: branch filter selects filtered branches")
        grid.resetAllFiltersAndRefresh()
        check(!grid.currentFilter.hasFilter && grid.currentFilter.isShowAllBranchesChecked, "toolbar: reset clears filters")
    }



    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure("RevisionGridTests: \(message)") }
    }

    private static func makeCommit(_ id: String, parents: [String] = [], body: String = "", refs: [RevisionReference] = [],
                                   commitDate: Date = Date(timeIntervalSince1970: 1)) -> Commit {
        Commit(id: testRevisionID(id), shortID: id, subject: id, body: body, authorName: "Test", authorEmail: "test@example.com",
               authorDate: Date(timeIntervalSince1970: 1), committerName: "Test", committerEmail: "test@example.com",
               commitDate: commitDate, parentIDs: parents.map(testObjectID), references: refs, kind: .revision)
    }
}

private struct FakeGridSource: RepositoryRevisionGridDataSource {
    var resolved: [String: ObjectID]
    func resolveRevision(_ expression: String) async -> ObjectID? { resolved[expression] }
    func openDirDiffWithDifftool(first: RevisionID?, second: RevisionID) async throws {}
    func mergeBase(of revisions: [ObjectID], includesArtificial: Bool) async throws -> ObjectID? { nil }
    func ancestors(of revision: ObjectID) async -> [ObjectID] { [] }
    func aheadBehindData() async -> [String: AheadBehindData] { [:] }
    func superprojectInfo(branches: Bool, remoteBranches: Bool, tags: Bool) async -> SuperprojectInfo? { nil }
}

private final class GridFixture {
    let root: URL
    private init(root: URL) { self.root = root }

    static func make() throws -> GridFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Grid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return GridFixture(root: root.resolvingSymlinksInPath())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-b", "main", url.path], in: root)
        try identity(url)
        return url
    }

    func identity(_ url: URL) throws {
        try git(["config", "user.name", "Grid Fixture"], in: url)
        try git(["config", "user.email", "grid@example.com"], in: url)
        try git(["config", "commit.gpgsign", "false"], in: url)
    }

    func commit(_ file: String, _ content: String, _ message: String, in url: URL, author: String? = nil) throws {
        try Data(content.utf8).write(to: url.appendingPathComponent(file))
        try git(["add", file], in: url)
        try git(["commit", "-m", message] + (author.map { ["--author", $0] } ?? []), in: url)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            preconditionFailure("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
