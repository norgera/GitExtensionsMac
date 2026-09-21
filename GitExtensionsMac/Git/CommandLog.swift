import Foundation

enum CommandLogContext {
    static let entryID = TaskLocal<UUID?>(wrappedValue: nil)
}

package struct CommandLogEntry: Sendable, Identifiable, Equatable {
    package let id: UUID
    package let startedAt: Date
    package let arguments: [String]
    package let directory: String
    package let accessesRemote: Bool
    package let mayChangeRepository: Bool
    package var executable = "git"
    package var processID: Int32?
    package var isOnMainThread = false
    fileprivate var startedUptime = ProcessInfo.processInfo.systemUptime
    package var duration: TimeInterval?
    package var exitStatus: Int32?
    package var cancelled = false
    package var failedToExecute = false
    package var stdoutBytes = 0
    package var stderrBytes = 0
    package var callStack: [String] = []

    package var commandLine: String {
        Self.quoted([executable] + arguments)
    }

    package var displayCommand: String {
        var skip = false
        let visible = arguments.filter { value in
            if skip { skip = false; return false }
            if value == "-c" { skip = true; return false }
            return value != "--no-optional-locks"
        }
        return Self.quoted(["git"] + visible)
    }

    private static func quoted(_ arguments: [String]) -> String {
        arguments.map { value in
            value.isEmpty || value.contains(where: { $0.isWhitespace || "'\"\\;$`".contains($0) })
                ? "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" : value
        }.joined(separator: " ")
    }
}

package final class CommandLog: @unchecked Sendable {
    package static let shared = CommandLog()
    private let lock = NSLock()
    private var entries: [CommandLogEntry] = []
    private var captureStacks = false
    package var capturesCallStacks: Bool {
        get { lock.lock(); defer { lock.unlock() }; return captureStacks }
        set { lock.lock(); defer { lock.unlock() }; captureStacks = newValue }
    }

    package init() {}

    package func snapshot() -> [CommandLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    package func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    package func start(_ command: GitCommand, directory: URL) -> UUID {
        var entry = CommandLogEntry(id: UUID(), startedAt: Date(),
                                    arguments: Self.redacted(command.arguments),
                                    directory: directory.path,
                                    accessesRemote: command.accessesRemote,
                                    mayChangeRepository: command.changesRepositoryState)
        if capturesCallStacks { entry.callStack = Thread.callStackSymbols }
        entry.isOnMainThread = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count >= 500 { entries.removeFirst(entries.count - 499) }
        return entry.id
    }

    package func finish(_ id: UUID, result: GitCommandResult? = nil, cancelled: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].duration = ProcessInfo.processInfo.systemUptime - entries[index].startedUptime
        entries[index].exitStatus = result?.exitStatus
        entries[index].cancelled = cancelled
        entries[index].failedToExecute = result == nil && !cancelled
        entries[index].stdoutBytes = result?.standardOutput.count ?? 0
        entries[index].stderrBytes = result?.standardError.count ?? 0
    }

    func processStarted(_ id: UUID?, executable: URL, pid: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].executable = executable.path
        entries[index].processID = pid
    }

    package static func redacted(_ arguments: [String]) -> [String] {
        var hideNext = false
        let isConfig = arguments.contains("config")
        return arguments.map { argument in
            if hideNext { hideNext = false; return "<redacted>" }
            if ["-c", "--config-env", "--password", "--token", "--access-token", "--header", "--extcmd", "--exec"].contains(argument) {
                hideNext = true
                return argument
            }
            if isConfig && argument != "config" && !argument.hasPrefix("-") { return "<redacted>" }
            let lower = argument.lowercased()
            if argument.hasPrefix("-c") && argument.count > 2 { return "-c<redacted>" }
            if lower.contains("password=") || lower.contains("token=") || lower.contains("authorization") || lower.contains("extraheader") || lower.hasPrefix("--extcmd=") || lower.hasPrefix("--exec=") {
                return "<redacted>"
            }
            if argument.contains("://") {
                guard var url = URLComponents(string: argument) else { return "<redacted URL>" }
                url.user = nil; url.password = nil
                if url.query != nil { url.query = "redacted" }
                url.fragment = nil
                return url.string ?? "<redacted URL>"
            }
            return argument
        }
    }
}
