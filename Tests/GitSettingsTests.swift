import Foundation
@testable import GitExtensionsCore
@testable import GitCommands

enum GitSettingsTests {
    private static func testArtificialRevisionCounts() throws {
        let oid = String(repeating: "a", count: 40)
        let records = try GitOutputParser.parsePorcelainV2(Data(([
            "1 MM N... 100644 100644 100644 \(oid) \(oid) both.txt",
            "1 A. N... 000000 100644 100644 \(oid) \(oid) staged.txt",
            "1 .D N... 100644 100644 100644 \(oid) \(oid) deleted.txt",
            "1 .M SCMU 160000 160000 160000 \(oid) \(oid) nested module",
            "? 新 file.txt"
        ].joined(separator: "\0") + "\0").utf8))
        let worktree = GitStatusRecord.revisionChangeCounts(records, staged: false)
        let index = GitStatusRecord.revisionChangeCounts(records, staged: true)
        precondition(worktree.changed == ["both.txt"] && index.changed == ["both.txt"])
        precondition(worktree.added == ["新 file.txt"] && index.added == ["staged.txt"])
        precondition(worktree.deleted == ["deleted.txt"] && index.deleted.isEmpty)
        precondition(worktree.submodulesChanged == ["nested module"] && worktree.submodulesDirty == ["nested module"])
        precondition(index.submodulesChanged.isEmpty && index.submodulesDirty.isEmpty)
        precondition(GitStatusRecord.revisionChangeCounts([], staged: false) == RevisionChangeCounts())
    }

    static func run() async throws {
        try testArtificialRevisionCounts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["GIT_CONFIG_GLOBAL": directory.appendingPathComponent("global.config").path,
                           "GIT_CONFIG_SYSTEM": directory.appendingPathComponent("system.config").path]
        let git = GitProcess()
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw GitError.malformedOutput(command: "Settings test", detail: message) }
        }
        func load(_ scope: GitSettingsScope) async throws -> [String: [String]] {
            try await GitSettingsConfiguration.load(scope, in: directory, git: git, environment: environment)
        }
        func save(_ key: String, _ value: String?, _ scope: GitSettingsScope) async throws {
            try await GitSettingsConfiguration.save(key, value: value, scope: scope, in: directory, git: git, environment: environment)
        }
        let initialized = try await git.run(GitCommand(arguments: ["init", "-b", "main"], accessesRemote: false, changesRepositoryState: true), in: directory, environment: environment)
        try require(initialized.succeeded, "disposable repository initialization")
        try require(try await load(.global).isEmpty, "missing global file is empty")
        try await save("user.name", "System", .system)
        try await save("user.name", "Global", .global)
        try await save("user.name", "Local", .local)
        try require(try await load(.effective)["user.name"]?.last == "Local", "effective scope precedence")
        try require(try await load(.global)["user.name"] == ["Global"], "local writes preserve global config")
        try await save("user.name", nil, .local)
        try require(try await load(.effective)["user.name"]?.last == "Global", "unset restores inherited value")
        try await save("user.name", nil, .local)
        try await save("sample.multiline", "first\nsecond é", .local)
        try await save("sample.empty", "", .local)
        try require(try await load(.local)["sample.multiline"] == ["first\nsecond é"], "NUL records retain multiline Unicode values")
        try require(try await load(.local)["sample.empty"] == [""], "empty value differs from missing key")
        for value in ["one", "two"] {
            let result = try await git.run(GitCommand(arguments: ["config", "--local", "--add", "credential.helper", value], accessesRemote: false, changesRepositoryState: true), in: directory, environment: environment)
            try require(result.succeeded, "multi-value fixture")
        }
        try await save("fetch.prune", "true", .local)
        try require(try await load(.local)["credential.helper"] == ["one", "two"], "unrelated multi-values survive scoped save")
        for (key, value, scope) in [("user.name", "Changed", GitSettingsScope.effective), ("invalid", "value", .local), ("user.name", "bad\0value", .local)] {
            var rejected = false
            do { try await save(key, value, scope) } catch { rejected = true }
            try require(rejected, "invalid/effective writes must be rejected")
        }
        try require(try await load(.effective)["user.name"]?.last == "Global", "rejected writes preserve existing identity")
        try await save("i18n.filesencoding", "WINDOWS-1252", .local)
        let module = GitRepositoryModule(repositoryURL: directory)
        _ = try await module.loadRepositoryState()
        try require(try await module.configuredFileEncoding() == .windows1252, "case-insensitive repository file encoding")
        let encoded = Data([0x80])
        let decoded = FileContentDecoder.decode(encoded, path: "example.txt", requestedEncoding: .automatic, configuredEncoding: .windows1252)
        try require(decoded.text == "€", "configured encoding is consumed by the file decoder")
        let bom = FileContentDecoder.decode(Data([0xEF, 0xBB, 0xBF, 0x61]), path: "example.txt", requestedEncoding: .automatic, configuredEncoding: .windows1252)
        try require(bom.text == "a" && bom.encoding == .utf8, "BOM overrides configured fallback")
        let explicit = FileContentDecoder.decode(encoded, path: "example.txt", requestedEncoding: .westernISO88591, configuredEncoding: .windows1252)
        try require(explicit.encoding == .westernISO88591, "explicit viewer choice overrides repository fallback")
        let japanese = RepositoryTextEncoding(ianaName: "shift_jis")!
        try require(GitSettingsTools.suggestedCommand(tool: "vscode", path: "", merge: true) == #""code" --new-window --wait --merge "$REMOTE" "$LOCAL" "$BASE" "$MERGED""#, "upstream VS Code merge ordering")
        try require(GitSettingsTools.suggestedCommand(tool: "kdiff3", path: "/Tools/k diff", merge: true) == #""/Tools/k diff" "$BASE" "$LOCAL" "$REMOTE" -o "$MERGED""#, "tool paths remain one shell word")
        try require(GitSettingsTools.suggestedCommand(tool: "custom", path: "", merge: true) == nil, "unknown custom tool commands are not invented")
        try require(GitSettingsTools.suggestedCommand(tool: "meld", path: "/Tools/$name", merge: false)?.hasPrefix(#""/Tools/\$name""#) == true, "literal shell metacharacters in tool paths")
        let japaneseData = "日本語".data(using: japanese.foundationEncoding)!
        let japaneseContent = FileContentDecoder.decode(japaneseData, path: "example.txt", requestedEncoding: japanese)
        try require(japaneseContent.text == "日本語", "platform encoding decodes Japanese content")
        try require(try JSONDecoder().decode(RepositoryTextEncoding.self, from: JSONEncoder().encode(japanese)) == japanese, "additional encoding round-trip")
        try require(RepositoryTextEncoding(ianaName: "utf-7") == nil, "UTF-7 is excluded as upstream requires")
        let utf32 = FileContentDecoder.decode(Data([0xFF, 0xFE, 0, 0, 0x61, 0, 0, 0]), path: "example.txt", requestedEncoding: .automatic, configuredEncoding: .windows1252)
        try require(utf32.text == "a" && utf32.encoding?.ianaName == "utf-32le", "UTF-32 BOM precedes UTF-16 detection and fallback")
        let directories = try await module.settingsDirectories()
        try require(directories.working.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath(), "distributed settings use repository working directory")
        let commit = try await git.run(GitCommand(arguments: ["-c", "user.name=Settings Test", "-c", "user.email=settings@example.invalid", "commit", "--allow-empty", "-m", "Initial"], accessesRemote: false, changesRepositoryState: true), in: directory, environment: environment)
        try require(commit.succeeded, "linked settings fixture commit")
        let linked = directory.appendingPathComponent("linked")
        let add = try await git.run(GitCommand(arguments: ["worktree", "add", "--detach", linked.path], accessesRemote: false, changesRepositoryState: true), in: directory, environment: environment)
        try require(add.succeeded, "linked settings fixture worktree")
        let linkedModule = GitRepositoryModule(repositoryURL: linked)
        _ = try await linkedModule.loadRepositoryState()
        let linkedDirectories = try await linkedModule.settingsDirectories()
        try require(linkedDirectories.commonGit.resolvingSymlinksInPath() == directories.commonGit.resolvingSymlinksInPath(), "local app settings share common Git directory across worktrees")
        try require(linkedDirectories.working.resolvingSymlinksInPath() == linked.resolvingSymlinksInPath(), "distributed settings are specific to each worktree")
        print("GitSettingsTests: passed")
    }
}
