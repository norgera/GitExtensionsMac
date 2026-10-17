import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @Suite("Command log")
    enum CommandLogTests {
        @Test("Scenarios") static func run() async throws {
            await MainActor.run {
                verifyWordWrap()
                verifyWindowActions()
            }
            let log = CommandLog()
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            let command = GitCommand(arguments: ["status", "--porcelain=v2"], accessesRemote: false, changesRepositoryState: false)
            let first = log.start(command, directory: directory)
            let second = log.start(command, directory: directory)
            log.finish(second, cancelled: true)
            log.finish(
                first, result: GitCommandResult(arguments: command.arguments, standardOutput: Data("out".utf8), standardError: Data("err".utf8), exitStatus: 1))
            #expect(log.snapshot().map(\.id) == [first, second])
            #expect(log.snapshot()[0].exitStatus == 1 && log.snapshot()[0].stdoutBytes == 3)
            #expect(log.snapshot()[1].cancelled)
            log.clear()
            log.finish(first)
            #expect(log.snapshot().isEmpty)
            for _ in 0..<510 { _ = log.start(command, directory: directory) }
            #expect(log.snapshot().count == 499)
            let redacted = CommandLog.redacted([
                "-c", "http.extraHeader=Authorization: secret", "fetch", "https://user:secret@example.invalid/repo?token=secret", "--password", "secret",
            ])
            #expect(!redacted.joined().contains("secret"))
            #expect(CommandLog.redacted(["config", "credential.helper", "secret"]) == ["config", "<redacted>", "<redacted>"])
            #expect(CommandLog.redacted(["-chttp.extraHeader=private", "https://user:private@example.invalid/repo"]).allSatisfy { !$0.contains("private") })
            let remote = log.start(GitCommand(arguments: ["fetch", "origin"], accessesRemote: true, changesRepositoryState: true), directory: directory)
            #expect(log.snapshot().last!.accessesRemote && log.snapshot().last!.mayChangeRepository)
            log.finish(remote)
            #expect(log.snapshot().last!.failedToExecute)
            CommandLog.shared.clear()
            let result = try await GitProcess().run(GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false), in: directory)
            #expect(result.succeeded)
            let captured = CommandLog.shared.snapshot()
            #expect(captured.count == 1 && captured[0].exitStatus == 0 && captured[0].processID != nil)
            #expect(captured[0].stdoutBytes == result.standardOutput.count)
            let streamed = try await GitProcess().runStreaming(
                GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false), in: directory
            ) { _ in }
            #expect(streamed.succeeded && CommandLog.shared.snapshot().count == 2)
            let failure = try await GitProcess().run(
                GitCommand(arguments: ["not-a-real-git-command"], accessesRemote: false, changesRepositoryState: false), in: directory)
            #expect(!failure.succeeded && CommandLog.shared.snapshot().last?.exitStatus == failure.exitStatus)
            let sleeper = Task {
                try await GitProcess(executableURL: URL(fileURLWithPath: "/bin/sleep")).run(
                    GitCommand(arguments: ["30"], accessesRemote: false, changesRepositoryState: false), in: directory)
            }
            for _ in 0..<100 {
                if CommandLog.shared.snapshot().last?.processID != nil && CommandLog.shared.snapshot().last?.arguments == ["30"] { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            sleeper.cancel()
            do {
                _ = try await sleeper.value
                Issue.record("Cancelled process completed normally")
            } catch is CancellationError {}
            #expect(CommandLog.shared.snapshot().last?.cancelled == true)
            log.capturesCallStacks = true
            _ = log.start(command, directory: directory)
            #expect(!log.snapshot().last!.callStack.isEmpty)
        }

        private actor CacheRunner: GitCommandRunning {
            var calls = 0
            var fails = false
            func setFailure(_ value: Bool) { fails = value }
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                calls += 1
                return GitCommandResult(
                    arguments: arguments, standardOutput: Data("Another Git result".utf8), standardError: Data("Still no Git error.".utf8),
                    exitStatus: fails ? 1 : 0)
            }
        }

        @Test("Cache") @MainActor static func runCache() async throws {
            func entry(_ key: String, _ output: String = "Git result", _ error: String = "No Git error!") -> CommandCacheEntry {
                CommandCacheEntry(key: key, arguments: [key], directory: "/fixture", output: Data(output.utf8), error: Data(error.utf8))
            }
            let cache = CommandCache()
            #expect(cache.capacity == 50)
            cache.add(nil)
            cache.add(entry(""))
            #expect(cache.snapshot().isEmpty && cache.value(for: nil) == nil && cache.value(for: "") == nil, "pinned TestAddCannotCache/TestTryGetFails")
            cache.add(entry("git command"))
            #expect(cache.snapshot().map(\.key) == ["git command"], "pinned TestAdd")
            cache.add(entry("git command", "Another Git result", "Still no Git error."))
            let found = cache.value(for: "git command")!
            #expect(
                String(decoding: found.output, as: UTF8.self) == "Another Git result" && String(decoding: found.error, as: UTF8.self) == "Still no Git error.",
                "pinned TestTryGet")
            let lru = CommandCache(capacity: 3)
            for key in ["1", "2", "3"] { lru.add(entry(key)) }
            for key in ["3", "2", "1"] { #expect(lru.value(for: key) != nil) }
            #expect(lru.snapshot().map(\.key) == ["1", "2", "3"], "reads promote recency without reordering source dictionary-slot display")
            lru.add(entry("4"))
            #expect(lru.value(for: "3") == nil && lru.snapshot().map(\.key) == ["1", "2", "4"], "pinned MruCache renewal/expiry with recycled dictionary slot")
            lru.clear()
            #expect(lru.snapshot().isEmpty)
            for index in 0..<51 { cache.add(entry(String(index))) }
            #expect(cache.snapshot().count == 50 && cache.value(for: "0") == nil, "bounded source capacity50 evicts least recent")
            #expect(CommandCacheEntry.printable("a\0b\rc\nd\te f\u{1b}") == "a\\0b\\rc\\n\nd»e·f\\x1b", "exact upstream PrintableChars substitutions")
            let encoded = CommandCacheEntry(
                key: "encoded", arguments: ["cat-file"], directory: "/fixture", output: "café λ".data(using: .utf16LittleEndian)!, error: Data(),
                outputEncoding: .utf16LittleEndian)
            #expect(encoded.details.contains("café·λ"), "cache presentation uses supplied file encoding while retaining original bytes")
            let detected = CommandCacheEntry(
                key: "detected", arguments: ["cat-file"], directory: "/fixture", output: Data([0xff, 0xfe]) + "café".data(using: .utf16LittleEndian)!,
                error: Data(), outputEncoding: nil)
            #expect(detected.details.contains("café"), "cache automatic representation reuses existing BOM-aware decoder")
            let runner = CacheRunner()
            let executionCache = CommandCache()
            let command = GitCommand(
                arguments: ["ls-tree", "-z", "0123456789012345678901234567890123456789"], accessesRemote: false, changesRepositoryState: false)
            let directory = URL(fileURLWithPath: "/fixture")
            let first = try await runner.runCached(command, in: directory, cache: executionCache)
            let second = try await runner.runCached(command, in: directory, cache: executionCache)
            let calls = await runner.calls
            #expect(
                calls == 1 && first.standardOutput == second.standardOutput && second.standardError == first.standardError,
                "cache hit bypasses real command execution and preserves output/error")
            _ = try await runner.runCached(command, in: URL(fileURLWithPath: "/other-repository"), cache: executionCache)
            let separateCalls = await runner.calls
            #expect(separateCalls == 2, "upstream ExecuteAsync repository key separation")
            await runner.setFailure(true)
            executionCache.clear()
            _ = try await runner.runCached(command, in: directory, cache: executionCache)
            _ = try await runner.runCached(command, in: directory, cache: executionCache)
            #expect(executionCache.snapshot().isEmpty, "failed commands never enter upstream executable cache")
            CommandCache.shared.clear()
            defer { CommandCache.shared.clear() }
            let root = try RepositoryWorkflowTests.temporaryDirectory("command-cache")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("home")
            let repo = root.appendingPathComponent("repository")
            for path in [home, repo] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            let environment = ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
            for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Cache Fixture"], ["config", "user.email", "cache@example.invalid"]] {
                _ = try RepositoryWorkflowTests.git(args, in: repo, environment: environment)
            }
            try Data("source λ\n".utf8).write(to: repo.appendingPathComponent("space λ.txt"))
            _ = try RepositoryWorkflowTests.git(["add", "."], in: repo, environment: environment)
            _ = try RepositoryWorkflowTests.git(["-c", "commit.gpgsign=false", "commit", "-qm", "seed"], in: repo, environment: environment)
            let module = GitRepositoryModule(repositoryURL: repo, git: RepositoryWorkflowTests.EnvironmentGit(environment: environment))
            let state = try await module.loadRepositoryState()
            let commit = RepositoryWorkflowTests.commit(state.identity.headID!, references: [])
            let revision = try await module.loadRevisionDetails(for: commit)
            _ = try await module.loadRepositoryFiles(for: commit)
            _ = try await module.loadDiff(for: commit, file: revision.files.first!, options: FileDiffOptions())
            let real = CommandCache.shared.snapshot()
            #expect(
                real.contains { $0.arguments.contains("ls-tree") } && real.contains { $0.arguments.contains("--name-status") }
                    && real.contains { $0.arguments.contains("--patch") },
                "actual immutable repository tree/details/diff workflows populate shared command cache")
            #expect(
                real.allSatisfy { !$0.arguments.contains("status") && !$0.arguments.contains("config") && !$0.arguments.contains("--cached") },
                "mutable refs/index/worktree/config reads are not cached")
            let controller = CommandLogWindowController()
            let window = controller.window!
            window.setContentSize(NSSize(width: 659, height: 470))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let tabs = views(window.contentView!).compactMap { $0 as? NSTabView }.first!
            #expect(
                tabs.tabViewItems.map(\.label) == ["Command log", "Command cache"] && tabs.selectedTabViewItem?.label == "Command log",
                "source tab order and initial log mode")
            tabs.selectTabViewItem(withIdentifier: "cache")
            let table = views(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.accessibilityIdentifier() == "CommandCache.Table" }!
            let detail = views(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "CommandCache.Output" }!
            #expect(
                table.numberOfRows == real.count && table.selectedRow == real.count - 1 && !detail.isEditable && !detail.string.isEmpty,
                "populated cache selects tail and exposes actual raw output read-only")
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let selected = real[0].key
            CommandCache.shared.add(entry("added", "extra \t\0output", "error"))
            try await RepositoryWorkflowTests.waitUntil("cache update preserves selection") { table.numberOfRows == real.count + 1 }
            #expect(CommandCache.shared.snapshot()[table.selectedRow].key == selected, "non-tail selection preserved across cache change")
            let wordWrap = views(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Word wrap" }!
            wordWrap.state = .off
            RepositoryWorkflowTests.click(wordWrap)
            #expect(detail.enclosingScrollView!.hasHorizontalScroller, "word wrap shared with cache output")
            #expect(
                table.menu!.items.map(\.title) == ["Clear"] && table.menu!.items[0].keyEquivalent == "l",
                "separate Clear-only source context action and native CmdL")
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            for index in 0..<50 { CommandCache.shared.add(entry("replacement \(index)")) }
            try await RepositoryWorkflowTests.waitUntil("cache eviction keeps source selection slot") { table.numberOfRows == 50 }
            #expect(table.selectedRow == 2, "recycled cache slot retains source selected index when the old key is evicted")
            let logCount = CommandLog.shared.snapshot().count
            let lastDetail = detail.string
            let clear = table.menu!.items[0]
            NSApp.sendAction(clear.action!, to: clear.target, from: clear)
            #expect(
                CommandCache.shared.snapshot().isEmpty && table.numberOfRows == 0 && CommandLog.shared.snapshot().count == logCount,
                "cache Clear is independent of command log and repository state")
            #expect(detail.string == lastDetail, "source empty-after-clear preserves last displayed output")
            tabs.selectTabViewItem(withIdentifier: "log")
            #expect(tabs.selectedTabViewItem?.label == "Command log")
        }

        @MainActor private static func verifyWindowActions() {
            let controller = CommandLogWindowController()
            let window = controller.window!
            defer { window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(window.contentView!)
            let buttons = views.compactMap { $0 as? NSButton }
            #expect(
                buttons.map(\.title).sorted() == ["Always on top", "Capture call stacks", "Word wrap"],
                "only the shared source options appear below the log, with no duplicate permanent action footer")
            let table = views.compactMap { $0 as? NSTableView }.first!
            #expect(
                table.menu!.items.map(\.title) == ["Save to file…", "Copy full command line", "Clear"],
                "all actions remain reachable in source context-menu order")
            #expect(
                table.menu!.items.map(\.keyEquivalent) == ["s", "c", "l"] && table.menu!.items.allSatisfy { $0.keyEquivalentModifierMask == .command },
                "native keyboard equivalents remain present")
        }

        @MainActor private static func verifyWordWrap() {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
            scroll.hasVerticalScroller = true
            let text = CommandLogDetailView(frame: scroll.bounds)
            text.isRichText = false
            text.isVerticallyResizable = true
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            scroll.documentView = text
            let content = "Command: git log " + String(repeating: "a-long-argument ", count: 30)
            text.string = content
            for _ in 0..<3 {
                text.setWordWrap(false)
                #expect(scroll.hasHorizontalScroller && text.frame.width > scroll.contentSize.width)
                text.setWordWrap(true)
                #expect(!scroll.hasHorizontalScroller && abs(text.frame.width - scroll.contentSize.width) < 1)
                #expect(text.frame.height > text.font!.pointSize * 2)
                #expect(text.string == content)
            }
            scroll.setFrameSize(NSSize(width: 240, height: 150))
            scroll.layoutSubtreeIfNeeded()
            #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            #expect(text.layoutManager!.usedRect(for: text.textContainer!).width <= scroll.contentSize.width)
        }
    }
}

typealias CommandLogTests = UIIntegrationTests.CommandLogTests
