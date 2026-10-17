import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Revision comparison")
    enum RevisionComparisonTests {
        @Test("Scenarios") static func run() async throws {
            let defaults = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
            #expect(!defaults.automaticContinuousScroll && defaults.automaticContinuousScrollDelay == 600, "upstream continuous-scroll defaults migrate safely")
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
            try fixture.write("space ü.txt", "base\n")
            try fixture.commitAll("base")
            let baseID = try fixture.head()
            try fixture.git(["checkout", "-q", "-b", "topic"])
            try fixture.write("topic.txt", "topic\n")
            try fixture.write("topic-more.txt", "another\n")
            try fixture.commitAll("topic")
            let topicID = try fixture.head()
            try fixture.git(["checkout", "-q", "main"])
            try fixture.write("main.txt", "main\n")
            try fixture.commitAll("main")
            let mainID = try fixture.head()
            try fixture.git(["tag", "target", topicID.string])
            try fixture.git(["remote", "add", "origin", fixture.repo.path])
            try fixture.git(["update-ref", "refs/remotes/origin/topic", topicID.string])
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let state = try await module.loadRepositoryState()
            let request = try await module.comparisonReadRequest()
            #expect(request.reader !== state.revisionReadRequest.reader, "independent reader session")
            let main = try await module.comparisonRevision(.object(mainID), headID: mainID)
            let topic = try await module.comparisonTarget("origin/topic")
            let base = try await module.comparisonTarget("HEAD~1")
            let tag = try await module.comparisonTarget("target")
            #expect(topic.objectID == topicID && tag.objectID == topicID && base.objectID == baseID, "branch/tag/expression resolution")
            #expect(main.parentIDs == [baseID], "actual parents")
            #expect(RevisionComparison.firstID(in: [main]) == .object(baseID), "one revision uses first parent")
            #expect(RevisionComparison.firstID(in: [main, topic, base]) == .object(baseID), "latest first, earliest last")
            #expect(RevisionComparison.firstID(in: [base]) == nil, "root has no implicit base")
            let worktree = try await module.comparisonRevision(.workingDirectory, headID: mainID)
            let index = try await module.comparisonRevision(.index, headID: mainID)
            #expect(
                worktree.objectID == nil && index.objectID == nil && RevisionComparison.firstID(in: [worktree]) == .index
                    && RevisionComparison.firstID(in: [index]) == .object(mainID), "artificial identities and parent semantics")
            #expect(try await module.comparisonMergeBase(first: main.id, second: topic.id, headID: mainID) == baseID, "merge base")
            #expect(try await module.comparisonMergeBase(first: main.id, second: .workingDirectory, headID: mainID) == nil, "same HEAD merge base disabled")
            #expect(try await module.comparisonMergeBase(first: topic.id, second: .index, headID: mainID) == baseID, "artificial merge base resolves HEAD")
            #expect(try await module.comparisonCount(from: main.id, to: "origin/topic", headID: mainID) == "(+1-1)", "BranchSelector counts")
            do {
                _ = try await module.comparisonTarget("no-such-target")
                Issue.record("invalid target fails")
            } catch {}
            do {
                _ = try await module.comparisonRevision(.object(testObjectID("missing")), headID: mainID)
                Issue.record("stale object fails")
            } catch {}

            try fixture.write("space ü.txt", "staged\n")
            try fixture.git(["add", "space ü.txt"])
            try fixture.write("space ü.txt", "unstaged\n")
            let before = try fixture.git(["status", "--porcelain=v2"])
            let cases: [(RevisionID, RevisionID, String)] = [
                (main.id, .index, "staged"), (.index, .workingDirectory, "unstaged"), (.workingDirectory, .index, "staged"),
            ]
            for (a, b, text) in cases {
                let first = try await module.comparisonRevision(a, headID: mainID)
                let second = try await module.comparisonRevision(b, headID: mainID)
                let groups = try await module.calculateFileStatus(
                    .init(revisions: [second, first], headID: mainID, allowMultiDiff: false), describe: { $0.shortString })
                guard let group = groups.first, let file = group.files.first,
                    case .diff(let diff?) = try await module.loadFileStatusDiff(group: group, file: file, options: FileDiffOptions(), grep: GitGrepOptions())
                else {
                    Issue.record("shared diff has output")
                    return
                }
                #expect(diff.lines.contains { $0.kind == .addition && $0.text.contains(text) }, "directional artificial diff")
            }
            try await hosted(module: module, request: request, main: main, topic: topic, base: base)
            #expect(try fixture.git(["status", "--porcelain=v2"]) == before && fixture.head() == mainID, "comparisons never mutate")

            let bare = fixture.root.appendingPathComponent("bare.git")
            try fixture.git(["clone", "--bare", fixture.repo.path, bare.path])
            let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
            let bareRequest = try await bareModule.comparisonReadRequest()
            #expect(bareRequest.identity.currentRepository.isBare, "bare identity")
            let bareCommit = try await bareModule.comparisonTarget("topic")
            #expect(bareCommit.objectID == topicID, "bare comparison target")
            var bareRevisions: [Commit] = []
            for try await batch in await bareRequest.reader.read(bareRequest.context) { bareRevisions += batch }
            #expect(!bareRevisions.contains { $0.isArtificial }, "bare grid omits artificial rows")
            let bareBrowser = RepositoryBrowserViewController(repositoryModule: bareModule)
            let bareOwner = NSWindow(contentViewController: bareBrowser)
            bareOwner.makeKeyAndOrderFront(nil)
            defer { bareOwner.close() }
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
            #expect(
                bareDiff?.diffController.isBareRepository == true
                    && bareDiff?.diffController.filesController.isBareRepository == true,
                "bare CommitDiff disables working-tree file actions")
        }

        private static func hosted(module: GitRepositoryModule, request: RevisionComparisonReadRequest, main: Commit, topic: Commit, base: Commit) async throws
        {
            let browser = RepositoryBrowserViewController(repositoryModule: module)
            let owner = NSWindow(contentViewController: browser)
            owner.setContentSize(NSSize(width: 1100, height: 800))
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            let commands = GitUICommands(repositoryModule: module, browser: browser)
            var notifications = 0
            let subscription = commands.repositoryChangedNotifier.subscribe { _, _ in notifications += 1 }
            defer { subscription.cancel() }
            let window = try await commands.showRevisionComparison(first: topic, second: main, request: request, owner: owner)
            defer { window.close() }
            let pair = window.contentViewController as! RevisionPairViewController
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let pickers = descendants(pair.view).compactMap { $0 as? NSButton }.filter {
                ["Select another branch", "Select another commit"].contains($0.toolTip ?? "")
            }
            #expect(
                pickers.count == 4 && pickers.allSatisfy { $0.title.isEmpty && $0.imagePosition == .imageOnly },
                "endpoint branch/commit pickers use source image-only controls")
            #expect(
                !pair.diff.filesController.canUseFindInCommitFilesGitGrep && !pair.diff.filesController.canAutoRefresh,
                "FormDiff preserves source standalone file-list capabilities")
            try await wait("initial comparison loads without touching controls") {
                !pair.diff.filesController.isLoading && !pair.diff.filesController.selectedItems().isEmpty
            }
            #expect(pair.mergeBase?.id == base.id && pair.effectiveFirst.id == topic.id, "opening base captured, unchecked")
            pair.baseCheckbox.state = .on
            pair.populate()
            #expect(pair.effectiveFirst.id == base.id, "merge base toggle")
            pair.swapEndpoints()
            #expect(pair.first.id == main.id && pair.second.id == topic.id && pair.mergeBase?.id == base.id, "swap retains original merge base")
            pair.replaceEndpoint(first: true, revision: base)
            #expect(pair.mergeBase?.id == base.id, "pick retains original base")
            pair.baseCheckbox.state = .off
            pair.populate()
            #expect(pair.effectiveFirst.id == base.id, "unchecked uses chosen endpoint")
            try await wait("file list") { !pair.diff.filesController.isLoading && !pair.diff.filesController.selectedItems().isEmpty }
            let firstFile = pair.diff.filesController.selectedItems().first
            let moved = pair.diff.filesController.selectAdjacentVisibleFile(forward: true)
            #expect(moved && pair.diff.filesController.selectedItems().first != firstFile, "next visible file")
            #expect(
                pair.diff.filesController.selectAdjacentVisibleFile(forward: false) && pair.diff.filesController.selectedItems().first == firstFile,
                "previous visible file")

            let autosave = "NSWindow Frame GitExtensionsMac.CommitDiff"
            let frame = UserDefaults.standard.object(forKey: autosave)
            UserDefaults.standard.removeObject(forKey: autosave)
            defer {
                if let frame { UserDefaults.standard.set(frame, forKey: autosave) } else { UserDefaults.standard.removeObject(forKey: autosave) }
            }
            let commitWindow = CommitDiffWindowController(
                revision: topic, source: module, infoSource: module, repositoryURL: URL(fileURLWithPath: request.identity.currentRepository.path),
                command: { _ in })
            defer { commitWindow.close() }
            commitWindow.showWindow(nil)
            try await wait("single-parent CommitDiff file list") {
                !commitWindow.diffController.filesController.isLoading && !commitWindow.diffController.filesController.selectedItems().isEmpty
            }
            #expect(
                commitWindow.window!.title.contains(CommitInfoPresentation.fullDate(topic.authorDate)) && !commitWindow.window!.title.contains("+0000"),
                "commit window title uses local date like CommitInfo")
            #expect(
                commitWindow.window!.contentRect(forFrameRect: commitWindow.window!.frame).size == NSSize(width: 717, height: 529)
                    && commitWindow.window!.minSize == NSSize(width: 150, height: 148), "pinned CommitDiff actual Designer client/minimum dimensions")
            #expect(
                !commitWindow.diffController.filesController.isToolbarItemVisible("btnCollapseGroups")
                    && !commitWindow.diffController.filesController.isToolbarItemVisible("btnRefresh"),
                "single-parent standalone commit list excludes source-inapplicable collapse/refresh controls")
            let comparison = commands.startCompareRevisions(owner: owner)!
            defer { comparison.close() }
            let content = comparison.contentViewController as! RevisionComparisonGridController
            try await wait("comparison stream") { !content.isLoading && !content.revisions.isEmpty && !content.grid.isShowingLoading }
            #expect(!content.view.subviews.contains { $0 is NSStackView }, "comparison grid has no extra branch/text filter toolbar")
            #expect(
                !content.diff.filesController.canUseFindInCommitFilesGitGrep && !content.diff.filesController.canAutoRefresh,
                "FormLog standalone file-list capability gates")
            let table = descendants(content.grid.view).compactMap { $0 as? NSTableView }.first!
            let scroll = table.enclosingScrollView!
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = false
            scroll.tile()
            comparison.window!.contentView!.layoutSubtreeIfNeeded()
            try await wait("SHA column after native scroller appears") {
                let column = table.tableColumns.firstIndex { $0.identifier.rawValue == "Commit ID" }!
                return table.rect(ofColumn: column).maxX <= scroll.contentView.bounds.width + 1
            }
            #expect(
                content.grid.view.convert(content.grid.view.bounds, to: content.view).maxY == content.view.bounds.maxY,
                "FormLog grid starts at the top of the surface")
            table.deselectAll(nil)
            #expect(content.grid.selectedCommits.isEmpty, "grid permits upstream empty-selection comparison")
            var viewed: [Commit]?
            content.grid.onViewSelected = { viewed = $0 }
            content.grid.perform(NSSelectorFromString("openSelectedCommit"))
            #expect(viewed?.isEmpty == true, "empty double-click routes to general comparison")
            try await waitUntil("grid selects main") {
                if content.grid.selectedCommits.first?.id != main.id { content.grid.selectCommit(id: main.id) }
                return content.grid.selectedCommits.first?.id == main.id
            }
            comparison.window?.makeFirstResponder(table)
            let selectBase = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control,
                timestamp: 1, windowNumber: comparison.window!.windowNumber, context: nil,
                characters: "\u{c}", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!
            table.keyDown(with: selectBase)
            #expect(content.grid.comparisonBase?.id == main.id, "BASE grid-local")
            content.grid.selectCommit(id: topic.id)
            content.reload()
            try await wait("reload selection") { !content.isLoading && !content.grid.isShowingLoading && content.grid.selectedCommits.first?.id == topic.id }
            #expect(content.grid.comparisonBase?.id == main.id, "BASE survives reload")
            content.grid.setAndApplyPathFilter("does-not-exist")
            content.grid.setAndApplyPathFilter("main.txt")
            try await wait("filtered history") {
                !content.isLoading && !content.grid.isShowingLoading && content.revisions.contains { $0.id == main.id }
                    && !content.revisions.contains { $0.id == topic.id }
            }
            commands.repositoryChangedNotifier.notify()
            try await wait("notifier reload") { !content.isLoading && !content.grid.isShowingLoading && content.revisions.contains { $0.id == main.id } }
            #expect(notifications == 1, "only explicit mutation notification, no notification on reads")

            var context = RevisionContextMenuContext(focusedCommit: main, selectedCommits: [main], history: [main, topic, base], currentBranchName: "main")
            var menu = RevisionContextMenuBuilder.build(context)
            for id in ["branch", "current", "setBase", "worktree", "selected"] {
                #expect(menu.entry(id: "revision.compare." + id)?.isEnabled == true, "enabled comparison \(id)")
            }
            #expect(menu.entry(id: "revision.compare.base")?.isEnabled == false, "BASE requires remembered selection")
            context.hasComparisonBase = true
            context.isBareRepository = true
            menu = RevisionContextMenuBuilder.build(context)
            #expect(
                menu.entry(id: "revision.compare.base")?.isEnabled == true && menu.entry(id: "revision.compare.worktree")?.isEnabled == false,
                "BASE/bare eligibility")
            let picker = ComparisonBranchPicker(branches: request.branches, selected: main.id, headID: main.objectID, source: module)
            _ = picker.view
            let values = (0..<picker.field.numberOfItems).compactMap { picker.field.itemObjectValue(at: $0) as? String }
            #expect(values.contains("origin/topic") && !values.contains("main") && picker.field.stringValue.isEmpty, "remote-first empty branch picker")
            let topicIndex = values.firstIndex(of: "origin/topic")!
            let pickerWindow = NSWindow(contentViewController: picker)
            defer {
                picker.cancel()
                pickerWindow.close()
            }
            picker.field.selectItem(at: topicIndex)
            try await wait("count refreshes after list selection") { picker.countText.hasPrefix("(+") || picker.countText == "=" }
            let expectedCount = try await module.comparisonCount(from: main.id, to: "origin/topic", headID: main.objectID)
            #expect(!expectedCount.isEmpty && picker.countText == expectedCount, "selected branch count \(picker.countText) == \(expectedCount)")
            let chooser = RevisionComparisonGridController(source: module, choosing: true, preselect: .index, showArtificial: true)
            let chooseWindow = RevisionComparisonWindowController(
                content: chooser, title: "Choose commit", size: NSSize(width: 900, height: 550), autosave: "RevisionCompareTests.Chooser")
            chooseWindow.showWindow(nil)
            defer {
                chooser.cancel()
                chooseWindow.close()
            }
            try await wait("artificial picker") { !chooser.isLoading && !chooser.grid.isShowingLoading && chooser.grid.selectedCommits.first?.id == .index }
            #expect(chooser.grid.allowsArtificialViewSelection && !chooser.grid.allowsMultipleRevisionSelection, "picker allows artificial single selection")
            let chooserTable = descendants(chooser.grid.view).compactMap { $0 as? NSTableView }.first!
            #expect(!chooserTable.allowsMultipleSelection, "picker table remains single-select after loading")
            #expect(chooseWindow.window?.firstResponder === chooserTable, "selected revision list receives initial focus")
            #expect(!descendants(chooser.view).contains { $0 is NSComboBox || $0 is NSSearchField }, "chooser has no Browse branch/text filter toolbar")
            #expect(
                descendants(chooser.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Find specific commit:" },
                "chooser retains source Go to caption")
            #expect(
                chooser.grid.referenceNames().branches.contains("origin/topic") && chooser.grid.referenceNames().tags.contains("target"),
                "Go to shares actual repository branch/tag names")
            chooseWindow.close()

            var commitPicker: RevisionComparisonGridController?
            let canceled = Task {
                await RevisionCommitChooser.choose(source: module, preselect: topic.id, owner: owner) { content, _ in commitPicker = content }
            }
            try await wait("default commit picker preselection") {
                commitPicker?.isLoading == false && commitPicker?.grid.selectedCommits.first?.id == topic.id
            }
            #expect(
                commitPicker!.revisions.allSatisfy { !$0.isArtificial } && !commitPicker!.grid.allowsArtificialViewSelection,
                "source default chooser excludes artificial revisions")
            let parent = descendants(commitPicker!.view).compactMap { $0 as? NSButton }.first { $0.title == base.shortID }!
            parent.performClick(nil)
            #expect(commitPicker!.grid.selectedCommits.first?.id == base.id, "parent link navigates to actual selected revision parent")
            #expect(
                !descendants(commitPicker!.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Parent(s):" },
                "root revision hides parent links")
            descendants(commitPicker!.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            #expect(await canceled.value == nil, "commit chooser cancellation returns no replacement")

            let rebaseChoice = try await module.rebaseCommitChoice(onto: topic.objectID!.string, from: main.objectID!.string)
            let rebasePicker = Task {
                await RevisionCommitChooser.choose(source: module, preselect: rebaseChoice.preselect, rebaseChoice: rebaseChoice, owner: owner) { content, _ in
                    commitPicker = content
                }
            }
            try await wait("Rebase chooser retains specific-range scope") {
                commitPicker?.isLoading == false && commitPicker?.grid.selectedCommits.first?.id == main.id && commitPicker?.revisions.map(\.id) == [main.id]
            }
            #expect(
                rebaseChoice.mergeBase == base.objectID && commitPicker!.revisions.allSatisfy { !$0.isArtificial },
                "shared picker preserves current-branch merge-base boundary")
            descendants(commitPicker!.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            #expect(await rebasePicker.value == nil, "scoped Rebase picker cancellation returns no replacement")

            commands.startArchive(selected: [topic])
            var archive: NSWindow?
            try await wait("Archive launches") {
                archive = NSApp.windows.first { $0.title == "Archive" && $0.isVisible }
                return archive != nil
            }
            defer { archive?.close() }
            let archiveControls = descendants(archive!.contentView!)
            let archiveSummary = archiveControls.compactMap { $0 as? CommitSummaryView }.first!
            let target = archiveControls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Archive.ChooseRevision" }!
            target.performClick(nil)
            var archivePicker: RevisionComparisonGridController?
            try await wait("Archive uses shared graph chooser") {
                archivePicker = archive?.attachedSheet?.contentViewController as? RevisionComparisonGridController
                return archivePicker?.isLoading == false && archivePicker?.grid.selectedCommits.first?.id == topic.id
            }
            #expect(archivePicker!.revisions.allSatisfy { !$0.isArtificial }, "Archive chooser defaults to real commits")
            archivePicker!.grid.selectCommit(id: main.id)
            descendants(archivePicker!.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            try await wait("Archive cancel preserves selected revision") { archive?.attachedSheet == nil && archiveSummary.title == topic.shortID }
            target.performClick(nil)
            try await wait("Archive chooser reopens with original preselection") {
                archivePicker = archive?.attachedSheet?.contentViewController as? RevisionComparisonGridController
                return archivePicker?.isLoading == false && archivePicker?.grid.selectedCommits.first?.id == topic.id
            }
            archivePicker!.grid.selectCommit(id: main.id)
            descendants(archivePicker!.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
            try await wait("Archive acceptance updates target summary") { archive?.attachedSheet == nil && archiveSummary.title == main.shortID }
            let comparisonFilter = archiveControls.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Take the files") }!
            comparisonFilter.performClick(nil)
            let comparisonButton = archiveControls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Archive.ChooseComparison" }!
            comparisonButton.performClick(nil)
            try await wait("Archive comparison uses shared graph chooser") {
                archivePicker = archive?.attachedSheet?.contentViewController as? RevisionComparisonGridController
                return archivePicker?.isLoading == false && archivePicker?.grid.selectedCommits.first?.id == main.id
            }
            archivePicker!.grid.selectCommit(id: base.id)
            archivePicker!.grid.onViewSelected?([base])
            try await wait("Archive comparison accepts shared double click") {
                archive?.attachedSheet == nil && archiveControls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix(base.subject + "\n") }
            }
            #expect(
                archiveControls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix(base.subject + "\n") },
                "Archive comparison summary uses chosen revision")
            #expect(notifications == 1, "chooser and Archive draft changes add no repository mutation notifications")
        }

        private static func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            #expect(predicate(), Comment(rawValue: label))
        }
    }
}

typealias RevisionComparisonTests = UIIntegrationTests.RevisionComparisonTests
