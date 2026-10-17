import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Command line")
    enum CommandLineTests {
        static func request(_ args: [String], directory: URL = URL(fileURLWithPath: "/tmp")) throws -> CommandLineRequest {
            try CommandLineRequest.parse(["GitExtensionsMac"] + args, currentDirectory: directory)!
        }
        @Test("Parsing") static func parsing() throws {
            #expect(try CommandLineRequest.parse(["app"]) == nil, "no arguments preserve normal startup")
            #expect(try CommandLineRequest.parse(["app", "--dashboard"]) == nil, "dashboard compatibility")
            #expect(
                try CommandLineRequest.parse(["app", "-NSDocumentRevisionsDebugMode", "YES"]) == nil,
                "Xcode Run argument-domain defaults preserve normal startup")
            #expect(
                try CommandLineRequest.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES", "-psn_0_12345"]) == nil,
                "Cocoa argument-domain pairs and process serial number are not commands")
            #expect(try request(["-NSDocumentRevisionsDebugMode", "YES", "browse", "/tmp"]).verb == .browse, "explicit command after argument-domain defaults")
            #expect(
                try request(["-h"]).verb == .help && (try request(["browse", "-commit=abc"])).verb == .browse,
                "single-dash help and upstream -option= forms preserved")
            let needsFile: Set<CommandLineRequest.Verb> = [.blame, .blamehistory, .filehistory, .fileeditor, .difftool, .revert]
            for verb in CommandLineRequest.Verb.allCases {
                let parsed = try request([verb.rawValue] + (needsFile.contains(verb) ? ["a.txt"] : []))
                #expect(parsed.verb == verb, "verb \(verb)")
                #expect(CommandLineSession.usage.contains(verb.rawValue), "help documents \(verb)")
            }
            let pinned = """
                [path]
                browse [path] [-filter=] [--pathFilter=<filepath>] [-commit=<selectedSha>[,<firstSha>]]
                about
                add [filename]
                addfiles [filename]
                apply [filename]
                applypatch [filename]
                blame filename
                branch
                checkout
                checkoutbranch
                checkoutrevision
                cherry
                cleanup
                clone [path]
                commit [--quiet] [--message commitmessage]
                difftool filename
                filehistory filename
                fileeditor filename
                formatpatch
                gitignore
                help (shows this dialog)
                init [path]
                merge [--branch name]
                mergeconflicts [--quiet]
                mergetool [--quiet]
                openrepo [path] [-filter=]
                pull [--rebase] [--merge] [--fetch] [--quiet] [--remotebranch name]
                push [--quiet]
                rebase [--branch name]
                remotes
                reset
                revert filename
                searchfile
                settings
                stash
                synchronize [--rebase] [--merge] [--fetch] [--quiet]
                tag
                viewdiff
                viewpatch [filename]
                """
            let upstreamLines = CommandLineSession.usage.split(separator: "\n").map(String.init).filter {
                !["blamehistory filename", "uninstall"].contains($0)
            }
            #expect(upstreamLines == pinned.split(separator: "\n").map(String.init), "pinned FormCommandlineHelp resource verbs, order and argument wording")
            let help = CommandLineHelpWindow()
            defer { help.close() }
            let text = descendants(help.window!.contentView!).compactMap { $0 as? NSTextView }.first!
            #expect(
                text.string == CommandLineSession.header + "\n\n" + CommandLineSession.usage && !text.isEditable,
                "help presents the shared source usage text read-only")
            #expect(text.font == AppSettingsStore.shared.applicationFont(size: 12), "help uses the application proportional font")
            #expect(
                help.window!.contentRect(forFrameRect: help.window!.frame).size == NSSize(width: 394, height: 662)
                    && help.window!.minSize == NSSize(width: 410, height: 700), "source command-line help dimensions and minimum")
            let captions: [CommandLineRequest.Verb: (String, String)] = [
                .blame: ("Cannot open blame, there is no file selected.", "Blame"),
                .difftool: ("Cannot open difftool, there is no file selected.", "Difftool"),
                .blamehistory: ("Cannot open blame / file history, there is no file selected.", "Blame / file history"),
                .filehistory: ("Cannot open blame / file history, there is no file selected.", "Blame / file history"),
                .fileeditor: ("Cannot open file editor, there is no file selected.", "File editor"),
                .revert: ("Cannot open revert, there is no file selected.", "Revert"),
            ]
            for verb in needsFile {
                do {
                    _ = try request([verb.rawValue])
                    Issue.record("missing file accepted \(verb)")
                } catch let error as CLIError {
                    #expect(error == .message(captions[verb]!.0, caption: captions[verb]!.1), "upstream message box for \(verb): \(error)")
                }
            }
            #expect(try request(["reset"]).verb == .reset, "reset needs no file")
            do {
                _ = try request(["filehistory", "a", "HEAD"])
                Issue.record("named revision accepted")
            } catch let error as CLIError { #expect(error.caption == nil, "invalid history revision fails without a dialog") }
            do {
                _ = try request(["commit", "--quiet", "--quiet"])
                Issue.record("duplicate accepted")
            } catch let error as CLIError {
                #expect(error.caption == "Invalid Git Extensions command line", "argument exceptions report as invalid command line")
            }
            #expect(
                CLIError.notValidRepository == .message("The current directory is not a valid git repository.", caption: "Error"),
                "not a valid repository message")
            #expect(
                try request(["browse"]).opensDashboardWithoutRepository && request(["openrepo"]).opensDashboardWithoutRepository
                    && !request(["commit"]).opensDashboardWithoutRepository, "browse without a repository opens the Dashboard")
            let object = testObjectID("cli")
            let legacy = try request([
                "--repository", "/tmp/repo", "--select-revision", object.string, "--select-revision", "INDEX", "--file-history-path", "file ü.txt",
            ])
            #expect(
                legacy.repository?.path == "/tmp/repo" && legacy.selection == [.object(object), .index] && legacy.fileHistory?.path == "file ü.txt",
                "legacy repeated selections")
            let browse = try request(["browse", "/tmp/repo", "-filter=subject", "--pathFilter=space ü.txt", "-commit=HEAD,HEAD~1,ignored"])
            #expect(
                browse.commitArgument == "HEAD,HEAD~1,ignored" && browse.revisionFilter == "subject" && browse.pathFilter == "space ü.txt",
                "browse equals flags keep the raw commit argument")
            #expect(try request(["browse", "-commit="]).commitArgument == nil, "empty -commit opens without a selection")
            let pull = try request(["pull", "--merge", "--rebase", "--fetch", "--autostash", "--quiet", "--remotebranch", "topic"])
            #expect(pull.has("quiet") && pull.has("fetch") && pull.value("remotebranch") == "topic", "presence/value option semantics")
            #expect(try request(["commit", "--message", "first\n\nbody"]).value("message") == "first\n\nbody", "message preserves bytes")
            for args in [["commit", "--quiet", "--quiet"], ["--repository"], ["filehistory", "a", "HEAD"], ["blamehistory", "a", object.string, "wrong"]] {
                do {
                    _ = try request(args)
                    Issue.record("invalid arguments accepted \(args)")
                } catch {}
            }
            let history = try request(["blamehistory", "a.txt", object.string, "--filter-by-revision"])
            #expect(history.has("filter-by-revision") && history.arguments[1] == object.string, "typed history selector")
            for url in ["git://example/repo", "https://example/repo", "github-mac://openRepo/https://example/ü", "github-windows://openRepo/https://example/ü"]
            {
                let parsed = try request([url])
                #expect(parsed.verb == .clone && parsed.arguments[0].contains("://"), "protocol clone")
            }
            #expect(try request(["unknown"]).verb == .help && request(["--help"]).verb == .help, "unknown upstream help")
            #expect(try request(["revert", "a"]).verb == .revert, "revert is file changes")
            #expect(try request(["mergeconflicts", "--quiet"]).succeedsOnClose, "resolver dispatch result")
            #expect(try !request(["tag"]).succeedsOnClose && request(["commit"]).succeedsOnClose, "verb-specific cancellation results")
            #expect(try request(["blame", "a"]).path("dir/a").path == "/tmp/dir/a", "working directory paths")
            #expect(try request(["blame", "a"]).relativeFile("/repo/a", root: URL(fileURLWithPath: "/repo")) == "a", "absolute filename normalization")
            #expect(
                try CommandLineRepository.addFiles("\"space ü.txt\" dir", force: true, dryRun: true).arguments == [
                    "add", "--dry-run", "-f", "space ü.txt", "dir",
                ], "upstream add ordering")
            #expect(try !CommandLineRepository.addFiles(".", force: false, dryRun: true).changesRepositoryState, "preview metadata")
        }
        @Test("Repository") static func repository() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("dir/space ü.txt", "one\n")
            try fixture.commitAll("base")
            let nested = fixture.repo.appendingPathComponent("dir")
            #expect(
                CommandLineRepository.discover(candidate: nested.appendingPathComponent("space ü.txt"), currentDirectory: URL(fileURLWithPath: "/"))
                    == fixture.repo, "file ancestor discovery")
            #expect(CommandLineRepository.discover(candidate: URL(fileURLWithPath: "/missing/cli"), currentDirectory: nested) == fixture.repo, "cwd fallback")
            #expect(CommandLineRepository.discover(candidate: nil, currentDirectory: URL(fileURLWithPath: "/")) == nil, "no repository")
            let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            #expect(CommandLineRepository.discover(candidate: nil, currentDirectory: outside) == nil, "discovery stops at the filesystem root")
            let pathFile = fixture.root.appendingPathComponent("repository-path.txt")
            try (" \n" + fixture.repo.path + "\nignored\n").write(to: pathFile, atomically: true, encoding: .utf8)
            #expect(try CommandLineRepository.repositoryPathFile(pathFile) == fixture.repo, "openrepo first trimmed line")
            #expect(try request(["openrepo", pathFile.path], directory: nested).repositoryLocation() == fixture.repo, "openrepo dispatch location")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            try fixture.write("dir/space ü.txt", "two\n")
            let preview = try await module.addFiles(filter: "\"dir/space ü.txt\"", force: false, dryRun: true, output: { _ in })
            let before = try fixture.git(["diff", "--cached", "--name-only"])
            #expect(preview.command.succeeded && !preview.changed && before.isEmpty, "preview preserves real index")
            let add = try await module.addFiles(filter: "\"dir/space ü.txt\"", force: false, dryRun: false, output: { _ in })
            let index = try fixture.git(["show", ":dir/space ü.txt"])
            #expect(add.command.succeeded && add.changed && index == "two\n", "actual stage exact bytes")
            let noop = try await module.addFiles(filter: ".", force: false, dryRun: false, output: { _ in })
            #expect(!noop.changed, "no-op add does not request refresh")
            try fixture.write(".gitignore", "ignored\n")
            try fixture.write("ignored", "hidden\n")
            let failed = try await module.addFiles(filter: "ignored", force: false, dryRun: false, output: { _ in })
            #expect(!failed.command.succeeded && !failed.changed, "ignored add fails without mutation")
            let forced = try await module.addFiles(filter: "ignored", force: true, dryRun: false, output: { _ in })
            let ignored = try fixture.git(["show", ":ignored"])
            #expect(forced.changed && ignored == "hidden\n", "force add ignored file")
            let head = try fixture.head()
            let git = FileStatusFixtureGit()
            #expect(await CommandLineRepository.resolvePartialCommitID(head.shortString, git: git, in: fixture.repo) == head, "partial object id")
            #expect(await CommandLineRepository.resolvePartialCommitID("HEAD", git: git, in: fixture.repo) == nil, "refs are not object id prefixes")
            #expect(await CommandLineRepository.resolvePartialCommitID("no-such-revision", git: git, in: fixture.repo) == nil, "stale selector rejected")
            let unknown = String(repeating: "e", count: 40)
            #expect(
                await CommandLineRepository.resolvePartialCommitID(unknown, git: git, in: fixture.repo)?.string == unknown,
                "a full hash is accepted without Git")
            let pair = await CommandLineRepository.commitSelection("\(head.shortString),\(head.string),\(unknown.prefix(7))", git: git, in: fixture.repo)
            #expect(pair?.selected == head && pair?.first == head, "selected and first; further parts ignored")
            #expect(
                await CommandLineRepository.commitSelection("\(head.shortString),HEAD", git: git, in: fixture.repo) == nil,
                "any unresolved part fails the selection")
            try await uninstall(fixture)
            let bare = fixture.root.appendingPathComponent("bare.git")
            try fixture.git(["clone", "--bare", fixture.repo.path, bare.path])
            #expect(CommandLineRepository.discover(candidate: bare, currentDirectory: nested)?.path == bare.path, "bare discovery")
            let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
            _ = try await bareModule.loadRepositoryState()
            do {
                _ = try await bareModule.addFiles(filter: ".", force: false, dryRun: false, output: { _ in })
                Issue.record("bare stage accepted")
            } catch RepositoryMutationError.bareRepository {}
        }
        struct GlobalRunner: GitCommandRunning {
            let config: URL
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                try await GitProcess().run(
                    arguments: arguments, in: directory, standardInput: standardInput,
                    environment: environment.merging(
                        ["GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"], uniquingKeysWith: { _, fixture in fixture }))
            }
        }
        static func uninstall(_ fixture: FileStatusFixture) async throws {
            let runner = GlobalRunner(config: fixture.root.appendingPathComponent("global.gitconfig"))
            let command = GitCommand(arguments: ["config", "--global", "core.editor", "other-editor"], accessesRemote: false, changesRepositoryState: true)
            _ = try await runner.run(command, in: fixture.repo)
            try await CommandLineRepository.removeOwnEditor(applicationPath: "/Applications/GitExtensionsMac.app", git: runner, directory: fixture.repo)
            let read = GitCommand(arguments: ["config", "--global", "--get", "core.editor"], accessesRemote: false, changesRepositoryState: false)
            let other = try await runner.run(read, in: fixture.repo)
            #expect(other.standardOutputString.trimmingCharacters(in: .newlines) == "other-editor", "uninstall preserves unrelated editor")
            _ = try await runner.run(
                .init(
                    arguments: ["config", "--global", "core.editor", "/Applications/GitExtensionsMac.app/Contents/MacOS/GitExtensionsMac fileeditor"],
                    accessesRemote: false, changesRepositoryState: true), in: fixture.repo)
            try await CommandLineRepository.removeOwnEditor(applicationPath: "/Applications/GitExtensionsMac.app", git: runner, directory: fixture.repo)
            let removed = try await runner.run(read, in: fixture.repo)
            #expect(removed.exitStatus == 1, "uninstall removes only own global editor")
        }
        static func wait(_ label: String, until predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate() {
                guard ContinuousClock.now < deadline else { throw CLIError.invalid("Test timed out: " + label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        static func close(_ window: NSWindow) {
            let buttons =
                window.contentView.map { descendants($0).compactMap { $0 as? NSButton }.filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor } } ?? []
            if let button = ["Cancel", "Close", "Abort"].lazy.compactMap({ title in buttons.first { $0.title == title } }).first,
                let action = button.action
            {
                NSApp.sendAction(action, to: button.target, from: button)
            } else if window.sheetParent != nil {
                (window.contentViewController as NSResponder? ?? window).cancelOperation(nil)
            } else {
                window.performClose(nil)
            }
        }
        @Test("Presentations") static func presentations() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.txt", "base\n")
            try fixture.commitAll("base")
            let store = AppSettingsStore.shared
            let savedPull = store.pullPreferences
            let savedGrid = store.revisionGridPreferences
            let savedRuntime = store.revisionGridRuntime
            defer {
                store.savePullPreferences(savedPull)
                store.saveRevisionGridPreferences(savedGrid)
                store.revisionGridRuntime = savedRuntime
            }
            var pullPreferences = savedPull
            pullPreferences.formAction = .merge
            store.savePullPreferences(pullPreferences)
            var preferences = savedGrid
            preferences.useBrowseForFileHistory = false
            store.saveRevisionGridPreferences(preferences)
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let browser = RepositoryBrowserViewController(repositoryModule: module, loadsRevisionHistory: false)
            let owner = NSWindow(contentViewController: browser)
            owner.isReleasedWhenClosed = false
            owner.setContentSize(NSSize(width: 1100, height: 800))
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            try await wait("state") { browser.repositoryIdentity != nil }
            browser.prepareCommandLineRevision(try await module.loadBlameRevision(nil))
            for args in [["commit", "--quiet"], ["mergetool", "--quiet"]] {
                if case .completed(let succeeded) = try await browser.uiCommands.runCommandLine(request(args, directory: fixture.repo)) {
                    #expect(succeeded, "quiet no-op upstream success")
                } else {
                    Issue.record("quiet opened dialog")
                }
            }
            let commands: [([String], String)] = [
                (["addfiles", "a.txt"], "Add files"), (["blame", "a.txt", "1"], "Blame"),
                (["filehistory", "a.txt"], "File history"), (["blamehistory", "a.txt"], "File history"),
                (["commit", "--message", "CLI message"], "Commit"), (["remotes"], "Remote"),
                (["pull", "--remotebranch", "unfetched-topic"], "Pull"), (["push"], "Push"),
                (["branch"], "Create branch"), (["checkoutbranch"], "Checkout"), (["checkoutrevision"], "Checkout"),
                (["tag"], "Create tag"), (["cherry"], "Cherry"), (["viewdiff"], "Compare"),
                (["formatpatch"], "Format"), (["applypatch"], "Apply"), (["cleanup"], "Clean"), (["fileeditor", "a.txt"], "a.txt"),
            ]
            for (arguments, title) in commands {
                print("CommandLineTests: \(arguments.joined(separator: " "))")
                fflush(stdout)
                let before = NSHashTable<NSWindow>.weakObjects()
                for window in NSApp.windows { before.add(window) }
                let baselineWindows = NSApp.windows.map { "\(ObjectIdentifier($0)) \($0.title) visible=\($0.isVisible)" }
                let parsed = try request(arguments, directory: fixture.repo)
                let monitor = CommandLinePresentation(owner: owner, notifier: browser.uiCommands.repositoryChangedNotifier)
                monitor.successfulRead = parsed.succeedsOnClose
                defer { monitor.finish() }
                let task = Task {
                    switch try await browser.uiCommands.runCommandLine(parsed) {
                    case .completed(let succeeded): return succeeded
                    case .presentation: return try await monitor.wait()
                    }
                }
                do {
                    try await wait("\(arguments) window") {
                        NSApp.windows.contains { candidate in !before.allObjects.contains(where: { $0 === candidate }) && candidate.isVisible }
                            || owner.attachedSheet != nil
                    }
                } catch {
                    print("CommandLineTests baseline: \(baselineWindows)")
                    print(
                        "CommandLineTests current: \(NSApp.windows.map { candidate in "\(ObjectIdentifier(candidate)) \(candidate.title) visible=\(candidate.isVisible) baseline=\(before.allObjects.contains { $0 === candidate })" })"
                    )
                    print("CommandLineTests monitor: presented=\(monitor.presented) mutated=\(monitor.mutated)")
                    throw error
                }
                let window =
                    owner.attachedSheet ?? NSApp.windows.first { candidate in !before.allObjects.contains(where: { $0 === candidate }) && candidate.isVisible }!
                let caption =
                    window.title.isEmpty
                    ? (descendants(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.first { !$0.isEmpty } ?? "")
                    : window.title
                #expect(
                    caption.localizedCaseInsensitiveContains(arguments[0] == "viewdiff" ? "Diff" : title)
                        || arguments[0] == "pull" && window.title.hasPrefix("Fetch"), "\(arguments) dispatched \(caption)")
                if arguments[0] == "commit" {
                    #expect(descendants(window.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string == "CLI message" }, "message prefill")
                }
                if arguments[0] == "pull" {
                    try await wait("pull initial branch") {
                        descendants(window.contentView!).compactMap { $0 as? NSComboBox }.contains { $0.stringValue == "unfetched-topic" }
                    }
                }
                close(window)
                let result = try await task.value
                #expect(result == (parsed.succeedsOnClose || parsed.verb == .fileeditor), "\(arguments) cancellation result \(result)")
                if arguments[0] == "filehistory" || arguments[0] == "blamehistory" { try await Task.sleep(for: .milliseconds(80)) }
            }
            let before = try fixture.head()
            let task = Task { try await browser.uiCommands.runCommandLine(request(["rebase", "--branch", "HEAD~1"], directory: fixture.repo)) }
            try await wait("rebase sheet") { owner.attachedSheet?.title == "Rebase" }
            let sheet = owner.attachedSheet!
            try await Task.sleep(for: .milliseconds(300))
            let after = try fixture.head()
            #expect(
                before == after && descendants(sheet.contentView!).compactMap { $0 as? NSComboBox }.contains { $0.stringValue == "HEAD~1" },
                "rebase prefill does not execute")
            close(sheet)
            if case .completed(let succeeded) = try await task.value {
                #expect(succeeded, "rebase close upstream result")
            } else {
                Issue.record("rebase completion")
            }
            let search = Task { try await browser.uiCommands.runCommandLine(request(["searchfile"], directory: fixture.repo)) }
            try await wait("search window") { NSApp.windows.contains { $0.title == "Find file" && $0.isVisible } }
            let panel = NSApp.windows.first { $0.title == "Find file" && $0.isVisible }!
            #expect(panel.sheetParent == nil && owner.attachedSheet == nil && !owner.isVisible, "searchfile shows only the search window")
            panel.performClose(nil)
            if case .completed(let succeeded) = try await search.value {
                #expect(!succeeded && !panel.isVisible, "searchfile cancel result")
            } else {
                Issue.record("searchfile completion")
            }
            owner.makeKeyAndOrderFront(nil)
        }
        @Test("Startup") static func startup() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.txt", "a\n")
            try fixture.commitAll("first")
            let first = try fixture.head()
            try fixture.write("a.txt", "b\n")
            try fixture.commitAll("second")
            let head = try fixture.head()
            let request = try self.request(
                ["browse", "-commit=\(first.shortString),\(head.shortString)", "--repository", fixture.repo.path], directory: fixture.root)
            let store = AppSettingsStore.shared
            let savedRuntime = store.revisionGridRuntime
            let savedGrid = store.revisionGridPreferences
            defer {
                store.revisionGridRuntime = savedRuntime
                store.saveRevisionGridPreferences(savedGrid)
            }
            let host = ApplicationHostViewController(launch: .commandLine(request))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.viewDidAppear()
            try await wait("CLI browse selection") { (host.activeController as? RepositoryBrowserViewController)?.selectedCommitID == .object(first) }
            let browser = host.activeController as! RepositoryBrowserViewController
            #expect(browser.repositoryIdentity?.currentRepository.path == fixture.repo.path, "CLI startup opens requested repository")
            #expect(browser.revisions.contains { $0.objectID == head }, "existing RevisionReader history")

            let empty = fixture.root.appendingPathComponent("not-a-repository", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            var presented: [(String, String)] = []
            let savedPresent = CommandLineSession.present
            let savedStatus = CommandLineSession.exitStatus
            CommandLineSession.present = { presented.append(($0, $1)) }
            defer {
                CommandLineSession.present = savedPresent
                CommandLineSession.exitStatus = savedStatus
            }
            CommandLineSession.exitStatus = 0
            let dashboardHost = ApplicationHostViewController(launch: .commandLine(try self.request(["browse"], directory: empty)))
            let dashboardWindow = NSWindow(contentViewController: dashboardHost)
            dashboardWindow.isReleasedWhenClosed = false
            dashboardWindow.makeKeyAndOrderFront(nil)
            defer { dashboardWindow.close() }
            dashboardHost.viewDidAppear()
            try await Task.sleep(for: .milliseconds(500))
            #expect(
                dashboardHost.activeController is DashboardViewController && presented.isEmpty && CommandLineSession.exitStatus == 0,
                "browse without a repository opens the Dashboard")
            let failingHost = ApplicationHostViewController(launch: .commandLine(try self.request(["commit"], directory: empty)))
            let failingWindow = NSWindow(contentViewController: failingHost)
            failingWindow.isReleasedWhenClosed = false
            failingWindow.makeKeyAndOrderFront(nil)
            defer { failingWindow.close() }
            failingHost.viewDidAppear()
            try await wait("not a repository message") { !presented.isEmpty }
            #expect(
                presented.first! == ("The current directory is not a valid git repository.", "Error") && CommandLineSession.exitStatus == -1,
                "repository verbs report an invalid working directory")
        }

        @Test("Standalone editor startup") static func standaloneEditorStartup() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.txt", "base\n")
            try fixture.commitAll("base")
            _ = try fixture.git(["config", "core.commentChar", "$"])
            try fixture.write(".git/COMMIT_EDITMSG", "subject\n\n$ repository comment\n")
            let savedStatus = CommandLineSession.exitStatus
            defer { CommandLineSession.exitStatus = savedStatus }
            let host = ApplicationHostViewController(launch: .dashboard)
            let owner = NSWindow(contentViewController: host)
            owner.isReleasedWhenClosed = false
            owner.setContentSize(NSSize(width: 1000, height: 700))
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            host.viewDidAppear()
            let request = try self.request(["fileeditor", ".git/COMMIT_EDITMSG"], directory: fixture.repo)
            let operation = Task { await host.runCommandLine(request) }
            try await wait("standalone repository-aware file editor") { NSApp.windows.contains { $0.title == ".git/COMMIT_EDITMSG" && $0.isVisible } }
            let window = NSApp.windows.first { $0.title == ".git/COMMIT_EDITMSG" && $0.isVisible }!
            let controller = window.windowController as! FileEditorWindowController
            #expect(host.activeController is DashboardViewController, "fileeditor resolves repository settings without constructing Browse")
            #expect(
                controller.editor.commentSetting == "$" && controller.editor.syntaxPath?.hasSuffix("COMMIT_EDITMSG") == true,
                "standalone editor retains actual repository comment configuration: \(controller.editor.commentSetting), \((try? request.repositoryLocation())?.path ?? "none")"
            )
            #expect(
                !controller.hasChanges && controller.editor.viewerToolbar?.isHidden == false, "standalone fileeditor starts clean with shared viewer controls")
            window.performClose(nil)
            await operation.value
            #expect(CommandLineSession.exitStatus == 0, "standalone editor close completes CLI successfully")
            #expect(
                try String(contentsOf: fixture.repo.appendingPathComponent(".git/COMMIT_EDITMSG"), encoding: .utf8) == "subject\n\n$ repository comment\n",
                "standalone editor presentation leaves file bytes unchanged")
        }
    }
}

typealias CommandLineTests = UIIntegrationTests.CommandLineTests
