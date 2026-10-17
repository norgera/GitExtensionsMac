import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Git execution")
    enum GitExecutionTests {
        @Test("Scenarios") static func run() async throws {
            try commandConfigurationVectors()
            try await sharedPathCarriesConfiguration()
            try await hostileIgnoreSubmodulesAndSubmoduleFormat()
            try await hostileShowSignature()
            try await hostileColor()
            try await hostilePrefixes(key: "diff.noprefix", value: "true", marker: "--- f.txt")
            try await hostilePrefixes(key: "diff.mnemonicprefix", value: "true", marker: "--- i/f.txt")
            try await processInput()
            try await processInputCancellation()
            try await processInputIsNotLogged()
            try await executionIntentEnvironment()
            try await askPassCredential()
            try await askPassDismissalAndCancellation()
            try await sshAskPassHelper()
            try processDialogPreferences()
            try await processInputController()
        }

        private struct Failure: LocalizedError { let errorDescription: String? }

        private static func wait(_ message: String, seconds: Double = 10, until condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while try !condition() {
                #expect(ContinuousClock.now < deadline, Comment(rawValue: message))
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        private static func subcommand(_ arguments: [String]) -> String? {
            GitCommandConfiguration.subcommandIndex(in: arguments).map { arguments[$0] }
        }

        private static func commandConfigurationVectors() throws {
            let configuration = GitCommandConfiguration.default
            func items(_ command: String) -> [String] { configuration.items(for: command).map { "\($0.key)=\($0.value)" } }
            #expect(items("rebase") == ["rebase.autosquash=false"], "rebase")
            for command in ["log", "show", "whatchanged"] { #expect(items(command) == ["log.showsignature=false"], Comment(rawValue: command)) }
            #expect(
                items("diff") == [
                    "color.ui=never", "diff.submodule=short", "diff.noprefix=false", "diff.mnemonicprefix=false",
                    "diff.ignoresubmodules=none", "core.safecrlf=false",
                ], "diff in upstream order")
            #expect(items("range-diff") == ["color.ui=never"] && items("grep") == ["color.ui=never"], "range-diff and grep")
            #expect(items("status") == ["diff.ignoresubmodules=none"], "status")
            for command in ["commit", "fetch", "push", "pull", "apply", "config", "rev-parse", "merge", "foo"] {
                #expect(items(command).isEmpty, "\(command) has no defaults")
            }
            #expect(configuration.apply(to: ["foo", "--bar"]) == ["foo", "--bar"], "Command_with_one_argument")
            #expect(configuration.apply(to: ["foo"]) == ["foo"], "Command_with_no_arguments")
            #expect(configuration.apply(to: ["log", "-n", "1"]) == ["-c", "log.showsignature=false", "log", "-n", "1"], "Command_with_default_config_item")
            #expect(configuration.apply(to: ["-c", "bar=baz", "foo"]) == ["-c", "bar=baz", "foo"], "Command_with_custom_config_item")
            #expect(
                configuration.apply(to: ["-c", "bar=baz", "log", "-n", "1"]) == ["-c", "log.showsignature=false", "-c", "bar=baz", "log", "-n", "1"],
                "Command_with_default_and_custom_config_items")
            #expect(
                configuration.apply(to: ["-c", "log.showsignature=true", "log", "-n", "1"]) == ["-c", "log.showsignature=true", "log", "-n", "1"],
                "Command_with_config_item_that_overrides_default")
            #expect(
                configuration.apply(to: ["-c", "LOG.showSIGNATURE=true", "log", "-n", "1"]) == ["-c", "LOG.showSIGNATURE=true", "log", "-n", "1"],
                "Command_with_config_item_that_overrides_default_different_case")
            #expect(
                configuration.apply(to: ["-c", "core.safecrlf=true", "diff"]).filter { $0.hasPrefix("core.safecrlf") } == ["core.safecrlf=true"],
                "explicit diff override wins without duplicating the default")
            #expect(
                configuration.apply(to: ["--config-env=color.ui=GIT_COLOR", "grep", "x"]) == ["--config-env=color.ui=GIT_COLOR", "grep", "x"],
                "--config-env overrides count as explicit")
            #expect(
                configuration.apply(to: ["--no-optional-locks", "status", "--porcelain=2"])
                    == ["-c", "diff.ignoresubmodules=none", "--no-optional-locks", "status", "--porcelain=2"], "global options before the subcommand")
            #expect(subcommand(["-C", "dir", "--git-dir", "x", "-c", "a=b", "diff"]) == "diff", "options with values are skipped")
            #expect(subcommand(["log", "-c", "-p"]) == "log", "combined diff -c after the subcommand is an argument")
            #expect(configuration.apply(to: ["--version"]) == ["--version"] && subcommand(["--exec-path"]) == nil, "no subcommand")
            #expect(
                GitCommand(arguments: ["rebase", "main"], accessesRemote: false, changesRepositoryState: true).processArguments
                    == ["-c", "rebase.autosquash=false", "rebase", "main"], "CommandsTests RebaseCmd prefix")
            let wordDiff = GitCommand(
                arguments: GitDiffAppearance.wordDiffCommand(["diff", "--no-color", "--", "f"], configured: []), accessesRemote: false,
                changesRepositoryState: false
            ).processArguments
            #expect(
                subcommand(wordDiff) == "diff" && wordDiff.contains("--color=always") && wordDiff.contains("color.ui=never")
                    && wordDiff.filter({ $0.hasPrefix("color.diff.") }).count > 0, "word diff keeps its explicit display colouring")
        }

        private static func sharedPathCarriesConfiguration() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("shared")
            try fixture.commit(repo, file: "f.txt", contents: "one\n")
            try "two\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            let runner = RecordingRunner()
            let module = GitRepositoryModule(repositoryURL: repo, git: runner)
            _ = try await module.loadRepositoryState()
            let revisions = try await readRevisions(module)
            let working = revisions.first { $0.kind == .workingDirectory }!
            let details = try await module.loadRevisionDetails(for: working)
            _ = try await module.loadDiff(for: working, file: details.files.first { $0.path == "f.txt" }!, options: FileDiffOptions())
            let commands = runner.commands
            func has(_ name: String, _ item: String) -> Bool {
                commands.contains { subcommand($0) == name && zip($0, $0.dropFirst()).contains { $0 == "-c" && $1 == item } }
            }
            #expect(has("status", "diff.ignoresubmodules=none"), "status reader receives the default: \(commands.filter { subcommand($0) == "status" })")
            #expect(has("log", "log.showsignature=false"), "revision reader receives log.showsignature=false")
            #expect(
                has("diff", "diff.noprefix=false") && has("diff", "color.ui=never") && has("diff", "core.safecrlf=false"), "diff reader receives diff defaults")
            #expect(!commands.contains { subcommand($0) == "rev-parse" && $0.first == "-c" }, "unconfigured commands are untouched")
        }

        private static func hostileIgnoreSubmodulesAndSubmoduleFormat() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let (superproject, submodule) = try fixture.superprojectWithSubmodule()
            try fixture.commit(submodule, file: "child.txt", contents: "moved\n")
            try fixture.git(["config", "diff.ignoreSubmodules", "all"], in: superproject)
            try fixture.git(["config", "diff.submodule", "log"], in: superproject)
            #expect(
                try !fixture.git(["status", "--porcelain=2"], in: superproject).contains("sub"), "control: hostile config hides the submodule from raw status")
            #expect(
                try fixture.git(["-c", "diff.ignoreSubmodules=none", "diff", "--", "sub"], in: superproject).contains("Submodule sub"),
                "control: hostile diff.submodule=log changes the raw patch format")
            let module = GitRepositoryModule(repositoryURL: superproject)
            let state = try await module.loadRepositoryState()
            let worktree = RevisionCommitBuilder.artificialRevisions(headID: state.commitContext.headID).first { $0.kind == .workingDirectory }!
            let details = try await module.loadRevisionDetails(for: worktree)
            let file = details.files.first { $0.path == "sub" }
            #expect(file != nil, "changed submodule stays visible in status: \(details.files.map(\.path))")
            let diff = try await module.loadDiff(for: worktree, file: file!, options: FileDiffOptions())
            let text = diff?.lines.map(\.text).joined(separator: "\n") ?? ""
            #expect(text.contains("Subproject commit") && !text.contains("Submodule sub "), "submodule diff keeps the short unified format: \(text)")
        }

        private static func hostileShowSignature() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("signed")
            let key = fixture.root.appendingPathComponent("signing-key")
            try fixture.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path], in: fixture.root)
            try fixture.git(["config", "gpg.format", "ssh"], in: repo)
            try fixture.git(["config", "user.signingkey", key.path], in: repo)
            try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["add", "."], in: repo)
            try fixture.git(["commit", "-q", "-S", "-m", "Signed subject"], in: repo)
            try "b\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["add", "."], in: repo)
            try fixture.git(["commit", "-q", "-S", "-m", "Second signed subject"], in: repo)
            try fixture.git(["config", "log.showSignature", "true"], in: repo)
            #expect(try fixture.git(["log", "-1", "--format=%H"], in: repo).contains("No signature"), "control: hostile showSignature prefixes raw log output")
            let module = GitRepositoryModule(repositoryURL: repo)
            _ = try await module.loadRepositoryState()
            let revisions = try await readRevisions(module).filter { $0.kind == .revision }
            #expect(revisions.map(\.subject) == ["Second signed subject", "Signed subject"], "revision records parse cleanly: \(revisions.map(\.subject))")
            #expect(
                revisions.first?.objectID?.string == (try fixture.git(["-c", "log.showSignature=false", "rev-parse", "HEAD"], in: repo)), "revision ids intact")
        }

        private static func hostileColor() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("color")
            try fixture.commit(repo, file: "match.txt", contents: "needle\n")
            try fixture.commit(repo, file: "other.txt", contents: "hay\n")
            try "needle changed\n".write(to: repo.appendingPathComponent("match.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["config", "color.ui", "always"], in: repo)
            let grep = try FileStatusCommands.grepFiles(["-e", "needle"], revision: .workingDirectory, options: GitGrepOptions())
            let raw = try await GitProcess().run(arguments: grep.arguments, in: repo)
            #expect(raw.standardOutputString.contains("\u{1b}["), "control: hostile color.ui injects ANSI into raw grep output")
            let hardened = try await GitProcess().run(grep, in: repo)
            #expect(!hardened.standardOutputString.contains("\u{1b}"), "grep output is free of ANSI escapes")
            let files = FileStatusCommands.parseGrepFiles(hardened.standardOutputString, revision: .workingDirectory, grepText: "needle")
            #expect(files.map(\.path) == ["match.txt"], "grep parser input stays clean: \(files.map(\.path))")
            let module = GitRepositoryModule(repositoryURL: repo)
            let state = try await module.loadRepositoryState()
            let worktree = RevisionCommitBuilder.artificialRevisions(headID: state.commitContext.headID).first { $0.kind == .workingDirectory }!
            let details = try await module.loadRevisionDetails(for: worktree)
            let diff = try await module.loadDiff(for: worktree, file: details.files.first { $0.path == "match.txt" }!, options: FileDiffOptions())
            #expect(
                diff?.lines.contains { $0.text.contains("\u{1b}") } == false && diff?.lines.contains { $0.kind == .addition } == true,
                "diff parser input stays clean")
        }

        private static func hostilePrefixes(key: String, value: String, marker: String) async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("prefix")
            try fixture.commit(repo, file: "f.txt", contents: "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")
            try "1\nchanged\n3\n4\n5\n6\n7\n8\n9\n10\n11\nlast\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["config", key, value], in: repo)
            #expect(try fixture.git(["diff"], in: repo).contains(marker), "control: hostile \(key) changes raw patch prefixes")
            let module = GitRepositoryModule(repositoryURL: repo)
            let state = try await module.loadRepositoryState()
            let worktree = RevisionCommitBuilder.artificialRevisions(headID: state.commitContext.headID).first { $0.kind == .workingDirectory }!
            let details = try await module.loadRevisionDetails(for: worktree)
            let file = details.files.first { $0.path == "f.txt" }!
            let diff = try await module.loadDiff(for: worktree, file: file, options: FileDiffOptions(contextLines: 1))
            let headers = diff?.lines.filter { $0.kind == .header }.map(\.text) ?? []
            #expect(headers.contains("--- a/f.txt") && headers.contains("+++ b/f.txt"), "\(key): parser sees standard a/ b/ prefixes: \(headers)")
            let firstChange = diff!.lines.first { $0.kind == .addition }!
            _ = try await module.applyHunk(RepositoryHunkSelection(file: file, diff: diff!, lineID: firstChange.id, direction: .stage))
            let staged = try fixture.git(["-c", "\(key)=false", "diff", "--cached", "-U0"], in: repo)
            #expect(staged.contains("+changed") && !staged.contains("+last"), "\(key): hunk staging applies only the selected hunk: \(staged)")
        }

        private static func shell(_ script: String) -> (GitProcess, GitCommand) {
            (
                GitProcess(executableURL: URL(fileURLWithPath: "/bin/sh")),
                GitCommand(arguments: ["-c", script], accessesRemote: false, changesRepositoryState: false)
            )
        }

        private static func processInput() async throws {
            let session = GitInteractiveSession { _ in nil }
            defer { session.close() }
            #expect(!session.send("nobody"), "send without a running process reports failure")
            let (process, command) = shell("IFS= read -r a; echo \"got:$a\"; IFS= read -r b; echo \"got:$b\"")
            let directory = FileManager.default.temporaryDirectory
            let task = Task { try await session.bind { try await process.run(command, in: directory) } }
            try await wait("stdin attached") { session.hasActiveInput }
            #expect(session.send("one") && session.send("two words"), "lines written while the process runs")
            let result = try await task.value
            #expect(result.standardOutputString == "got:one\ngot:two words\n", "each send is one terminated line: \(result.standardOutputString)")
            #expect(!session.hasActiveInput, "input detached after exit")

            let (closer, closing) = shell("exec 0<&-; sleep 0.4; echo done")
            let closedTask = Task { try await session.bind { try await closer.run(closing, in: directory) } }
            try await wait("stdin attached for the closing process") { session.hasActiveInput }
            try await Task.sleep(for: .milliseconds(150))
            #expect(!session.send("ignored"), "broken stdin reports failure without SIGPIPE")
            let closedOutput = try await closedTask.value.standardOutputString
            #expect(closedOutput == "done\n", "process completes normally after a broken-pipe send")

            let (explicit, explicitCommand) = shell("cat")
            let explicitResult = try await session.bind { try await explicit.run(explicitCommand, in: directory, standardInput: Data("given".utf8)) }
            #expect(explicitResult.standardOutputString == "given", "explicit standard input is preserved inside a session")

        }

        private static func processInputCancellation() async throws {
            let session = GitInteractiveSession { _ in nil }
            defer { session.close() }
            let (process, command) = shell("IFS= read -r a; echo \"$a\"")
            let task = Task { try await session.bind { try await process.run(command, in: FileManager.default.temporaryDirectory) } }
            try await wait("stdin attached before cancellation") { session.hasActiveInput }
            let started = ContinuousClock.now
            task.cancel()
            var cancelled = false
            do { _ = try await task.value } catch is CancellationError { cancelled = true }
            #expect(cancelled && ContinuousClock.now - started < .seconds(5), "cancellation terminates a process waiting on input")
            #expect(!session.hasActiveInput && !session.send("late"), "no input target after cancellation")
        }

        private static func processInputIsNotLogged() async throws {
            let session = GitInteractiveSession { _ in nil }
            defer { session.close() }
            let secret = "TopSecret-\(UUID().uuidString)"
            let (process, command) = shell("IFS= read -r a; echo received")
            let task = Task {
                try await ProcessOutputHistory.recording.withValue(true) {
                    try await session.bind { try await process.runStreaming(command, in: FileManager.default.temporaryDirectory) { _ in } }
                }
            }
            try await wait("stdin attached for logging check") { session.hasActiveInput }
            #expect(session.send(secret), "secret sent")
            let received = try await task.value.standardOutputString
            #expect(received == "received\n", "process consumed the secret")
            let logged = CommandLog.shared.snapshot().map { $0.commandLine }.joined(separator: "\n")
            let history = CommandLog.shared.outputHistorySnapshot().map(\.output).joined(separator: "\n")
            #expect(!logged.contains(secret) && !history.contains(secret), "sent input never reaches the command log or output history")
            #expect(history.contains("received"), "process output is still recorded")
        }

        private static func environment(_ session: GitInteractiveSession?) async throws -> [String: String] {
            let process = GitProcess(executableURL: URL(fileURLWithPath: "/usr/bin/env"))
            let command = GitCommand(arguments: [], accessesRemote: false, changesRepositoryState: false)
            let result = try await {
                if let session { return try await session.bind { try await process.run(command, in: FileManager.default.temporaryDirectory) } }
                return try await process.run(command, in: FileManager.default.temporaryDirectory)
            }()
            return Dictionary(
                result.standardOutputString.split(separator: "\n").compactMap { line -> (String, String)? in
                    let parts = line.split(separator: "=", maxSplits: 1)
                    return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
                }, uniquingKeysWith: { _, last in last })
        }

        private static func executionIntentEnvironment() async throws {
            let background = try await environment(nil)
            #expect(background["GIT_TERMINAL_PROMPT"] == "0", "background keeps terminal prompts disabled")
            #expect(
                background["SSH_ASKPASS"]?.contains("GitExtensionsMac-askpass") != true
                    && background["SSH_ASKPASS_REQUIRE"] == ProcessInfo.processInfo.environment["SSH_ASKPASS_REQUIRE"],
                "background execution receives no interactive prompt path")
            let session = GitInteractiveSession { _ in nil }
            let interactive = try await environment(session)
            guard let helper = session.askPassURL?.path else { throw Failure(errorDescription: "askpass helper created") }
            #expect(interactive["GIT_TERMINAL_PROMPT"] == "0", "interactive keeps terminal prompts disabled (askpass is the fallback)")
            #expect(interactive["SSH_ASKPASS"] == helper && interactive["SSH_ASKPASS_REQUIRE"] == "force", "interactive execution receives the askpass bridge")
            #expect(
                interactive["GIT_ASKPASS"] == ProcessInfo.processInfo.environment["GIT_ASKPASS"],
                "GIT_ASKPASS and core.askPass keep precedence over the fallback")
            let attributes = try FileManager.default.attributesOfItem(atPath: (helper as NSString).deletingLastPathComponent)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "askpass directory is private")
            let script = try String(contentsOfFile: helper, encoding: .utf8)
            #expect(script == GitAskPassBridge.script, "helper contains only the fixed bridge script")
            session.close()
            #expect(!FileManager.default.fileExists(atPath: helper), "helper removed when the session closes")
            let closed = try await environment(session)
            #expect(closed["SSH_ASKPASS"] != helper, "a closed session no longer offers askpass")
        }

        private actor PromptLog {
            var prompts: [GitCredentialPrompt] = []
            func add(_ prompt: GitCredentialPrompt) { prompts.append(prompt) }
        }

        private static let isolatedGit = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        private static let credentialRequest = Data("protocol=https\nhost=example.invalid\n\n".utf8)
        private static let credentialFill = GitCommand(arguments: ["credential", "fill"], accessesRemote: false, changesRepositoryState: false)

        private static func askPassCredential() async throws {
            let log = PromptLog()
            let session = GitInteractiveSession { prompt in
                await log.add(prompt)
                return prompt.isSecret ? "synthetic-secret" : "synthetic-user"
            }
            let directory = FileManager.default.temporaryDirectory
            var environment = isolatedGit
            environment["HOME"] = directory.path
            let result = try await session.bind {
                try await GitProcess().run(credentialFill, in: directory, standardInput: credentialRequest, environment: environment)
            }
            #expect(result.succeeded, "credential fill succeeds through askpass: \(result.standardErrorString)")
            #expect(
                result.standardOutputString.contains("username=synthetic-user\n") && result.standardOutputString.contains("password=synthetic-secret\n"),
                "synthetic credential returned to Git")
            let prompts = await log.prompts
            #expect(
                prompts.count == 2 && prompts[0].text.hasPrefix("Username for 'https://example.invalid'") && !prompts[0].isSecret
                    && prompts[1].text.hasPrefix("Password for 'https://synthetic-user@example.invalid'") && prompts[1].isSecret,
                "username is plain, password is secret: \(prompts)")
            let bridge = session.askPassURL!.deletingLastPathComponent()
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: bridge.path).sorted()
            #expect(leftovers == ["askpass.sh", "request"], "per-prompt files are removed: \(leftovers)")
            #expect(
                try String(contentsOf: bridge.appendingPathComponent("askpass.sh"), encoding: .utf8).contains("synthetic") == false, "no secret in the helper")
            session.close()
            #expect(!FileManager.default.fileExists(atPath: bridge.path), "bridge directory removed")

            let backgroundCalled = PromptLog()
            let unused = GitInteractiveSession { prompt in
                await backgroundCalled.add(prompt)
                return "x"
            }
            defer { unused.close() }
            let background = try await GitProcess().run(credentialFill, in: directory, standardInput: credentialRequest, environment: environment)
            #expect(
                !background.succeeded && background.standardErrorString.contains("terminal prompts disabled"),
                "background credential requests fail instead of prompting: \(background.standardErrorString)")
            let backgroundPrompts = await backgroundCalled.prompts
            #expect(backgroundPrompts.isEmpty, "no prompt reaches the UI outside an interactive session")
        }

        private static func askPassDismissalAndCancellation() async throws {
            let directory = FileManager.default.temporaryDirectory
            var environment = isolatedGit
            environment["HOME"] = directory.path
            let dismissed = GitInteractiveSession { _ in nil }
            defer { dismissed.close() }
            let result = try await dismissed.bind {
                try await GitProcess().run(credentialFill, in: directory, standardInput: credentialRequest, environment: environment)
            }
            #expect(!result.succeeded && !result.standardOutputString.contains("password="), "dismissing the prompt fails the Git command")

            let log = PromptLog()
            let hanging = GitInteractiveSession { prompt in
                await log.add(prompt)
                try? await Task.sleep(for: .seconds(60))
                return "too late"
            }
            defer { hanging.close() }
            let task = Task {
                try await hanging.bind { try await GitProcess().run(credentialFill, in: directory, standardInput: credentialRequest, environment: environment) }
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while await log.prompts.isEmpty {
                #expect(ContinuousClock.now < deadline, "prompt reached before cancellation")
                try await Task.sleep(for: .milliseconds(10))
            }
            let started = ContinuousClock.now
            task.cancel()
            var cancelled = false
            do { _ = try await task.value } catch is CancellationError { cancelled = true }
            #expect(cancelled && ContinuousClock.now - started < .seconds(5), "cancelling the operation ends a pending askpass prompt")
        }

        private static func sshAskPassHelper() async throws {
            let log = PromptLog()
            let session = GitInteractiveSession { prompt in
                await log.add(prompt)
                return "pass phrase with spaces"
            }
            defer { session.close() }
            _ = try await environment(session)
            let helper = GitProcess(executableURL: session.askPassURL!)
            let prompt = "Enter passphrase for key '/tmp/id_test': "
            let result = try await helper.run(
                GitCommand(arguments: [prompt], accessesRemote: false, changesRepositoryState: false), in: FileManager.default.temporaryDirectory)
            #expect(
                result.succeeded && result.standardOutputString == "pass phrase with spaces\n",
                "helper answers like ssh-askpass: \(result.standardOutputString)")
            let seen = await log.prompts
            #expect(seen == [GitCredentialPrompt(text: prompt)] && GitCredentialPrompt(text: prompt).isSecret, "passphrase prompt is secret")
            #expect(
                !GitCredentialPrompt(text: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ").isSecret,
                "host-key confirmation is plain text")
        }

        private static func processDialogPreferences() throws {
            #expect(!ProcessDialogPreferences().showPasswordInput, "ShowProcessDialogPasswordInput defaults to false")
            #expect(try JSONDecoder().decode(ProcessDialogPreferences.self, from: Data("{}".utf8)) == ProcessDialogPreferences(), "tolerant decoding")
            let suite = "GitExtensionsMac.GitExecutionTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            #expect(!store.processDialogPreferences.showPasswordInput, "fresh store default")
            var preferences = store.processDialogPreferences
            preferences.showPasswordInput = true
            store.saveProcessDialogPreferences(preferences)
            #expect(AppSettingsStore(defaults: defaults).processDialogPreferences.showPasswordInput, "preference persists")
        }

        private static func processInputController() async throws {
            let suite = "GitExecutionTests.controller.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let controller = ProcessInputController(store: store)
            let footer = NSStackView(views: [controller.toggle])
            let bottom = controller.bottomStack(footer: footer)
            window.contentView!.addSubview(bottom)
            controller.window = window
            #expect(controller.toggle.title == "Show password input" && controller.sendButton.title == "Send input", "upstream captions")
            #expect(controller.toggle.state == .off && controller.inputRow.isHidden, "hidden by default")
            controller.observeOutput("progress 10%\r")
            controller.observeOutput("complete line\n")
            #expect(controller.inputRow.isHidden, "complete lines and progress do not reveal the input")
            controller.observeOutput("Password: ")
            #expect(
                controller.toggle.state == .mixed && !controller.inputRow.isHidden && !store.processDialogPreferences.showPasswordInput,
                "an unterminated prompt reveals the input without persisting")
            controller.toggle.performClick(nil)
            #expect(controller.toggle.state == .off && controller.inputRow.isHidden && !store.processDialogPreferences.showPasswordInput, "mixed click hides")
            controller.toggle.performClick(nil)
            #expect(
                controller.toggle.state == .on && !controller.inputRow.isHidden && store.processDialogPreferences.showPasswordInput,
                "checking persists and shows")
            #expect(
                ProcessInputController(store: store).toggle.state == .on && !ProcessInputController(store: store).inputRow.isHidden, "next dialog restores it")
            #expect(controller.secureField.isHidden == false && controller.plainField.isHidden, "input is a secure field")
            controller.revealButton.performClick(nil)
            #expect(controller.secureField.isHidden && !controller.plainField.isHidden, "reveal toggles to plain text")
            controller.revealButton.performClick(nil)

            let (process, command) = shell("IFS= read -r a; echo \"got:$a\"")
            let task = Task { try await controller.perform { try await process.run(command, in: FileManager.default.temporaryDirectory) } }
            try await wait("controller session attached") { controller.session.hasActiveInput }
            controller.inputText = "typed value"
            controller.sendButton.performClick(nil)
            #expect(controller.inputText.isEmpty, "input cleared after send")
            let sent = try await task.value.standardOutputString
            #expect(sent == "got:typed value\n", "Send input writes to the running process")

            let directory = FileManager.default.temporaryDirectory
            var environment = isolatedGit
            environment["HOME"] = directory.path
            let credentialTask = Task {
                try await controller.perform {
                    try await GitProcess().run(credentialFill, in: directory, standardInput: credentialRequest, environment: environment)
                }
            }
            for (expectSecure, answer) in [(false, "sheet-user"), (true, "sheet-secret")] {
                try await wait("askpass prompt sheet shown") { window.attachedSheet != nil }
                let sheet = window.attachedSheet!
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let field = descendants(sheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "ProcessInput.prompt" }!
                #expect((field is NSSecureTextField) == expectSecure, "prompt field secureness matches the prompt")
                field.stringValue = answer
                descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
                try await wait("prompt sheet dismissed") { window.attachedSheet !== sheet }
            }
            let credential = try await credentialTask.value
            #expect(
                credential.standardOutputString.contains("username=sheet-user\n") && credential.standardOutputString.contains("password=sheet-secret\n"),
                "prompt sheets answer Git's credential prompts")
            let bridge = controller.session.askPassURL!.deletingLastPathComponent()
            controller.finish()
            #expect(controller.toggle.isHidden && controller.inputRow.isHidden && controller.inputText.isEmpty, "finish hides the input like FormStatus.Done")
            #expect(!FileManager.default.fileExists(atPath: bridge.path), "finish removes the askpass bridge")
            let persisted = defaults.persistentDomain(forName: suite) ?? [:]
            let dump = persisted.values.map { value -> String in
                if let data = value as? Data { return String(decoding: data, as: UTF8.self) }
                return "\(value)"
            }.joined()
            #expect(!dump.contains("sheet-secret") && !dump.contains("typed value"), "no secret in persisted settings")
        }

        private static func readRevisions(_ module: GitRepositoryModule) async throws -> [Commit] {
            let request = try await module.revisionReadRequest()
            var revisions: [Commit] = []
            for try await batch in await request.reader.read(request.context, batchSize: 200) { revisions += batch }
            return revisions
        }

        private final class RecordingRunner: GitCommandRunning, @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [[String]] = []
            private let base = GitProcess()
            var commands: [[String]] { lock.withLock { recorded } }

            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                lock.withLock { recorded.append(arguments) }
                return try await base.run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
            }

            func runStreaming(
                arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String],
                output: @escaping GitOutputHandler
            ) async throws -> GitCommandResult {
                lock.withLock { recorded.append(arguments) }
                return try await base.runStreaming(arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: output)
            }
        }

        private final class Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-GitExecution-\(UUID().uuidString)", isDirectory: true)

            init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            func remove() { try? FileManager.default.removeItem(at: root) }

            func repository(_ name: String) throws -> URL {
                let url = root.appendingPathComponent(name, isDirectory: true)
                try git(["init", "-q", "-b", "main", url.path], in: root)
                try git(["config", "user.name", "Execution Parity"], in: url)
                try git(["config", "user.email", "execution@example.com"], in: url)
                try git(["config", "commit.gpgsign", "false"], in: url)
                return url
            }

            func commit(_ repo: URL, file: String, contents: String) throws {
                try contents.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
                try git(["add", "--", file], in: repo)
                try git(["commit", "-q", "-m", "update \(file)"], in: repo)
            }

            func superprojectWithSubmodule() throws -> (URL, URL) {
                let child = try repository("child")
                try commit(child, file: "child.txt", contents: "child\n")
                let superproject = try repository("super")
                try commit(superproject, file: "super.txt", contents: "super\n")
                try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", "../child", "sub"], in: superproject)
                try git(["commit", "-q", "-m", "add sub"], in: superproject)
                let submodule = superproject.appendingPathComponent("sub", isDirectory: true)
                try git(["config", "user.name", "Execution Parity"], in: submodule)
                try git(["config", "user.email", "execution@example.com"], in: submodule)
                try git(["config", "commit.gpgsign", "false"], in: submodule)
                return (superproject, submodule)
            }

            @discardableResult
            func git(_ arguments: [String], in directory: URL) throws -> String {
                try run("/usr/bin/git", arguments, in: directory)
            }

            @discardableResult
            func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
                let process = FixtureProcess()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardOutput = output
                process.standardError = errors
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw Failure(errorDescription: "\(executable) \(arguments.joined(separator: " ")) failed: \(String(decoding: errorData, as: UTF8.self))")
                }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

typealias GitExecutionTests = UIIntegrationTests.GitExecutionTests
