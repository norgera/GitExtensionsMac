import Foundation
import GitExtensionsCore
@testable import GitCommands
@testable import GitUI

enum ApplicationScriptsTests {
    private static func expect(_ value: Bool, line: UInt = #line) { precondition(value, "Scripts expectation failed at line \(line)") }
    static func run() async throws {
        try expect(ScriptExecution.arguments(#"one 'two three' "four five" '' a\ b"#) == ["one", "two three", "four five", "", "a b"])
        try expect(ScriptExecution.arguments(#""C:\work\file""#) == [#"C:\work\file"#])
        do { _ = try ScriptExecution.arguments("'unfinished"); preconditionFailure() }
        catch ScriptExecutionError.invalidArguments { }
        let options = ["WorkingDir": ["/tmp/a b/"], "sHashes": ["one", "two"], "value": ["it's {WorkingDir}"]]
        try expect(ScriptExecution.arguments(ScriptExecution.expand("{{WorkingDir}} {{sHashes}} {{value}}", options: options)) == ["/tmp/a b/", "one", "two", "it's {WorkingDir}"])
        precondition(ScriptExecution.expand("{{value}}", options: options, powerShell: true) == "'it''s {WorkingDir}'")
        precondition(ScriptExecution.revisionArgument(.workingDirectory) == String(repeating: "1", count: 40))
        precondition(ScriptExecution.revisionArgument(.index) == String(repeating: "2", count: 40))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        var script = ScriptDefinition(); script.command = "/usr/bin/printf"
        script.arguments = "'%s' 'spaces Unicode λ; $(not-executed)'"
        let invocation = try ScriptExecution.invocation(script, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"))
        let result = try await ScriptExecution.run(invocation, output: { _ in })
        precondition(result.succeeded && result.standardOutputString == "spaces Unicode λ; $(not-executed)")
        script.command = "/bin/sh"; script.arguments = "-c 'printf out; printf err >&2; exit 7'"
        let failing = try await ScriptExecution.run(ScriptExecution.invocation(script, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git")), output: { _ in })
        precondition(failing.exitStatus == 7 && failing.standardOutputString == "out" && failing.standardErrorString == "err")
        script.command = "/usr/bin/env"; script.arguments = ""
        let environment = try ScriptExecution.invocation(script, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"), environment: ["SCRIPT_TEST_VALUE": "a b λ"])
        let envResult = try await ScriptExecution.run(environment, output: { _ in })
        precondition(envResult.standardOutputString.contains("SCRIPT_TEST_VALUE=a b λ"))
        script.command = "/bin/pwd"
        let pwd = try await ScriptExecution.run(ScriptExecution.invocation(script, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git")), output: { _ in })
        precondition(URL(fileURLWithPath: pwd.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
        script.command = "/bin/sleep"; script.arguments = "30"
        let sleeper = try ScriptExecution.invocation(script, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"))
        let task = Task { try await ScriptExecution.run(sleeper, output: { _ in }) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation ignored") } catch is CancellationError { }
        script.arguments = "{sHash}"
        do { _ = try ScriptExecution.invocation(script, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git")); preconditionFailure() }
        catch ScriptExecutionError.missingOption { }
        let marker = directory.appendingPathComponent("ScriptsBackground-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: marker) }
        let background = ScriptInvocation(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.2; printf done > \"$1\"", "script", marker.path],
            workingDirectory: directory, environment: [:])
        guard case .started(let pid) = try await ScriptExecution.startBackground(background) else { preconditionFailure() }
        precondition(pid > 0 && !FileManager.default.fileExists(atPath: marker.path))
        for _ in 0..<100 {
            if (try? String(contentsOf: marker, encoding: .utf8)) == "done" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(String(contentsOf: marker, encoding: .utf8) == "done")
        let invalidBackground = ScriptInvocation(executable: URL(fileURLWithPath: "/no-such-script-executable"),
            arguments: [], workingDirectory: directory, environment: [:])
        do { _ = try await ScriptExecution.startBackground(invalidBackground); preconditionFailure("Launch failure hidden") }
        catch GitError.executableUnavailable { }
        try await persistenceAndOrdering()
        var powershell = ScriptDefinition()
        powershell.isPowerShell = true; powershell.command = "Write-Output"; powershell.arguments = "'hello λ'"
        let shellDirectory = directory.appendingPathComponent("ScriptsPowerShell-\(UUID())")
        try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shellDirectory) }
        let shellPath = shellDirectory.appendingPathComponent("pwsh")
        try FileManager.default.createSymbolicLink(at: shellPath, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let terminal = try ScriptExecution.invocation(powershell, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"), environment: ["PATH": shellDirectory.path])
        precondition(terminal.executable.path == "/usr/bin/open" && terminal.arguments.prefix(2) == ["-a", "Terminal"])
        let launcher = URL(fileURLWithPath: terminal.arguments[2])
        let contents = try String(contentsOf: launcher, encoding: .utf8)
        precondition(contents.contains("'-NoExit'") && contents.contains("'-Command'") && contents.contains("hello λ"))
        try FileManager.default.removeItem(at: launcher)
        powershell.runInBackground = true
        let detached = try ScriptExecution.invocation(powershell, directory: directory, options: [:], gitExecutable: URL(fileURLWithPath: "/usr/bin/git"), environment: ["PATH": shellDirectory.path])
        precondition(detached.executable == shellPath && !detached.arguments.contains("-NoExit"))
        precondition(detached.arguments.last == "Write-Output 'hello λ'")
        try await repositoryContextAndHookPlacement()
        print("ApplicationScriptsTests: passed")
    }

    private static func repositoryContextAndHookPlacement() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScriptsRepository-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = GitProcess()
        @Sendable func command(_ arguments: [String]) async throws -> String {
            let result = try await git.run(arguments: arguments, in: directory)
            precondition(result.succeeded, result.standardErrorString)
            return result.standardOutputString.trimmingCharacters(in: .newlines)
        }
        _ = try await command(["init", "-b", "main"])
        _ = try await command(["config", "user.name", "Scripts Test"])
        _ = try await command(["config", "user.email", "scripts@example.test"])
        _ = try await command(["commit", "--allow-empty", "-m", "Initial"])
        let head = try await command(["rev-parse", "HEAD"])
        _ = try await command(["branch", "other"])
        _ = try await command(["tag", "-a", "-m", "Tag", "v1"])
        let module = GitRepositoryModule(repositoryURL: directory)
        _ = try await module.loadRepositoryState()
        let context = try await module.scriptContext(selected: [try .init(parsing: head)], arguments: "{HEAD} {sHash} {cTag}")
        precondition(context["HEAD"] == ["main"] && context["sHash"] == [head] && context["cTag"] == ["v1"])
        let resolved = try await module.scriptRevision("main")
        try expect(resolved == ObjectID(parsing: head))
        _ = try await command(["remote", "add", "team/origin", directory.path])
        _ = try await command(["update-ref", "refs/remotes/team/origin/main", head])
        let remoteContext = try await module.scriptContext(selected: [resolved], arguments: "{sRemote} {sRemoteBranchName}")
        precondition(remoteContext["sRemote"] == ["team/origin"] && remoteContext["sRemoteBranchName"] == ["main"])
        let multiContext = try await module.scriptContext(selected: [resolved, resolved], arguments: "{{sHashes}}")
        try expect(ScriptExecution.arguments(ScriptExecution.expand("{{sHashes}}", options: multiContext)) == [head + " " + head])
        try "change".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let commit = RepositoryCommitRequest(message: "Script placement", mode: .normal, stageAllBeforeCommit: true,
            allowEmpty: false, signOff: false, author: nil, resetAuthor: false)
        do {
            _ = try await module.commit(commit, beforeExecution: {
                let staged = try await command(["diff", "--cached", "--name-only"])
                precondition(staged == "file.txt", "BeforeCommit must see automatic staging")
                throw CancellationError()
            })
            preconditionFailure("BeforeCommit cancellation ignored")
        } catch is CancellationError { }
        let unchanged = try await command(["rev-parse", "HEAD"])
        precondition(unchanged == head)
        do {
            _ = try await module.checkout(RepositoryCheckoutRequest(target: .localBranch("other"), localChanges: .stash(includeUntracked: true, reapply: false)), beforeExecution: {
                let status = try await command(["status", "--porcelain"])
                let stash = try await command(["stash", "list"])
                precondition(status.isEmpty && !stash.isEmpty, "BeforeCheckout must run after autostash")
                throw CancellationError()
            })
            preconditionFailure("BeforeCheckout cancellation ignored")
        } catch is CancellationError { }
        let branch = try await command(["branch", "--show-current"])
        precondition(branch == "main")
        _ = try await command(["stash", "pop"])
        _ = try await command(["add", "file.txt"])
        _ = try await command(["commit", "-m", "Tracked file"])
        try "dirty".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await module.performPull(.init(source: .url(directory.path), mode: .merge,
                remoteBranch: "main", autoStash: true), beforeExecution: {
                    let status = try await command(["status", "--porcelain"])
                    let stash = try await command(["stash", "list"])
                    precondition(status.isEmpty && !stash.isEmpty, "BeforePull/Fetch must see automatic stash")
                    throw CancellationError()
                }, output: { _ in })
            preconditionFailure("BeforePull cancellation ignored")
        } catch is CancellationError { }
    }

    @MainActor private static func persistenceAndOrdering() async throws {
        var refreshes = 0
        let notifier = RepositoryChangedNotifier { refreshes += 1 }
        let hooks = ApplicationScriptHooks(begin: { notifier.lock() },
            end: { notifier.unlock(requestNotify: false) }, run: { _ in notifier.notify(); return true })
        hooks.begin()
        _ = await hooks.run(.beforeCommit)
        notifier.notify()
        _ = await hooks.run(.afterCommit)
        precondition(refreshes == 0)
        hooks.end()
        precondition(refreshes == 1)
        var prompt = ScriptDefinition()
        do {
            try ScriptExecution.validateContext("{UserInput:Target={sHash}}", options: [:], beforePrompts: true)
            preconditionFailure("Missing nested revision context was not rejected before prompting")
        } catch ScriptExecutionError.missingOption("sHash") { }
        prompt.arguments = "{{UserInput:Target={cLocalBranch}}} {{UserInput:Target}}"
        var promptCalls = 0
        let resolved = await ScriptPrompts.resolve(prompt, options: ["cLocalBranch": ["main"]], input: { label, initial in
            promptCalls += 1
            precondition(label == "Target" && initial == "main")
            return "a b"
        }, files: { preconditionFailure("Unexpected file prompt") })
        precondition(promptCalls == 1)
        try expect(ScriptExecution.arguments(resolved!.arguments) == ["a b", "a b"])
        let cancelled = await ScriptPrompts.resolve(prompt, options: [:], input: { _, _ in nil }, files: { nil })
        precondition(cancelled == nil)
        prompt.arguments = "{UserFiles}"
        let filePrompt = await ScriptPrompts.resolve(prompt, options: [:], input: { _, _ in preconditionFailure() }, files: {
            [URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/tmp/λ")]
        })
        try expect(ScriptExecution.arguments(filePrompt!.arguments) == ["/tmp/a b", "/tmp/λ"])
        let suite = "ApplicationScriptsTests.\(UUID())"
        var menuScript = ScriptDefinition()
        menuScript.onEvent = .showInUserMenuBar
        precondition(ApplicationScriptsMenu.includes(menuScript, placement: .toolbar))
        precondition(!ApplicationScriptsMenu.includes(menuScript, placement: .files))
        menuScript.addToRevisionGridContextMenu = true
        precondition(ApplicationScriptsMenu.includes(menuScript, placement: .revisions))
        menuScript.enabled = false
        precondition(!ApplicationScriptsMenu.includes(menuScript, placement: .revisions))
        menuScript.enabled = true; menuScript.onEvent = .showInFileList
        precondition(ApplicationScriptsMenu.includes(menuScript, placement: .files))
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationScriptsStore(defaults: defaults)
        try expect(store.load().allSatisfy { !$0.enabled })
        var first = ScriptDefinition(); first.name = "first"; first.onEvent = .beforeCommit
        var second = first; second.id = UUID(); second.name = "second"
        var third = first; third.id = UUID(); third.name = "third"
        try store.save([first, second, third])
        let loaded = try ApplicationScriptsStore(defaults: defaults).load()
        precondition(loaded.map(\.name) == ["first", "second", "third"])
        precondition(Set(loaded.map(\.hotkeyCommandIdentifier)).count == 3)
        var executed: [String] = []
        let success = try await ApplicationScriptEvents.run(.beforeCommit, scripts: loaded) { script in
            executed.append(script.name); return script.name != "second"
        }
        precondition(!success && executed == ["first", "second"])
        executed = []
        let after = try await ApplicationScriptEvents.run(.afterCommit, scripts: loaded) { script in executed.append(script.name); return true }
        precondition(after && executed.isEmpty)
        try store.save([]); try expect(store.load().isEmpty)
        defaults.set(Data("invalid".utf8), forKey: "GitExtensionsMac.applicationScripts.v1")
        do { _ = try store.load(); preconditionFailure("Corrupt preferences silently replaced") }
        catch is DecodingError { }
    }
}
