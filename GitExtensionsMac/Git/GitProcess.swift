import GitExtensionsCore
import Darwin
import Foundation

package struct GitCommand: Sendable, Equatable {
    package enum ExecutionClass: Sendable, Equatable {
        case local
        case remote
    }

    package let arguments: [String]
    package let accessesRemote: Bool
    package let changesRepositoryState: Bool

    package init(arguments: [String], accessesRemote: Bool, changesRepositoryState: Bool) {
        self.arguments = arguments
        self.accessesRemote = accessesRemote
        self.changesRepositoryState = changesRepositoryState
    }

    package var executionClass: ExecutionClass { accessesRemote ? .remote : .local }
}

package struct GitCommandResult: Sendable {
    package let arguments: [String]
    package let standardOutput: Data
    package let standardError: Data
    package let exitStatus: Int32
    package let executionClass: GitCommand.ExecutionClass

    package init(
        arguments: [String],
        standardOutput: Data,
        standardError: Data,
        exitStatus: Int32,
        executionClass: GitCommand.ExecutionClass = .local
    ) {
        self.arguments = arguments
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitStatus = exitStatus
        self.executionClass = executionClass
    }

    package var succeeded: Bool { exitStatus == 0 }
    package var standardOutputString: String { String(decoding: standardOutput, as: UTF8.self) }
    package var standardErrorString: String { String(decoding: standardError, as: UTF8.self) }
}

package enum GitOutputStream: Sendable {
    case standardOutput
    case standardError
}

package struct GitOutputEvent: Sendable {
    package let stream: GitOutputStream
    package let data: Data

    package var text: String { String(decoding: data, as: UTF8.self) }
}

package typealias GitOutputHandler = @Sendable (GitOutputEvent) -> Void

package enum GitError: LocalizedError, Sendable {
    case executableUnavailable(String)
    case invalidRepository(String)
    case launchFailed(String)
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case malformedOutput(command: String, detail: String)
    case fileUnavailable(String)

    package var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            "Git executable is unavailable at \(path)."
        case .invalidRepository(let path):
            "The selected directory is not a Git repository: \(path)"
        case .launchFailed(let message):
            "Git could not be launched: \(message)"
        case .commandFailed(let arguments, let status, let stderr):
            "git \(arguments.joined(separator: " ")) failed (exit \(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .malformedOutput(let command, let detail):
            "Git returned malformed output for \(command): \(detail)"
        case .fileUnavailable(let path):
            "The file is unavailable: \(path)"
        }
    }
}

package protocol GitCommandRunning: Sendable {
    func run(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String]
    ) async throws -> GitCommandResult

    func runStreaming(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String],
        output: @escaping GitOutputHandler
    ) async throws -> GitCommandResult
}

package extension GitCommandRunning {
    /// Structured entry point. The raw runner remains the sole executable seam;
    /// remote classification is preserved in the result for process/UI policy.
    func run(
        _ command: GitCommand,
        in directory: URL,
        standardInput: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> GitCommandResult {
        let result = try await run(
            arguments: command.arguments,
            in: directory,
            standardInput: standardInput,
            environment: environment
        )
        return GitCommandResult(
            arguments: result.arguments,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitStatus: result.exitStatus,
            executionClass: command.executionClass
        )
    }

    func runStreaming(
        _ command: GitCommand,
        in directory: URL,
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        output: @escaping GitOutputHandler
    ) async throws -> GitCommandResult {
        let result = try await runStreaming(
            arguments: command.arguments,
            in: directory,
            standardInput: standardInput,
            environment: environment,
            output: output
        )
        return GitCommandResult(
            arguments: result.arguments,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitStatus: result.exitStatus,
            executionClass: command.executionClass
        )
    }
    func runStreaming(
        arguments: [String],
        in directory: URL,
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        output: @escaping GitOutputHandler
    ) async throws -> GitCommandResult {
        let result = try await run(
            arguments: arguments,
            in: directory,
            standardInput: standardInput,
            environment: environment
        )
        if !result.standardOutput.isEmpty {
            output(GitOutputEvent(stream: .standardOutput, data: result.standardOutput))
        }
        if !result.standardError.isEmpty {
            output(GitOutputEvent(stream: .standardError, data: result.standardError))
        }
        return result
    }
}

package final class GitProcess: GitCommandRunning, @unchecked Sendable {
    private let executableURL: URL
    private let executionQueue = DispatchQueue(label: "com.gitextensions.mac.git-process", qos: .userInitiated, attributes: .concurrent)
    private let ioQueue = DispatchQueue(label: "com.gitextensions.mac.git-process-io", qos: .userInitiated, attributes: .concurrent)

    package init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executableURL = executableURL
    }

    package func run(
        arguments: [String],
        in directory: URL,
        standardInput: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> GitCommandResult {
        try await run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: nil)
    }

    package func runStreaming(
        arguments: [String],
        in directory: URL,
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        output: @escaping GitOutputHandler
    ) async throws -> GitCommandResult {
        try await run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: output)
    }

    private func run(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String],
        output: GitOutputHandler?
    ) async throws -> GitCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitError.executableUnavailable(executableURL.path)
        }

        let execution = GitProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            directory: directory,
            standardInput: standardInput,
            environmentOverrides: environment,
            executionQueue: executionQueue,
            ioQueue: ioQueue,
            outputHandler: output
        )

        return try await withTaskCancellationHandler {
            try await execution.result()
        } onCancel: {
            execution.cancel()
        }
    }
}

private enum GitProcessEnvironment {
    private static let packageManagerPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/local/bin",
        "/opt/local/sbin"
    ]

    static func make(overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inheritedPaths = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let paths = (packageManagerPaths + inheritedPaths).reduce(into: [String]()) { paths, path in
            guard !paths.contains(path) else { return }
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        overrides.forEach { environment[$0.key] = $0.value }
        return environment
    }
}

private final class GitProcessExecution: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let directory: URL
    private let standardInput: Data?
    private let environmentOverrides: [String: String]
    private let executionQueue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let outputHandler: GitOutputHandler?
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    init(
        executableURL: URL,
        arguments: [String],
        directory: URL,
        standardInput: Data?,
        environmentOverrides: [String: String],
        executionQueue: DispatchQueue,
        ioQueue: DispatchQueue,
        outputHandler: GitOutputHandler?
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.directory = directory
        self.standardInput = standardInput
        self.environmentOverrides = environmentOverrides
        self.executionQueue = executionQueue
        self.ioQueue = ioQueue
        self.outputHandler = outputHandler
    }

    func result() async throws -> GitCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            executionQueue.async { [self] in
                do {
                    continuation.resume(returning: try execute())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let runningProcess = process
        lock.unlock()

        if runningProcess?.isRunning == true {
            Self.terminateProcessTree(runningProcess!)
        }
    }

    private func execute() throws -> GitCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        process.environment = GitProcessEnvironment.make(overrides: environmentOverrides)

        lock.lock()
        if isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            clearProcess()
            throw GitError.launchFailed(error.localizedDescription)
        }
        lock.lock()
        let cancelledImmediatelyAfterLaunch = isCancelled
        lock.unlock()
        if cancelledImmediatelyAfterLaunch, process.isRunning {
            Self.terminateProcessTree(process)
        }

        let outputGroup = DispatchGroup()
        let dataLock = NSLock()
        var stdout = Data()
        var stderr = Data()

        if let standardInput, let stdinPipe {
            outputGroup.enter()
            ioQueue.async {
                stdinPipe.fileHandleForWriting.write(standardInput)
                try? stdinPipe.fileHandleForWriting.close()
                outputGroup.leave()
            }
        }

        outputGroup.enter()
        ioQueue.async { [outputHandler] in
            let data = Self.read(
                from: stdoutPipe.fileHandleForReading,
                stream: .standardOutput,
                outputHandler: outputHandler
            )
            dataLock.lock()
            stdout = data
            dataLock.unlock()
            outputGroup.leave()
        }

        outputGroup.enter()
        ioQueue.async { [outputHandler] in
            let data = Self.read(
                from: stderrPipe.fileHandleForReading,
                stream: .standardError,
                outputHandler: outputHandler
            )
            dataLock.lock()
            stderr = data
            dataLock.unlock()
            outputGroup.leave()
        }

        process.waitUntilExit()
        outputGroup.wait()
        clearProcess()

        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }

        return GitCommandResult(
            arguments: arguments,
            standardOutput: stdout,
            standardError: stderr,
            exitStatus: process.terminationStatus
        )
    }

    private func clearProcess() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    private static func terminateProcessTree(_ process: Process) {
        let processID = process.processIdentifier
        for child in descendantProcessIDs(of: processID).reversed() {
            _ = Darwin.kill(child, SIGTERM)
        }
        if process.isRunning { process.terminate() }
    }

    private static func descendantProcessIDs(of root: pid_t) -> [pid_t] {
        typealias ListChildren = @convention(c) (pid_t, UnsafeMutableRawPointer?, Int32) -> Int32
        guard let library = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY),
              let symbol = dlsym(library, "proc_listchildpids")
        else { return [] }
        defer { dlclose(library) }
        let listChildren = unsafeBitCast(symbol, to: ListChildren.self)
        var descendants: [pid_t] = []
        var pending = [root]
        var visited = Set<pid_t>([root])
        while let parent = pending.popLast() {
            var children = [pid_t](repeating: 0, count: 256)
            let returned = children.withUnsafeMutableBytes {
                listChildren(parent, $0.baseAddress, Int32($0.count))
            }
            guard returned > 0 else { continue }
            for child in children.prefix(min(Int(returned), children.count)) where child > 0 && visited.insert(child).inserted {
                descendants.append(child)
                pending.append(child)
            }
        }
        return descendants
    }

    private static func read(
        from handle: FileHandle,
        stream: GitOutputStream,
        outputHandler: GitOutputHandler?
    ) -> Data {
        var collected = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            collected.append(chunk)
            outputHandler?(GitOutputEvent(stream: stream, data: chunk))
        }
        return collected
    }
}
