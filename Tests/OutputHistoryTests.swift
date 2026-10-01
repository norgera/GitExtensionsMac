@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit

@MainActor
enum OutputHistoryTests {
    static func run() async throws {
        let journal = CommandLog()
        journal.setOutputHistoryDepth(2)
        let directory = URL(fileURLWithPath: "/private/tmp")
        let command = GitCommand(arguments: ["fetch", "https://name:secret@example.invalid/r?token=fixture"], accessesRemote: true, changesRepositoryState: true)
        let id = journal.start(command, directory: directory, recordsOutput: true)
        journal.appendOutput(id, event: .init(stream: .standardOutput, data: Data("first\n".utf8)))
        journal.appendOutput(id, event: .init(stream: .standardError, data: Data("second\nhttps://name:secret@example.invalid/r?token=fixture\n".utf8)))
        journal.finish(id, result: .init(arguments: command.arguments, standardOutput: Data("first\n".utf8), standardError: Data("second\n".utf8), exitStatus: 1))
        let record = journal.outputHistorySnapshot()[0]
        precondition(record.output.hasPrefix("first\nsecond\n"))
        precondition(!record.output.contains("secret") && !record.output.contains("fixture"))
        precondition(record.command.exitStatus == 1 && record.command.duration != nil)
        precondition(!record.command.commandLine.contains("secret"))
        let background = journal.start(command, directory: directory)
        journal.finish(background, result: .init(arguments: [], standardOutput: Data(), standardError: Data(), exitStatus: 0))
        precondition(journal.outputHistorySnapshot().count == 1)
        let cancelled = journal.start(command, directory: directory, recordsOutput: true)
        journal.appendOutput(cancelled, event: .init(stream: .standardError, data: Data("before abort\n".utf8)))
        journal.finish(cancelled, cancelled: true)
        precondition(journal.outputHistorySnapshot().last!.output.contains("before abort\n\nAborted"))
        precondition(journal.outputHistorySnapshot().last!.command.cancelled)
        let failed = journal.start(command, directory: directory, recordsOutput: true)
        journal.finish(failed, errorDescription: "launch error")
        precondition(journal.outputHistorySnapshot().count == 2)
        precondition(journal.outputHistorySnapshot().first!.command.id == cancelled)
        precondition(journal.outputHistorySnapshot().last!.output.contains("launch error"))
        let view = OutputHistoryViewController(journal: journal)
        _ = view.view
        precondition(view.textView.string.hasSuffix("###\n"))
        view.textView.setSelectedRange(.init(location: 0, length: 0))
        precondition(view.textView.copyContent == view.textView.string)
        view.textView.setSelectedRange(.init(location: 0, length: 4))
        precondition(view.textView.copyContent == String(view.textView.string.prefix(4)))
        let ansiID = journal.start(command, directory: directory, recordsOutput: true)
        journal.finish(ansiID, result: .init(arguments: [], standardOutput: Data("\u{1b}[31mred\u{1b}[0m\rprogress\u{000B}done\n".utf8), standardError: Data(), exitStatus: 0))
        precondition(OutputHistoryViewController.format(journal.outputHistorySnapshot()).contains("red\nprogress\ndone"))
        journal.clearOutputHistory(); view.reload()
        precondition(view.textView.string == "###\n" && journal.snapshot().count > 0)
        journal.setOutputHistoryDepth(0)
        let disabled = journal.start(command, directory: directory, recordsOutput: true)
        journal.finish(disabled, cancelled: true)
        precondition(journal.outputHistorySnapshot().isEmpty)

        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n"); try fixture.commitAll("base")
        let shared = CommandLog.shared
        shared.clearOutputHistory(); shared.setOutputHistoryDepth(20)
        let git = GitProcess()
        let version = GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false)
        _ = try await git.runStreaming(version, in: fixture.repo, output: { _ in })
        precondition(shared.outputHistorySnapshot().isEmpty)
        try await OutputHistoryRecording.perform {
            _ = try await git.runStreaming(version, in: fixture.repo, output: { _ in })
        }
        precondition(shared.outputHistorySnapshot().count == 1)
        precondition(shared.outputHistorySnapshot()[0].output.contains("git version"))
        precondition(!ProcessOutputHistory.recordsOutput)
        let slow = GitProcess(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let task = Task {
            try await OutputHistoryRecording.perform {
                try await slow.runStreaming(GitCommand(arguments: ["10"], accessesRemote: false, changesRepositoryState: false), in: fixture.repo, output: { _ in })
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        precondition(shared.outputHistorySnapshot().last!.command.cancelled)
        let beforeFailure = shared.outputHistorySnapshot().count
        try await OutputHistoryRecording.perform {
            let result = try await git.runStreaming(GitCommand(arguments: ["not-a-git-command"], accessesRemote: false, changesRepositoryState: false), in: fixture.repo, output: { _ in })
            precondition(!result.succeeded)
        }
        precondition(shared.outputHistorySnapshot().count == beforeFailure + 1)
        precondition(shared.outputHistorySnapshot().last!.output.contains("not-a-git-command"))
        let scriptCount = shared.outputHistorySnapshot().count
        try await OutputHistoryRecording.perform {
            _ = try await ScriptExecution.run(.init(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["foreground script\\n"], workingDirectory: fixture.repo, environment: [:]), output: { _ in })
        }
        precondition(shared.outputHistorySnapshot().count == scriptCount + 1)
        precondition(shared.outputHistorySnapshot().last!.command.executable == "/usr/bin/printf")
        precondition(shared.outputHistorySnapshot().last!.output == "foreground script\n")
        let old = AppSettingsStore.shared.preferences
        let oldLayout = AppSettingsStore.shared.browserLayoutPreferences
        defer {
            AppSettingsStore.shared.save(old)
            AppSettingsStore.shared.saveBrowserLayoutPreferences(oldLayout)
            shared.clearOutputHistory()
        }
        var preferences = old
        preferences.showOutputHistoryAsTab = true; preferences.outputHistoryDepth = 20
        AppSettingsStore.shared.save(preferences)
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: git)
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentViewController: browser)
        window.setContentSize(.init(width: 1200, height: 800)); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let previousPull = AppSettingsStore.shared.pullPreferences
        var autoClosePull = previousPull; autoClosePull.closeProcessOnSuccess = true
        AppSettingsStore.shared.savePullPreferences(autoClosePull)
        defer { AppSettingsStore.shared.savePullPreferences(previousPull) }
        let beforeDialog = shared.outputHistorySnapshot().count
        let succeeded = await HostingProcessDialog.run("Output fixture", window) { output in
            try await git.runStreaming(version, in: fixture.repo, output: output).succeeded
        }
        precondition(succeeded && shared.outputHistorySnapshot().count == beforeDialog + 1)
        browser.uiCommands.startOutputHistory()
        precondition(browser.outputHistoryPresentation.enabled && browser.outputHistoryPresentation.tab)
        precondition(window.firstResponder === browser.outputHistoryController.textView)
        preferences.showOutputHistoryAsTab = false; preferences.outputHistoryPanelVisible = false
        AppSettingsStore.shared.save(preferences)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!browser.outputHistoryPresentation.tab && !browser.outputHistoryPresentation.panelVisible)
        browser.uiCommands.startOutputHistory()
        precondition(browser.outputHistoryPresentation.panelVisible)
        precondition(window.firstResponder === browser.outputHistoryController.textView)
        browser.performTopLevelCommand(.focusNextTab(true))
        try await Task.sleep(for: .milliseconds(150))
        browser.view.layoutSubtreeIfNeeded()
        func descendants(_ root: NSViewController) -> [NSViewController] { [root] + root.children.flatMap(descendants) }
        let diff = descendants(browser).compactMap { $0 as? RevisionDiffViewController }.first { $0.mode == .diff }!
        let panelFrame = browser.view.convert(browser.outputHistoryController.view.bounds, from: browser.outputHistoryController.view)
        let filesFrame = browser.view.convert(diff.filesController.view.bounds, from: diff.filesController.view)
        precondition(abs(panelFrame.maxX - filesFrame.maxX) < 2, "Output panel spans the tree and file-list column")
        precondition(filesFrame.minY >= panelFrame.maxY - 2, "File list reserves the output panel height")
        browser.uiCommands.startOutputHistory()
        precondition(!browser.outputHistoryPresentation.panelVisible)
        preferences.outputHistoryDepth = 0
        AppSettingsStore.shared.save(preferences)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!browser.outputHistoryPresentation.enabled)
        let suite = "OutputHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        precondition(store.preferences.outputHistoryDepth == 20 && store.preferences.showOutputHistoryAsTab && !store.preferences.outputHistoryPanelVisible)
        var saved = store.preferences; saved.outputHistoryDepth = 3; saved.showOutputHistoryAsTab = false; saved.outputHistoryPanelVisible = true
        store.save(saved)
        precondition(AppSettingsStore(defaults: defaults).preferences == saved)
        precondition(ApplicationHotkeys.definitions.contains { $0.id == "focus.output" && $0.defaultChord == .init("9", .control) })
        print("OutputHistoryTests: passed")
    }
}
