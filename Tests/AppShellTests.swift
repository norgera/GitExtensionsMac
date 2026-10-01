@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit



@MainActor
enum AppShellTests {
    static func run() async throws {
        testHistoryOperations()
        testSplitterTopAndRecent()
        testSplitterCaptions()
        testStorePersistence()
        try await testBranchNames()
        try testOpenDirectory()
        try await testDashboard()
        try await testHost()
        testEnvironmentInformation()
        print("AppShellTests: passed")
    }

    private static func entry(_ path: String, _ anchor: RepositoryAnchor = .none, _ category: String? = nil) -> RepositoryHistoryEntry {
        RepositoryHistoryEntry(path: path, anchor: anchor, category: category)
    }

    private static func testHistoryOperations() {
        var history = [entry("/r/a"), entry("/r/b", .anchoredInTop), entry("/r/c")]
        history = RepositoryHistory.addAsMostRecent("/R/B/", to: history)
        check(history.map(\.path) == ["/r/b", "/r/a", "/r/c"] && history[0].anchor == .anchoredInTop, "history: move keeps anchor, case-insensitive")
        check(RepositoryHistory.addAsMostRecent("/r/b", to: history) == history, "history: already most recent")
        history = RepositoryHistory.addAsMostRecent("/r/d", to: history)
        check(history.first == entry("/r/d"), "history: new entry first")

        let adjusted = RepositoryHistory.adjustHistorySize([entry("/1"), entry("/2", .anchoredInRecent), entry("/3"), entry("/4"), entry("/5", .anchoredInTop)], size: 3)
        check(adjusted.map(\.path) == ["/1", "/2", "/5"], "history: adjust size \(adjusted.map(\.path))")
        check(RepositoryHistory.remove("/R/A", from: [entry("/r/a"), entry("/r/b")]).map(\.path) == ["/r/b"], "history: remove")
        var favourites = RepositoryHistory.assignCategory(entry("/r/a"), category: "Work", favourites: [])
        check(favourites == [entry("/r/a", .none, "Work")], "history: category adds favourite")
        favourites = RepositoryHistory.assignCategory(entry("/r/a"), category: "Home", favourites: favourites)
        check(favourites == [entry("/r/a", .none, "Home")], "history: category updates favourite")
        favourites = RepositoryHistory.assignCategory(entry("/r/a"), category: "  ", favourites: favourites)
        check(favourites.isEmpty, "history: blank category removes favourite")
        check(RepositoryHistory.removeInvalid([entry("/ok"), entry("/bad")]) { $0 == "/ok" }.map(\.path) == ["/ok"], "history: remove invalid")
        check(RepositoryHistory.displayPath("/Users/me/src/x", homeDirectory: "/Users/me") == "~/src/x", "history: display path")
        check(RepositoryHistory.displayPath("/opt/x", homeDirectory: "/Users/me") == "/opt/x", "history: display path outside profile")
        let legacy = try? JSONDecoder().decode(RepositoryHistoryEntry.self, from: Data(#"{"path":"/x","anchor":"Bogus"}"#.utf8))
        check(legacy == entry("/x"), "history: tolerant entry decoding")
        let settings = try? JSONDecoder().decode(RecentRepositorySettings.self, from: Data(#"{"maxTopRepositories":3}"#.utf8))
        check(settings?.maxTopRepositories == 3 && settings?.historySize == 30 && settings?.showCurrentBranch == true, "history: tolerant settings")
    }

    private static func splitter(_ configure: (inout RecentRepositorySettings) -> Void = { _ in }) -> RecentRepoSplitter {
        var settings = RecentRepositorySettings()
        configure(&settings)
        return RecentRepoSplitter(settings: settings, homeDirectory: "/Users/me")
    }

    private static func testSplitterTopAndRecent() {
        let history = [entry("/w/c"), entry("/w/a"), entry("/w/b", .anchoredInTop), entry("/w/d", .anchoredInRecent)]
        var split = splitter().split(history)
        check(split.top.map(\.repo.path) == ["/w/b"] && split.recent.count == 4, "splitter: only anchored top by default")
        split = splitter { $0.maxTopRepositories = 2 }.split(history)
        check(split.top.map(\.repo.path) == ["/w/c", "/w/b"], "splitter: unanchored trimmed after anchored \(split.top.map(\.repo.path))")
        split = splitter { $0.maxTopRepositories = 2; $0.hideTopRepositoriesFromRecentList = true }.split(history)
        check(split.recent.map(\.repo.path) == ["/w/d"], "splitter: hide top from recent \(split.recent.map(\.repo.path))")
        split = splitter { $0.sortRecentRepos = true }.split(history)
        check(split.recent.map(\.repo.path) == ["/w/a", "/w/b", "/w/c", "/w/d"], "splitter: sorted recent")
        check(split.recent.first { $0.repo.path == "/w/d" }?.anchored == true, "splitter: anchored flag")
    }

    private static func testSplitterCaptions() {
        let history = [entry("/Users/me/src/one/app"), entry("/Users/me/other/one/app"), entry("/opt/tools")]
        var captions = splitter().split(history).recent.map { $0.caption ?? "" }
        check(captions == ["~/src/one/app", "~/other/one/app", "/opt/tools"], "captions: none \(captions)")
        captions = splitter { $0.shorteningStrategy = .mostSignDir }.split(history).recent.map { $0.caption ?? "" }
        check(captions == ["app (src/one)", "app (other/one)", "tools"], "captions: most significant directory \(captions)")
        captions = splitter { $0.shorteningStrategy = .middleDots }.split([entry("/Users/me/a/b/c/proj/wd"), entry("/Users/me/github/proj/wd"), entry("/x/y/z")])
            .recent.map { $0.caption ?? "" }
        check(captions == ["~/a/../proj/wd", "~/github/proj/wd", "/x/y/z"], "captions: middle dots \(captions)")
        var dots = splitter { $0.shorteningStrategy = .middleDots; $0.comboMinWidth = 100 }
        dots.measure = { CGFloat($0.count) * 7 }
        let shortened = dots.split([entry("/Volumes/Data/company/projects/repository/working")]).recent.first?.caption ?? ""
        check(shortened.contains("..") && shortened.hasSuffix("working") && shortened.hasPrefix("/Vol") && shortened.count < 30, "captions: fixed-width middle dots \(shortened)")
    }

    private static func testStorePersistence() {
        withStore { store, defaults in
            check(!store.preferences.reopenLastRepository, "store: StartWithRecentWorkingDir defaults off")
            defaults.set(try? JSONEncoder().encode([["path": "/legacy/a", "lastOpened": "0"], ["path": "/legacy/b", "lastOpened": "0"]]),
                         forKey: "GitExtensionsMac.recentRepositories.v1")
            check(store.recentRepositories.map(\.path) == ["/legacy/a", "/legacy/b"], "store: legacy recent list migrates")
            var preferences = store.preferences
            preferences.maximumRecentRepositories = 5
            store.save(preferences)
            check(store.recentRepositorySettings.historySize == 10, "store: customized legacy limit clamps to 10")
            var settings = RecentRepositorySettings()
            settings.historySize = 12
            settings.shorteningStrategy = .mostSignDir
            store.saveRecentRepositorySettings(settings)
            check(AppSettingsStore(defaults: defaults).recentRepositorySettings == settings, "store: settings round trip")
            store.recordOpenedRepository(URL(fileURLWithPath: "/legacy/b", isDirectory: true))
            check(store.recentRepositories.map(\.path) == ["/legacy/b", "/legacy/a"] && store.lastRepositoryPath == "/legacy/b", "store: record opened")
            for index in 0..<20 { store.recordRecentRepository(URL(fileURLWithPath: "/many/\(index)", isDirectory: true)) }
            check(store.recentRepositories.count == 12 && store.recentRepositories.first?.path == "/many/19", "store: history size")
            store.assignCategory(entry("/many/19"), category: "Work")
            check(AppSettingsStore(defaults: defaults).favouriteRepositories == [entry("/many/19", .none, "Work")], "store: favourites persist")
            store.removeInvalidRepositories { $0.hasSuffix("/19") || $0.hasSuffix("/18") }
            check(store.recentRepositories.map(\.path) == ["/many/19", "/many/18"] && store.favouriteRepositories.count == 1, "store: remove invalid")
            store.removeFavouriteRepository(path: "/many/19")
            store.clearRecentRepositories()
            check(store.recentRepositories.isEmpty && store.favouriteRepositories.isEmpty, "store: clear")
        }
    }

    private static func testBranchNames() async throws {
        let fixture = try ShellFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("branches")
        let git = GitProcess()
        let onMain = await RepositoryHistory.currentBranchName(repo.path, git: git)
        check(onMain == "main", "branch: HEAD file")
        try fixture.git(["checkout", "-q", "--detach"], in: repo)
        let detached = await RepositoryHistory.currentBranchName(repo.path, git: git)
        check(detached == "(no branch)", "branch: detached")
        try fixture.git(["checkout", "-q", "main"], in: repo)
        let worktree = fixture.root.appendingPathComponent("linked")
        try fixture.git(["worktree", "add", "-q", "-b", "topic", worktree.path], in: repo)
        let linked = await RepositoryHistory.currentBranchName(worktree.path, git: git)
        check(linked == "topic", "branch: gitdir file")
        let bare = fixture.root.appendingPathComponent("bare.git")
        try fixture.git(["init", "-q", "--bare", bare.path], in: fixture.root)
        check(RepositoryHistory.isValidGitWorkingDir(bare.path) && RepositoryHistory.isBareRepository(bare.path)
              && !RepositoryHistory.isBareRepository(repo.path) && RepositoryHistory.isValidGitWorkingDir(worktree.path),
              "branch: bare and linked working directories")
        check(!RepositoryHistory.isValidGitWorkingDir(fixture.root.path), "branch: plain folder invalid")
    }

    private static func testOpenDirectory() throws {
        let fixture = try ShellFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("open")
        withStore { store, _ in
            let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
            check(OpenLocalRepositoryDialog.directories(store: store, currentRepository: nil) == [home], "open: home without history")
            var creation = store.repositoryCreationPreferences
            creation.cloneDestinationPath = "/clones"
            store.saveRepositoryCreationPreferences(creation)
            store.recordRecentRepository(URL(fileURLWithPath: "/r/one"))
            check(OpenLocalRepositoryDialog.directories(store: store, currentRepository: URL(fileURLWithPath: "/work/current"))
                  == ["/clones/", "/work/", "/r/one"], "open: clone path, parent and history")
            check(OpenLocalRepositoryDialog.openGitRepository(fixture.root.path, store: store) == nil, "open: invalid directory")
            check(OpenLocalRepositoryDialog.openGitRepository(fixture.root.appendingPathComponent("missing").path, store: store) == nil, "open: missing")
            check(OpenLocalRepositoryDialog.openGitRepository(repo.path, store: store)?.path == repo.path
                  && store.recentRepositories.first?.path == repo.path, "open: valid repository recorded as most recent")
        }
    }

    @MainActor
    private static func testDashboard() async throws {
        let fixture = try ShellFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("dash")
        let missing = fixture.root.appendingPathComponent("gone").path
        try await withStoreAsync { store, _ in
            store.saveRecentHistory([entry(repo.path), entry(missing)])
            store.saveFavouriteHistory([entry(repo.path, .none, "Work")])
            let dashboard = DashboardViewController(store: store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = dashboard
            dashboard.viewDidAppear()
            let list = dashboard.repositoriesList
            window.layoutIfNeeded()
            check(list.groups.map(\.title) == ["Recent repositories", "Work"] && list.groups[0].tiles.count == 2, "dashboard: groups")
            check(list.hasInvalidRepositories && list.groups[0].tiles[1].isValid == false, "dashboard: invalid repository")
            check(list.groups[1].tiles[0].isFavourite, "dashboard: favourite tile")
            check(window.firstResponder === list.searchField.currentEditor() || window.firstResponder === list.searchField, "dashboard: search focused")
            var opened: URL?
            dashboard.onOpenRecentRepository = { opened = $0 }
            list.searchField.stringValue = "dash"
            list.showRecentRepositories(reloadData: false)
            check(list.groups.flatMap(\.tiles).allSatisfy { $0.repository.path == repo.path }, "dashboard: search filter")
            _ = list.control(list.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            check(opened?.path == repo.path, "dashboard: Enter opens the first repository")
            list.searchField.stringValue = ""
            list.showRecentRepositories(reloadData: false)
            let menu = list.contextMenu(for: IndexPath(item: 0, section: 0))
            check(menu?.items.map(\.title) == ["Show in Finder", "", "Categories", "", "Remove project from the list", "Remove missing projects from the list"],
                  "dashboard: repository context menu \(menu?.items.map(\.title) ?? [])")
            let categories = menu?.item(withTitle: "Categories")?.submenu?.items
            check(categories?.map(\.title) == ["(none)", "Work", "", "Add new..."] && categories?[0].isEnabled == false, "dashboard: categories")
            for _ in 0..<200 where RepositoryCurrentBranchNameCache.shared.cachedBranchName(repo.path) == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            check(RepositoryCurrentBranchNameCache.shared.cachedBranchName(repo.path) == "main", "dashboard: branch name loaded")
            list.focusList()
            check(list.collectionView.selectionIndexPaths == [IndexPath(item: 0, section: 0)], "dashboard: list focus selects first")
            check(list.moveUpFromTopRow() && (window.firstResponder === list.searchField.currentEditor() || window.firstResponder === list.searchField),
                  "dashboard: up from top row returns to search")
            window.close()
        }
    }

    @MainActor
    private static func testHost() async throws {
        let fixture = try ShellFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("host")
        let store = AppSettingsStore.shared
        let savedRecent = store.recentRepositories, savedFavourites = store.favouriteRepositories
        defer { store.saveRecentHistory(savedRecent); store.saveFavouriteHistory(savedFavourites) }
        let host = ApplicationHostViewController(launch: .dashboard)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.viewDidAppear()
        check(host.dashboard != nil && window.title == "Git Extensions", "host: dashboard at startup")
        check(!ApplicationLifecycle.terminatesWithMainWindow && window.tabbingMode == .disallowed, "host: one window, tests do not terminate")
        BrowserCommandCenter.perform(.openRecentRepository(repo))
        for _ in 0..<500 where !(host.activeController is RepositoryBrowserViewController) { try await Task.sleep(nanoseconds: 10_000_000) }
        check(host.activeController is RepositoryBrowserViewController, "host: recent repository opens the browser")
        check(store.recentRepositories.first?.path == repo.path && store.lastRepositoryPath == repo.path, "host: opening records history")
        check(BrowserCommandAvailability.shared.isDashboard == false, "host: dashboard menu disabled in browser")
        BrowserCommandCenter.perform(.closeToDashboard)
        for _ in 0..<100 where host.dashboard == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        check(host.dashboard != nil && window.title == "Git Extensions", "host: close returns to dashboard")
        for _ in 0..<100 where BrowserCommandAvailability.shared.isDashboard != true { try await Task.sleep(nanoseconds: 10_000_000) }
        check(BrowserCommandAvailability.shared.isDashboard, "host: dashboard menu enabled")
        BrowserCommandCenter.perform(.clearRecentRepositories)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(store.recentRepositories.isEmpty && host.dashboard?.repositoriesList.groups.isEmpty == true, "host: clear list refreshes dashboard")
        window.close()
    }

    @MainActor
    private static func testEnvironmentInformation() {
        check(UserEnvironmentInformation.gitVersionInfo(nil) == "- (minimum: 2.43.0, recommended: 2.53.0)", "environment: no git")
        check(UserEnvironmentInformation.gitVersionInfo("2.39.5") == "2.39.5 (minimum: 2.43.0, please update!)", "environment: old git")
        check(UserEnvironmentInformation.gitVersionInfo("2.50.1") == "2.50.1 (recommended: 2.53.0 or later)", "environment: supported git")
        check(UserEnvironmentInformation.gitVersionInfo("2.53.0") == "2.53.0", "environment: recommended git")
        let text = UserEnvironmentInformation.information(gitVersion: "2.53.0")
        check(text.hasPrefix("- Git Extensions ") && text.contains("\n- Git 2.53.0\n"), "environment: block \(text)")
        check(GitExtensionsContributors.all.count > 100 && GitExtensionsContributors.all.contains("Henk Westhuis"), "about: contributors")
        let item = RepositoryHistoryUIService.menuItem(splitter().split([entry("/Users/me/x", .anchoredInTop)]).top[0], number: 10, group: "top", anchored: true)
        check(item.title == "10: ~/x" && item.toolTip == "/Users/me/x" && item.anchored, "menu: numbered caption with path tooltip")
    }



    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure("AppShellTests: \(message)") }
    }

    private static func withStore(_ body: (AppSettingsStore, UserDefaults) -> Void) {
        let suite = "GitExtensionsMac.AppShellTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("defaults suite") }
        body(AppSettingsStore(defaults: defaults), defaults)
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    private static func withStoreAsync(_ body: (AppSettingsStore, UserDefaults) async throws -> Void) async throws {
        let suite = "GitExtensionsMac.AppShellTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(AppSettingsStore(defaults: defaults), defaults)
    }
}

private final class ShellFixture {
    let root: URL
    private init(root: URL) { self.root = root }

    static func make() throws -> ShellFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ShellFixture(root: root.resolvingSymlinksInPath())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-q", "-b", "main", url.path], in: root)
        try git(["config", "user.name", "Shell Fixture"], in: url)
        try git(["config", "user.email", "shell@example.com"], in: url)
        try git(["config", "commit.gpgsign", "false"], in: url)
        try Data("1".utf8).write(to: url.appendingPathComponent("a.txt"))
        try git(["add", "a.txt"], in: url)
        try git(["commit", "-qm", "First"], in: url)
        return url
    }

    func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            preconditionFailure("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
    }
}
