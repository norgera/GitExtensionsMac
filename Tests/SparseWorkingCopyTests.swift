@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit


@MainActor
enum SparseWorkingCopyTests {
    static func run() async throws {
        _ = NSApplication.shared
        testRules()
        try await testGitLayer()
        try await testDialog()
        try await testBrowserAndWorktrees()
        print("SparseWorkingCopyTests: passed")
    }

    private static func testRules() {
        check(SparseWorkingCopyRules.adjustmentNeeded("") == nil, "no active rule needs no adjustment")
        check(SparseWorkingCopyRules.adjustmentNeeded("# only\n\n") == nil, "comments need no adjustment")
        check(SparseWorkingCopyRules.adjustmentNeeded(" /* \n/*\n#x") == nil, "only /* passes everything")
        check(SparseWorkingCopyRules.adjustmentNeeded("/a/\n/*") == .init(isCurrentRuleSetEmpty: false), "other rules need adjustment")
        check(SparseWorkingCopyRules.adjustedForDisabling("/a/\n\n# c\n  \nb") == "/*\n#/a/\n# c\n  \n#b", "rules commented under /*")
        check(SparseWorkingCopyCommands.isEnabled("True\n") && SparseWorkingCopyCommands.isEnabled("true")
              && !SparseWorkingCopyCommands.isEnabled("yes") && !SparseWorkingCopyCommands.isEnabled("1"), "only \"true\" enables")
        check(SparseWorkingCopyCommands.refresh.arguments == ["read-tree", "-m", "-u", "HEAD"], "refresh command")
    }

    private static func makeFixture() throws -> FileStatusFixture {
        let fixture = try FileStatusFixture.make()
        try fixture.write("a/one.txt", "1\n")
        try fixture.write("b/two.txt", "2\n")
        try fixture.write("root.txt", "r\n")
        try fixture.commitAll("base")
        return fixture
    }

    private static func exists(_ fixture: FileStatusFixture, _ path: String, in root: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (root ?? fixture.repo).appendingPathComponent(path).path)
    }

    private static func testGitLayer() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()

        await checkAsync(try await module.isSparseCheckoutEnabled() == false, "not enabled by default")
        try fixture.git(["config", "core.sparsecheckout", "yes"])
        await checkAsync(try await module.isSparseCheckoutEnabled() == false, "\"yes\" is not True for the form")
        try await module.setSparseCheckoutEnabled(true)
        check(try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "true", "local true")
        await checkAsync(try await module.isSparseCheckoutEnabled(), "enabled after set")
        let file = try await module.sparseCheckoutFileURL()
        check(file == fixture.repo.appendingPathComponent(".git/info/sparse-checkout").standardizedFileURL, "rules file \(file.path)")

        try Data("/a/\n".utf8).write(to: file)
        let result = try await module.refreshSparseWorkingCopy { _ in }
        check(result.succeeded, "read-tree succeeded")
        check(exists(fixture, "a/one.txt") && !exists(fixture, "b/two.txt") && !exists(fixture, "root.txt"), "only a/ is checked out")
        check(try fixture.git(["ls-files", "-v"]).contains("S b/two.txt"), "excluded paths are skip-worktree")

        try await module.setSparseCheckoutEnabled(false)
        check(try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false", "local false")
    }

    private static func testDialog() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let savedRun = HostingProcessDialog.run
        var processRuns = 0
        HostingProcessDialog.run = { _, _, operation in
            processRuns += 1
            return (try? await operation { _ in }) ?? false
        }
        defer { HostingProcessDialog.run = savedRun }
        let rulesFile = fixture.repo.appendingPathComponent(".git/info/sparse-checkout")


        var saved = 0
        let dialog = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: { saved += 1 }, onClose: {})
        await dialog.load()
        check(!dialog.isSparseCheckoutEnabled && dialog.editor.isHidden && !dialog.hasUnsavedChanges && dialog.rulesText == nil, "initial disabled state")
        check(dialog.isRefreshWorkingCopyOnSave, "refresh on save is on by default")
        func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
        let enable = subviews(dialog.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Sparse.Enable" }!
        NSApp.sendAction(enable.action!, to: enable.target, from: enable)
        check(dialog.isSparseCheckoutEnabled && !dialog.editor.isHidden && dialog.hasUnsavedChanges, "Enable shows the rules")


        dialog.editor.replaceAll(with: "/a/\nroot.txt")
        check(dialog.rulesText == "/a/\nroot.txt" && dialog.isRulesTextChanged, "typed rules")
        try await dialog.saveChanges(window: dialog.window!)
        check(try String(contentsOf: rulesFile, encoding: .utf8) == "/a/\nroot.txt", "rules written without a final newline")
        check(try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "true", "enabled in config")
        check(processRuns == 1 && saved == 1, "refresh ran once and the browser was notified")
        check(exists(fixture, "a/one.txt") && exists(fixture, "root.txt") && !exists(fixture, "b/two.txt"), "working copy filtered")
        check(!dialog.hasUnsavedChanges, "nothing unsaved after save")


        try Data("/a/\nroot.txt\n/b/\n".utf8).write(to: rulesFile)
        let reopened = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: {}, onClose: {})
        await reopened.load()
        check(reopened.isSparseCheckoutEnabled && reopened.editor.text == "/a/\nroot.txt\n/b/\n" && !reopened.hasUnsavedChanges, "already-sparse state")
        check(!exists(fixture, "b/two.txt"), "outdated working copy")
        try await reopened.saveChanges(window: reopened.window!)
        check(processRuns == 2 && exists(fixture, "b/two.txt"), "unchanged save refreshes the working copy")
        try Data("/a/\nroot.txt".utf8).write(to: rulesFile)
        await reopened.load()


        reopened.refreshCheckbox.state = .off
        try await reopened.saveChanges(window: reopened.window!)
        check(processRuns == 2, "no refresh when unchecked")
        reopened.refreshCheckbox.state = .on



        try await reopened.saveChanges(window: reopened.window!)
        check(!exists(fixture, "b/two.txt"), "rules applied before disabling")
        reopened.showWindow(nil)
        let disable = subviews(reopened.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Sparse.Disable" }!
        NSApp.sendAction(disable.action!, to: disable.target, from: disable)
        check(!reopened.isSparseCheckoutEnabled && reopened.editor.isHidden && reopened.hasUnsavedChanges, "Disable hides the rules")
        let save = Task { @MainActor in try await reopened.saveChanges(window: reopened.window!) }
        try await wait("disable confirmation") { reopened.window?.attachedSheet != nil }
        let alert = reopened.window!.attachedSheet!
        check(subviews(alert.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.hasPrefix("You are about to disable Git Sparse feature for this repository, with some rules still") },
              "confirmation text")
        reopened.window!.endSheet(alert, returnCode: .alertFirstButtonReturn)
        try await save.value
        check(try String(contentsOf: rulesFile, encoding: .utf8) == "/*\n#/a/\n#root.txt", "filter adjusted")
        check(try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false", "disabled in config")
        check(processRuns == 4, "the refresh ran after disabling")


        let restore = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: {}, onClose: {})
        await restore.load()
        check(!restore.isSparseCheckoutEnabled && restore.editor.isHidden && restore.editor.text == "/*\n#/a/\n#root.txt", "disabled state with the adjusted filter")
        restore.setSparseCheckoutEnabled(true)
        try await restore.saveChanges(window: restore.window!)
        check(try exists(fixture, "b/two.txt") && !fixture.git(["ls-files", "-v"]).contains("S "), "full working copy restored")
        restore.setSparseCheckoutEnabled(false)
        try await restore.saveChanges(window: restore.window!)
        check(restore.window?.attachedSheet == nil && processRuns == 6, "pass-all rules disable without confirmation")
        check(try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false", "disabled again")


        let cancelled = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: {}, onClose: {})
        await cancelled.load()
        cancelled.showWindow(nil)
        cancelled.setSparseCheckoutEnabled(true)
        check(cancelled.windowShouldClose(cancelled.window!) == false, "unsaved changes block the close for the prompt")
        try await wait("unsaved prompt") { cancelled.window?.attachedSheet != nil }
        let prompt = cancelled.window!.attachedSheet!
        check(subviews(prompt.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains("Sparse Working Copy – Cancel"), "prompt caption")
        cancelled.window!.endSheet(prompt, returnCode: .alertSecondButtonReturn)
        try await wait("closed") { cancelled.window?.isVisible == false }
        check(try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false" && processRuns == 6,
              "No discards the changes")
    }

    private static func testBrowserAndWorktrees() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let browser = RepositoryBrowserViewController(repositoryModule: GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit()))
        let window = NSWindow(contentViewController: browser)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await wait("browser loaded") { browser.repositoryIdentity != nil }
        browser.performTopLevelCommand(.sparseWorkingCopy)
        try await wait("sparse window") { browser.uiCommands.fileEditorWindows["sparse-working-copy"]?.window?.isVisible == true }
        let controller = browser.uiCommands.fileEditorWindows["sparse-working-copy"]!
        check(controller.window?.title == "Sparse Working Copy", "window title")
        browser.performTopLevelCommand(.sparseWorkingCopy)
        check(browser.uiCommands.fileEditorWindows.count == 1, "a second request focuses the dialog")
        controller.window?.performClose(nil)
        try await wait("closed") { browser.uiCommands.fileEditorWindows.isEmpty }


        let linked = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try fixture.git(["worktree", "add", "-q", linked.path, "-b", "side"])
        let linkedModule = GitRepositoryModule(repositoryURL: linked, git: FileStatusFixtureGit())
        _ = try await linkedModule.loadRepositoryState()
        let linkedFile = try await linkedModule.sparseCheckoutFileURL()
        check(linkedFile.path.hasSuffix(".git/worktrees/linked/info/sparse-checkout"), "worktree rules file \(linkedFile.path)")
        let savedRun = HostingProcessDialog.run
        HostingProcessDialog.run = { _, _, operation in (try? await operation { _ in }) ?? false }
        defer { HostingProcessDialog.run = savedRun }
        let dialog = SparseWorkingCopyWindowController(source: linkedModule, processTitle: "Process", onSaved: {}, onClose: {})
        await dialog.load()
        dialog.setSparseCheckoutEnabled(true)
        dialog.editor.replaceAll(with: "/b/")
        try await dialog.saveChanges(window: dialog.window!)
        check(FileManager.default.fileExists(atPath: linkedFile.path) && !exists(fixture, ".git/info/sparse-checkout"), "only the worktree's rules file is written")
        check(exists(fixture, "b/two.txt", in: linked) && !exists(fixture, "a/one.txt", in: linked), "linked worktree filtered")
        check(exists(fixture, "a/one.txt"), "main worktree keeps its files")


        let bare = fixture.root.appendingPathComponent("bare.git", isDirectory: true)
        try fixture.git(["clone", "-q", "--bare", fixture.repo.path, bare.path])
        let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
        _ = try await bareModule.loadRepositoryState()
        let bareFile = try await bareModule.sparseCheckoutFileURL()
        check(bareFile.resolvingSymlinksInPath() == bare.appendingPathComponent("info/sparse-checkout").resolvingSymlinksInPath(), "bare rules file")
        await checkAsync(try await bareModule.refreshSparseWorkingCopy { _ in }.succeeded == false, "read-tree fails without a work tree")
    }

    private static func wait(_ message: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { preconditionFailure("SparseWorkingCopyTests: timed out waiting for \(message())") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? condition()) == true else { preconditionFailure("SparseWorkingCopyTests: \(message)") }
    }

    private static func checkAsync(_ condition: @autoclosure () async throws -> Bool, _ message: String) async {
        guard (try? await condition()) == true else { preconditionFailure("SparseWorkingCopyTests: \(message)") }
    }
}
