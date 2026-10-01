@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit

@MainActor
enum FileHistoryTests {
    static func run() async throws {
        _ = NSApplication.shared
        let saved = AppSettingsStore.shared.revisionGridPreferences
        let runtime = AppSettingsStore.shared.revisionGridRuntime
        defer { AppSettingsStore.shared.saveRevisionGridPreferences(saved); AppSettingsStore.shared.revisionGridRuntime = runtime }
        var preferences = RevisionGridPreferences()
        preferences.showArtificialCommits = false
        AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
        AppSettingsStore.shared.revisionGridRuntime = RevisionGridRuntimeSettings()
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a ü.txt", "original\nsecond\n")
        try fixture.commitAll("created")
        let created = try fixture.head()
        try fixture.git(["mv", "a ü.txt", "b space.txt"]); try fixture.commitAll("rename b")
        let renamedB = try fixture.head()
        try fixture.git(["mv", "b space.txt", "c.txt"]); try fixture.commitAll("rename c")
        let renamedC = try fixture.head()
        try fixture.write("c.txt", "changed\nsecond\n"); try fixture.commitAll("modified")
        let modified = try fixture.head()
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let state = try await module.loadRepositoryState()
        let browserRead = await state.revisionReadRequest.reader.read(state.revisionReadRequest.context, batchSize: 1)
        let request = try await module.fileHistoryReadRequest()
        check(request.reader !== state.revisionReadRequest.reader, "independent reader, same module")
        var options = RevisionReadOptions()
        options.showArtificialCommits = false; options.showStashes = false
        options.filter.byPathFilter = true; options.filter.pathFilter = "c.txt"
        options.followRenamesExactOnly = false
        var commits: [Commit] = []
        for try await batch in await request.reader.read(request.context.with(options), batchSize: 1) { commits += batch }
        check(commits.compactMap(\.objectID) == [modified, renamedC, renamedB, created], "rename history ordering")
        var browserCommits: [Commit] = []
        for try await batch in browserRead { browserCommits += batch }
        check(browserCommits.contains { $0.objectID == created }, "File History does not cancel Browser")
        for (id, path) in [(created, "a ü.txt"), (renamedB, "b space.txt"), (renamedC, "c.txt"), (modified, "c.txt")] {
            let actual = await request.reader.fileName(at: id, path: "c.txt")
            check(actual == path, "tracked name at \(id): \(actual)")
            let data = try await module.loadFileData(path: actual, at: .object(id))
            check(String(decoding: data, as: UTF8.self).contains(id == modified ? "changed" : "original"), "historical file bytes")
        }
        let command = RevisionLogCommands.follow(path: "a ü.txt", exactOnly: true)
        check(command.arguments == ["log", "--format=Commit: %H", "--name-only", "--follow", "--find-renames=100%", "--find-copies=100%", "-z", "--", "a ü.txt"], "exact rename arguments")
        check(!command.accessesRemote && !command.changesRepositoryState, "read-only metadata")
        let parsed = RevisionLogCommands.followedPaths("Commit: \(created.string)\0\nline\nbreak.txt\0")
        check(parsed.names == ["line\nbreak.txt"] && parsed.byRevision[created] == "line\nbreak.txt", "NUL path parsing")
        let markerName = "Commit: " + modified.string
        let markerPath = RevisionLogCommands.followedPaths("Commit: \(created.string)\0\n\(markerName)\0")
        check(markerPath.byRevision[created] == markerName, "filename cannot impersonate a commit marker")
        options.followRenames = false
        var noFollow: [Commit] = []
        for try await batch in await request.reader.read(request.context.with(options)) { noFollow += batch }
        check(!noFollow.contains { $0.objectID == created }, "follow disabled")
        check(try JSONDecoder().decode(RevisionGridPreferences.self, from: Data("{}".utf8)).loadFileHistoryOnShow, "compatible defaults")
        check(try JSONDecoder().decode(RevisionGridPreferences.self, from: Data("{}".utf8)).useBrowseForFileHistory, "upstream Browse mode default")
        let browseRequest = FileHistoryBrowseRequest(path: "c space ü.txt", filterRevision: modified)
        check(FileHistoryBrowseRequest.parse(browseRequest.arguments) == browseRequest, "typed Browse launch round trip")
        check(FileHistoryBrowseRequest.parse(["--file-history-path"]) == nil, "malformed launch")
        try await testBrowseMode(module: module, created: created)
        let revision = try await module.loadBlameRevision(modified)
        var actions: [String] = []
        let window = FileHistoryWindowController(source: module, history: module, file: "c.txt", revision: revision,
            filterByRevision: false, showBlame: false) { id, _, _ in actions.append(id) }
        window.showWindow(nil)
        defer { window.close() }
        let controller = window.controller
        try await wait("initial history") { !controller.isLoading && !controller.grid.isShowingLoading && controller.revisions.count == 4 }
        check(controller.grid.view.bounds.height >= 150, "history grid starts expanded in the real window")
        let tabs = controllers(controller).compactMap { $0 as? NSTabViewController }.first!
        check(tabs.tabView.tabViewType == .topTabsBezelBorder, "standalone tabs have a visible selectable tab bar")
        let toolbar = controller.view.subviews.compactMap { $0 as? NSStackView }.first!
        let optionsMenu = toolbar.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first { $0.title == "Options" }!.menu!
        check(!optionsMenu.autoenablesItems, "AppKit cannot override dependent history-option eligibility")
        controller.menuNeedsUpdate(optionsMenu)
        check(optionsMenu.items.first { $0.identifier?.rawValue == "simplify" }?.isEnabled == preferences.fullHistoryInFileHistory,
              "Simplify merges requires full history")
        try await testTagAccessory(owner: window.window!, revisions: commits)
        controller.grid.selectCommit(id: .object(created)); controller.selectTab("view")
        try await wait("renamed view") { controller.selectedPath == "a ü.txt" && texts(controller.fileView.view).contains("original\nsecond\n") }
        check(abs(controller.view.frame.height - window.window!.contentLayoutRect.height) < 1,
              "switching tabs keeps the root filling the window: \(controller.view.frame), \(window.window!.contentLayoutRect)")
        check(controller.view.subviews.first { $0 is NSStackView }!.bounds.height == 28,
              "tab content cannot stretch the history toolbar")
        controller.selectTab("blame")
        try await wait("renamed blame") { controller.blame.blameID == created && controller.blame.fileName == "a ü.txt" }
        controller.selectTab("commit")
        try await wait("CommitInfo") { controller.info.commit?.objectID == created }
        controller.selectTab("diff")
        try await wait("root diff") { controller.shownItem?.file.path == "a ü.txt" && controller.shownItem?.first == nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        controller.buildMenu(menu, selected: [revision])
        check(menu.items.contains { $0.identifier?.rawValue == "file.save" && $0.isEnabled }, "save eligibility")
        let manipulate = menu.items.first { $0.title == "Manipulate commit" }!.submenu!
        let revert = manipulate.items.first { $0.identifier?.rawValue == "revert" }!
        _ = NSApp.sendAction(revert.action!, to: revert.target, from: revert)
        check(actions == ["revert"], "Revert uses workflow handoff")
        controller.grid.selectCommit(id: .object(created))
        controller.reload()
        try await wait("reload preserves selection") { !controller.isLoading && !controller.grid.isShowingLoading && controller.grid.selectedRevisionIDs == [.object(created)] }
        try fixture.git(["rm", "c.txt"]); try fixture.commitAll("deleted")
        let deleted = try fixture.head()
        controller.reload()
        try await wait("new revision") { !controller.isLoading && controller.revisions.contains { $0.objectID == deleted } }
        controller.grid.selectCommit(id: .object(deleted))
        try await wait("missing file tab") { controller.selectedTab == "commit" && controller.selectedPath == "c.txt" }
        var context = ChangedFileContextMenuContext(selectedFiles: [ChangedFile(id: "c", path: "c.txt", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)])
        context.canFileHistory = true
        check(ChangedFileContextMenuBuilder.build(context).contains { $0.id == "file.history" && $0.isEnabled }, "file-list history eligibility")
        try await testAdditionalStates(fixture: fixture)
        try await testMergeParents()
        print("FileHistoryTests: passed")
    }
    private static func texts(_ view: NSView) -> String {
        (view as? NSTextView)?.string ?? view.subviews.map(texts).joined(separator: "\n")
    }
    private static func testTagAccessory(owner: NSWindow, revisions: [Commit]) async throws {


        let task = Task { await TagDialogs.createTag(initial: CreateTagDialogValue(), revisions: revisions, remote: nil, window: owner) }
        try await wait("Tags accessory sheet") { owner.attachedSheet != nil }
        let sheet = owner.attachedSheet!
        check(sheet.frame.width >= 455 && sheet.frame.height > 300, "Tags accessory has a real fitted frame")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        let result = await task.value
        check(result == nil, "Tags accessory cancellation remains non-mutating")
    }
    private static func testMergeParents() async throws {
        let saved = AppSettingsStore.shared.revisionGridPreferences
        var preferences = saved
        preferences.fullHistoryInFileHistory = true; preferences.showArtificialCommits = false; preferences.loadFileHistoryOnShow = true
        AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
        defer { AppSettingsStore.shared.saveRevisionGridPreferences(saved) }
        let fixture = try FileStatusFixture.make(); defer { fixture.remove() }
        try fixture.write("file.txt", "base\n"); try fixture.commitAll("base")
        try fixture.git(["checkout", "-q", "-b", "side"])
        try fixture.write("file.txt", "side\n"); try fixture.commitAll("side")
        try fixture.git(["checkout", "-q", "main"])
        try fixture.write("other.txt", "unrelated\n"); try fixture.commitAll("unrelated first parent")
        let firstParent = try fixture.head()
        try fixture.git(["merge", "--no-ff", "-m", "merge side", "side"])
        let merge = try fixture.head()
        let source = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let window = FileHistoryWindowController(source: source, history: source, file: "file.txt", revision: nil, filterByRevision: false, showBlame: false) { _, _, _ in }
        window.showWindow(nil); defer { window.close() }
        try await wait("merge history") { !window.controller.isLoading && window.controller.revisions.contains { $0.objectID == merge } }
        window.controller.grid.selectCommit(id: .object(merge)); window.controller.selectTab("diff")
        try await wait("actual merge parent") { window.controller.shownItem?.first == .object(firstParent) }
        check(window.controller.shownItem?.second == .object(merge), "merge comparison target")
    }
    private static func controllers(_ root: NSViewController) -> [NSViewController] { [root] + root.children.flatMap(controllers) }

    private static func testBrowseMode(module: GitRepositoryModule, created: ObjectID) async throws {
        let browser = RepositoryBrowserViewController(repositoryModule: module, openingSelection: [.object(created)], fileHistory: .init(path: "c.txt"))
        let window = NSWindow(contentViewController: browser)
        window.setContentSize(NSSize(width: 1200, height: 800)); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let grid = controllers(browser).compactMap { $0 as? RevisionGridViewController }.first!
        let diff = controllers(browser).compactMap { $0 as? RevisionDiffViewController }.first!
        try await wait("Browse file history selection") { !grid.isShowingLoading && browser.selectedCommitID == .object(created) }
        check(grid.currentFilter.pathArguments == ["c.txt"], "Browse history path filter")
        try await wait("Browse tracked filename") { diff.fallbackFollowedFile == "a ü.txt" }
        check(browser.layoutSnapshot.leftPanelCollapsed, "Browse history temporarily hides LeftPanel")
        grid.updateFilter { $0.byMessage = true; $0.message = "modified" }
        try await wait("Browse search restarts reader") { !grid.isShowingLoading && browser.revisions.filter { !$0.isArtificial }.count == 1 }
        check(browser.revisions.first { !$0.isArtificial }?.subject == "modified", "search filters file history")
    }

    private static func testAdditionalStates(fixture: FileStatusFixture) async throws {
        try fixture.write("dir/f.txt", "folder\n"); try fixture.commitAll("folder")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let revision = try await module.loadBlameRevision(try fixture.head())
        let folder = FileHistoryWindowController(source: module, history: module, file: "dir/", revision: revision, filterByRevision: false, showBlame: false) { _, _, _ in }
        folder.showWindow(nil); defer { folder.close() }
        try await wait("directory history") { !folder.controller.isLoading && folder.controller.selectedTab == "commit" && folder.controller.shownItem != nil }
        check(folder.controller.selectedPath == "dir/", "directory is not a followed filename")
        folder.controller.reload(); folder.controller.reload()
        try await wait("stale reload suppressed") { !folder.controller.isLoading && folder.controller.revisions.filter { !$0.isArtificial }.count == 1 }
        let bareURL = fixture.root.appendingPathComponent("bare.git")
        try fixture.git(["clone", "-q", "--bare", fixture.repo.path, bareURL.path])
        let bare = GitRepositoryModule(repositoryURL: bareURL, git: FileStatusFixtureGit())
        let bareWindow = FileHistoryWindowController(source: bare, history: bare, file: "dir/f.txt", revision: revision, filterByRevision: false, showBlame: false) { _, _, _ in }
        bareWindow.showWindow(nil); defer { bareWindow.close() }
        try await wait("bare file history") { !bareWindow.controller.isLoading && bareWindow.controller.shownItem != nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        bareWindow.controller.buildMenu(menu, selected: [revision])
        check(menu.items.first { $0.title == "Manipulate commit" }?.isEnabled == false, "bare mutation actions disabled")
        check(menu.items.first { $0.identifier?.rawValue == "file.save" }?.isEnabled == true, "bare read actions enabled")
        check(!bareWindow.controller.revisions.contains(where: \.isArtificial), "bare history has no artificial rows")
        var preferences = AppSettingsStore.shared.revisionGridPreferences
        preferences.showArtificialCommits = true
        AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
        try fixture.write("dir/f.txt", "dirty\n")
        let artificial = FileHistoryWindowController(source: module, history: module, file: "dir/f.txt", revision: nil, filterByRevision: false, showBlame: false) { _, _, _ in }
        artificial.showWindow(nil); defer { artificial.close() }
        try await wait("artificial history loaded") { !artificial.controller.isLoading && artificial.controller.revisions.contains { $0.kind == .workingDirectory } }
        artificial.controller.grid.selectCommit(id: .workingDirectory)
        try await wait("artificial Diff only") { artificial.controller.selectedTab == "diff" && artificial.controller.shownItem?.second == .workingDirectory }
        check(artificial.controller.shownItem?.first == .index, "artificial parent stays typed")
        artificial.controller.grid.selectCommit(id: .object(revision.objectID!))
        artificial.controller.reload()
        try await wait("dirty refresh selection") { !artificial.controller.isLoading && artificial.controller.grid.selectedRevisionIDs == [revision.id] }
        preferences.loadFileHistoryOnShow = false; preferences.loadBlameOnShow = false
        AppSettingsStore.shared.saveRevisionGridPreferences(preferences)
        let unloaded = FileHistoryWindowController(source: module, history: module, file: "dir/f.txt", revision: revision, filterByRevision: false, showBlame: false) { _, _, _ in }
        unloaded.showWindow(nil); defer { unloaded.close() }
        check(unloaded.controller.grid.view.isHidden && unloaded.controller.revisions.isEmpty, "load-on-show disabled")
        unloaded.controller.reload()
        try await wait("manual load") { !unloaded.controller.isLoading && !unloaded.controller.grid.view.isHidden && !unloaded.controller.revisions.isEmpty }
    }
    private static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        check(condition(), label)
    }
    private static func check(_ condition: Bool, _ label: String) { precondition(condition, "FileHistoryTests: \(label)") }
}
