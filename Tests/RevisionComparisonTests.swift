@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit

@MainActor
enum RevisionComparisonTests {
    static func run() async throws {
        _ = NSApplication.shared
        let defaults = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        check(!defaults.automaticContinuousScroll && defaults.automaticContinuousScrollDelay == 600, "upstream continuous-scroll defaults migrate safely")
        let saved = AppSettingsStore.shared.revisionGridPreferences
        let runtime = AppSettingsStore.shared.revisionGridRuntime
        let statusPreferences = AppSettingsStore.shared.fileStatusListPreferences
        let hotkeys = AppSettingsStore.shared.hotkeyOverrides
        defer {
            AppSettingsStore.shared.saveRevisionGridPreferences(saved)
            AppSettingsStore.shared.revisionGridRuntime = runtime
            AppSettingsStore.shared.saveFileStatusListPreferences(statusPreferences)
            AppSettingsStore.shared.hotkeyOverrides = hotkeys
        }
        AppSettingsStore.shared.saveRevisionGridPreferences(RevisionGridPreferences())
        AppSettingsStore.shared.revisionGridRuntime = RevisionGridRuntimeSettings()
        AppSettingsStore.shared.hotkeyOverrides = [:]
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("space ü.txt", "base\n"); try fixture.commitAll("base")
        let baseID = try fixture.head()
        try fixture.git(["checkout", "-q", "-b", "topic"])
        try fixture.write("topic.txt", "topic\n"); try fixture.write("topic-more.txt", "another\n"); try fixture.commitAll("topic")
        let topicID = try fixture.head()
        try fixture.git(["checkout", "-q", "main"])
        try fixture.write("main.txt", "main\n"); try fixture.commitAll("main")
        let mainID = try fixture.head()
        try fixture.git(["tag", "target", topicID.string])
        try fixture.git(["remote", "add", "origin", fixture.repo.path])
        try fixture.git(["update-ref", "refs/remotes/origin/topic", topicID.string])
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let state = try await module.loadRepositoryState()
        let request = try await module.comparisonReadRequest()
        check(request.reader !== state.revisionReadRequest.reader, "independent reader session")
        let main = try await module.comparisonRevision(.object(mainID), headID: mainID)
        let topic = try await module.comparisonTarget("origin/topic")
        let base = try await module.comparisonTarget("HEAD~1")
        let tag = try await module.comparisonTarget("target")
        check(topic.objectID == topicID && tag.objectID == topicID && base.objectID == baseID, "branch/tag/expression resolution")
        check(main.parentIDs == [baseID], "actual parents")
        check(RevisionComparison.firstID(in: [main]) == .object(baseID), "one revision uses first parent")
        check(RevisionComparison.firstID(in: [main, topic, base]) == .object(baseID), "latest first, earliest last")
        check(RevisionComparison.firstID(in: [base]) == nil, "root has no implicit base")
        let worktree = try await module.comparisonRevision(.workingDirectory, headID: mainID)
        let index = try await module.comparisonRevision(.index, headID: mainID)
        check(worktree.objectID == nil && index.objectID == nil && RevisionComparison.firstID(in: [worktree]) == .index
              && RevisionComparison.firstID(in: [index]) == .object(mainID), "artificial identities and parent semantics")
        check(try await module.comparisonMergeBase(first: main.id, second: topic.id, headID: mainID) == baseID, "merge base")
        check(try await module.comparisonMergeBase(first: main.id, second: .workingDirectory, headID: mainID) == nil, "same HEAD merge base disabled")
        check(try await module.comparisonMergeBase(first: topic.id, second: .index, headID: mainID) == baseID, "artificial merge base resolves HEAD")
        check(try await module.comparisonCount(from: main.id, to: "origin/topic", headID: mainID) == "(+1-1)", "BranchSelector counts")
        do { _ = try await module.comparisonTarget("no-such-target"); check(false, "invalid target fails") } catch {}
        do { _ = try await module.comparisonRevision(.object(testObjectID("missing")), headID: mainID); check(false, "stale object fails") } catch {}

        try fixture.write("space ü.txt", "staged\n"); try fixture.git(["add", "space ü.txt"])
        try fixture.write("space ü.txt", "unstaged\n")
        let before = try fixture.git(["status", "--porcelain=v2"])
        let cases: [(RevisionID, RevisionID, String)] = [(main.id, .index, "staged"), (.index, .workingDirectory, "unstaged"), (.workingDirectory, .index, "staged")]
        for (a, b, text) in cases {
            let first = try await module.comparisonRevision(a, headID: mainID)
            let second = try await module.comparisonRevision(b, headID: mainID)
            let groups = try await module.calculateFileStatus(.init(revisions: [second, first], headID: mainID, allowMultiDiff: false), describe: { $0.shortString })
            guard let group = groups.first, let file = group.files.first,
                  case .diff(let diff?) = try await module.loadFileStatusDiff(group: group, file: file, options: FileDiffOptions(), grep: GitGrepOptions()) else {
                check(false, "shared diff has output"); return
            }
            check(diff.lines.contains { $0.kind == .addition && $0.text.contains(text) }, "directional artificial diff")
        }
        try await hosted(module: module, request: request, main: main, topic: topic, base: base)
        check(try fixture.git(["status", "--porcelain=v2"]) == before && fixture.head() == mainID, "comparisons never mutate")

        let bare = fixture.root.appendingPathComponent("bare.git")
        try fixture.git(["clone", "--bare", fixture.repo.path, bare.path])
        let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
        let bareRequest = try await bareModule.comparisonReadRequest()
        check(bareRequest.identity.currentRepository.isBare, "bare identity")
        let bareCommit = try await bareModule.comparisonTarget("topic")
        check(bareCommit.objectID == topicID, "bare comparison target")
        var bareRevisions: [Commit] = []
        for try await batch in await bareRequest.reader.read(bareRequest.context) { bareRevisions += batch }
        check(!bareRevisions.contains(where: \.isArtificial), "bare grid omits artificial rows")
        let bareBrowser = RepositoryBrowserViewController(repositoryModule: bareModule)
        let bareOwner = NSWindow(contentViewController: bareBrowser)
        bareOwner.makeKeyAndOrderFront(nil); defer { bareOwner.close() }
        try await wait("bare Browser identity") { bareBrowser.repositoryIdentity?.currentRepository.isBare == true }
        let bareCommands = GitUICommands(repositoryModule: bareModule, browser: bareBrowser)
        bareCommands.startViewRevisions([bareCommit], owner: bareOwner)
        var bareDiff: CommitDiffWindowController?
        try await wait("bare CommitDiff handoff") {
            bareDiff = NSApp.windows.compactMap { $0.windowController as? CommitDiffWindowController }
                .first { $0.infoController.commit?.id == bareCommit.id }
            return bareDiff != nil
        }
        defer { bareDiff?.close() }
        check(bareDiff?.diffController.isBareRepository == true
              && bareDiff?.diffController.filesController.isBareRepository == true,
              "bare CommitDiff disables working-tree file actions")
        print("RevisionComparisonTests: passed")
    }

    private static func hosted(module: GitRepositoryModule, request: RevisionComparisonReadRequest, main: Commit, topic: Commit, base: Commit) async throws {
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let owner = NSWindow(contentViewController: browser); owner.setContentSize(NSSize(width: 1100, height: 800)); owner.makeKeyAndOrderFront(nil)
        defer { owner.close() }
        let commands = GitUICommands(repositoryModule: module, browser: browser)
        var notifications = 0
        let subscription = commands.repositoryChangedNotifier.subscribe { _, _ in notifications += 1 }
        defer { subscription.cancel() }
        let window = try await commands.showRevisionComparison(first: topic, second: main, request: request, owner: owner)
        defer { window.close() }
        let pair = window.contentViewController as! RevisionPairViewController
        try await wait("initial comparison loads without touching controls") {
            !pair.diff.filesController.isLoading && !pair.diff.filesController.selectedItems().isEmpty
        }
        check(pair.mergeBase?.id == base.id && pair.effectiveFirst.id == topic.id, "opening base captured, unchecked")
        pair.baseCheckbox.state = .on; pair.populate()
        check(pair.effectiveFirst.id == base.id, "merge base toggle")
        pair.swapEndpoints()
        check(pair.first.id == main.id && pair.second.id == topic.id && pair.mergeBase?.id == base.id, "swap retains original merge base")
        pair.replaceEndpoint(first: true, revision: base)
        check(pair.mergeBase?.id == base.id, "pick retains original base")
        pair.baseCheckbox.state = .off; pair.populate()
        check(pair.effectiveFirst.id == base.id, "unchecked uses chosen endpoint")
        try await wait("file list") { !pair.diff.filesController.isLoading && !pair.diff.filesController.selectedItems().isEmpty }
        let firstFile = pair.diff.filesController.selectedItems().first
        let moved = pair.diff.filesController.selectAdjacentVisibleFile(forward: true)
        check(moved && pair.diff.filesController.selectedItems().first != firstFile, "next visible file")
        check(pair.diff.filesController.selectAdjacentVisibleFile(forward: false) && pair.diff.filesController.selectedItems().first == firstFile, "previous visible file")

        let comparison = commands.startCompareRevisions(owner: owner)!
        defer { comparison.close() }
        let content = comparison.contentViewController as! RevisionComparisonGridController
        try await wait("comparison stream") { !content.isLoading && !content.revisions.isEmpty && !content.grid.isShowingLoading }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = descendants(content.grid.view).compactMap { $0 as? NSTableView }.first!
        table.deselectAll(nil)
        check(content.grid.selectedCommits.isEmpty, "grid permits upstream empty-selection comparison")
        var viewed: [Commit]?
        content.grid.onViewSelected = { viewed = $0 }
        content.grid.perform(NSSelectorFromString("openSelectedCommit"))
        check(viewed?.isEmpty == true, "empty double-click routes to general comparison")
        content.grid.selectCommit(id: main.id)
        comparison.window?.makeFirstResponder(table)
        let selectBase = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 1, windowNumber: comparison.window!.windowNumber, context: nil,
            characters: "\u{c}", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!
        table.keyDown(with: selectBase)
        check(content.grid.comparisonBase?.id == main.id, "BASE grid-local")
        content.grid.selectCommit(id: topic.id)
        content.reload()
        try await wait("reload selection") { !content.isLoading && !content.grid.isShowingLoading && content.grid.selectedCommits.first?.id == topic.id }
        check(content.grid.comparisonBase?.id == main.id, "BASE survives reload")
        content.grid.setAndApplyPathFilter("does-not-exist")
        content.grid.setAndApplyPathFilter("main.txt")
        try await wait("filtered history") { !content.isLoading && !content.grid.isShowingLoading && content.revisions.contains { $0.id == main.id } && !content.revisions.contains { $0.id == topic.id } }
        commands.repositoryChangedNotifier.notify()
        try await wait("notifier reload") { !content.isLoading && !content.grid.isShowingLoading && content.revisions.contains { $0.id == main.id } }
        check(notifications == 1, "only explicit mutation notification, no notification on reads")

        var context = RevisionContextMenuContext(focusedCommit: main, selectedCommits: [main], history: [main, topic, base], currentBranchName: "main")
        var menu = RevisionContextMenuBuilder.build(context)
        for id in ["branch", "current", "setBase", "worktree", "selected"] {
            check(menu.entry(id: "revision.compare." + id)?.isEnabled == true, "enabled comparison \(id)")
        }
        check(menu.entry(id: "revision.compare.base")?.isEnabled == false, "BASE requires remembered selection")
        context.hasComparisonBase = true; context.isBareRepository = true
        menu = RevisionContextMenuBuilder.build(context)
        check(menu.entry(id: "revision.compare.base")?.isEnabled == true && menu.entry(id: "revision.compare.worktree")?.isEnabled == false, "BASE/bare eligibility")
        let picker = ComparisonBranchPicker(branches: request.branches, selected: main.id, headID: main.objectID, source: module)
        _ = picker.view
        let values = (0..<picker.field.numberOfItems).compactMap { picker.field.itemObjectValue(at: $0) as? String }
        check(values.contains("origin/topic") && !values.contains("main") && picker.field.stringValue.isEmpty, "remote-first empty branch picker")
        let chooser = RevisionComparisonGridController(source: module, choosing: true, preselect: .index)
        let chooseWindow = RevisionComparisonWindowController(content: chooser, title: "Choose commit", size: NSSize(width: 900, height: 550), autosave: "RevisionCompareTests.Chooser")
        chooseWindow.showWindow(nil); defer { chooser.cancel(); chooseWindow.close() }
        try await wait("artificial picker") { !chooser.isLoading && !chooser.grid.isShowingLoading && chooser.grid.selectedCommits.first?.id == .index }
        check(chooser.grid.allowsArtificialViewSelection && !chooser.grid.allowsMultipleRevisionSelection, "picker allows artificial single selection")
        let chooserTable = descendants(chooser.grid.view).compactMap { $0 as? NSTableView }.first!
        check(!chooserTable.allowsMultipleSelection, "picker table remains single-select after loading")
    }

    private static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        check(predicate(), label)
    }
    private static func check(_ value: Bool, _ message: String) { if !value { fatalError("RevisionComparisonTests: " + message) } }
}
