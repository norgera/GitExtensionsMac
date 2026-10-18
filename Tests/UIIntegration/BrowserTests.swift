import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @Suite("Browser")
    enum BrowserTests {

        @MainActor
        @Test("Toolbar controls are flat until hovered or checked") private static func testFlatToolbar() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("base.txt", "fixture\n")
            try fixture.commitAll("base")
            let browser = RepositoryBrowserViewController(repositoryModule: GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit()))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1300, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            window.setContentSize(NSSize(width: 1300, height: 500))
            window.makeKeyAndOrderFront(nil)
            defer {
                browser.viewWillDisappear()
                window.close()
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while browser.repositoryIdentity == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            browser.view.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let highlight = try #require(descendants(browser.view).compactMap { $0 as? ToolStripHighlightView }.first)
            let items = ToolStripHighlightView.items(in: highlight.stack)
            let popUps = items.compactMap { $0 as? NSPopUpButton }
            #expect(popUps.count >= 5 && popUps.allSatisfy { !$0.isBordered }, "toolbar dropdowns have no resting bezel")
            #expect(items.compactMap { $0 as? NSButton }.allSatisfy { !$0.isBordered }, "toolbar buttons have no resting bezel")
            #expect(items.contains { $0 is FlatSegmentedControl }, "stash split button draws without segment bezels")
            #expect(highlight.checkedButtons.count == 4, "layout, reflog and first-parent toggles show a checked box when on")
            #expect(highlight.splitPairs.count == 4 && highlight.splitPairs.allSatisfy { pair in
                (pair.1 as? NSButton).map { $0.title.isEmpty && $0.image != nil && $0.frame.width == ToolStripHighlightView.dropDownWidth } ?? false
            }, "split buttons pair with compact solid-arrow dropdowns")
            #expect(popUps.allSatisfy { ($0.cell as? NSPopUpButtonCell)?.arrowPosition == .noArrow }, "dropdowns use the toolstrip arrow")
            let probeImage = NSImage(size: NSSize(width: 16, height: 16))
            for popUp in popUps where !popUp.isHiddenOrHasHiddenAncestor {
                let cell = try #require(popUp.cell as? NSPopUpButtonCell)
                let arrowStart = popUp.bounds.maxX - ToolStripHighlightView.dropDownWidth + 1
                if popUp.title.isEmpty {
                    let saved = popUp.image
                    popUp.image = probeImage
                    #expect(cell.imageRect(forBounds: popUp.bounds).maxX <= arrowStart, "\(popUp.toolTip ?? ""): icon stays clear of its drop-down arrow")
                    popUp.image = saved
                } else {
                    let text = ceil((popUp.title as NSString).size(withAttributes: [.font: popUp.font!]).width)
                    let image: CGFloat = popUp.imagePosition == .imageLeading ? 20 : 0
                    let textEnd = cell.titleRect(forBounds: popUp.bounds).minX + image + text
                    #expect(textEnd <= arrowStart, "\(popUp.title): text ends before the drop-down arrow")
                    #expect(popUp.frame.width - textEnd <= ToolStripHighlightView.dropDownWidth + 12, "\(popUp.title): arrow sits close to the text \(popUp.frame.width - textEnd)")
                }
            }
            let iconButtons = items.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) && $0.title.isEmpty && $0.image != nil && $0.frame.width > ToolStripHighlightView.dropDownWidth }
            #expect(Set(iconButtons.map { $0.frame.width }).count <= 1, "icon buttons share one width \(iconButtons.map { $0.frame.width })")
            let branch = try #require(popUps.first { $0.title == "main" })
            highlight.hover(at: highlight.convert(NSPoint(x: branch.bounds.midX, y: branch.bounds.midY), from: branch))
            #expect(highlight.hoveredControl === branch, "hover highlights the control under the pointer")
            highlight.hover(at: nil)
            #expect(highlight.hoveredControl == nil, "leaving the toolbar clears the hover box")
        }

        @MainActor
        @Test("Detail tab buttons fill the tab bar") private static func testDetailTabHeight() {
            let pages = (0..<2).map { _ in
                let page = NSViewController()
                page.view = NSView()
                return page
            }
            let tabs = DetailTabsViewController()
            tabs.configure(items: [("Commit", "Commit", pages[0]), ("Diff", "Diff", pages[1])], selectedIndex: 0)
            let window = NSWindow(contentViewController: tabs)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 600, height: 200))
            defer { window.close() }
            tabs.view.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(tabs.view).compactMap { $0 as? NSButton }
            #expect(buttons.count == 2 && buttons.allSatisfy { $0.frame.height == 24 }, "tab buttons are as tall as the 24 pt tab bar \(buttons.map(\.frame.height))")
        }

        @Test("Command eligibility") private static func testCommandEligibility() {
            let real = commit("a")
            let other = commit("b")
            let worktree = Commit(
                id: .workingDirectory, shortID: "", subject: "Working directory", body: "", authorName: "", authorEmail: "",
                authorDate: Date(), committerName: "", committerEmail: "", commitDate: Date(), parentIDs: [],
                references: [], kind: .workingDirectory)
            var eligibility = BrowserCommandEligibility.make(selected: [real], isBare: false)
            #expect(
                eligibility.singleNormalCommitNotBare && eligibility.rebase && eligibility.singleNormalCommit && eligibility.notBare,
                "eligibility: one real commit enables every command")
            eligibility = .make(selected: [real, other], isBare: false)
            #expect(
                !eligibility.singleNormalCommitNotBare && eligibility.rebase && !eligibility.singleNormalCommit,
                "eligibility: two commits allow rebase only among selection commands")
            eligibility = .make(selected: [worktree], isBare: false)
            #expect(!eligibility.singleNormalCommitNotBare && !eligibility.rebase && eligibility.notBare, "eligibility: artificial selection")
            eligibility = .make(selected: [real], isBare: true)
            #expect(
                !eligibility.singleNormalCommitNotBare && eligibility.singleNormalCommit && !eligibility.notBare && !eligibility.rebase,
                "eligibility: bare repositories keep tag/archive only")
        }

        @Test("Git action presentation") private static func testGitActionPresentation() {
            #expect(BrowserGitAction.detect(rebase: true, merge: true, patch: true) == .rebase, "git action: rebase first")
            #expect(BrowserGitAction.detect(rebase: false, merge: true, patch: true) == .merge, "git action: merge before patch")
            #expect(BrowserGitAction.none.presentation(hasConflicts: false) == nil, "git action: hidden without action/conflicts")
            #expect(
                BrowserGitAction.none.presentation(hasConflicts: true)?.message == "There are unresolved merge conflicts."
                    && BrowserGitAction.none.presentation(hasConflicts: true)?.buttons == [.resolve], "git action: conflicts only")
            let merge = BrowserGitAction.merge.presentation(hasConflicts: false)
            #expect(merge?.message == "Merge is currently in progress." && merge?.buttons == [.continue, .abort], "git action: merge")
            let patch = BrowserGitAction.patch.presentation(hasConflicts: true)
            #expect(
                patch?.message == "Patch is currently in progress with merge conflicts." && patch?.buttons == [.resolve, .abort, .more],
                "git action: patch with conflicts")
            #expect(BrowserGitAction.rebase.presentation(hasConflicts: false)?.buttons == [.continue, .abort, .more], "git action: rebase")
        }

        @Test("Layout preferences") private static func testLayoutPreferences() {
            let saved = BrowserLayoutPreferences.Splitter(distance: 300, size: 1000)
            #expect(BrowserLayoutPreferences.restoredDistance(saved, size: 1000, fixed: .proportional) == 300, "splitter: same size")
            #expect(BrowserLayoutPreferences.restoredDistance(saved, size: 2000, fixed: .proportional) == 600, "splitter: proportional")
            #expect(BrowserLayoutPreferences.restoredDistance(saved, size: 2000, fixed: .fixedLeadingPane) == 300, "splitter: fixed panel 1")
            #expect(BrowserLayoutPreferences.restoredDistance(saved, size: 2000, fixed: .fixedTrailingPane) == 1300, "splitter: fixed panel 2")
            #expect(BrowserLayoutPreferences.restoredDistance(nil, size: 2000, fixed: .proportional) == nil, "splitter: nothing stored")
            let legacy = try? JSONDecoder().decode(BrowserLayoutPreferences.self, from: Data(#"{"commitInfoPosition":2}"#.utf8))
            #expect(legacy?.commitInfoPosition == .rightwardFromList && legacy?.showSplitViewLayout == true, "layout: tolerant decoding")
        }

        @MainActor
        @Test("Hotkeys") private static func testHotkeys() {
            let overrides: [String: ApplicationKeyChord] = [:]
            #expect(ApplicationHotkeys.chord("createTag", overrides: overrides) == .init("t", .control), "hotkey: Create tag ⌃T")
            #expect(ApplicationHotkeys.chord("toggleLeftPanel", overrides: overrides) == .init("c", [.control, .option]), "hotkey: toggle left panel")
            #expect(ApplicationHotkeys.chord("focus.build", overrides: overrides) == .init("7", .control), "hotkey: focus build status")
            #expect(
                BrowserCommand.browseHotkey("stashPop") == .stashPop && BrowserCommand.browseHotkey("gitBash") == .openTerminal,
                "hotkey: window-level FormBrowse commands")
            #expect(ApplicationHotkeys.browseWindowCommands.allSatisfy { BrowserCommand.browseHotkey($0) != nil }, "hotkey: every window command maps")
            #expect(
                ApplicationHotkeys.chord("goToChild", overrides: overrides) == .init("n", .control)
                    && ApplicationHotkeys.chord("goToParent", overrides: overrides) == .init("p", .control)
                    && ApplicationHotkeys.chord("toggleArtificialAndHead", overrides: overrides) == .init("\\", .control)
                    && ApplicationHotkeys.chord("goToSubmodule", overrides: overrides).key.isEmpty
                    && ApplicationHotkeys.chord("openCommitsWithDifftool", overrides: overrides).key.isEmpty, "hotkey: FormBrowse forward defaults")
            #expect(
                BrowserCommand.browseHotkey("goToChild") == .revisionGridRestoringFileFocus("revision.navigate.child")
                    && BrowserCommand.browseHotkey("goToParent") == .revisionGridRestoringFileFocus("revision.navigate.parent")
                    && BrowserCommand.browseHotkey("toggleArtificialAndHead") == .revisionGrid("revision.navigate.toggleArtificial")
                    && BrowserCommand.browseHotkey("openCommitsWithDifftool") == .revisionGrid("revision.compare.difftool")
                    && BrowserCommand.browseHotkey("goToSubmodule") == .goToSubmodule, "hotkey: FormBrowse forwards route to grid/toolbar owners")
            #expect(ApplicationHotkeys.matching(.init("\u{f706}"), category: "Commit", overrides: overrides) == "commit.openWithDifftool", "hotkey: Commit F3")
        }

        private static func key(_ window: NSWindow, _ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            return window.performKeyEquivalent(with: event)
        }

        private static func wait(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw TestFailure(description: "BrowserTests: timed out waiting for \(message)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        @MainActor
        @Test("Deferred hotkeys") private static func testDeferredHotkeys() async throws {
            let store = AppSettingsStore.shared
            let savedPreferences = store.revisionGridPreferences
            store.saveRevisionGridPreferences(RevisionGridPreferences())
            defer { store.saveRevisionGridPreferences(savedPreferences) }
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.txt", "base\n")
            try fixture.commitAll("base")
            let base = try fixture.head()
            try fixture.write("a.txt", "second\n")
            try fixture.commitAll("second")
            let head = try fixture.head()
            try fixture.write("a.txt", "worktree\n")
            try fixture.write("b.txt", "staged\n")
            _ = try fixture.git(["add", "b.txt"])
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let browser = RepositoryBrowserViewController(repositoryModule: module)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.makeKeyAndOrderFront(nil)
            defer {
                browser.viewWillDisappear()
                window.close()
            }
            func controllers(_ root: NSViewController) -> [NSViewController] { [root] + root.children.flatMap(controllers) }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            try await wait("browser loaded") { browser.revisions.contains { $0.id == .object(head) } }
            let grid = controllers(browser).compactMap { $0 as? RevisionGridViewController }.first!
            let diff = controllers(browser).compactMap { $0 as? RevisionDiffViewController }.first { $0.mode == .diff }!
            try await wait("history finished") { !grid.isShowingLoading }
            let tabs = controllers(browser).compactMap { $0 as? DetailTabsViewController }.first!
            for index in 0..<4 where diff.view.window == nil || diff.view.isHiddenOrHasHiddenAncestor { tabs.selectTab(at: index) }
            grid.selectCommit(id: .object(head))
            try await wait("head selected") { browser.selectedCommitID == .object(head) }
            let fileList = descendants(diff.view).first { $0 is NSOutlineView || $0 is NSTableView }!
            window.makeFirstResponder(fileList)
            #expect(key(window, "p", .control, keyCode: 35), "hotkey: ⌃P handled by the Browse window")
            try await wait("parent selected") { browser.selectedCommitID == .object(base) }
            #expect(window.firstResponder === fileList, "hotkey: ⌃P restores file-list focus")
            #expect(key(window, "n", .control, keyCode: 45), "hotkey: ⌃N handled by the Browse window")
            try await wait("child selected") { browser.selectedCommitID == .object(head) }
            #expect(window.firstResponder === fileList, "hotkey: ⌃N restores file-list focus")
            #expect(key(window, "\\", .control, keyCode: 42), "hotkey: ⌃\\ handled by the Browse window")
            try await wait("artificial selected") { browser.selectedCommitID == .workingDirectory }
            #expect(!key(window, "s", [.control, .option], keyCode: 1), "hotkey: unbound chords fall through")

            var opened: [(RevisionID, String)] = []
            let controller = CommitWorkflowDialog.present(
                source: module, initialMode: .normal, head: nil, draft: nil, owner: window,
                onDifftool: { commit, file in opened.append((commit.id, file.path)) },
                onRepositoryChanged: { _ in }, onClose: {})
            let commitWindow = controller.window!
            defer { commitWindow.close() }
            try await wait("commit lists") {
                descendants(commitWindow.contentView!).compactMap { $0 as? NSOutlineView }.filter { $0.numberOfRows > 0 }.count >= 2
            }
            let lists = descendants(commitWindow.contentView!).compactMap { $0 as? NSOutlineView }.filter { $0.numberOfRows > 0 }
            for (list, kind, path) in [(lists[0], RevisionID.workingDirectory, "a.txt"), (lists[1], RevisionID.index, "b.txt")] {
                let row = (0..<list.numberOfRows).first { (list.item(atRow: $0) as? ChangedFileNode)?.file != nil }!
                list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                commitWindow.makeFirstResponder(list)
                try await wait("F3 \(path)") {
                    opened.removeAll()
                    _ = key(commitWindow, "\u{f706}", .function, keyCode: 99)
                    return opened.count == 1 && opened[0].0 == kind && opened[0].1 == path
                }
            }
        }

        @Test("Window title") @MainActor private static func testWindowTitle() throws {
            let fixture = try BrowserFixture.make()
            defer { fixture.remove() }
            let repo = try fixture.repository("Project")
            #expect(BrowserPresentation.windowTitle(repositoryURL: repo, branch: "main") == "Project (main) - Git Extensions", "title: repository and branch")
            #expect(BrowserPresentation.windowTitle(repositoryURL: repo, branch: nil) == "Project (no branch) - Git Extensions", "title: detached")
            #expect(
                BrowserPresentation.windowTitle(repositoryURL: repo, branch: "main", pathFilter: "src/file.swift")
                    == "\"file.swift\" Project (main) - Git Extensions", "title: path filter")
            #expect(BrowserPresentation.windowTitle(repositoryURL: fixture.root, branch: "main") == "Git Extensions", "title: not a repository")
            try "Custom name\n".write(to: repo.appendingPathComponent(".git/description"), atomically: true, encoding: .utf8)
            #expect(BrowserPresentation.repositoryDescription(repo) == "Custom name", "title: .git/description")
            let nested = fixture.root.appendingPathComponent("Holder/repo", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try fixture.git(["init", "-q", "-b", "main", nested.path], in: fixture.root)
            #expect(BrowserPresentation.repositoryDescription(nested) == "repo", "title: a root repository keeps its own name")
            let inner = repo.appendingPathComponent("inner", isDirectory: true)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try fixture.git(["init", "-q", "-b", "main", inner.path], in: fixture.root)
            #expect(BrowserPresentation.repositoryDescription(inner) == "inner < Custom name", "title: nested repository names its root")
        }

        @Test("Maintenance") private static func testMaintenance() async throws {
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
            #expect(undone.selectedCommitID == .object(parentID), "undo last commit: HEAD moves to the parent")
            let staged = try fixture.git(["diff", "--cached", "--name-only"], in: repo)
            #expect(staged.contains(".gitmodules"), "undo last commit: changes stay staged")

            let gitDir = repo.appendingPathComponent(".git/index.lock")
            let childLock = URL(
                fileURLWithPath: try fixture.git(["rev-parse", "--absolute-git-dir"], in: repo.appendingPathComponent("child"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ).appendingPathComponent("index.lock")
            try Data().write(to: gitDir)
            try Data().write(to: childLock)
            let deleted = try await module.deleteIndexLocks()
            #expect(
                deleted.count == 2 && !FileManager.default.fileExists(atPath: gitDir.path) && !FileManager.default.fileExists(atPath: childLock.path),
                "delete index.lock: repository and submodule locks")
            #expect(
                RepositoryBrowserMaintenanceCommands.parseSubmodulePaths("160000 abc 0\tchild\u{0}100644 def 0\tfile\u{0}") == ["child"],
                "delete index.lock: gitlinks from ls-files --stage")

            let gc = try await module.compressGitDatabase { _ in }
            #expect(gc.succeeded && gc.arguments.contains("gc"), "compress git database: git gc")
        }

        @Test("Continue merge") private static func testContinueMerge() async throws {
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
            #expect(state.mergeInProgress, "merge: in progress before continue")
            let result = try await module.continueMerge()
            let parents = try fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo).split(separator: " ")
            #expect(result.outcome == .completed && parents.count == 3, "merge --continue commits the merge")
            let after = try await module.loadMutationState()
            #expect(!after.mergeInProgress, "merge: no longer in progress")
        }

        @MainActor
        @Test("Browser composition") private static func testBrowserComposition() async throws {
            let store = AppSettingsStore.shared
            let savedLayout = store.browserLayoutPreferences
            let savedPull = store.pullPreferences
            defer {
                store.saveBrowserLayoutPreferences(savedLayout)
                store.savePullPreferences(savedPull)
            }
            store.saveBrowserLayoutPreferences(BrowserLayoutPreferences())
            let fixture = try BrowserFixture.make()
            defer { fixture.remove() }
            let repo = try fixture.repository("Composition")
            let module = GitRepositoryModule(repositoryURL: repo, git: GitProcess())
            let browser = RepositoryBrowserViewController(repositoryModule: module)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            window.setContentSize(NSSize(width: 1200, height: 800))
            browser.viewDidAppear()
            for _ in 0..<300 where !window.title.contains("Composition") { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(window.title == "Composition (main) - Git Extensions", "browser: window title \(window.title)")
            #expect(
                BrowserCommandAvailability.shared.hasRepository && !BrowserCommandAvailability.shared.isBareRepository, "browser: repository state published")
            browser.rebuildBranchMenu()
            let branchItems = browser.branchPopUp.itemArray
            if #available(macOS 27.0, *) {
                #expect(branchItems.dropFirst(3).allSatisfy { $0.preferredImageVisibility == .visible }, "native branch images explicitly visible")
            }
            for (index, id) in ["stash", "stashStaged", "stashPop"].enumerated() {
                let chord = ApplicationHotkeys.shared.chord(for: id)!
                let item = browser.stashMenu.items[index]
                #expect(
                    item.keyEquivalent == chord.key && item.keyEquivalentModifierMask.rawValue == chord.modifiers,
                    "stash dropdown uses configured shortcut cues for \(id)")
            }
            let worktrees = browser.worktreesMenu()
            if #available(macOS 27.0, *) {
                #expect(
                    worktrees.items.filter { $0.representedObject is String || $0.title == "Create worktree…" }.allSatisfy {
                        $0.preferredImageVisibility == .visible
                    }, "worktree and create images visible")
            }
            #expect(browser.branchPopUp.title == "main" && branchItems.first?.title == "main", "pull-down caption preserves the current branch")
            #expect(
                branchItems.count >= 4 && branchItems[1].title == "Checkout branch…" && branchItems[2].isSeparatorItem,
                "visible dropdown begins with Checkout and separator")
            #expect(
                branchItems.filter { $0.title == "main" }.count == 2 && branchItems.dropFirst(3).contains { $0.title == "main" && $0.state == .on },
                "the current branch also remains selectable without replacing the caption item")

            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let pull = descendants(browser.view).compactMap { $0 as? SplitToolbarPopUpButton }.first!
            let pullMenu = pull.menu!
            #expect(
                pull.pullsDown && pullMenu.items.dropFirst().prefix(2).map { $0.isSeparatorItem ? "|" : $0.title } == ["Open pull dialog…", "|"],
                "source visible dropdown begins with Open pull dialog and separator")
            #expect(
                pullMenu.items[1].keyEquivalent == String(UnicodeScalar(NSDownArrowFunctionKey)!) && pullMenu.items[1].keyEquivalentModifierMask == [.control],
                "Open pull dialog exposes source Control-Down cue")
            let choices = pullMenu.items.last!.submenu!
            #expect(
                choices.items.map(\.title) == ["Open pull dialog", "Pull - merge", "Pull - rebase", "Fetch", "Fetch and prune all"],
                "single-remote default-action submenu source ordering and fetch-all visibility")
            let fetch = choices.items.first { $0.representedObject as? String == PullActionPreference.fetch.rawValue }!
            let persistent = fetch.view as! PersistentMenuChoiceView
            #expect(persistent.accessibilityPerformPress(), "default choice exposes an actual native accessibility action")
            #expect(
                store.pullPreferences.defaultAction == .fetch && pull.menu === pullMenu && pullMenu.items.last!.submenu === choices,
                "default preference updates without replacing or closing tracked menus")
            #expect(
                fetch.state == .on && choices.items.filter { $0.state == .on }.count == 1 && pull.toolTip == "Fetch",
                "default update refreshes single checkmark and primary action tooltip")
            #expect(
                persistent.accessibilityPerformPress() && store.pullPreferences.defaultAction == .fetch && fetch.state == .on,
                "selecting current default remains selected")
            var primary = 0
            pull.onPrimaryClick = { primary += 1 }
            let point = pull.convert(NSPoint(x: pull.bounds.minX + 2, y: pull.bounds.midY), to: nil)
            let mouse = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            pull.mouseDown(with: mouse)
            #expect(
                primary == 1 && pull.menu === pullMenu,
                "split primary click dispatches default directly without opening dropdown or launching fixture Git action")
            let merge = choices.items.first { $0.representedObject as? String == PullActionPreference.merge.rawValue }!
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            (merge.view as! PersistentMenuChoiceView).keyDown(with: event)
            #expect(
                store.pullPreferences.defaultAction == .merge && merge.state == .on && pull.menu === pullMenu,
                "Return is an actual persistent default-choice command")
            let modules = browser.submodulesMenu()
            modules.update()
            #expect(
                modules.items.map { $0.isSeparatorItem ? "|" : $0.title } == ["No submodules", "|", "Update all submodules"]
                    && !modules.items[0].isEnabled && modules.items[2].isEnabled, "actual no-submodule menu retains information and update workflow")
            if #available(macOS 27.0, *) { #expect(modules.items[2].preferredImageVisibility == .visible, "submodule update icon explicitly visible") }
            var snapshot = browser.layoutSnapshot
            #expect(
                !snapshot.leftPanelCollapsed && !snapshot.detailsCollapsed && snapshot.commitTabShown && !snapshot.commitInfoBesideGraph,
                "browser: default layout")
            #expect(
                !snapshot.visibleToolbarItems.contains("pull_shortcut_fetchToolStripMenuItem") && snapshot.visibleToolbarItems.contains("toolStripButtonPush"),
                "browser: fetch/pull shortcuts hidden by default")
            #expect(!snapshot.visibleToolbarItems.contains("toolStripWorktrees"), "browser: worktree button needs several worktrees")

            browser.setCommitInfoPosition(.rightwardFromList)
            snapshot = browser.layoutSnapshot
            #expect(!snapshot.commitTabShown && snapshot.commitInfoBesideGraph, "browser: commit info beside the graph")
            #expect(store.browserLayoutPreferences.commitInfoPosition == .rightwardFromList, "browser: commit info position persisted")
            browser.setShowSplitViewLayout(false)
            #expect(browser.layoutSnapshot.detailsCollapsed && !store.browserLayoutPreferences.showSplitViewLayout, "browser: split view layout")
            browser.toggleLeftPanel()
            #expect(browser.layoutSnapshot.leftPanelCollapsed && store.browserLayoutPreferences.leftPanelCollapsed, "browser: left panel persisted")
            browser.performTopLevelCommand(.toolbarItemVisibility("pull_shortcut_fetchToolStripMenuItem"))
            #expect(
                browser.layoutSnapshot.visibleToolbarItems.contains("pull_shortcut_fetchToolStripMenuItem")
                    && store.browserLayoutPreferences.toolbarItemVisibility["pull_shortcut_fetchToolStripMenuItem"] == true,
                "browser: toolbar item customization")
            browser.performTopLevelCommand(.toolbarVisibility("Standard"))
            #expect(
                !browser.layoutSnapshot.visibleToolbarItems.contains("toolStripButtonPush")
                    && BrowserCommandAvailability.shared.toolbars.first?.isVisible == false, "browser: Standard toolbar hidden for the session")
            var cleared = store.browserLayoutPreferences
            cleared.splitters = [:]
            store.saveBrowserLayoutPreferences(cleared)
            NotificationCenter.default.post(name: CommandLineSession.willExit, object: nil)
            #expect(!store.browserLayoutPreferences.splitters.isEmpty, "browser: splitters saved before a command-line session exits")

            let reopened = RepositoryBrowserViewController(repositoryModule: module)
            _ = reopened.view
            let restored = reopened.layoutSnapshot
            #expect(
                restored.leftPanelCollapsed && restored.detailsCollapsed && restored.commitInfoBesideGraph && !restored.commitTabShown
                    && restored.visibleToolbarItems.contains("toolStripButtonPush"), "browser: layout restored, toolbar visibility is session-only")
            browser.viewWillDisappear()
            window.close()
        }

        private static func commit(_ id: String) -> Commit {
            Commit(
                id: testRevisionID(id), shortID: id, subject: id, body: "", authorName: "T", authorEmail: "t@example.com",
                authorDate: Date(), committerName: "T", committerEmail: "t@example.com", commitDate: Date(), parentIDs: [], references: [])
        }
    }
}

typealias BrowserTests = UIIntegrationTests.BrowserTests

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
        let process = FixtureProcess()
        let stdout = Pipe()
        let stderr = Pipe()
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
            throw TestFailure(description: "git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
