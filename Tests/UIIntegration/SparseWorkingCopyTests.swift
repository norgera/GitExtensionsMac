import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Sparse working copy")
    enum SparseWorkingCopyTests {

        @Test("Rules") private static func testRules() {
            #expect(SparseWorkingCopyRules.adjustmentNeeded("") == nil, "no active rule needs no adjustment")
            #expect(SparseWorkingCopyRules.adjustmentNeeded("# only\n\n") == nil, "comments need no adjustment")
            #expect(SparseWorkingCopyRules.adjustmentNeeded(" /* \n/*\n#x") == nil, "only /* passes everything")
            #expect(SparseWorkingCopyRules.adjustmentNeeded("/a/\n/*") == .init(isCurrentRuleSetEmpty: false), "other rules need adjustment")
            #expect(SparseWorkingCopyRules.adjustedForDisabling("/a/\n\n# c\n  \nb") == "/*\n#/a/\n# c\n  \n#b", "rules commented under /*")
            #expect(
                SparseWorkingCopyCommands.isEnabled("True\n") && SparseWorkingCopyCommands.isEnabled("true")
                    && !SparseWorkingCopyCommands.isEnabled("yes") && !SparseWorkingCopyCommands.isEnabled("1"), "only \"true\" enables")
            #expect(SparseWorkingCopyCommands.refresh.arguments == ["read-tree", "-m", "-u", "HEAD"], "refresh command")
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

        @Test("Git layer") private static func testGitLayer() async throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()

            #expect(try await module.isSparseCheckoutEnabled() == false, "not enabled by default")
            try fixture.git(["config", "core.sparsecheckout", "yes"])
            #expect(try await module.isSparseCheckoutEnabled() == false, "\"yes\" is not True for the form")
            try await module.setSparseCheckoutEnabled(true)
            #expect(
                try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "true", "local true")
            #expect(try await module.isSparseCheckoutEnabled(), "enabled after set")
            let file = try await module.sparseCheckoutFileURL()
            #expect(file == fixture.repo.appendingPathComponent(".git/info/sparse-checkout").standardizedFileURL, "rules file \(file.path)")

            try Data("/a/\n".utf8).write(to: file)
            let result = try await module.refreshSparseWorkingCopy { _ in }
            #expect(result.succeeded, "read-tree succeeded")
            #expect(exists(fixture, "a/one.txt") && !exists(fixture, "b/two.txt") && !exists(fixture, "root.txt"), "only a/ is checked out")
            #expect(try fixture.git(["ls-files", "-v"]).contains("S b/two.txt"), "excluded paths are skip-worktree")

            try await module.setSparseCheckoutEnabled(false)
            #expect(
                try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false", "local false"
            )
        }

        @Test("Dialog") private static func testDialog() async throws {
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
            #expect(!dialog.isSparseCheckoutEnabled && dialog.editor.isHidden && !dialog.hasUnsavedChanges && dialog.rulesText == nil, "initial disabled state")
            #expect(dialog.isRefreshWorkingCopyOnSave, "refresh on save is on by default")
            func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
            let enable = subviews(dialog.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Sparse.Enable" }!
            NSApp.sendAction(enable.action!, to: enable.target, from: enable)
            #expect(dialog.isSparseCheckoutEnabled && !dialog.editor.isHidden && dialog.hasUnsavedChanges, "Enable shows the rules")

            dialog.editor.replaceAll(with: "/a/\nroot.txt")
            #expect(dialog.rulesText == "/a/\nroot.txt" && dialog.isRulesTextChanged, "typed rules")
            try await dialog.saveChanges(window: dialog.window!)
            #expect(try String(contentsOf: rulesFile, encoding: .utf8) == "/a/\nroot.txt", "rules written without a final newline")
            #expect(
                try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "true",
                "enabled in config")
            #expect(processRuns == 1 && saved == 1, "refresh ran once and the browser was notified")
            #expect(exists(fixture, "a/one.txt") && exists(fixture, "root.txt") && !exists(fixture, "b/two.txt"), "working copy filtered")
            #expect(!dialog.hasUnsavedChanges, "nothing unsaved after save")

            try Data("/a/\nroot.txt\n/b/\n".utf8).write(to: rulesFile)
            let reopened = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: {}, onClose: {})
            await reopened.load()
            #expect(reopened.isSparseCheckoutEnabled && reopened.editor.text == "/a/\nroot.txt\n/b/\n" && !reopened.hasUnsavedChanges, "already-sparse state")
            #expect(!exists(fixture, "b/two.txt"), "outdated working copy")
            try await reopened.saveChanges(window: reopened.window!)
            #expect(processRuns == 2 && exists(fixture, "b/two.txt"), "unchanged save refreshes the working copy")
            try Data("/a/\nroot.txt".utf8).write(to: rulesFile)
            await reopened.load()

            reopened.refreshCheckbox.state = .off
            try await reopened.saveChanges(window: reopened.window!)
            #expect(processRuns == 2, "no refresh when unchecked")
            reopened.refreshCheckbox.state = .on

            try await reopened.saveChanges(window: reopened.window!)
            #expect(!exists(fixture, "b/two.txt"), "rules applied before disabling")
            reopened.showWindow(nil)
            let disable = subviews(reopened.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Sparse.Disable" }!
            NSApp.sendAction(disable.action!, to: disable.target, from: disable)
            #expect(!reopened.isSparseCheckoutEnabled && reopened.editor.isHidden && reopened.hasUnsavedChanges, "Disable hides the rules")
            let save = Task { @MainActor in try await reopened.saveChanges(window: reopened.window!) }
            try await wait("disable confirmation") { reopened.window?.attachedSheet != nil }
            let alert = reopened.window!.attachedSheet!
            #expect(
                subviews(alert.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains {
                    $0.hasPrefix("You are about to disable Git Sparse feature for this repository, with some rules still")
                },
                "confirmation text")
            reopened.window!.endSheet(alert, returnCode: .alertFirstButtonReturn)
            try await save.value
            #expect(try String(contentsOf: rulesFile, encoding: .utf8) == "/*\n#/a/\n#root.txt", "filter adjusted")
            #expect(
                try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false",
                "disabled in config")
            #expect(processRuns == 4, "the refresh ran after disabling")

            let restore = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: {}, onClose: {})
            await restore.load()
            #expect(
                !restore.isSparseCheckoutEnabled && restore.editor.isHidden && restore.editor.text == "/*\n#/a/\n#root.txt",
                "disabled state with the adjusted filter")
            restore.setSparseCheckoutEnabled(true)
            try await restore.saveChanges(window: restore.window!)
            #expect(try exists(fixture, "b/two.txt") && !fixture.git(["ls-files", "-v"]).contains("S "), "full working copy restored")
            restore.setSparseCheckoutEnabled(false)
            try await restore.saveChanges(window: restore.window!)
            #expect(restore.window?.attachedSheet == nil && processRuns == 6, "pass-all rules disable without confirmation")
            #expect(
                try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false",
                "disabled again")

            let cancelled = SparseWorkingCopyWindowController(source: module, processTitle: "Process", onSaved: {}, onClose: {})
            await cancelled.load()
            cancelled.showWindow(nil)
            cancelled.setSparseCheckoutEnabled(true)
            #expect(cancelled.windowShouldClose(cancelled.window!) == false, "unsaved changes block the close for the prompt")
            try await wait("unsaved prompt") { cancelled.window?.attachedSheet != nil }
            let prompt = cancelled.window!.attachedSheet!
            do {
                let actual = subviews(prompt.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains("Sparse Working Copy – Cancel")
                #expect(actual, "prompt caption")
            }
            cancelled.window!.endSheet(prompt, returnCode: .alertSecondButtonReturn)
            try await wait("closed") { cancelled.window?.isVisible == false }
            #expect(
                try fixture.git(["config", "--local", "--get", "core.sparsecheckout"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false"
                    && processRuns == 6,
                "No discards the changes")
        }

        @Test("Browser and worktrees") private static func testBrowserAndWorktrees() async throws {
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
            #expect(controller.window?.title == "Sparse Working Copy", "window title")
            browser.performTopLevelCommand(.sparseWorkingCopy)
            #expect(browser.uiCommands.fileEditorWindows.count == 1, "a second request focuses the dialog")
            controller.window?.performClose(nil)
            try await wait("closed") { browser.uiCommands.fileEditorWindows.isEmpty }

            let linked = fixture.root.appendingPathComponent("linked", isDirectory: true)
            try fixture.git(["worktree", "add", "-q", linked.path, "-b", "side"])
            let linkedModule = GitRepositoryModule(repositoryURL: linked, git: FileStatusFixtureGit())
            _ = try await linkedModule.loadRepositoryState()
            let linkedFile = try await linkedModule.sparseCheckoutFileURL()
            #expect(linkedFile.path.hasSuffix(".git/worktrees/linked/info/sparse-checkout"), "worktree rules file \(linkedFile.path)")
            let savedRun = HostingProcessDialog.run
            HostingProcessDialog.run = { _, _, operation in (try? await operation { _ in }) ?? false }
            defer { HostingProcessDialog.run = savedRun }
            let dialog = SparseWorkingCopyWindowController(source: linkedModule, processTitle: "Process", onSaved: {}, onClose: {})
            await dialog.load()
            dialog.setSparseCheckoutEnabled(true)
            dialog.editor.replaceAll(with: "/b/")
            try await dialog.saveChanges(window: dialog.window!)
            #expect(
                FileManager.default.fileExists(atPath: linkedFile.path) && !exists(fixture, ".git/info/sparse-checkout"),
                "only the worktree's rules file is written")
            #expect(exists(fixture, "b/two.txt", in: linked) && !exists(fixture, "a/one.txt", in: linked), "linked worktree filtered")
            #expect(exists(fixture, "a/one.txt"), "main worktree keeps its files")

            let bare = fixture.root.appendingPathComponent("bare.git", isDirectory: true)
            try fixture.git(["clone", "-q", "--bare", fixture.repo.path, bare.path])
            let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
            _ = try await bareModule.loadRepositoryState()
            let bareFile = try await bareModule.sparseCheckoutFileURL()
            #expect(bareFile.resolvingSymlinksInPath() == bare.appendingPathComponent("info/sparse-checkout").resolvingSymlinksInPath(), "bare rules file")
            #expect(try await bareModule.refreshSparseWorkingCopy { _ in }.succeeded == false, "read-tree fails without a work tree")
        }

        private static func wait(_ message: @autoclosure () -> String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw TestFailure(description: "SparseWorkingCopyTests: timed out waiting for \(message())") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

    }
}

typealias SparseWorkingCopyTests = UIIntegrationTests.SparseWorkingCopyTests
