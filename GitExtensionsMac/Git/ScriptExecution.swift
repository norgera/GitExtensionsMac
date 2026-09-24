import Foundation
import GitExtensionsCore

package protocol RepositoryScriptContextDataSource: Sendable {
    func scriptContext(selected: [ObjectID], arguments: String) async throws -> [String: [String]]
    func scriptRevision(_ expression: String) async throws -> ObjectID
}

extension GitRepositoryModule: RepositoryScriptContextDataSource {
    package func scriptRevision(_ expression: String) async throws -> ObjectID {
        let directory = try await settingsDirectories().working
        let arguments = ["rev-parse", "--verify", "--end-of-options", expression + "^{commit}"]
        let result = try await git.run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false), in: directory)
        guard result.succeeded else { throw GitError.commandFailed(arguments: arguments, status: result.exitStatus, stderr: result.standardErrorString) }
        return try ObjectID(parsing: result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    package func scriptContext(selected: [ObjectID], arguments: String) async throws -> [String: [String]] {
        let directory = try await settingsDirectories().working
        func read(_ arguments: [String]) async throws -> String {
            let result = try await git.run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false), in: directory)
            guard result.succeeded else { throw GitError.commandFailed(arguments: arguments, status: result.exitStatus, stderr: result.standardErrorString) }
            return result.standardOutputString.trimmingCharacters(in: .newlines)
        }
        var values: [String: [String]] = ["WorkingDir": [directory.path + "/"], "RepoName": [directory.lastPathComponent]]
        let head = try? await read(["rev-parse", "--verify", "HEAD"])
        let branch = (try? await read(["symbolic-ref", "--quiet", "--short", "HEAD"])) ?? ""
        let remoteNames = ((try? await read(["remote"])) ?? "").split(separator: "\n").map(String.init).sorted { $0.count > $1.count }
        func remoteName(_ branch: String) -> String {
            remoteNames.first(where: { branch.hasPrefix($0 + "/") }) ?? branch.split(separator: "/").first.map(String.init) ?? ""
        }
        if let head { values["HEAD"] = [branch.isEmpty ? head : branch] }
        if !selected.isEmpty { values["sHashes"] = [selected.map(\.string).joined(separator: " ")] }
        for (prefix, revision) in [("c", head), ("s", selected.first?.string)] {
            guard let revision else { continue }
            let raw = try await read(["show", "-s", "--format=%H%x00%B%x00%s%x00%an%x00%cn%x00%at%x00%ct", revision, "--"])
            let fields = raw.components(separatedBy: "\0")
            guard fields.count == 7 else { throw ScriptExecutionError.missingOption(prefix + "Hash") }
            _ = try ObjectID(parsing: fields[0])
            for (index, name) in ["Hash", "Message", "Subject", "Author", "Committer", "AuthorDate", "CommitDate"].enumerated() {
                var value = fields[index]
                if index == 1 { value = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n") }
                if index >= 5, let timestamp = Double(value) {
                    value = DateFormatter.localizedString(from: Date(timeIntervalSince1970: timestamp), dateStyle: .short, timeStyle: .medium)
                }
                values[prefix + name] = [value]
            }
            let refs = try await read(["for-each-ref", "--points-at", revision, "--format=%(refname)"])
            let names = refs.split(separator: "\n").map(String.init)
            let locals = names.filter { $0.hasPrefix("refs/heads/") }.map { String($0.dropFirst(11)) }
            let remotes = names.filter { $0.hasPrefix("refs/remotes/") }.map { String($0.dropFirst(13)) }
            values[prefix + "LocalBranch"] = locals
            values[prefix + "RemoteBranch"] = remotes
            values[prefix + "Branch"] = locals + remotes
            values[prefix + "Tag"] = names.filter { $0.hasPrefix("refs/tags/") }.map { String($0.dropFirst(10)) }
            values[prefix + "RemoteBranchName"] = remotes.map { String($0.dropFirst(remoteName($0).count + 1)) }
            if prefix == "s" {
                let remoteNames = Array(Set(remotes.map(remoteName))).sorted()
                values["sRemote"] = remoteNames
                var urls: [String] = []
                for name in remoteNames { urls.append((try? await read(["config", "--get", "remote.\(name).url"])) ?? "") }
                values["sRemoteUrl"] = urls
                values["sRemotePathFromUrl"] = urls.map(Self.scriptRemotePath)
            }
        }
        let remote = (try? await read(["config", "--get", "branch.\(branch).remote"])) ?? ""
        values["cDefaultRemote"] = [remote]
        let url = remote.isEmpty ? "" : (try? await read(["config", "--get", "remote.\(remote).url"])) ?? ""
        values["cDefaultRemoteUrl"] = [url]
        values["cDefaultRemotePathFromUrl"] = [Self.scriptRemotePath(url)]
        for key in ["cTag", "cBranch", "cLocalBranch", "cRemoteBranch", "cRemoteBranchName", "sTag", "sBranch", "sLocalBranch", "sRemoteBranch", "sRemoteBranchName", "sRemote", "sRemoteUrl", "sRemotePathFromUrl"] where values[key]?.isEmpty == true {
            values[key] = [""]
        }
        return values
    }

    private static func scriptRemotePath(_ value: String) -> String {
        var path = URL(string: value)?.scheme != nil ? URL(string: value)?.path ?? "" : value.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path.isEmpty || path.hasPrefix("/") ? path : "/" + path
    }
}

package enum ScriptEvent: String, Codable, CaseIterable, Sendable {
    case none = "None"
    case beforeCommit = "BeforeCommit", afterCommit = "AfterCommit"
    case beforePull = "BeforePull", afterPull = "AfterPull"
    case beforePush = "BeforePush", afterPush = "AfterPush"
    case showInUserMenuBar = "ShowInUserMenuBar"
    case beforeCheckout = "BeforeCheckout", afterCheckout = "AfterCheckout"
    case beforeMerge = "BeforeMerge", afterMerge = "AfterMerge"
    case beforeFetch = "BeforeFetch", afterFetch = "AfterFetch"
    case showInFileList = "ShowInFileList"
}

package struct ScriptDefinition: Codable, Equatable, Identifiable, Sendable {
    package var id: UUID = UUID()
    package var enabled = true
    package var name = "New script"
    package var command = ""
    package var arguments = ""
    package var addToRevisionGridContextMenu = false
    package var onEvent: ScriptEvent = .none
    package var askConfirmation = false
    package var runInBackground = false
    package var isPowerShell = false
    package var hotkeyCommandIdentifier = 9000
    package var icon: String?
    package var iconFilePath: String?

    package init() {}

    package var displayName: String {
        name.replacingOccurrences(of: "&(?!&)", with: "", options: .regularExpression)
    }
}

package enum ScriptExecutionError: LocalizedError {
    case invalidArguments
    case executableNotFound(String)
    case missingOption(String)
    case unsupportedCommand(String)

    package var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Script arguments contain an unfinished quote or escape."
        case .executableNotFound(let command): return "Script executable not found: \(command)"
        case .missingOption(let option): return "The script requires unavailable context: \(option)"
        case .unsupportedCommand(let command): return "This script command requires an application handoff: \(command)"
        }
    }
}

package struct ScriptInvocation: Sendable {
    package let executable: URL
    package let arguments: [String]
    package let workingDirectory: URL
    package let environment: [String: String]
}

package enum ScriptExecutionOutcome: Sendable {
    case completed(GitCommandResult)
    case started(processID: Int32)
}

package enum ScriptExecution {
    package static func revisionArgument(_ id: RevisionID) -> String {
        switch id {
        case .object(let id): return id.string
        case .workingDirectory: return String(repeating: "1", count: 40)
        case .index: return String(repeating: "2", count: 40)
        }
    }

    package static func selectedRevisionOptions(_ revisions: [Commit]) -> [String: [String]] {
        guard let selected = revisions.first else { return [:] }
        var result = ["sHashes": [revisions.map { revisionArgument($0.id) }.joined(separator: " ")]]
        guard selected.isArtificial else { return result }
        result["sHash"] = [revisionArgument(selected.id)]
        result["sSubject"] = [selected.subject]
        result["sMessage"] = [(selected.body.isEmpty ? selected.subject : selected.body).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n")]
        result["sAuthor"] = [selected.authorName]; result["sCommitter"] = [selected.committerName]
        result["sAuthorDate"] = [DateFormatter.localizedString(from: selected.authorDate, dateStyle: .short, timeStyle: .medium)]
        result["sCommitDate"] = [DateFormatter.localizedString(from: selected.commitDate, dateStyle: .short, timeStyle: .medium)]
        for key in ["sTag", "sBranch", "sLocalBranch", "sRemoteBranch", "sRemoteBranchName", "sRemote", "sRemoteUrl", "sRemotePathFromUrl"] { result[key] = [""] }
        return result
    }

    package static func replaceOption(_ option: String, in source: String, values: [String], powerShell: Bool = false) -> String {
        source.replacingOccurrences(of: "{{\(option)}}", with: values.map {
            "'" + $0.replacingOccurrences(of: "'", with: powerShell ? "''" : "'\\''") + "'"
        }.joined(separator: " "))
        .replacingOccurrences(of: "{\(option)}", with: values.joined(separator: " "))
    }

    package static func arguments(_ source: String) throws -> [String] {
        var result: [String] = [], current = ""
        var quote: Character?, escaped = false, started = false
        let characters = Array(source)
        for (index, character) in characters.enumerated() {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" {
                if quote == "\"", index + 1 < characters.count,
                   ![Character("\""), "\\", "$", "`", "\n"].contains(characters[index + 1]) {
                    current.append(character)
                } else { escaped = true }
                started = true; continue
            }
            if let delimiter = quote {
                if character == delimiter { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw ScriptExecutionError.invalidArguments }
        if started { result.append(current) }
        return result
    }

    package static func expand(_ source: String, options: [String: [String]], powerShell: Bool = false) -> String {
        let pattern = #"\{\{([^{}]+)\}\}|\{([^{}]+)\}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let quoted = match.range(at: 1).location != NSNotFound
            let keyRange = Range(match.range(at: quoted ? 1 : 2), in: source)!
            guard let values = options[String(source[keyRange])], let range = Range(match.range, in: result) else { continue }
            let replacement = values.map { quoted ? "'" + $0.replacingOccurrences(of: "'", with: powerShell ? "''" : "'\\''") + "'" : $0 }.joined(separator: " ")
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    package static func invocation(_ script: ScriptDefinition, directory: URL,
                                   options: [String: [String]], gitExecutable: URL,
                                   environment: [String: String] = [:], applicationExecutable: URL? = nil) throws -> ScriptInvocation {
        var options = options
        options["WorkingDir"] = [directory.path.hasSuffix("/") ? directory.path : directory.path + "/"]
        options["RepoName"] = [directory.lastPathComponent]
        try validateContext(script.arguments, options: options)
        var command = script.command.replacingOccurrences(of: "{WorkingDir}", with: options["WorkingDir"]![0])
        if command.lowercased() == "git" || command.lowercased() == "{git}" { command = gitExecutable.path }
        if ["gitextensions", "{gitextensions}", "gitex", "{gitex}"].contains(command.lowercased()) {
            guard let applicationExecutable else { throw ScriptExecutionError.unsupportedCommand(command) }
            command = applicationExecutable.path
        }
        if command.lowercased() == "{openurl}" { command = "/usr/bin/open" }
        let expandedArguments = expand(script.arguments, options: options, powerShell: script.isPowerShell)
        if script.isPowerShell {
            let shellArguments = (script.runInBackground ? [] : ["-NoExit"])
                + ["-ExecutionPolicy", "Unrestricted", "-Command", command + " " + expandedArguments]
            let invocation = ScriptInvocation(executable: try executable("pwsh", directory: directory, environment: environment),
                arguments: shellArguments, workingDirectory: directory, environment: environment)
            if script.runInBackground { return invocation }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensions-Script-\(UUID()).command")
            func quote(_ value: String) -> String { expand("{{value}}", options: ["value": [value]]) }
            let exports = environment.sorted(by: { $0.key < $1.key }).map { quote($0.key + "=" + $0.value) }
            let launch = (["/usr/bin/env"] + exports + [quote(invocation.executable.path)] + invocation.arguments.map(quote)).joined(separator: " ")
            let contents = "#!/bin/sh\n/bin/rm -f -- \"$0\"\ncd -- \(quote(directory.path)) || exit\nexec \(launch)\n"
            guard FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return ScriptInvocation(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Terminal", file.path], workingDirectory: directory, environment: environment)
        }
        let args = try arguments(expandedArguments)
        if command.hasPrefix("navigateTo:") { command = String(command.dropFirst("navigateTo:".count)) }
        guard !command.hasPrefix("plugin:") else {
            throw ScriptExecutionError.unsupportedCommand(command)
        }
        return ScriptInvocation(executable: try executable(command, directory: directory, environment: environment), arguments: args, workingDirectory: directory, environment: environment)
    }

    private static func executable(_ command: String, directory: URL, environment: [String: String]) throws -> URL {
        let executable: URL
        if command.contains("/") {
            executable = URL(fileURLWithPath: (command as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
        } else {
            let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            guard let found = path.split(separator: ":", omittingEmptySubsequences: false)
                .map({ URL(fileURLWithPath: $0.isEmpty ? directory.path : String($0)).appendingPathComponent(command) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw ScriptExecutionError.executableNotFound(command)
            }
            executable = found
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ScriptExecutionError.executableNotFound(command)
        }
        return executable
    }

    package static func validateContext(_ arguments: String, options: [String: [String]], beforePrompts: Bool = false) throws {
        let knownOptions = Set(["sHashes", "sTag", "sBranch", "sLocalBranch", "sRemoteBranch", "sRemoteBranchName", "sRemote", "sRemoteUrl", "sRemotePathFromUrl", "sHash", "sMessage", "sSubject", "sAuthor", "sCommitter", "sAuthorDate", "sCommitDate", "HEAD", "cTag", "cBranch", "cLocalBranch", "cRemoteBranch", "cRemoteBranchName", "cHash", "cMessage", "cSubject", "cAuthor", "cCommitter", "cAuthorDate", "cCommitDate", "cDefaultRemote", "cDefaultRemoteUrl", "cDefaultRemotePathFromUrl", "SelectedRelativePaths", "LineNumber", "ColumnNumber", "UserFiles", "UserInput"])
        let placeholders = try NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        for match in placeholders.matches(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)) {
            let option = String(arguments[Range(match.range(at: 1), in: arguments)!])
            if beforePrompts && (option == "UserFiles" || option == "UserInput" || option.hasPrefix("UserInput:")) { continue }
            if (knownOptions.contains(option) || option.hasPrefix("UserInput:")), options[option] == nil {
                throw ScriptExecutionError.missingOption(option)
            }
        }
    }

    package static func run(_ invocation: ScriptInvocation, output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        try await GitProcess(executableURL: invocation.executable).runStreaming(
            arguments: invocation.arguments, in: invocation.workingDirectory,
            standardInput: nil, environment: invocation.environment, output: output)
    }

    package static func startBackground(_ invocation: ScriptInvocation) async throws -> ScriptExecutionOutcome {
        let pid = try await GitProcess(executableURL: invocation.executable).startBackground(
            arguments: invocation.arguments, in: invocation.workingDirectory, environment: invocation.environment)
        return .started(processID: pid)
    }
}
