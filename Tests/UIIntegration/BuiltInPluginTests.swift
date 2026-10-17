import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Built in plugin")
    enum BuiltInPluginTests {
        @Test("Models") static func models() throws {
            let plugins = BuiltInPlugins.make()
            #expect(plugins.count == 10 && Set(plugins.map(\.identifier)).count == 10, "ten distinct pinned identities")
            #expect(plugins.filter { !$0.requiresRepository }.map(\.name) == ["Proxy Switcher"], "repository eligibility")
            for plugin in plugins { #expect(type(of: plugin).init().identifier == plugin.identifier, "child repository plugin identity") }
            let threshold = BuiltInPluginKind.largeFiles.settings[0]
            try threshold.validate("0.5")
            for invalid in ["NaN", "infinity", "-1", "text"] {
                do {
                    try threshold.validate(invalid)
                    Issue.record("invalid threshold accepted")
                } catch {}
            }
            let command = BuiltInPluginCommands.backgroundFetch(" fetch  --all ")
            #expect(command.arguments == ["fetch", "--all"] && command.accessesRemote && command.changesRepositoryState, "fetch metadata")
            #expect(
                BuiltInPluginCommands.backgroundFetch("", submodules: true).arguments == ["submodule", "foreach", "--recursive", "git", "fetch", "--all"],
                "submodule fetch")
            let empty = GitCommandResult(arguments: command.arguments, standardOutput: Data(), standardError: Data(), exitStatus: 0)
            let fetched = GitCommandResult(arguments: command.arguments, standardOutput: Data(), standardError: Data("From local\n".utf8), exitStatus: 0)
            #expect(
                !BuiltInPluginCommands.shouldRefreshAfterFetch(command, result: empty)
                    && BuiltInPluginCommands.shouldRefreshAfterFetch(command, result: fetched), "refresh only changed fetch")
            #expect(
                BuiltInPluginCommands.shouldRefreshAfterFetch(BuiltInPluginCommands.backgroundFetch("status"), result: empty), "non-fetch upstream refresh rule"
            )
            let names = try BuiltInPluginCommands.branchCandidates(
                "  feature/x\n* main\n+ linked\n  HEAD\n* (HEAD detached at abc)\n  +valid\n", current: "main", base: "HEAD", remote: nil, pattern: nil,
                ignoreCase: false, invert: false)
            #expect(names == ["feature/x", "linked", "+valid"], "upstream markers")
            let remote = try BuiltInPluginCommands.branchCandidates(
                "  origin/HEAD -> origin/main\n  origin/feature/x\n  other/y\n", current: "main", base: "HEAD", remote: "origin", pattern: "FEATURE",
                ignoreCase: true, invert: false)
            #expect(remote == ["origin/feature/x"], "remote and regex filters")
            do {
                _ = try BuiltInPluginCommands.branchCandidates("  x\n", current: "", base: "HEAD", remote: nil, pattern: "[", ignoreCase: false, invert: false)
                Issue.record("invalid regex")
            } catch {}
            #expect(
                BuiltInPluginCommands.deleteBranch("origin/topic", remote: "origin", unmerged: false).arguments == ["push", "origin", ":topic"],
                "upstream remote deletion")
            let notes = BuiltInPluginCommands.parseReleaseNotes("0824e@Subject@with at\n\nbody\n1234@Next\n")
            #expect(notes.count == 2 && notes[0].message == ["Subject@with at", "", "body"], "release continuation lines")
            let log = try BuiltInPluginCommands.releaseNotes(from: "v1", to: "HEAD", arguments: BuiltInPluginCommands.releaseArguments)
            #expect(log.arguments == ["log", "--pretty=format:%h@%s%b", "--abbrev-commit", "v1..HEAD"], "release argument order")
            do {
                _ = try BuiltInPluginCommands.releaseNotes(from: "", to: "HEAD", arguments: "{0}..{1}")
                Issue.record("missing From")
            } catch {}
            let rewrite = BuiltInPluginCommands.rewriteRemoving("dir/space ü's.txt")
            #expect(
                rewrite.arguments == [
                    "filter-branch", "--index-filter", "git rm -r -f --cached --ignore-unmatch 'dir/space ü'\\''s.txt'", "--prune-empty", "--", "--all",
                ], "history rewrite and shell quoting")
            let proxy = BuiltInPluginCommands.proxy(host: "proxy.test", port: "8080", username: "u", password: "not-real", global: true, remove: false)
            #expect(proxy.arguments == ["config", "--global", "http.proxy", "u:not-real@proxy.test:8080"], "proxy arguments")
            #expect(!CommandLog.redacted(proxy.arguments).joined().contains("not-real"), "proxy secret redaction")
            #expect(BuiltInPluginDialog.obscuredProxy("u:not-real@proxy.test") == "u:****@proxy.test", "proxy presentation")
            let count = CodeLineCounter.analyze("// comment\r\n\r\ncode\r\n/* start\r\nend */\r\n", path: "a.cs")
            #expect(count.total == 5 && count.blank == 1 && count.comments == 3 && count.code == 1, "code classification and CRLF")
            let designer = CodeLineCounter.analyze("a\nb\n", path: "a.Designer.cs")
            #expect(designer.designer == 2 && designer.code == 0, "designer category")
            let test = CodeLineCounter.analyze("[Test]\na\n", path: "test.cs")
            #expect(test.test == 2, "test attribute")
        }

        struct Runner: GitCommandRunning {
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                try await GitProcess().run(
                    arguments: arguments, in: directory, standardInput: standardInput,
                    environment: environment.merging(
                        ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "FILTER_BRANCH_SQUELCH_WARNING": "1"],
                        uniquingKeysWith: { _, fixture in fixture }))
            }
        }
        struct CancelAfterBranchRunner: GitCommandRunning {
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                let result = try await Runner().run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
                if arguments.starts(with: ["branch", "--track"]), result.succeeded { throw CancellationError() }
                return result
            }
        }
        final class Batches: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [(Int, Int, [LargeGitFile])] = []
            func append(_ completed: Int, _ total: Int, _ files: [LargeGitFile]) {
                lock.lock()
                defer { lock.unlock() }
                values.append((completed, total, files))
            }
            func snapshot() -> [(Int, Int, [LargeGitFile])] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }
        actor BranchGate {
            var waiting = false
            private var continuation: CheckedContinuation<Void, Never>?
            func pause() async {
                waiting = true
                await withCheckedContinuation { continuation = $0 }
            }
            func resume() {
                continuation?.resume()
                continuation = nil
            }
        }
        struct GatedBranchRunner: GitCommandRunning {
            let gate: BranchGate
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                let result = try await Runner().run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
                if arguments.starts(with: ["branch", "--track"]), result.succeeded { await gate.pause() }
                return result
            }
        }
        @Test("Closed mutation") static func closedMutation() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("file.txt", "base\n")
            try fixture.commitAll("base")
            let head = try fixture.head()
            try fixture.git(["remote", "add", "origin", fixture.repo.path])
            try fixture.git(["update-ref", "refs/remotes/origin/closed-dialog", head.string])
            let gate = BranchGate()
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: GatedBranchRunner(gate: gate))
            _ = try await module.loadRepositoryState()
            var refreshes = 0
            let host = GitExtensionPluginHost(refresh: { refreshes += 1 }, navigate: { _ in }, readSetting: { _, _ in nil }, writeSetting: { _, _, _ in })
            host.update(context: ["WorkingDir": [fixture.repo.path]], owner: nil)
            host.builtInRepository = module
            let controller = try BuiltInPluginDialog(plugin: CreateLocalBranchesPlugin(), host: host)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let button = descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Create local tracking branches" }!
            button.performClick(nil)
            let deadline = ContinuousClock.now + .seconds(10)
            while !(await gate.waiting), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await gate.waiting, "branch mutation reached completion gate")
            controller.close()
            await gate.resume()
            while refreshes == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(refreshes == 1, "closing during successful mutation still refreshes exactly once")
            let target = try fixture.git(["rev-parse", "closed-dialog"]).trimmingCharacters(in: .newlines)
            #expect(target == head.string, "closed dialog reports actual new branch")
        }
        @Test("Repository") static func repository() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.cs", "// comment\n\ncode\n")
            try fixture.write("large space ü's.txt", String(repeating: "x", count: 2048))
            try fixture.commitAll("base")
            let base = try fixture.head()
            try fixture.git(["branch", "obsolete"])
            try fixture.git(["remote", "add", "origin", fixture.repo.path])
            try fixture.git(["update-ref", "refs/remotes/origin/topic", base.string])
            try fixture.git(["update-ref", "refs/remotes/origin/main", base.string])
            try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
            try fixture.write("a.cs", "// comment\ncode\ncode2\n")
            try fixture.commitAll("second\n\nbody")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: Runner())
            _ = try await module.loadRepositoryState()
            let tracking = try await module.createTrackingBranches(remote: "origin")
            #expect(tracking.created == 1, "create only missing tracking branch")
            let target = try fixture.git(["rev-parse", "topic"]).trimmingCharacters(in: .newlines)
            let trackingConfig = try fixture.git(["config", "branch.topic.merge"]).trimmingCharacters(in: .newlines)
            #expect(target == base.string && trackingConfig == "refs/heads/topic", "actual target and upstream")
            let repeated = try await module.createTrackingBranches(remote: "origin")
            #expect(repeated.created == 0, "existing branch never overwritten")
            try fixture.git(["remote", "add", "cancelremote", fixture.repo.path])
            try fixture.git(["update-ref", "refs/remotes/cancelremote/preserved", base.string])
            let cancelling = GitRepositoryModule(repositoryURL: fixture.repo, git: CancelAfterBranchRunner())
            _ = try await cancelling.loadRepositoryState()
            do {
                _ = try await cancelling.createTrackingBranches(remote: "cancelremote")
                Issue.record("cancellation ignored")
            } catch let error as BuiltInMutationError { #expect(error.changed && error.cancelled, "partial creation retains refresh outcome") }
            let preserved = try fixture.git(["rev-parse", "preserved"]).trimmingCharacters(in: .newlines)
            #expect(preserved == base.string, "cancelled creation reports actual surviving ref")
            let obsolete = try await module.obsoleteBranches(base: "HEAD", remote: nil, unmerged: false, pattern: "obsolete", ignoreCase: false, invert: false)
            #expect(obsolete.map(\.name) == ["obsolete"], "merged candidate and subject")
            let deleted = try await module.executePluginCommand(
                BuiltInPluginCommands.deleteBranch("obsolete", remote: nil, unmerged: false), standardInput: nil)
            #expect(deleted.succeeded, "delete merged branch")
            let refs = try fixture.git(["branch", "--list", "obsolete"])
            #expect(refs.isEmpty, "ref removed")
            let batches = Batches()
            let files = try await module.findLargeFiles(minimum: 1024, progress: { batches.append($0, $1, $2) })
            let snapshots = batches.snapshot()
            #expect(snapshots.map { $0.0 } == [1, 2] && snapshots.allSatisfy { $0.1 == 2 && $0.2.count == 1 }, "incremental ordered object delivery")
            #expect(snapshots.last?.2.first?.revisions.count == 2, "incremental revision associations")
            #expect(
                files.count == 1 && files[0].path == "large space ü's.txt" && files[0].size == 2048 && files[0].revisions.count == 2,
                "dedup by object and revision count")
            let notesCommand = try BuiltInPluginCommands.releaseNotes(from: base.string, to: "HEAD", arguments: BuiltInPluginCommands.releaseArguments)
            let log = try await module.executePluginCommand(notesCommand, standardInput: nil)
            let notes = BuiltInPluginCommands.parseReleaseNotes(log.standardOutputString)
            #expect(notes.count == 1 && notes[0].message.joined().contains("body"), "real release notes")
            let stats = try await module.codeStatistics(pattern: "*.cs", ignoredDirectories: "\\bin", includeSubmodules: false)
            #expect(stats.code == 2 && stats.comments == 1 && stats.contributors.reduce(0, { $0 + $1.1 }) == 2, "real stats")
            let authors = try await module.gourceAuthors()
            #expect(authors.count == 1 && authors[0].1 == "Fixture", "gource author association")
            try fixture.write("one.sln", "sln")
            try fixture.write("nested/two.sln", "sln")
            try fixture.write("Z-Audit.sln", "sln")
            try fixture.write("A-Audit.sln", "sln")
            let solutions = try await module.solutionFiles()
            #expect(
                solutions.map(\.lastPathComponent) == ["A-Audit.sln", "one.sln", "Z-Audit.sln", "two.sln"],
                "recursive solutions enumerate root files in name order before subdirectories, so the skipped first entry is A-Audit.sln \(solutions.map(\.lastPathComponent))"
            )
            let proxy = BuiltInPluginCommands.proxy(host: "proxy.test", port: "8080", username: "", password: "", global: false, remove: false)
            _ = try await module.executePluginCommand(proxy, standardInput: nil)
            let configured = try fixture.git(["config", "http.proxy"]).trimmingCharacters(in: .newlines)
            #expect(configured == "proxy.test:8080", "local proxy stored")
            _ = try await module.executePluginCommand(
                BuiltInPluginCommands.proxy(host: "", port: "", username: "", password: "", global: false, remove: true), standardInput: nil)
            let config = try await module.loadGitSettings(.local)
            #expect(config["http.proxy"] == nil, "proxy removed")
            try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("one.sln"))
            try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("nested"))
            let rewritten = try await module.removeLargeFiles(["large space ü's.txt"])
            #expect(rewritten.changed && rewritten.errors.isEmpty, "typed history rewrite outcome")
            let tree = try fixture.git(["ls-tree", "-r", "HEAD"])
            let old = try fixture.git(["for-each-ref", "refs/original"])
            #expect(!tree.contains("large space") && old.isEmpty, "rewrite resulting tree and backup cleanup")
            try fixture.write("a-small.bin", String(repeating: "a", count: 2048))
            try fixture.write("b-big.bin", String(repeating: "b", count: 4096))
            try fixture.commitAll("order")
            let ordered = try await module.findLargeFiles(minimum: 1024, progress: { _, _, _ in })
            #expect(ordered.map(\.path) == ["a-small.bin", "b-big.bin"], "large files keep git tree enumeration order \(ordered.map(\.path))")
            let host = GitExtensionPluginHost(
                refresh: {}, navigate: { _ in }, readSetting: { name, _ in name == "Find large files bigger than (Mb)" ? "0.001" : nil },
                writeSetting: { _, _, _ in })
            host.update(context: ["WorkingDir": [fixture.repo.path]], owner: nil)
            host.builtInRepository = module
            let dialog = try BuiltInPluginDialog(plugin: FindLargeFilesPlugin(), host: host)
            dialog.showWindow(nil)
            defer { dialog.close() }
            let table = DialogBehaviorTests.allSubviews(dialog.window!.contentView!).compactMap { $0 as? NSTableView }.first!
            NSApp.sendAction(NSSelectorFromString("run"), to: dialog, from: nil)
            let deadline = ContinuousClock.now + .seconds(10)
            while table.numberOfRows != ordered.count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(table.numberOfRows == ordered.count, "large-file grid loads real object rows")
            let shaColumn = table.tableColumns.first { $0.identifier.rawValue == "id" }!
            for (row, file) in ordered.enumerated() {
                let label = dialog.tableView(table, viewFor: shaColumn, row: row) as! NSTextField
                #expect(
                    label.stringValue == file.id.string && label.toolTip == file.id.string && label.stringValue.count == 40,
                    "full object SHA in both row and tooltip")
            }
        }

        @Test("Background") static func background() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a", "a")
            try fixture.commitAll("base")
            try fixture.git(["remote", "add", "origin", fixture.repo.path])
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: Runner())
            _ = try await module.loadRepositoryState()
            var values = ["Fetch immediately on repository opening": "true", "Refresh view after fetch": "true"]
            var refreshes = 0
            let host = GitExtensionPluginHost(
                refresh: { refreshes += 1 }, navigate: { _ in }, readSetting: { name, _ in values[name] },
                writeSetting: { name, value, _ in values[name] = value })
            host.update(context: ["WorkingDir": [fixture.repo.path]], owner: nil)
            host.builtInRepository = module
            let plugin = BackgroundFetchPlugin()
            try plugin.register(with: host)
            let deadline = ContinuousClock.now + .seconds(5)
            while refreshes == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            #expect(refreshes == 1, "one-shot immediate fetch refresh")
            let refs = try fixture.git(["rev-parse", "refs/remotes/origin/main"])
            #expect(refs.trimmingCharacters(in: .newlines) == (try fixture.head()).string, "actual fetched refs")
            plugin.unregister(from: host)
            values["Fetch immediately on repository opening"] = "false"
            values["Fetch every (seconds) - set to 0 to disable"] = "5"
            try plugin.register(with: host)
            plugin.unregister(from: host)
            try await Task.sleep(for: .milliseconds(100))
            #expect(refreshes == 1, "cancelled timer cannot publish")
            let compile = AutoCompileSubmodulesPlugin()
            try compile.register(with: host)
            _ = try host.dispatch("PostUpdateSubmodules", succeeded: false)
            _ = try host.dispatch("PostUpdateSubmodules", succeeded: true)
            compile.unregister(from: host)
        }

        @Test("Presentation") static func presentation() async throws {
            try proxyPresentation()
            let host = GitExtensionPluginHost(refresh: {}, navigate: { _ in }, readSetting: { _, _ in nil }, writeSetting: { _, _, _ in })
            for plugin in BuiltInPlugins.make() {
                if [.backgroundFetch, .compileSubmodules, .impact].contains(plugin.kind) { continue }
                let controller = try BuiltInPluginDialog(plugin: plugin, host: host)
                #expect(controller.window?.title == plugin.name && controller.window?.contentView != nil, "native dialog \(plugin.name)")
                if plugin.kind == .largeFiles {
                    let tables = DialogBehaviorTests.allSubviews(controller.window!.contentView!).compactMap { $0 as? NSTableView }
                    #expect(
                        tables.count == 1
                            && tables[0].tableColumns.map(\.title) == ["SHA", "Path", "Size", "Compressed size", "Commit count", "Last commit date", "Delete"],
                        "source column order puts Delete last")
                    #expect(tables[0].sortDescriptors.isEmpty, "initial grid does not impose a size sort")
                }
                controller.close()
            }
            let invocation = ScriptInvocation(
                executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "space ü"], workingDirectory: FileManager.default.temporaryDirectory,
                environment: [:])
            let result = try await ScriptExecution.run(invocation, output: { _ in })
            #expect(result.standardOutputString == "space ü", "external tool argv boundary")
            let sleep = ScriptInvocation(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], workingDirectory: FileManager.default.temporaryDirectory, environment: [:])
            let task = Task { try await ScriptExecution.run(sleep, output: { _ in }) }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancellation ignored")
            } catch is CancellationError {}
        }

        static func proxyPresentation() throws {
            let host = GitExtensionPluginHost(refresh: {}, navigate: { _ in }, readSetting: { _, _ in nil }, writeSetting: { _, _, _ in })
            let controller = try BuiltInPluginDialog(plugin: ProxySwitcherPlugin(), host: host)
            let window = controller.window!
            defer { controller.close() }
            window.makeKeyAndOrderFront(nil)
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            let fields = DialogBehaviorTests.allSubviews(root).compactMap { $0 as? NSTextField }.filter { $0.isBezeled && !$0.isEditable }
            #expect(fields.count == 2, "two read-only proxy values")
            #expect(fields.allSatisfy { $0.bounds.width >= 180 && $0.isSelectable }, "empty read-only fields retain useful selectable width")
            let labels = DialogBehaviorTests.allSubviews(root).compactMap { $0 as? NSTextField }.filter { !$0.isBezeled }.map(\.stringValue)
            #expect(labels.contains("Local http.proxy:") && labels.contains("Global http.proxy:"), "exact pinned field captions")
            #expect(
                abs(root.bounds.width - 341) < 1 && abs(window.contentMinSize.width - 341) < 1, "pinned client width and minimum translated to native content")
            let checkbox = DialogBehaviorTests.allSubviews(root).compactMap { $0 as? NSButton }.first { $0.title == "Apply globally" }!
            let left = root.convert(fields[0].bounds, from: fields[0]).minX
            #expect(
                abs(root.convert(checkbox.bounds, from: checkbox).minX - left) < 1 && checkbox.state == .on,
                "default checked scope aligns in the value column")
            let actions = DialogBehaviorTests.allSubviews(root).compactMap { $0 as? NSButton }.filter {
                ["Set proxy", "Unset proxy", "Close"].contains($0.title)
            }
            #expect(
                actions.map(\.title) == ["Set proxy", "Unset proxy", "Close"] && actions.allSatisfy { $0.isEnabled },
                "source action order and existing native Close")
            let last = root.convert(actions.last!.bounds, from: actions.last!)
            #expect(abs(last.maxX - (root.bounds.maxX - 12)) < 2 && root.bounds.contains(last), "actions align right and fit the native dialog")
            let width = fields[0].bounds.width
            window.setContentSize(NSSize(width: 541, height: root.bounds.height))
            root.layoutSubtreeIfNeeded()
            #expect(abs(fields[0].bounds.width - width - 200) < 2, "value column fills resized width")
            fields[0].stringValue = "audit-user:****@proxy.example.invalid:8080"
            window.setContentSize(NSSize(width: 341, height: root.bounds.height))
            root.layoutSubtreeIfNeeded()
            #expect(
                fields.allSatisfy { root.bounds.contains(root.convert($0.bounds, from: $0)) && $0.bounds.width >= 180 },
                "populated readonly values preserve the minimum layout")
            #expect(actions.last?.keyEquivalent == "\u{1b}", "existing native Escape/Close remains")
        }
    }
}

typealias BuiltInPluginTests = UIIntegrationTests.BuiltInPluginTests
