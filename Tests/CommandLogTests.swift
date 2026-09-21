@testable import GitCommands
@testable import GitUI
import AppKit
import Foundation

enum CommandLogTests {
    static func run() async throws {
        await MainActor.run { verifyWordWrap() }
        let log = CommandLog()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let command = GitCommand(arguments: ["status", "--porcelain=v2"], accessesRemote: false, changesRepositoryState: false)
        let first = log.start(command, directory: directory)
        let second = log.start(command, directory: directory)
        log.finish(second, cancelled: true)
        log.finish(first, result: GitCommandResult(arguments: command.arguments, standardOutput: Data("out".utf8), standardError: Data("err".utf8), exitStatus: 1))
        precondition(log.snapshot().map(\.id) == [first, second])
        precondition(log.snapshot()[0].exitStatus == 1 && log.snapshot()[0].stdoutBytes == 3)
        precondition(log.snapshot()[1].cancelled)
        log.clear(); log.finish(first)
        precondition(log.snapshot().isEmpty)
        for _ in 0..<510 { _ = log.start(command, directory: directory) }
        precondition(log.snapshot().count == 499)
        let redacted = CommandLog.redacted(["-c", "http.extraHeader=Authorization: secret", "fetch", "https://user:secret@example.invalid/repo?token=secret", "--password", "secret"])
        precondition(!redacted.joined().contains("secret"))
        precondition(CommandLog.redacted(["config", "credential.helper", "secret"]) == ["config", "<redacted>", "<redacted>"])
        precondition(CommandLog.redacted(["-chttp.extraHeader=private", "https://user:private@example.invalid/repo"]).allSatisfy { !$0.contains("private") })
        let remote = log.start(GitCommand(arguments: ["fetch", "origin"], accessesRemote: true, changesRepositoryState: true), directory: directory)
        precondition(log.snapshot().last!.accessesRemote && log.snapshot().last!.mayChangeRepository)
        log.finish(remote)
        precondition(log.snapshot().last!.failedToExecute)
        CommandLog.shared.clear()
        let result = try await GitProcess().run(GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false), in: directory)
        precondition(result.succeeded)
        let captured = CommandLog.shared.snapshot()
        precondition(captured.count == 1 && captured[0].exitStatus == 0 && captured[0].processID != nil)
        precondition(captured[0].stdoutBytes == result.standardOutput.count)
        let streamed = try await GitProcess().runStreaming(GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false), in: directory) { _ in }
        precondition(streamed.succeeded && CommandLog.shared.snapshot().count == 2)
        let failure = try await GitProcess().run(GitCommand(arguments: ["not-a-real-git-command"], accessesRemote: false, changesRepositoryState: false), in: directory)
        precondition(!failure.succeeded && CommandLog.shared.snapshot().last?.exitStatus == failure.exitStatus)
        let sleeper = Task {
            try await GitProcess(executableURL: URL(fileURLWithPath: "/bin/sleep")).run(
                GitCommand(arguments: ["30"], accessesRemote: false, changesRepositoryState: false), in: directory)
        }
        for _ in 0..<100 {
            if CommandLog.shared.snapshot().last?.processID != nil && CommandLog.shared.snapshot().last?.arguments == ["30"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        sleeper.cancel()
        do { _ = try await sleeper.value; preconditionFailure("Cancelled process completed normally") }
        catch is CancellationError { }
        precondition(CommandLog.shared.snapshot().last?.cancelled == true)
        log.capturesCallStacks = true
        _ = log.start(command, directory: directory)
        precondition(!log.snapshot().last!.callStack.isEmpty)
        print("CommandLogTests: passed")
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
            precondition(scroll.hasHorizontalScroller && text.frame.width > scroll.contentSize.width)
            text.setWordWrap(true)
            precondition(!scroll.hasHorizontalScroller && abs(text.frame.width - scroll.contentSize.width) < 1)
            precondition(text.frame.height > text.font!.pointSize * 2)
            precondition(text.string == content)
        }
        scroll.setFrameSize(NSSize(width: 240, height: 150))
        scroll.layoutSubtreeIfNeeded()
        precondition(abs(text.frame.width - scroll.contentSize.width) < 1)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        precondition(text.layoutManager!.usedRect(for: text.textContainer!).width <= scroll.contentSize.width)
    }
}
