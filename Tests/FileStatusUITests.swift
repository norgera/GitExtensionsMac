@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit


@MainActor
enum FileStatusUITests {
    static func run() async throws {
        _ = NSApplication.shared

        let savedPreferences = AppSettingsStore.shared.fileStatusListPreferences
        AppSettingsStore.shared.saveFileStatusListPreferences(FileStatusListPreferences())
        defer { AppSettingsStore.shared.saveFileStatusListPreferences(savedPreferences) }
        try testPlainListing()
        try await testDiffTab()
        try await testWorkingDirectory()
        try await testFileTreeAndGrep()
        try await testSubmoduleCommitQueue()
        try await testBrowserStageKeepsSelection()
        testFolderDescription()
        print("FileStatusUITests: passed")
    }


    private static let implemented: Set<String> = [
        "file.openSubmodule", "tree.selectAll", "tree.collapseAll", "tree.expandAll", "tree.collapseRootFolders",
        "file.submodule.update", "file.submodule.reset", "file.submodule.stash", "file.submodule.commit",
        "file.stage", "file.unstage", "file.reset.first", "file.reset.second", "file.resetChunk", "file.interactiveAdd", "file.cherryPick",
        "file.difftool", "file.difftool.selectedToLocal", "file.difftool.firstToLocal", "file.difftool.twoSelected",
        "file.difftool.remembered", "file.difftool.rememberSecond", "file.difftool.rememberFirst",
        "file.open.local", "file.open.localWith", "file.open.revision", "file.open.revisionWith", "file.save", "file.move",
        "file.delete", "file.copyPaths", "file.showFinder", "file.showFileTree", "file.filterGrid", "file.find", "file.findCommit",
        "file.showFindCommit", "file.skipWorktree", "file.assumeUnchanged", "file.stopTracking",
        "file.edit.local", "file.ignore.gitignore", "file.ignore.exclude", "file.blame", "file.history",
        "sort.pathTree", "sort.pathFlat", "sort.extensionTree", "sort.extensionFlat", "sort.statusTree", "sort.statusFlat"
    ]
    private static let alwaysDisabled: Set<String> = []

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) } }
    private static func outline(_ controller: NSViewController) -> NSOutlineView {
        descendants(controller.view).compactMap { $0 as? NSOutlineView }.first { $0.accessibilityIdentifier() == "FileStatusList" }!
    }
    private static func rows(_ outline: NSOutlineView) -> [ChangedFileNode] {
        (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? ChangedFileNode }
    }
    private static func select(_ outline: NSOutlineView, where predicate: (ChangedFileNode) -> Bool) {
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? ChangedFileNode).map(predicate) == true }) else {
            preconditionFailure("FileStatusUITests: row not found in \(rows(outline).map(\.title))")
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    private static func wait(_ message: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { preconditionFailure("FileStatusUITests: timed out waiting for \(message())") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func click(_ button: NSButton, toggles: Bool = false) {
        if toggles { button.state = button.state == .on ? .off : .on }
        NSApp.sendAction(button.action!, to: button.target, from: button)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure("FileStatusUITests: \(message)") }
    }


    private static func checkMenu(_ menu: NSMenu, _ context: String) {
        for item in items(menu) where item.submenu == nil && item.isEnabled {
            guard let id = item.identifier?.rawValue else { continue }
            let base = id.components(separatedBy: ".tool:")[0]
            check(implemented.contains(base) && item.action != nil && item.target != nil, "\(context): enabled placeholder \(id)")
        }
        for item in items(menu) {
            if let id = item.identifier?.rawValue, alwaysDisabled.contains(id) { check(!item.isEnabled, "\(context): \(id) must stay disabled") }
        }
    }


    private static func testPlainListing() throws {
        let controller = ChangedFilesViewController()
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 480, height: 500))
        defer { window.close() }
        let file = ChangedFile(id: "file.txt", path: "file.txt", oldPath: nil, changeType: .modified, additions: 1, deletions: 0)
        controller.apply(files: [file], scope: .workingTree, comparisonTitle: "Working directory")
        let list = outline(controller)
        select(list) { $0.file != nil }
        let menu = list.menu!
        controller.menuNeedsUpdate(menu)
        for item in items(menu) where item.submenu == nil && item.isEnabled {
            guard let id = item.identifier?.rawValue else { continue }
            check(["file.copyPaths", "file.find"].contains(id), "plain list enabled \(id)")
        }
        check(controller.currentlySelectedFiles().map(\.path) == ["file.txt"], "plain selection")
    }

    private static func makeController(_ mode: FileStatusListMode, fixture: FileStatusFixture, module: GitRepositoryModule) -> (RevisionDiffViewController, NSWindow) {
        let controller = RevisionDiffViewController(mode: mode)
        controller.fileStatusSource = module
        controller.repositoryURL = fixture.repo
        controller.contentProvider = { commit, file, encoding in try await module.loadFilePresentation(for: commit, file: file, encoding: encoding) }
        controller.treeEntriesProvider = { commit in try await module.loadRepositoryFiles(for: commit) }
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        return (controller, window)
    }

    private static func testDiffTab() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("shared.txt", "base\n")
        try fixture.write("keep.txt", "keep\n")
        try fixture.commitAll("base")
        let base = try fixture.head()
        try fixture.git(["checkout", "-q", "-b", "topic"])
        try fixture.write("a-only.txt", "a\n")
        try fixture.write("shared.txt", "topic\n")
        try fixture.commitAll("topic")
        let topic = try fixture.head()
        try fixture.git(["checkout", "-q", "main"])
        try fixture.write("dir/b-only.txt", "b\n")
        try fixture.write("dir/b-two.txt", "b2\n")
        try fixture.write("shared.txt", "main\n")
        try fixture.commitAll("main")
        let main = try fixture.head()
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let (controller, window) = makeController(.diff, fixture: fixture, module: module)
        defer { window.close() }
        var commands: [FileStatusListCommand] = []
        controller.onCommand = { commands.append($0) }
        controller.parentsOf = { revision in revision == .object(main) ? [.object(base)] : [] }
        let list = outline(controller)


        controller.setDiffs(revisions: [FileStatusTests.commitModel(main, parents: [base])], headID: main)
        try await wait("single revision listing") { rows(list).contains { $0.file.map { $0.path.hasSuffix("b-only.txt") } == true } }
        check(rows(list).first?.isDiffGroup == true && rows(list).first?.title.contains("Diff with A: ") == true, "diff group root \(rows(list).map(\.title))")
        select(list) { $0.file?.path == "shared.txt" }
        let menu = list.menu!
        controller.filesController.menuNeedsUpdate(menu)
        checkMenu(menu, "revision file")
        for id in ["file.reset", "file.open.revision", "file.save", "file.showFileTree", "file.filterGrid", "file.findCommit"] {
            check(menuItem(withIdentifier: id, in: menu)?.isEnabled == true, "revision file enables \(id)")
        }
        check(menuItem(withIdentifier: "file.stage", in: menu) == nil, "revision file has no stage")

        controller.filesController.perform("file.filterGrid")
        check(commands.last?.identifier == "file.filterGrid" && commands.last?.items.first?.second == .object(main)
              && commands.last?.items.first?.first == .object(base), "filter command routed with revisions")


        select(list) { $0.folderPath == "dir" }
        check(controller.filesController.selectedFolder == "dir" && controller.filesController.selectedItems().map(\.file.path).sorted() == ["dir/b-only.txt", "dir/b-two.txt"],
              "folder selection")
        controller.filesController.menuNeedsUpdate(menu)
        checkMenu(menu, "folder")
        check(menuItem(withIdentifier: "tree.selectAll", in: menu)?.isEnabled == true && menuItem(withIdentifier: "file.move", in: menu)?.isEnabled == true,
              "folder offers tree commands and move")


        controller.setDiffs(revisions: [FileStatusTests.commitModel(main, parents: [base]), FileStatusTests.commitModel(topic, parents: [base])], headID: main)
        try await wait("A/B groups \(rows(list).map { "\($0.title)|\($0.isDiffGroup)" })") { rows(list).filter(\.isDiffGroup).count == 3 && rows(list).contains { $0.file?.isRangeDiff == true } }
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        let onlyA = buttons.first { $0.toolTip == "Show files changed in A only" }!
        check(controller.filesController.isToolbarItemVisible("btnA"), "A/B filter visible with A/B groups")
        let firstGroupFiles = { rows(list).compactMap(\.file).filter { $0.id.hasPrefix(controller.filesController.allItems.first!.group.id) } }
        check(firstGroupFiles().contains { $0.path == "a-only.txt" }, "A-only change listed \(firstGroupFiles().map(\.path))")
        click(onlyA, toggles: true)
        check(!firstGroupFiles().contains { $0.path == "a-only.txt" } && firstGroupFiles().contains { $0.path == "shared.txt" },
              "A filter hides A-only changes")
        click(onlyA, toggles: true)

        select(list) { $0.file?.isRangeDiff == true }
        controller.filesController.menuNeedsUpdate(menu)
        check(menuItem(withIdentifier: "file.difftool.menu", in: menu)?.isEnabled != true, "range diff has no difftool")


        var preferences = AppSettingsStore.shared.fileStatusListPreferences
        let savedPreferences = preferences
        defer { AppSettingsStore.shared.saveFileStatusListPreferences(savedPreferences) }
        preferences.showDiffForAllParents = false
        AppSettingsStore.shared.saveFileStatusListPreferences(preferences)
        controller.setDiffs(revisions: [FileStatusTests.commitModel(main, parents: [base]), FileStatusTests.commitModel(topic, parents: [base])], headID: main)
        try await wait("single A->B group") { rows(list).filter(\.isDiffGroup).count == 1 && !rows(list).contains { $0.file?.isRangeDiff == true } }
        check(!controller.filesController.isToolbarItemVisible("btnA"), "A/B filter hidden without A/B groups")
        check(controller.filesController.isToolbarItemVisible("btnSettings") && controller.filesController.isToolbarItemVisible("btnRefresh"),
              "Settings and Refresh stay in the Diff toolbar")
    }

    private static func testWorkingDirectory() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "one\n")
        try fixture.commitAll("base")
        let head = try fixture.head()
        try fixture.write("tracked.txt", "two\n")
        try fixture.write("untracked.txt", "new\n")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let (controller, window) = makeController(.diff, fixture: fixture, module: module)
        defer { window.close() }
        var refreshes = 0
        controller.onRefreshArtificial = { refreshes += 1 }
        controller.parentsOf = { $0 == .workingDirectory ? [.index] : $0 == .index ? [.object(head)] : [] }
        let list = outline(controller)
        let revisions = [FileStatusTests.artificial(.workingDirectory, head: head)]
        controller.setDiffs(revisions: revisions, headID: head)
        try await wait("worktree listing") { rows(list).contains { $0.file?.path == "untracked.txt" } }


        let refresh = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "Refresh artificial commit" }!
        check(refresh.isEnabled, "refresh enabled for the working directory")
        click(refresh)
        check(refreshes == 1, "refresh requests the artificial status")


        select(list) { $0.file?.path == "tracked.txt" }
        let menu = list.menu!
        controller.filesController.menuNeedsUpdate(menu)
        checkMenu(menu, "worktree file")
        for id in ["file.stage", "file.reset", "file.resetChunk", "file.interactiveAdd", "file.skipWorktree", "file.assumeUnchanged",
                   "file.stopTracking", "file.delete", "file.open.local"] {
            check(menuItem(withIdentifier: id, in: menu)?.isEnabled == true, "worktree enables \(id)")
        }
        check(menuItem(withIdentifier: "file.open.revision", in: menu) == nil && menuItem(withIdentifier: "file.cherryPick", in: menu) == nil,
              "worktree has no revision temp file or cherry pick")


        let settings = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.toolTip == "Settings" }!
        controller.filesController.menuNeedsUpdate(settings.menu!)
        let untracked = settings.menu!.items.first { $0.title == "Show untracked files" }!
        check(untracked.isEnabled && untracked.state == .on, "show untracked enabled for the worktree")
        check(settings.menu!.items.first { $0.title == "Edit ignored files" }?.isEnabled == true
              && settings.menu!.items.first { $0.title == "Edit locally ignored files" }?.isEnabled == true, "ignore editors are offered")
        check(!settings.menu!.items.contains { $0.title == "Show ignored files" || $0.title == "Show assumed-unchanged files" },
              "Browse hides ignored/assumed-unchanged options")
        NSApp.sendAction(untracked.action!, to: untracked.target, from: untracked)
        try await wait("untracked hidden") { !rows(list).contains { $0.file?.path == "untracked.txt" } && rows(list).contains { $0.file?.path == "tracked.txt" } }

        _ = try fixture.git(["update-index", "--skip-worktree", "tracked.txt"])
        controller.filesController.menuNeedsUpdate(settings.menu!)
        let skip = settings.menu!.items.first { $0.title == "Show skip-worktree files" }!
        NSApp.sendAction(skip.action!, to: skip.target, from: skip)
        try await wait("skip-worktree listed") { controller.filesController.allItems.contains { $0.file.isSkipWorktree && $0.file.path == "tracked.txt" } }


        controller.setDiffs(revisions: [FileStatusTests.commitModel(head, parents: [])], headID: head)
        try await wait("root listing") { rows(list).contains { $0.file?.path == "tracked.txt" && $0.file?.changeType == .added } }
        check(!refresh.isEnabled, "refresh disabled for a real revision")
        controller.filesController.menuNeedsUpdate(settings.menu!)
        check(settings.menu!.items.first { $0.title == "Show untracked files" }?.isEnabled == false, "show untracked needs the worktree")
    }

    private static func testFileTreeAndGrep() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("src/main.c", "int main() { return needle; }\n")
        try fixture.write("src/util.c", "int util;\n")
        try fixture.write("README", "Needle in docs\n")
        try fixture.commitAll("tree")
        let head = try fixture.head()
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        var preferences = AppSettingsStore.shared.fileStatusListPreferences
        let saved = preferences
        defer { AppSettingsStore.shared.saveFileStatusListPreferences(saved) }
        preferences.showFindInCommitFilesGitGrep = true
        preferences.gitGrepIgnoreCase = false
        preferences.gitGrepMatchWholeWord = false
        preferences.gitGrepUserArguments = ""
        AppSettingsStore.shared.saveFileStatusListPreferences(preferences)
        let (controller, window) = makeController(.fileTree, fixture: fixture, module: module)
        defer { window.close() }
        let list = outline(controller)
        controller.setDiffs(revisions: [FileStatusTests.commitModel(head, parents: [])], headID: head)
        try await wait("tree listing") { rows(list).contains { $0.folderPath == "src" } }

        check(!rows(list).contains { $0.isDiffGroup } && Set(controller.filesController.allItems.map(\.file.path)) == ["README", "src/main.c", "src/util.c"],
              "tree lists every file \(controller.filesController.allItems.map(\.file.path))")
        let srcRow = list.row(forItem: rows(list).first { $0.folderPath == "src" })
        check(!list.isItemExpanded(list.item(atRow: srcRow)), "root folders start collapsed")
        let menu = list.menu!
        select(list) { $0.file?.path == "README" }
        controller.filesController.menuNeedsUpdate(menu)
        checkMenu(menu, "tree file")
        check(menuItem(withIdentifier: "file.showFileTree", in: menu) == nil, "no Show in File tree inside the File tree")
        check(menuItem(withIdentifier: "tree.collapseRootFolders", in: menu) == nil, "collapse root folders only with expanded roots")


        let grepBox = descendants(controller.view).compactMap { $0 as? NSComboBox }.first { $0.accessibilityIdentifier() == "FileStatusGitGrep" }!
        check(!grepBox.isHidden, "grep input box shown in the file tree")
        grepBox.stringValue = "needle"
        controller.filesController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: grepBox))
        try await wait("grep results \(controller.filesController.allItems.map { "\($0.group.kind):\($0.file.path)" }) grep=\(controller.filesController.grepText)") { controller.filesController.allItems.map(\.file.path) == ["src/main.c"] }
        check(rows(list).contains { $0.file?.path == "src/main.c" }, "grep results expanded")
        select(list) { $0.file?.path == "src/main.c" }
        preferences.gitGrepIgnoreCase = true
        AppSettingsStore.shared.saveFileStatusListPreferences(preferences)
        grepBox.stringValue = "needle"
        controller.filesController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: grepBox))
        try await wait("case-insensitive grep") { Set(controller.filesController.allItems.map(\.file.path)) == ["README", "src/main.c"] }

        grepBox.stringValue = ""
        controller.filesController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: grepBox))
        try await wait("tree restored") { controller.filesController.allItems.count == 3 }


        controller.selectFileOrFolder("src/util.c")
        check(controller.filesController.selectedItems().map(\.file.path) == ["src/util.c"], "select file in tree")
    }

    private static func testFolderDescription() {
        let group = FileStatusGroup(first: nil, second: .workingDirectory, summary: "", files: [])
        let items = ["dir/a.txt", "dir/sub/b.txt"].map { FileStatusListItem(group: group, file: ChangedFile(id: $0, path: $0, oldPath: nil, changeType: .modified, additions: 0, deletions: 0)) }
        check(RevisionDiffViewController.folderDescription("dir", items: items) == "(2) dir/\n\na.txt\nsub/b.txt", "folder description")
    }


    static func testBrowserStageKeepsSelection() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("shared.txt", "one\n")
        try fixture.commitAll("base")
        try fixture.write("shared.txt", "two\n")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentViewController: browser)
        window.setContentSize(NSSize(width: 1200, height: 800))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        func controllers(_ root: NSViewController) -> [NSViewController] { [root] + root.children.flatMap(controllers) }
        try await wait("browser loaded") { browser.revisions.contains { $0.id == .workingDirectory } }
        let grid = controllers(browser).compactMap { $0 as? RevisionGridViewController }.first!
        let diff = controllers(browser).compactMap { $0 as? RevisionDiffViewController }.first { $0.mode == .diff }!


        try await wait("browser history finished") { !grid.isShowingLoading }

        let tabs = controllers(browser).compactMap { $0 as? DetailTabsViewController }.first!
        for index in 0..<4 where diff.view.window == nil || diff.view.isHiddenOrHasHiddenAncestor { tabs.selectTab(at: index) }
        grid.selectCommit(id: .workingDirectory)
        try await wait("worktree diff \(browser.selectedCommitID.map(String.init(describing:)) ?? "-")") {
            browser.selectedCommitID == .workingDirectory && diff.filesController.allItems.contains { $0.file.path == "shared.txt" }
        }
        diff.filesController.selectItems(diff.filesController.allItems.filter { $0.file.path == "shared.txt" })
        diff.filesController.perform("file.stage")
        try await wait("staged") { ((try? fixture.git(["diff", "--cached", "--name-only"])) ?? "") == "shared.txt\n" }
        try await wait("refreshed \(browser.selectedCommitID.map(String.init(describing:)) ?? "-")") {
            browser.statusLabel.stringValue.hasPrefix("Staged") || browser.statusLabel.stringValue.hasPrefix("Selected")
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        check(browser.selectedCommitID == .workingDirectory, "stage keeps the Working directory selected: \(String(describing: browser.selectedCommitID))")
    }

    private static func testSubmoduleCommitQueue() async throws {
        let fixture = try FileStatusFixture.make(), child = try FileStatusFixture.make()
        defer { fixture.remove(); child.remove() }
        try child.write("file", "child\n")
        try child.commitAll("child")
        for path in ["one", "two"] {
            try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", child.repo.path, path])
        }
        try fixture.commitAll("children")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentViewController: browser)
        window.setContentSize(NSSize(width: 1000, height: 700))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await wait("Browser repository for submodule Commit") { browser.repositoryIdentity != nil }
        let commands = GitUICommands(repositoryModule: module, browser: browser)
        let group = FileStatusGroup(first: .index, second: .workingDirectory, summary: "", files: [])
        let items = ["one", "two"].map { path -> FileStatusListItem in
            var file = ChangedFile(id: path, path: path, oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
            file.isSubmodule = true
            return FileStatusListItem(group: group, file: file)
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        func commitWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && !existing.contains(ObjectIdentifier($0)) && $0.title.hasPrefix("Commit") }
        }
        defer { commitWindows().forEach { $0.close() } }
        commands.performFileStatusCommand(.init(identifier: "file.submodule.commit", items: items, folder: nil, tool: nil, focused: nil, remembered: nil))
        try await wait("first submodule Commit") { commitWindows().count == 1 }
        let first = commitWindows()[0]
        first.close()
        try await wait("second submodule Commit") { commitWindows().count == 1 && commitWindows()[0] !== first }
        commitWindows()[0].close()
        check(commitWindows().isEmpty, "selected submodules each open once, in sequence")
    }
}
