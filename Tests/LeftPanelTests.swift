@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit


@MainActor
enum LeftPanelTests {
    static func run() async throws {
        _ = NSApplication.shared
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n")
        try fixture.commitAll("base")
        try fixture.git(["branch", "feature"])
        try fixture.git(["branch", "group/one"])
        try fixture.git(["branch", "group/two"])
        try fixture.git(["tag", "v1"])
        try fixture.git(["remote", "add", "origin", fixture.repo.path])
        try fixture.git(["fetch", "-q", "origin"])
        try fixture.write("a.txt", "changed\n")
        try fixture.git(["stash", "-q"])

        let savedTree = AppSettingsStore.shared.repositoryTreePreferences
        AppSettingsStore.shared.saveRepositoryTreePreferences(RepositoryTreePreferences())
        defer { AppSettingsStore.shared.saveRepositoryTreePreferences(savedTree) }

        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentViewController: browser)
        window.setContentSize(NSSize(width: 1200, height: 800))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        func controllers(_ root: NSViewController) -> [NSViewController] { [root] + root.children.flatMap(controllers) }
        let tree = controllers(browser).compactMap { $0 as? RepositoryOutlineViewController }.first!
        try await wait("tree and grid loaded") {
            browser.revisions.contains { !$0.isArtificial } && (0..<tree.rowCount).contains { tree.node(atRow: $0)?.title == "Branches" }
        }
        let grid = controllers(browser).compactMap { $0 as? RevisionGridViewController }.first!
        try await wait("revision read finished") { !grid.isShowingLoading }
        tree.expandAll()

        func row(_ predicate: (RepositoryTreeNode) -> Bool) -> Int? {
            (0..<tree.rowCount).first { tree.node(atRow: $0).map(predicate) == true }
        }
        func leaves(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { item in item.submenu.map(leaves) ?? [item] } }


        var seen = Set<String>()
        for index in 0..<tree.rowCount {
            let menu = tree.contextMenu(forRow: index)
            for item in leaves(menu) where item.isEnabled {
                guard let id = item.identifier?.rawValue else { continue }
                seen.insert(id)
                check(item.action != nil && !(item.target is PlaceholderMenuTarget), "enabled placeholder \(id) on \(tree.node(atRow: index)?.title ?? "?")")
            }
        }
        for id in ["repository.remoteBranch.pull", "repository.remoteBranch.fetchRebase", "repository.stash.drop"] {
            check(seen.contains(id), "\(id) is offered and routed")
        }


        let folderRow = try require(row { if case .folder(_, let isRemote) = $0.kind { !isRemote } else { false } }, "branch folder row")
        let folderNode = try require(tree.node(atRow: folderRow), "folder node")
        tree.toggleSelectionWithDescendants(row: folderRow)
        try await Task.sleep(nanoseconds: 500_000_000)
        let selectedTitles = Set(tree.selectedNodesForTesting.map { $0.id })
        let expected = Set(([folderNode] + folderNode.children).map { $0.id })
        check(expected.isSubset(of: selectedTitles), "⌘⇧-click selects the folder with its descendants: \(selectedTitles)")


        let mainRow = try require(row { if case .branch(let branch) = $0.kind { branch.isCurrent } else { false } }, "current branch row")
        _ = tree.contextMenu(forRow: mainRow)
        try await wait("grid follows the branch selection") { grid.selectedCommits.map(\.id) == [browser.selectedCommitID] && !grid.isShowingLoading }
        var menu = tree.contextMenu(forRow: mainRow)
        for id in ["repository.branch.checkout", "repository.branch.merge", "repository.branch.reset", "repository.branch.delete"] {
            check(menuItem(withIdentifier: id, in: menu)?.isEnabled == false, "current branch disables \(id)")
        }
        check(menuItem(withIdentifier: "repository.branch.create", in: menu)?.isEnabled == true, "current branch can create")


        check(browser.selectedCommitID.flatMap { id in browser.revisions.first { $0.id == id } } != nil, "selecting the branch selects its revision")
        NSPasteboard.general.clearContents()
        let hash = try require(menuItem(withIdentifier: "revision.copy.hash", in: menu), "copy hash item")
        NSApp.sendAction(hash.action!, to: hash.target, from: hash)
        let head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        check(NSPasteboard.general.string(forType: .string) == head, "copy commit hash copies the selected revision")


        check(menuItem(withIdentifier: "repository.sortOrder", in: menu) == nil, "Git default sorting hides Sort order")
        check(menuItem(withIdentifier: "repository.sortBy.gitDefault", in: menu)?.state == .on, "current sort is checked")
        let alpha = try require(menuItem(withIdentifier: "repository.sortBy.alphaNumeric", in: menu), "alpha-numeric sort")
        NSApp.sendAction(alpha.action!, to: alpha.target, from: alpha)
        menu = tree.contextMenu(forRow: try require(row { if case .branch = $0.kind { true } else { false } }, "branch row"))
        check(menuItem(withIdentifier: "repository.sortOrder.ascending", in: menu)?.state == .on, "explicit sort shows the checked order")


        let stashRow = try require(row { if case .stash = $0.kind { true } else { false } }, "stash row")
        _ = tree.contextMenu(forRow: stashRow)
        let stashesBefore = try fixture.git(["stash", "list"])
        tree.performShortcut("tree.delete")
        try await Task.sleep(nanoseconds: 300_000_000)
        check(try fixture.git(["stash", "list"]) == stashesBefore && window.attachedSheet == nil, "Delete on a stash node does nothing")


        var preferences = AppSettingsStore.shared.repositoryTreePreferences
        preferences.rootOrder = [.branches, .remotes, .worktrees, .tags, .submodules, .stashes]
        preferences.visibleRoots.remove(.remotes)
        AppSettingsStore.shared.saveRepositoryTreePreferences(preferences)
        tree.reloadForTesting()
        let branchesRow = try require(row { $0.title == "Branches" }, "Branches root")
        menu = tree.contextMenu(forRow: branchesRow)
        let down = try require(menuItem(withIdentifier: "repository.root.moveDown", in: menu), "Move down")
        NSApp.sendAction(down.action!, to: down.target, from: down)
        let order = AppSettingsStore.shared.repositoryTreePreferences.rootOrder
        check(Array(order.prefix(3)) == [.worktrees, .remotes, .branches], "Move down swaps with the next visible root: \(order)")


        let headID = RevisionID.object(try fixture.head())
        grid.selectCommit(id: headID)
        try await wait("HEAD selected") { browser.selectedCommitID == headID }
        let labels = grid.labelContext
        grid.labelContext = labels
        grid.applyBuildStatusColumnSettings()
        try await Task.sleep(nanoseconds: 300_000_000)
        check(browser.selectedCommitID == headID && grid.selectedCommits.map(\.id) == [headID], "grid reloads keep the selection")


        grid.setAndApplyPathFilter("no-such-path")
        try await wait("filtered grid") { !grid.isShowingLoading && !browser.revisions.contains { !$0.isArtificial } }
        let tagRow = try require(row { if case .tag = $0.kind { true } else { false } }, "tag row")
        menu = tree.contextMenu(forRow: tagRow)
        let create = try require(menuItem(withIdentifier: "repository.tag.createBranch", in: menu), "tag Create branch")
        check(create.isEnabled, "hidden tag can create a branch")
        NSApp.sendAction(create.action!, to: create.target, from: create)
        func createWindow() -> NSWindow? {
            window.attachedSheet ?? NSApp.windows.first { $0.isVisible && $0.title == "Create branch" }
        }
        try await wait("Create branch dialog for a hidden tag") { createWindow() != nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet) } else { createWindow()?.close() }
        grid.setAndApplyPathFilter("")
        print("LeftPanelTests: passed")
    }

    private static func wait(_ message: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { preconditionFailure("LeftPanelTests: timed out waiting for \(message())") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { preconditionFailure("LeftPanelTests: missing \(message)") }
        return value
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? condition()) == true else { preconditionFailure("LeftPanelTests: \(message)") }
    }
}
