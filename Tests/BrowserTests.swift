@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit



enum BrowserTests {
    static func run() async throws {
        testCommandEligibility()
        testGitActionPresentation()
        testLayoutPreferences()
        await testHotkeys()
        try testWindowTitle()
        try await testMaintenance()
        try await testContinueMerge()
        try await testBrowserComposition()
        print("BrowserTests: passed")
    }

    private static func testCommandEligibility() {
        let real = commit("a"), other = commit("b")
        let worktree = Commit(id: .workingDirectory, shortID: "", subject: "Working directory", body: "", authorName: "", authorEmail: "",
                              authorDate: Date(), committerName: "", committerEmail: "", commitDate: Date(), parentIDs: [],
                              references: [], kind: .workingDirectory)
        var eligibility = BrowserCommandEligibility.make(selected: [real], isBare: false)
        check(eligibility.singleNormalCommitNotBare && eligibility.rebase && eligibility.singleNormalCommit && eligibility.notBare,
              "eligibility: one real commit enables every command")
        eligibility = .make(selected: [real, other], isBare: false)
        check(!eligibility.singleNormalCommitNotBare && eligibility.rebase && !eligibility.singleNormalCommit,
              "eligibility: two commits allow rebase only among selection commands")
        eligibility = .make(selected: [worktree], isBare: false)
        check(!eligibility.singleNormalCommitNotBare && !eligibility.rebase && eligibility.notBare, "eligibility: artificial selection")
        eligibility = .make(selected: [real], isBare: true)
        check(!eligibility.singleNormalCommitNotBare && eligibility.singleNormalCommit && !eligibility.notBare && !eligibility.rebase,
              "eligibility: bare repositories keep tag/archive only")
    }

    private static func testGitActionPresentation() {
        check(BrowserGitAction.detect(rebase: true, merge: true, patch: true) == .rebase, "git action: rebase first")
        check(BrowserGitAction.detect(rebase: false, merge: true, patch: true) == .merge, "git action: merge before patch")
        check(BrowserGitAction.none.presentation(hasConflicts: false) == nil, "git action: hidden without action/conflicts")
        check(BrowserGitAction.none.presentation(hasConflicts: true)?.message == "There are unresolved merge conflicts."
              && BrowserGitAction.none.presentation(hasConflicts: true)?.buttons == [.resolve], "git action: conflicts only")
        let merge = BrowserGitAction.merge.presentation(hasConflicts: false)
        check(merge?.message == "Merge is currently in progress." && merge?.buttons == [.continue, .abort], "git action: merge")
        let patch = BrowserGitAction.patch.presentation(hasConflicts: true)
        check(patch?.message == "Patch is currently in progress with merge conflicts." && patch?.buttons == [.resolve, .abort, .more],
              "git action: patch with conflicts")
        check(BrowserGitAction.rebase.presentation(hasConflicts: false)?.buttons == [.continue, .abort, .more], "git action: rebase")
    }

    private static func testLayoutPreferences() {
        let saved = BrowserLayoutPreferences.Splitter(distance: 300, size: 1000)
        check(BrowserLayoutPreferences.restoredDistance(saved, size: 1000, fixed: .proportional) == 300, "splitter: same size")
        check(BrowserLayoutPreferences.restoredDistance(saved, size: 2000, fixed: .proportional) == 600, "splitter: proportional")
        check(BrowserLayoutPreferences.restoredDistance(saved, size: 2000, fixed: .fixedLeadingPane) == 300, "splitter: fixed panel 1")
        check(BrowserLayoutPreferences.restoredDistance(saved, size: 2000, fixed: .fixedTrailingPane) == 1300, "splitter: fixed panel 2")
        check(BrowserLayoutPreferences.restoredDistance(nil, size: 2000, fixed: .proportional) == nil, "splitter: nothing stored")
        let legacy = try? JSONDecoder().decode(BrowserLayoutPreferences.self, from: Data(#"{"commitInfoPosition":2}"#.utf8))
        check(legacy?.commitInfoPosition == .rightwardFromList && legacy?.showSplitViewLayout == true, "layout: tolerant decoding")
    }

    @MainActor
    private static func testHotkeys() {
        let overrides: [String: ApplicationKeyChord] = [:]
        check(ApplicationHotkeys.chord("createTag", overrides: overrides) == .init("t", .control), "hotkey: Create tag ⌃T")
        check(ApplicationHotkeys.chord("toggleLeftPanel", overrides: overrides) == .init("c", [.control, .option]), "hotkey: toggle left panel")
        check(ApplicationHotkeys.chord("focus.build", overrides: overrides) == .init("7", .control), "hotkey: focus build status")
        check(BrowserCommand.browseHotkey("stashPop") == .stashPop && BrowserCommand.browseHotkey("gitBash") == .openTerminal,
              "hotkey: window-level FormBrowse commands")
        check(ApplicationHotkeys.browseWindowCommands.allSatisfy { BrowserCommand.browseHotkey($0) != nil }, "hotkey: every window command maps")
    }

    private static func testWindowTitle() throws {
        let fixture = try BrowserFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("Project")
        check(BrowserPresentation.windowTitle(repositoryURL: repo, branch: "main") == "Project (main) - Git Extensions", "title: repository and branch")
        check(BrowserPresentation.windowTitle(repositoryURL: repo, branch: nil) == "Project (no branch) - Git Extensions", "title: detached")
        check(BrowserPresentation.windowTitle(repositoryURL: repo, branch: "main", pathFilter: "src/file.swift")
              == "\"file.swift\" Project (main) - Git Extensions", "title: path filter")
        check(BrowserPresentation.windowTitle(repositoryURL: fixture.root, branch: "main") == "Git Extensions", "title: not a repository")
        try "Custom name\n".write(to: repo.appendingPathComponent(".git/description"), atomically: true, encoding: .utf8)
        check(BrowserPresentation.repositoryDescription(repo) == "Custom name", "title: .git/description")
        let nested = fixture.root.appendingPathComponent("Holder/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.git(["init", "-q", "-b", "main", nested.path], in: fixture.root)
        check(BrowserPresentation.repositoryDescription(nested) == "repo", "title: a root repository keeps its own name")
        let inner = repo.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try fixture.git(["init", "-q", "-b", "main", inner.path], in: fixture.root)
        check(BrowserPresentation.repositoryDescription(inner) == "inner < Custom name", "title: nested repository names its root")
    }

    private static func testMaintenance() async throws {
        let fixture = try BrowserFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("Maintenance")
        try fixture.commit("b.txt", "2", "Second", in: repo)
        let child = try fixture.repository("Child")
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", child.path, "child"], in: repo)
        try fixture.git(["commit", "-qm", "Add child"], in: repo)
        let module = GitRepositoryModule(repositoryURL: repo, git: GitProcess())
        _ = try await module.loadRepositoryState()

        let parent = try fixture.git(["rev-parse", "HEAD~1"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let undone = try await module.undoLastCommit()
        let parentID = try ObjectID.parse(parent)
        check(undone.selectedCommitID == .object(parentID), "undo last commit: HEAD moves to the parent")
        let staged = try fixture.git(["diff", "--cached", "--name-only"], in: repo)
        check(staged.contains(".gitmodules"), "undo last commit: changes stay staged")

        let gitDir = repo.appendingPathComponent(".git/index.lock")
        let childLock = URL(fileURLWithPath: try fixture.git(["rev-parse", "--absolute-git-dir"], in: repo.appendingPathComponent("child"))
            .trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("index.lock")
        try Data().write(to: gitDir); try Data().write(to: childLock)
        let deleted = try await module.deleteIndexLocks()
        check(deleted.count == 2 && !FileManager.default.fileExists(atPath: gitDir.path) && !FileManager.default.fileExists(atPath: childLock.path),
              "delete index.lock: repository and submodule locks")
        check(RepositoryBrowserMaintenanceCommands.parseSubmodulePaths("160000 abc 0\tchild\u{0}100644 def 0\tfile\u{0}") == ["child"],
              "delete index.lock: gitlinks from ls-files --stage")

        var output = ""
        let gc = try await module.compressGitDatabase { output += String(decoding: $0.data, as: UTF8.self) }
        check(gc.succeeded && gc.arguments.contains("gc"), "compress git database: git gc")
    }

    private static func testContinueMerge() async throws {
        let fixture = try BrowserFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("Merge")
        try fixture.git(["checkout", "-qb", "topic"], in: repo)
        try fixture.commit("topic.txt", "t", "Topic", in: repo)
        try fixture.git(["checkout", "-q", "main"], in: repo)
        try fixture.commit("main.txt", "m", "Main", in: repo)
        try fixture.git(["merge", "--no-commit", "--no-ff", "topic"], in: repo)
        let module = GitRepositoryModule(repositoryURL: repo, git: GitProcess())
        _ = try await module.loadRepositoryState()
        let state = try await module.loadMutationState()
        check(state.mergeInProgress, "merge: in progress before continue")
        let result = try await module.continueMerge()
        let parents = try fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo).split(separator: " ")
        check(result.outcome == .completed && parents.count == 3, "merge --continue commits the merge")
        let after = try await module.loadMutationState()
        check(!after.mergeInProgress, "merge: no longer in progress")
    }

    @MainActor
    private static func testBrowserComposition() async throws {
        let store = AppSettingsStore.shared
        let savedLayout = store.browserLayoutPreferences
        defer { store.saveBrowserLayoutPreferences(savedLayout) }
        store.saveBrowserLayoutPreferences(BrowserLayoutPreferences())
        let fixture = try BrowserFixture.make()
        defer { fixture.remove() }
        let repo = try fixture.repository("Composition")
        let module = GitRepositoryModule(repositoryURL: repo, git: GitProcess())
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1200, height: 800))
        browser.viewDidAppear()
        for _ in 0..<300 where !window.title.contains("Composition") { try await Task.sleep(nanoseconds: 10_000_000) }
        check(window.title == "Composition (main) - Git Extensions", "browser: window title \(window.title)")
        check(BrowserCommandAvailability.shared.hasRepository && !BrowserCommandAvailability.shared.isBareRepository, "browser: repository state published")

        var snapshot = browser.layoutSnapshot
        check(!snapshot.leftPanelCollapsed && !snapshot.detailsCollapsed && snapshot.commitTabShown && !snapshot.commitInfoBesideGraph,
              "browser: default layout")
        check(!snapshot.visibleToolbarItems.contains("pull_shortcut_fetchToolStripMenuItem") && snapshot.visibleToolbarItems.contains("toolStripButtonPush"),
              "browser: fetch/pull shortcuts hidden by default")
        check(!snapshot.visibleToolbarItems.contains("toolStripWorktrees"), "browser: worktree button needs several worktrees")

        browser.setCommitInfoPosition(.rightwardFromList)
        snapshot = browser.layoutSnapshot
        check(!snapshot.commitTabShown && snapshot.commitInfoBesideGraph, "browser: commit info beside the graph")
        check(store.browserLayoutPreferences.commitInfoPosition == .rightwardFromList, "browser: commit info position persisted")
        browser.setShowSplitViewLayout(false)
        check(browser.layoutSnapshot.detailsCollapsed && !store.browserLayoutPreferences.showSplitViewLayout, "browser: split view layout")
        browser.toggleLeftPanel()
        check(browser.layoutSnapshot.leftPanelCollapsed && store.browserLayoutPreferences.leftPanelCollapsed, "browser: left panel persisted")
        browser.performTopLevelCommand(.toolbarItemVisibility("pull_shortcut_fetchToolStripMenuItem"))
        check(browser.layoutSnapshot.visibleToolbarItems.contains("pull_shortcut_fetchToolStripMenuItem")
              && store.browserLayoutPreferences.toolbarItemVisibility["pull_shortcut_fetchToolStripMenuItem"] == true, "browser: toolbar item customization")
        browser.performTopLevelCommand(.toolbarVisibility("Standard"))
        check(!browser.layoutSnapshot.visibleToolbarItems.contains("toolStripButtonPush")
              && BrowserCommandAvailability.shared.toolbars.first?.isVisible == false, "browser: Standard toolbar hidden for the session")

        let reopened = RepositoryBrowserViewController(repositoryModule: module)
        _ = reopened.view
        let restored = reopened.layoutSnapshot
        check(restored.leftPanelCollapsed && restored.detailsCollapsed && restored.commitInfoBesideGraph && !restored.commitTabShown
              && restored.visibleToolbarItems.contains("toolStripButtonPush"), "browser: layout restored, toolbar visibility is session-only")
        browser.viewWillDisappear()
        window.close()
    }



    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure("BrowserTests: \(message)") }
    }

    private static func commit(_ id: String) -> Commit {
        Commit(id: testRevisionID(id), shortID: id, subject: id, body: "", authorName: "T", authorEmail: "t@example.com",
               authorDate: Date(), committerName: "T", committerEmail: "t@example.com", commitDate: Date(), parentIDs: [], references: [])
    }
}

private final class BrowserFixture {
    let root: URL
    private init(root: URL) { self.root = root }

    static func make() throws -> BrowserFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BrowserFixture(root: root.resolvingSymlinksInPath())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-q", "-b", "main", url.path], in: root)
        try git(["config", "user.name", "Browser Fixture"], in: url)
        try git(["config", "user.email", "browser@example.com"], in: url)
        try git(["config", "commit.gpgsign", "false"], in: url)
        try commit("a.txt", "1", "First", in: url)
        return url
    }

    func commit(_ file: String, _ content: String, _ message: String, in url: URL) throws {
        try Data(content.utf8).write(to: url.appendingPathComponent(file))
        try git(["add", file], in: url)
        try git(["commit", "-qm", message], in: url)
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
        environment["GIT_EDITOR"] = "true"
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
