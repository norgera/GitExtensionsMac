import Foundation
import GitExtensionsCore


package struct GitSettingsCheck: Equatable, Sendable {
    package enum Kind: String, Sendable { case git, identity, editor, mergeTool, diffTool }
    package enum Status: Sendable { case valid, warning, invalid }
    package let kind: Kind
    package let status: Status
    package let message: String

    package init(kind: Kind, status: Status, message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }
}

package enum GitSettingsChecklist {

    package static func versionCheck(_ output: String) -> GitSettingsCheck {
        let version = output.split(whereSeparator: \.isWhitespace).dropFirst(2).first.map(String.init) ?? ""
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0.prefix(while: \.isNumber)) }
        guard parts.count >= 2 else { return .init(kind: .git, status: .invalid, message: "Git not found. Set the correct path in settings.") }
        let numbers = parts + Array(repeating: 0, count: 3 - parts.count)
        if numbers.lexicographicallyPrecedes([2, 43, 0]) {
            return .init(kind: .git, status: .invalid, message: "Git found but version \(version) is not supported. Upgrade to version 2.53.0 or later.")
        }
        if numbers.lexicographicallyPrecedes([2, 53, 0]) {
            return .init(kind: .git, status: .warning, message: "Git found but version \(version) is older than recommended. Upgrade to version 2.53.0 or later.")
        }
        return .init(kind: .git, status: .valid, message: "Git \(version) is found on your computer.")
    }

    package static func configurationChecks(global: [String: [String]], effective: [String: [String]],
                                             environment: [String: String], knownTools: Set<String>) -> [GitSettingsCheck] {
        func value(_ key: String) -> String { effective[key]?.last ?? "" }
        let identity = !(global["user.name"]?.last ?? "").isEmpty && !(global["user.email"]?.last ?? "").isEmpty
        let editor = [environment["GIT_EDITOR"], global["core.editor"]?.last, environment["VISUAL"], environment["EDITOR"]]
            .compactMap { $0 }.first { !$0.isEmpty }
        var checks: [GitSettingsCheck] = [
            .init(kind: .identity, status: identity ? .valid : .invalid,
                  message: identity ? "A username and an email address are configured." : "You need to configure a username and an email address."),
            .init(kind: .editor, status: editor == nil ? .invalid : .valid,
                  message: editor.map { "An editor is configured: \($0)" } ?? "You need to configure an editor.")
        ]
        for merge in [true, false] {
            let prefix = merge ? "mergetool" : "difftool"
            let key = merge ? "merge" : "diff"
            let gui = value("\(key).guitool")

            let tool = merge && gui.isEmpty ? value("merge.tool") : gui
            let configured = !tool.isEmpty && (!value("\(prefix).\(tool).cmd").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || knownTools.contains(tool))
            let message: String
            if configured { message = "There is a \(prefix) configured: \(tool)" }
            else if merge && !tool.isEmpty { message = "\(tool) is configured as mergetool; this custom tool needs a custom command." }
            else { message = merge ? "You need to configure a merge tool in order to solve merge conflicts." : "You should configure a diff tool to show file differences in an external program." }
            checks.append(.init(kind: merge ? .mergeTool : .diffTool, status: configured ? .valid : .invalid, message: message))
        }
        return checks
    }

    package static func load(executableURL: URL, directory: URL = FileManager.default.temporaryDirectory,
                             git: (any GitCommandRunning)? = nil, environment: [String: String] = [:]) async throws -> [GitSettingsCheck] {
        let runner = git ?? GitProcess(executableURL: executableURL)
        let version: GitSettingsCheck
        do {
            let result = try await runner.run(GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false), in: directory, environment: environment)
            version = versionCheck(result.succeeded ? result.standardOutputString : "")
        } catch is CancellationError { throw CancellationError() }
        catch { return [.init(kind: .git, status: .invalid, message: "Git not found. Set the correct path in settings.\n\(error.localizedDescription)")] }
        let global = try await GitSettingsConfiguration.load(.global, in: directory, git: runner, environment: environment)
        let effective = try await GitSettingsConfiguration.load(.effective, in: directory, git: runner, environment: environment)

        let execPath = try await runner.run(GitCommand(arguments: ["--exec-path"], accessesRemote: false, changesRepositoryState: false), in: directory, environment: environment)
        let toolsURL = URL(fileURLWithPath: execPath.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("mergetools")
        let tools = execPath.succeeded ? Set((try? FileManager.default.contentsOfDirectory(atPath: toolsURL.path)) ?? []) : []
        let ambient = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, value in value })
        return [version] + configurationChecks(global: global, effective: effective, environment: ambient, knownTools: tools)
    }


    package static func locateGit(environment: [String: String] = ProcessInfo.processInfo.environment) async -> URL? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var seen = Set<String>()
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("git")
            guard seen.insert(url.path).inserted, FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if let result = try? await GitProcess(executableURL: url).run(GitCommand(arguments: ["--version"], accessesRemote: false, changesRepositoryState: false), in: FileManager.default.temporaryDirectory), result.succeeded { return url }
        }
        return nil
    }
}

package enum GitSettingsScope: String, CaseIterable, Sendable {
    case effective, local, global, system
    var arguments: [String] { self == .effective ? [] : ["--\(rawValue)"] }
}

package enum GitSettingsTools {
    package static let names = ["araxis", "bc", "diffmerge", "kdiff3", "meld", "p4merge", "semanticmerge", "smerge", "vscode"]
    package static func suggestedCommand(tool: String, path: String, merge: Bool) -> String? {
        let name = tool.lowercased()
        guard names.contains(name), !path.contains("\0"), !path.contains("\n") else { return nil }
        let executable = path.isEmpty ? ["araxis": "compare", "bc": "bcompare", "vscode": "code", "semanticmerge": "semanticmergetool"][name] ?? name : path
        let arguments: String
        switch (name, merge) {
        case ("vscode", false): arguments = #"--new-window --wait --diff "$LOCAL" "$REMOTE""#
        case ("vscode", true): arguments = #"--new-window --wait --merge "$REMOTE" "$LOCAL" "$BASE" "$MERGED""#
        case ("araxis", true): arguments = #"/merge /wait /a2 /3 "$LOCAL" "$BASE" "$REMOTE" "$MERGED""#
        case ("diffmerge", true): arguments = #"-merge -result="$MERGED" "$LOCAL" "$BASE" "$REMOTE""#
        case ("kdiff3", true): arguments = #""$BASE" "$LOCAL" "$REMOTE" -o "$MERGED""#
        case ("meld", true): arguments = #""$LOCAL" "$BASE" "$REMOTE" --output "$MERGED""#
        case ("p4merge", true): arguments = #""$BASE" "$LOCAL" "$REMOTE" "$MERGED""#
        case ("semanticmerge", false): arguments = #"-s "$LOCAL" -d "$REMOTE""#
        case ("semanticmerge", true): arguments = #"-s "$REMOTE" -d "$LOCAL" -b "$BASE" -r "$MERGED""#
        case ("smerge", false): arguments = #"mergetool "$LOCAL" "$REMOTE" -o="$MERGED""#
        case ("smerge", true): arguments = #"mergetool "$BASE" "$LOCAL" "$REMOTE" -o="$MERGED""#
        case (_, false): arguments = #""$LOCAL" "$REMOTE""#
        case (_, true): arguments = #""$LOCAL" "$REMOTE" "$BASE" "$MERGED""#
        }
        let quoted = executable.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        return "\"\(quoted)\" \(arguments)"
    }
}

package protocol RepositorySettingsDataSource: Sendable {
    func settingsDirectories() async throws -> (working: URL, commonGit: URL)
    func loadGitSettings(_ scope: GitSettingsScope) async throws -> [String: [String]]
    func saveGitSetting(_ key: String, value: String?, scope: GitSettingsScope) async throws
}

package enum GitSettingsConfiguration {
    package static func load(_ scope: GitSettingsScope, in directory: URL, git: any GitCommandRunning,
                             environment: [String: String] = [:]) async throws -> [String: [String]] {
        let command = GitCommand(arguments: ["config"] + scope.arguments + ["--null", "--get-regexp", "."],
                                 accessesRemote: false, changesRepositoryState: false)
        let result = try await git.run(command, in: directory, environment: environment)
        guard result.succeeded || result.exitStatus == 1 else {
            throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        var values: [String: [String]] = [:]
        for record in result.standardOutput.split(separator: 0) {
            let pieces = record.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(decoding: pieces[0], as: UTF8.self)
            let value = pieces.count == 2 ? String(decoding: pieces[1], as: UTF8.self) : ""
            values[key, default: []].append(value)
        }
        return values
    }

    package static func save(_ key: String, value: String?, scope: GitSettingsScope, in directory: URL,
                             git: any GitCommandRunning, environment: [String: String] = [:]) async throws {
        guard scope != .effective else { throw GitError.malformedOutput(command: "config", detail: "Effective Git settings are read-only.") }
        guard key.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[^\n\x00]+)?\.[A-Za-z][A-Za-z0-9-]*$"#, options: .regularExpression) != nil,
              value?.contains("\0") != true else {
            throw GitError.malformedOutput(command: "config", detail: "Invalid Git configuration key or value.")
        }
        let command = GitCommand(arguments: ["config"] + scope.arguments +
            (value.map { ["--replace-all", key, $0] } ?? ["--unset-all", key]),
            accessesRemote: false, changesRepositoryState: true)
        let result = try await git.run(command, in: directory, environment: environment)
        guard result.succeeded || (value == nil && result.exitStatus == 5) else {
            throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
    }

    package static func loadGlobal(_ scope: GitSettingsScope, executableURL: URL) async throws -> [String: [String]] {
        guard scope != .local else { throw RepositoryDataSourceError.unavailable }
        return try await load(scope, in: FileManager.default.temporaryDirectory, git: GitProcess(executableURL: executableURL))
    }
    package static func saveGlobal(_ key: String, value: String?, scope: GitSettingsScope, executableURL: URL) async throws {
        guard scope != .local else { throw RepositoryDataSourceError.unavailable }
        try await save(key, value: value, scope: scope, in: FileManager.default.temporaryDirectory, git: GitProcess(executableURL: executableURL))
    }
}

extension GitRepositoryModule: RepositorySettingsDataSource {
    package func settingsDirectories() async throws -> (working: URL, commonGit: URL) {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let command = GitCommand(arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], accessesRemote: false, changesRepositoryState: false)
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return (repository.rootURL, URL(fileURLWithPath: result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true))
    }
    func configuredFileEncoding() async throws -> RepositoryTextEncoding? {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let command = GitCommand(arguments: ["config", "--get", "i18n.filesencoding"], accessesRemote: false, changesRepositoryState: false)
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded || result.exitStatus == 1 else {
            throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return RepositoryTextEncoding(ianaName: result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func loadGitSettings(_ scope: GitSettingsScope) async throws -> [String: [String]] {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return try await GitSettingsConfiguration.load(scope, in: repository.rootURL, git: git)
    }
    package func saveGitSetting(_ key: String, value: String?, scope: GitSettingsScope) async throws {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        try await GitSettingsConfiguration.save(key, value: value, scope: scope, in: repository.rootURL, git: git)
    }
}
