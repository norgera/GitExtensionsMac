import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("File history")
    enum FileHistoryTests {
        @Test("Scenarios") static func run() async throws {
            let saved = AppSettingsStore.shared.revisionGridPreferences
            let runtime = AppSettingsStore.shared.revisionGridRuntime
            defer {
                AppSettingsStore.shared.saveRevisionGridPreferences(saved)
                AppSettingsStore.shared.revisionGridRuntime = runtime
            }
            var preferences = RevisionGridPreferences()
            preferences.showArtificialCommits = false
            AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
            AppSettingsStore.shared.revisionGridRuntime = RevisionGridRuntimeSettings()
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a ü.txt", "original\nsecond\n")
            try fixture.commitAll("created")
            let created = try fixture.head()
            try fixture.git(["mv", "a ü.txt", "b space.txt"])
            try fixture.commitAll("rename b")
            let renamedB = try fixture.head()
            try fixture.git(["mv", "b space.txt", "c.txt"])
            try fixture.commitAll("rename c")
            let renamedC = try fixture.head()
            try fixture.write("c.txt", "changed\nsecond\n")
            try fixture.commitAll("modified")
            let modified = try fixture.head()
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let state = try await module.loadRepositoryState()
            let browserRead = await state.revisionReadRequest.reader.read(state.revisionReadRequest.context, batchSize: 1)
            let request = try await module.fileHistoryReadRequest()
            #expect(request.reader !== state.revisionReadRequest.reader, "independent reader, same module")
            var options = RevisionReadOptions()
            options.showArtificialCommits = false
            options.showStashes = false
            options.filter.byPathFilter = true
            options.filter.pathFilter = "c.txt"
            options.followRenamesExactOnly = false
            var commits: [Commit] = []
            for try await batch in await request.reader.read(request.context.with(options), batchSize: 1) { commits += batch }
            #expect(commits.compactMap(\.objectID) == [modified, renamedC, renamedB, created], "rename history ordering")
            var browserCommits: [Commit] = []
            for try await batch in browserRead { browserCommits += batch }
            #expect(browserCommits.contains { $0.objectID == created }, "File History does not cancel Browser")
            for (id, path) in [(created, "a ü.txt"), (renamedB, "b space.txt"), (renamedC, "c.txt"), (modified, "c.txt")] {
                let actual = await request.reader.fileName(at: id, path: "c.txt")
                #expect(actual == path, "tracked name at \(id): \(actual)")
                let data = try await module.loadFileData(path: actual, at: .object(id))
                #expect(String(decoding: data, as: UTF8.self).contains(id == modified ? "changed" : "original"), "historical file bytes")
            }
            let command = RevisionLogCommands.follow(path: "a ü.txt", exactOnly: true)
            #expect(
                command.arguments == [
                    "log", "--format=Commit: %H", "--name-only", "--follow", "--find-renames=100%", "--find-copies=100%", "-z", "--", "a ü.txt",
                ], "exact rename arguments")
            #expect(!command.accessesRemote && !command.changesRepositoryState, "read-only metadata")
            let parsed = RevisionLogCommands.followedPaths("Commit: \(created.string)\0\nline\nbreak.txt\0")
            #expect(parsed.names == ["line\nbreak.txt"] && parsed.byRevision[created] == "line\nbreak.txt", "NUL path parsing")
            let markerName = "Commit: " + modified.string
            let markerPath = RevisionLogCommands.followedPaths("Commit: \(created.string)\0\n\(markerName)\0")
            #expect(markerPath.byRevision[created] == markerName, "filename cannot impersonate a commit marker")
            options.followRenames = false
            var noFollow: [Commit] = []
            for try await batch in await request.reader.read(request.context.with(options)) { noFollow += batch }
            #expect(!noFollow.contains { $0.objectID == created }, "follow disabled")
            #expect(try JSONDecoder().decode(RevisionGridPreferences.self, from: Data("{}".utf8)).loadFileHistoryOnShow, "compatible defaults")
            #expect(try JSONDecoder().decode(RevisionGridPreferences.self, from: Data("{}".utf8)).useBrowseForFileHistory, "upstream Browse mode default")
            let browseRequest = FileHistoryBrowseRequest(path: "c space ü.txt", filterRevision: modified)
            #expect(FileHistoryBrowseRequest.parse(browseRequest.arguments) == browseRequest, "typed Browse launch round trip")
            #expect(FileHistoryBrowseRequest.parse(["--file-history-path"]) == nil, "malformed launch")
            try await testBrowseMode(module: module, created: created)
            let revision = try await module.loadBlameRevision(modified)
            var actions: [String] = []
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame GitExtensionsMac.FileHistory")
            let window = FileHistoryWindowController(
                source: module, history: module, file: "c.txt", revision: revision,
                filterByRevision: false, showBlame: false
            ) { id, _, _ in actions.append(id) }
            window.showWindow(nil)
            defer { window.close() }
            let controller = window.controller
            try await wait("initial history") { !controller.isLoading && !controller.grid.isShowingLoading && controller.revisions.count == 4 }
            #expect(controller.grid.view.bounds.height >= 95, "history grid starts at the upstream splitter distance in the real window")
            if let historyWindow = window.window {
                let content = historyWindow.contentRect(forFrameRect: historyWindow.frame).size
                #expect(
                    content == NSSize(width: 748, height: 444),
                    "dedicated File History starts at the upstream 748x444 client size \(content)")
                #expect(historyWindow.minSize == NSSize(width: 299, height: 198), "dedicated File History uses the upstream 299x198 minimum size")
                #expect(
                    abs(controller.grid.view.bounds.height - 101) <= 1,
                    "grid pane starts at the upstream SplitterDistance 101 \(controller.grid.view.bounds.height)")
            }
            let tabs = controllers(controller).compactMap { $0 as? NSTabViewController }.first!
            #expect(tabs.tabView.tabViewType == .topTabsBezelBorder, "standalone tabs have a visible selectable tab bar")
            let toolbar = controller.view.subviews.compactMap { $0 as? NSStackView }.first!
            let controls = toolbar.arrangedSubviews.compactMap { $0 as? NSPopUpButton }
            let loadControl = controls.first { $0.toolTip == "Load file history" }!
            let fullControl = controls.first { $0.toolTip == "Show Full History" }!
            let blameControl = controls.first { $0.toolTip == "Blame options" }!
            #expect(loadControl is SplitToolbarPopUpButton, "history load has a primary action separate from its options dropdown")
            #expect(
                toolbar.arrangedSubviews.firstIndex(of: loadControl)! > toolbar.arrangedSubviews.firstIndex { $0.toolTip == "Show only first parent" }!,
                "source history controls follow revision filters")
            for control in [loadControl, fullControl, blameControl] {
                controller.menuNeedsUpdate(control.menu!)
                #expect(!control.menu!.autoenablesItems, "AppKit cannot override dependent history-option eligibility")
            }
            #expect(loadControl.menu!.items.dropFirst().map(\.title) == ["Load history on show", "Load blame on show"], "source load split dropdown")
            #expect(
                fullControl.menu!.items.dropFirst().map(\.title) == ["Show full history", "Simplify merges"],
                "source full-history dropdown excludes rename and blame options")
            #expect(
                fullControl.menu!.items.first { $0.identifier?.rawValue == "simplify" }?.isEnabled == preferences.fullHistoryInFileHistory,
                "Simplify merges requires full history")
            #expect(
                blameControl.menu!.items.dropFirst().map { $0.isSeparatorItem ? "|" : $0.title } == [
                    "Blame settings:", "Ignore whitespace", "Detect move and copy in this file", "Detect move and copy in all files", "|",
                    "Display result settings:", "Display author first", "Show author avatar", "Show author", "Show author date", "Show author time",
                    "Show line numbers", "Show original file path",
                ], "source blame section captions and author-avatar ordering")
            #expect(
                blameControl.menu!.items.filter { $0.identifier?.rawValue.hasPrefix("blame.caption.") == true }.allSatisfy { !$0.isEnabled },
                "blame section captions are noninteractive")
            try await testTagAccessory(owner: window.window!, revisions: commits)
            controller.grid.selectCommit(id: .object(created))
            controller.selectTab("view")
            try await wait("renamed view") { controller.selectedPath == "a ü.txt" && texts(controller.fileView.view).contains("original\nsecond\n") }
            #expect(
                abs(controller.view.frame.height - window.window!.contentLayoutRect.height) < 1,
                "switching tabs keeps the root filling the window: \(controller.view.frame), \(window.window!.contentLayoutRect)")
            #expect(
                controller.view.subviews.first { $0 is NSStackView }!.bounds.height == 28,
                "tab content cannot stretch the history toolbar")
            controller.selectTab("blame")
            try await wait("renamed blame") { controller.blame.blameID == created && controller.blame.fileName == "a ü.txt" }
            controller.selectTab("commit")
            try await wait("CommitInfo") { controller.info.commit?.objectID == created }
            controller.selectTab("diff")
            try await wait("root diff") { controller.shownItem?.file.path == "a ü.txt" && controller.shownItem?.first == nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            controller.buildMenu(menu, selected: [revision])
            #expect(
                menu.items.contains { $0.identifier?.rawValue == "follow" } && menu.items.contains { $0.identifier?.rawValue == "exact" }
                    && !menu.items.contains { $0.title == "History / Blame options" }, "source row menu directly exposes rename controls")
            if #available(macOS 27.0, *) {
                #expect(
                    ["revision.copy", "file.difftool", "file.save"].allSatisfy { menuItem(withIdentifier: $0, in: menu)?.preferredImageVisibility == .visible },
                    "history action icons visible")
            }
            #expect(
                tabs.tabViewItems.compactMap { $0.identifier as? String } == ["commit", "diff", "view", "blame"], "history icons retain tab identity/order")
            let nativeTabs = tabs.tabView.subviews.compactMap { $0 as? NSSegmentedControl }.first!
            let oldImage = tabs.tabViewItems[0].image
            let representativeImage = NSImage(size: NSSize(width: 16, height: 16))
            tabs.tabViewItems[0].image = representativeImage
            tabs.viewDidLayout()
            #expect(
                nativeTabs.image(forSegment: 0) === representativeImage && nativeTabs.label(forSegment: 0) == "Commit",
                "actual native segmented tabs present image and preserve caption")
            tabs.tabViewItems[0].image = oldImage
            tabs.viewDidLayout()
            #expect(nativeTabs.image(forSegment: 0) === oldImage, "native tab image is reset on reuse")
            let copy = menuItem(withIdentifier: "revision.copy", in: menu)!.submenu!
            if #available(macOS 27.0, *) {
                #expect(
                    menu.items.first!.preferredImageVisibility == .visible
                        && copy.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.preferredImageVisibility == .visible },
                    "copy resource icons remain explicitly visible under native menu presentation")
            }
            let expectedCopy = RevisionContextMenuBuilder.copyMenu([revision]).children.compactMap { entry -> String? in
                if case .command(_, let title, _) = entry { return title }
                return nil
            }
            #expect(copy.items.filter { !$0.isSeparatorItem }.map(\.title) == expectedCopy, "history uses dynamic selected-value copy previews")
            let copyHashIncludesSelection = copy.items.first { $0.identifier?.rawValue == "revision.copy.hash" }!.title.contains(
                revision.id.description.prefix(8))
            #expect(copyHashIncludesSelection, "copy commit hash includes selected value")
            func copyFixture(_ refs: [RevisionReference], commitDate: Date? = nil) -> Commit {
                Commit(
                    id: revision.id, shortID: revision.shortID, subject: revision.subject, body: revision.body,
                    authorName: revision.authorName, authorEmail: revision.authorEmail, authorDate: revision.authorDate,
                    committerName: revision.committerName, committerEmail: revision.committerEmail,
                    commitDate: commitDate ?? revision.authorDate, parentIDs: revision.parentIDs, references: refs)
            }
            var alternate = copyFixture([
                RevisionReference(id: "branch1", name: "branch1", kind: .localBranch), RevisionReference(id: "branch2", name: "branch2", kind: .localBranch),
            ])
            controller.buildMenu(menu, selected: [alternate])
            #expect(
                menuItem(withIdentifier: "revision.copy", in: menu)!.submenu!.numberOfItems == 8,
                "upstream two-branch copy fixture has caption, refs, separator and four values")
            alternate = copyFixture([RevisionReference(id: "tag1", name: "tag1", kind: .tag), RevisionReference(id: "tag2", name: "tag2", kind: .tag)])
            controller.buildMenu(menu, selected: [alternate])
            #expect(menuItem(withIdentifier: "revision.copy", in: menu)!.submenu!.numberOfItems == 8, "upstream two-tag copy fixture")
            alternate = copyFixture(
                alternate.references + [
                    RevisionReference(id: "branch1", name: "branch1", kind: .localBranch),
                    RevisionReference(id: "branch2", name: "branch2", kind: .localBranch),
                ])
            controller.buildMenu(menu, selected: [alternate])
            #expect(menuItem(withIdentifier: "revision.copy", in: menu)!.submenu!.numberOfItems == 12, "upstream combined branch-and-tag copy fixture")
            alternate = copyFixture(alternate.references, commitDate: alternate.authorDate.addingTimeInterval(60))
            controller.buildMenu(menu, selected: [alternate])
            #expect(
                menuItem(withIdentifier: "revision.copy.authorDate", in: menu) != nil && menuItem(withIdentifier: "revision.copy.commitDate", in: menu) != nil
                    && menuItem(withIdentifier: "revision.copy.date", in: menu) == nil, "different author and commit dates are presented independently")
            controller.buildMenu(menu, selected: [revision, alternate])
            #expect(
                menuItem(withIdentifier: "revision.copy.hash", in: menu)!.title.hasPrefix("Commit hashes:"),
                "multiple revisions use shared plural and deduplicated preview behavior")
            controller.buildMenu(menu, selected: [])
            #expect(!menu.items.first!.isEnabled, "copy disabled without selected revision")
            controller.buildMenu(menu, selected: [revision])
            #expect(menu.items.contains { $0.identifier?.rawValue == "file.save" && $0.isEnabled }, "save eligibility")
            let manipulate = menu.items.first { $0.title == "Manipulate commit" }!.submenu!
            let revert = manipulate.items.first { $0.identifier?.rawValue == "revert" }!
            _ = NSApp.sendAction(revert.action!, to: revert.target, from: revert)
            #expect(actions == ["revert"], "Revert uses workflow handoff")
            controller.grid.selectCommit(id: .object(created))
            controller.reload()
            try await wait("reload preserves selection") {
                !controller.isLoading && !controller.grid.isShowingLoading && controller.grid.selectedRevisionIDs == [.object(created)]
            }
            try fixture.git(["rm", "c.txt"])
            try fixture.commitAll("deleted")
            let deleted = try fixture.head()
            controller.reload()
            try await wait("new revision") { !controller.isLoading && controller.revisions.contains { $0.objectID == deleted } }
            controller.grid.selectCommit(id: .object(deleted))
            try await wait("missing file tab") { controller.selectedTab == "commit" && controller.selectedPath == "c.txt" }
            var context = ChangedFileContextMenuContext(selectedFiles: [
                ChangedFile(id: "c", path: "c.txt", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
            ])
            context.canFileHistory = true
            #expect(ChangedFileContextMenuBuilder.build(context).contains { $0.id == "file.history" && $0.isEnabled }, "file-list history eligibility")
            try await testAdditionalStates(fixture: fixture)
            try await testMergeParents()
        }
        private static func texts(_ view: NSView) -> String {
            (view as? NSTextView)?.string ?? view.subviews.map(texts).joined(separator: "\n")
        }
        private static func testTagAccessory(owner: NSWindow, revisions: [Commit]) async throws {

            let task = Task { await TagDialogs.createTag(initial: CreateTagDialogValue(), revisions: revisions, remote: nil, window: owner) }
            try await wait("Tags accessory sheet") { owner.attachedSheet != nil }
            let sheet = owner.attachedSheet!
            #expect(sheet.frame.width >= 455 && sheet.frame.height > 300, "Tags accessory has a real fitted frame")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            let result = await task.value
            #expect(result == nil, "Tags accessory cancellation remains non-mutating")
        }
        private static func testMergeParents() async throws {
            let saved = AppSettingsStore.shared.revisionGridPreferences
            var preferences = saved
            preferences.fullHistoryInFileHistory = true
            preferences.showArtificialCommits = false
            preferences.loadFileHistoryOnShow = true
            AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
            defer { AppSettingsStore.shared.saveRevisionGridPreferences(saved) }
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("file.txt", "base\n")
            try fixture.commitAll("base")
            try fixture.git(["checkout", "-q", "-b", "side"])
            try fixture.write("file.txt", "side\n")
            try fixture.commitAll("side")
            try fixture.git(["checkout", "-q", "main"])
            try fixture.write("other.txt", "unrelated\n")
            try fixture.commitAll("unrelated first parent")
            let firstParent = try fixture.head()
            try fixture.git(["merge", "--no-ff", "-m", "merge side", "side"])
            let merge = try fixture.head()
            let source = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let window = FileHistoryWindowController(
                source: source, history: source, file: "file.txt", revision: nil, filterByRevision: false, showBlame: false
            ) { _, _, _ in }
            window.showWindow(nil)
            defer { window.close() }
            try await wait("merge history") { !window.controller.isLoading && window.controller.revisions.contains { $0.objectID == merge } }
            window.controller.grid.selectCommit(id: .object(merge))
            window.controller.selectTab("diff")
            try await wait("actual merge parent") { window.controller.shownItem?.first == .object(firstParent) }
            #expect(window.controller.shownItem?.second == .object(merge), "merge comparison target")
        }
        private static func controllers(_ root: NSViewController) -> [NSViewController] { [root] + root.children.flatMap(controllers) }

        private static func testBrowseMode(module: GitRepositoryModule, created: ObjectID) async throws {
            let browser = RepositoryBrowserViewController(repositoryModule: module, openingSelection: [.object(created)], fileHistory: .init(path: "c.txt"))
            let window = NSWindow(contentViewController: browser)
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let grid = controllers(browser).compactMap { $0 as? RevisionGridViewController }.first!
            let diff = controllers(browser).compactMap { $0 as? RevisionDiffViewController }.first!
            try await wait("Browse file history selection") { !grid.isShowingLoading && browser.selectedCommitID == .object(created) }
            #expect(grid.currentFilter.pathArguments == ["c.txt"], "Browse history path filter")
            try await wait("Browse tracked filename") { diff.fallbackFollowedFile == "a ü.txt" }
            #expect(browser.layoutSnapshot.leftPanelCollapsed, "Browse history temporarily hides LeftPanel")
            grid.updateFilter {
                $0.byMessage = true
                $0.message = "modified"
            }
            try await wait("Browse search restarts reader") { !grid.isShowingLoading && browser.revisions.filter { !$0.isArtificial }.count == 1 }
            #expect(browser.revisions.first { !$0.isArtificial }?.subject == "modified", "search filters file history")
        }

        private static func testAdditionalStates(fixture: FileStatusFixture) async throws {
            try fixture.write("dir/f.txt", "folder\n")
            try fixture.commitAll("folder")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let revision = try await module.loadBlameRevision(try fixture.head())
            let folder = FileHistoryWindowController(
                source: module, history: module, file: "dir/", revision: revision, filterByRevision: false, showBlame: false
            ) { _, _, _ in }
            folder.showWindow(nil)
            defer { folder.close() }
            try await wait("directory history") {
                !folder.controller.isLoading && folder.controller.selectedTab == "commit" && folder.controller.shownItem != nil
            }
            #expect(folder.controller.selectedPath == "dir/", "directory is not a followed filename")
            folder.controller.reload()
            folder.controller.reload()
            try await wait("stale reload suppressed") { !folder.controller.isLoading && folder.controller.revisions.filter { !$0.isArtificial }.count == 1 }
            let bareURL = fixture.root.appendingPathComponent("bare.git")
            try fixture.git(["clone", "-q", "--bare", fixture.repo.path, bareURL.path])
            let bare = GitRepositoryModule(repositoryURL: bareURL, git: FileStatusFixtureGit())
            let bareWindow = FileHistoryWindowController(
                source: bare, history: bare, file: "dir/f.txt", revision: revision, filterByRevision: false, showBlame: false
            ) { _, _, _ in }
            bareWindow.showWindow(nil)
            defer { bareWindow.close() }
            try await wait("bare file history") { !bareWindow.controller.isLoading && bareWindow.controller.shownItem != nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            bareWindow.controller.buildMenu(menu, selected: [revision])
            #expect(menu.items.first { $0.title == "Manipulate commit" }?.isEnabled == false, "bare mutation actions disabled")
            #expect(menu.items.first { $0.identifier?.rawValue == "file.save" }?.isEnabled == true, "bare read actions enabled")
            #expect(!bareWindow.controller.revisions.contains { $0.isArtificial }, "bare history has no artificial rows")
            var preferences = AppSettingsStore.shared.revisionGridPreferences
            preferences.showArtificialCommits = true
            AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
            try fixture.write("dir/f.txt", "dirty\n")
            let artificial = FileHistoryWindowController(
                source: module, history: module, file: "dir/f.txt", revision: nil, filterByRevision: false, showBlame: false
            ) { _, _, _ in }
            artificial.showWindow(nil)
            defer { artificial.close() }
            try await wait("artificial history loaded") {
                !artificial.controller.isLoading && artificial.controller.revisions.contains { $0.kind == .workingDirectory }
            }
            artificial.controller.grid.selectCommit(id: .workingDirectory)
            try await wait("artificial Diff only") {
                artificial.controller.selectedTab == "diff" && artificial.controller.shownItem?.second == .workingDirectory
            }
            #expect(artificial.controller.shownItem?.first == .index, "artificial parent stays typed")
            artificial.controller.grid.selectCommit(id: .object(revision.objectID!))
            artificial.controller.reload()
            try await wait("dirty refresh selection") { !artificial.controller.isLoading && artificial.controller.grid.selectedRevisionIDs == [revision.id] }
            preferences.loadFileHistoryOnShow = false
            preferences.loadBlameOnShow = false
            AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
            let unloaded = FileHistoryWindowController(
                source: module, history: module, file: "dir/f.txt", revision: revision, filterByRevision: false, showBlame: false
            ) { _, _, _ in }
            unloaded.showWindow(nil)
            defer { unloaded.close() }
            #expect(unloaded.controller.grid.view.isHidden && unloaded.controller.revisions.isEmpty, "load-on-show disabled")
            unloaded.controller.reload()
            try await wait("manual load") {
                !unloaded.controller.isLoading && !unloaded.controller.grid.view.isHidden && !unloaded.controller.revisions.isEmpty
            }
        }
        private static func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(condition(), Comment(rawValue: label))
        }
    }
}

typealias FileHistoryTests = UIIntegrationTests.FileHistoryTests
