import Foundation
import GitExtensionsCore

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
