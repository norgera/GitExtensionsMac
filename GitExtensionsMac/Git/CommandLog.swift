import Foundation

enum CommandLogContext {
    static let entryID = TaskLocal<UUID?>(wrappedValue: nil)
}

package enum ProcessOutputHistory {
    package static let recording = TaskLocal<Bool>(wrappedValue: false)
    package static var recordsOutput: Bool { recording.wrappedValue }
}

package struct ProcessOutputRecord: Sendable, Equatable {
    package let command: CommandLogEntry
    package let finishedAt: Date
    package let output: String
}

package struct CommandLogEntry: Sendable, Identifiable, Equatable {
    package let id: UUID
    package let startedAt: Date
    package let arguments: [String]
    package let directory: String
    package let accessesRemote: Bool
    package let mayChangeRepository: Bool
    package var executable = "git"
    package var isGit = true
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
        if !isGit { return commandLine }
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
    private var outputDepth = 20
    private var outputRecords: [ProcessOutputRecord] = []
    private var pendingOutput: [UUID: Data] = [:]
    private var outputCommands: [UUID: CommandLogEntry] = [:]
    private var outputSecrets: [UUID: [String]] = [:]
    private var outputObservers: [UUID: @Sendable () -> Void] = [:]

    package func setOutputHistoryDepth(_ depth: Int) {
        lock.lock()
        outputDepth = max(0, depth)
        let previousCount = outputRecords.count
        if outputRecords.count > outputDepth { outputRecords.removeFirst(outputRecords.count - outputDepth) }
        let observers = previousCount == outputRecords.count ? [] : Array(outputObservers.values)
        lock.unlock()
        observers.forEach { $0() }
    }

    package func outputHistorySnapshot() -> [ProcessOutputRecord] {
        lock.lock(); defer { lock.unlock() }; return outputRecords
    }
    package func clearOutputHistory() {
        lock.lock(); outputRecords.removeAll(); let observers = Array(outputObservers.values); lock.unlock()
        observers.forEach { $0() }
    }
    package func observeOutputHistory(_ changed: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }; let id = UUID(); outputObservers[id] = changed; return id
    }
    package func removeOutputHistoryObserver(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; outputObservers[id] = nil
    }
    func appendOutput(_ id: UUID, event: GitOutputEvent) {
        lock.lock(); defer { lock.unlock() }
        guard pendingOutput[id] != nil else { return }
        pendingOutput[id]?.append(event.data)
    }
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

    package func start(_ command: GitCommand, directory: URL, recordsOutput: Bool = false, environment: [String: String] = [:]) -> UUID {
        startEntry(arguments: command.arguments, directory: directory, executable: "git", isGit: true,
            accessesRemote: command.accessesRemote, mayChangeRepository: command.changesRepositoryState,
            recordsOutput: recordsOutput, environment: environment)
    }

    package func startProcess(executable: URL, arguments: [String], directory: URL, environment: [String: String]) -> UUID {
        startEntry(arguments: arguments, directory: directory, executable: executable.path, isGit: false,
            accessesRemote: false, mayChangeRepository: false, recordsOutput: true, environment: environment)
    }

    private func startEntry(arguments: [String], directory: URL, executable: String, isGit: Bool,
                            accessesRemote: Bool, mayChangeRepository: Bool, recordsOutput: Bool, environment: [String: String]) -> UUID {
        var entry = CommandLogEntry(id: UUID(), startedAt: Date(),
                                    arguments: Self.redacted(arguments),
                                    directory: directory.path,
                                    accessesRemote: accessesRemote,
                                    mayChangeRepository: mayChangeRepository)
        entry.executable = executable
        entry.isGit = isGit
        if capturesCallStacks { entry.callStack = Thread.callStackSymbols }
        entry.isOnMainThread = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if recordsOutput && outputDepth > 0 {
            pendingOutput[entry.id] = Data()
            outputCommands[entry.id] = entry
            var secrets = zip(arguments, entry.arguments).filter { $0 != $1 }.flatMap { original, _ -> [String] in
                var values = [original]
                if let equal = original.firstIndex(of: "=") { values.append(String(original[original.index(after: equal)...])) }
                if let url = URLComponents(string: original), original.contains("://") {
                    if let password = url.password { values.append(password) }
                    values += (url.queryItems ?? []).compactMap(\.value)
                }
                return values
            }
            secrets += environment.filter { key, _ in
                ["TOKEN", "PASSWORD", "SECRET", "AUTHORIZATION"].contains { key.uppercased().contains($0) }
            }.map(\.value)
            outputSecrets[entry.id] = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        }
        if entries.count >= 500 { entries.removeFirst(entries.count - 499) }
        return entry.id
    }

    package func finish(_ id: UUID, result: GitCommandResult? = nil, cancelled: Bool = false, errorDescription: String? = nil) {
        lock.lock()
        guard var entry = entries.first(where: { $0.id == id }) ?? outputCommands[id] else { lock.unlock(); return }
        entry.duration = ProcessInfo.processInfo.systemUptime - entry.startedUptime
        entry.exitStatus = result?.exitStatus
        entry.cancelled = cancelled
        entry.failedToExecute = result == nil && !cancelled
        entry.stdoutBytes = result?.standardOutput.count ?? 0
        entry.stderrBytes = result?.standardError.count ?? 0
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry }
        var observers: [@Sendable () -> Void] = []
        if let captured = pendingOutput.removeValue(forKey: id) {
            outputCommands[id] = nil
            let bytes = captured.isEmpty ? (result?.standardOutput ?? Data()) + (result?.standardError ?? Data()) : captured
            var text = Self.redactedOutput(String(decoding: bytes, as: UTF8.self))
            if cancelled { text += "\nAborted\n" }
            else if result == nil { text += "\n" + Self.redactedOutput(errorDescription ?? "Process could not be started") + "\n" }
            for secret in outputSecrets.removeValue(forKey: id) ?? [] { text = text.replacingOccurrences(of: secret, with: "<redacted>") }
            if outputDepth > 0 {
                outputRecords.append(.init(command: entry, finishedAt: Date(), output: text))
                if outputRecords.count > outputDepth { outputRecords.removeFirst(outputRecords.count - outputDepth) }
                observers = Array(outputObservers.values)
            }
        }
        lock.unlock()
        observers.forEach { $0() }
    }

    func processStarted(_ id: UUID?, executable: URL, pid: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].executable = executable.path
        entries[index].processID = pid
        if outputCommands[id] != nil { outputCommands[id] = entries[index] }
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

    package static func redactedOutput(_ value: String) -> String {
        var text = value
        for (pattern, replacement) in [
            (#"(?i)\b(https?|ssh|git)://[^\s/@]+(?::[^\s/@]*)?@"#, "$1://<redacted>@"),
            (#"(?i)([?&](?:access_token|token|password|key|signature)=)[^\s&#]+"#, "$1<redacted>"),
            (#"(?im)(authorization\s*[:=]\s*)[^\r\n]+"#, "$1<redacted>"),
            (#"(?i)((?:password|access[_-]?token|token)\s*[=:]\s*)[^\s]+"#, "$1<redacted>")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }
}
