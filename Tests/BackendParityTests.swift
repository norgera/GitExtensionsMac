@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation
import AppKit

enum BackendParityTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, "BackendParityTests: " + message) }

    static func run() async throws {
        try await signatures()
        try await metadataEncoding()
        try await diffEncoding()
        try await materialization()
        try await mergeFastForward()
        try await nonInteractiveCredentials()
        try await rerereContinuation()
        stashPromptAnswers()
        deletionCandidates()
        try await bothDeletedConflict()
        copiedLinePatching()
        try await truthfulBrowserStatus()
        try await commitFileListControls()
        try agentRefsFilter()
        await simplifyMergesDependency()
        try await cloneRecursivePreference()
        syntaxRegistry()
        try await commitSpelling()
        await graphHoverCalculator()
        try await graphHoverGrid()
        impactParsing()
        try await impactRepository()
        try await impactLoaderLifecycle()
        await impactModel()
        try await impactWorkflow()
        try await commitPushTarget()
        try await scriptOptionSelection()
        try await sortingSettings()
        try await confirmationSettings()
        try await suppressibleConfirmations()
        try await diffViewerSettings()
        try await commitDialogSettings()
        try await advancedAppearanceSettings()
        try await editorComposedCommits()
        print("BackendParityTests: passed")
    }

    struct EnvironmentGit: GitCommandRunning {
        let environment: [String: String]
        func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
            try await GitProcess().run(arguments: arguments, in: directory, standardInput: standardInput,
                environment: environment.merging(self.environment, uniquingKeysWith: { _, fixture in fixture }))
        }
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gem-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func shell(_ executable: String, _ arguments: [String], in directory: URL, environment: [String: String] = [:], input: Data? = nil, allowFailure: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { _, new in new }
            .merging(environment) { _, new in new }
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        check(allowFailure || process.terminationStatus == 0, "\(executable) \(arguments.joined(separator: " ")) failed: \(String(decoding: errorData, as: UTF8.self))")
        return data
    }

    static func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:], input: Data? = nil) throws -> String {
        String(decoding: try shell("/usr/bin/env", ["git"] + arguments, in: directory, environment: environment, input: input), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gpgExecutable() -> String? {
        ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg", "/usr/bin/gpg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func commit(_ id: ObjectID, references: [RevisionReference]) -> Commit {
        Commit(id: .object(id), shortID: id.shortString, subject: "", body: "", authorName: "", authorEmail: "", authorDate: Date(),
               committerName: "", committerEmail: "", commitDate: Date(), parentIDs: [], references: references)
    }

    static func signatures() async throws {
        check(GitSignatureParser.commitStatus("G") == .goodSignature, "G")
        for code in ["B", "U", "X", "Y", "R"] { check(GitSignatureParser.commitStatus(code) == .signatureError, code) }
        check(GitSignatureParser.commitStatus("E") == .missingPublicKey, "E")
        check(GitSignatureParser.commitStatus("N") == .noSignature && GitSignatureParser.commitStatus("") == .noSignature, "N")
        check(GitSignatureParser.tagStatus(rawMessage: "[GNUPG:] GOODSIG x\n[GNUPG:] VALIDSIG y") == .oneGood, "tag good")
        check(GitSignatureParser.tagStatus(rawMessage: "error: no signature found") == .tagNotSigned, "tag unsigned")
        check(GitSignatureParser.tagStatus(rawMessage: "[GNUPG:] ERRSIG x\n[GNUPG:] NO_PUBKEY y") == .missingPublicKey, "tag missing key")
        check(GitSignatureParser.tagStatus(rawMessage: "[GNUPG:] BADSIG x") == .oneBad, "tag bad")

        guard let gpg = gpgExecutable() else {
            print("BackendParityTests: gpg unavailable; signature integration skipped")
            return
        }
        let root = URL(fileURLWithPath: "/tmp/gk\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for home in ["signer", "empty", "untrusted"] {
                _ = try? shell("/usr/bin/env", ["gpgconf", "--kill", "gpg-agent"], in: root, environment: ["GNUPGHOME": root.appendingPathComponent(home).path])
            }
            try? FileManager.default.removeItem(at: root)
        }
        let signer = root.appendingPathComponent("signer"), empty = root.appendingPathComponent("empty"), untrusted = root.appendingPathComponent("untrusted")
        for home in [signer, empty, untrusted] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try shell(gpg, ["--batch", "--pinentry-mode", "loopback", "--passphrase", "", "--quick-gen-key", "Signer <signer@example.invalid>", "ed25519", "sign", "never"],
                  in: root, environment: ["GNUPGHOME": signer.path])
        let fingerprint = String(decoding: try shell(gpg, ["--batch", "--with-colons", "--list-secret-keys"], in: root, environment: ["GNUPGHOME": signer.path]), as: UTF8.self)
            .split(separator: "\n").first { $0.hasPrefix("fpr:") }.map { String($0.split(separator: ":", omittingEmptySubsequences: false)[9]) } ?? ""
        check(!fingerprint.isEmpty, "test key fingerprint")
        let publicKey = try shell(gpg, ["--batch", "--armor", "--export", fingerprint], in: root, environment: ["GNUPGHOME": signer.path])
        try shell(gpg, ["--batch", "--import"], in: root, environment: ["GNUPGHOME": untrusted.path], input: publicKey)

        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let signing = ["GNUPGHOME": signer.path]
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Signer"], ["config", "user.email", "signer@example.invalid"],
                          ["config", "user.signingkey", fingerprint], ["config", "gpg.program", gpg], ["config", "commit.gpgsign", "false"]] {
            _ = try git(arguments, in: repo)
        }
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        let base = try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo))
        try Data("signed\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-a", "-S", "-m", "signed"], in: repo, environment: signing)
        let signed = try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo))
        _ = try git(["tag", "-s", "-m", "signed tag", "v-signed", signed.string], in: repo, environment: signing)
        _ = try git(["tag", "-a", "-m", "plain tag", "v-plain", base.string], in: repo)
        _ = try git(["tag", "light", base.string], in: repo)
        try Data("many\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-a", "-m", "many"], in: repo)
        let many = try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo))
        _ = try git(["tag", "-a", "-m", "one", "m-one", many.string], in: repo)
        _ = try git(["tag", "-a", "-m", "two", "m-two", many.string], in: repo)

        func load(_ id: ObjectID, home: URL) async throws -> RevisionGPGInfo? {
            let module = GitRepositoryModule(repositoryURL: repo, git: EnvironmentGit(environment: [
                "GNUPGHOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]))
            let state = try await module.loadRepositoryState()
            return try await module.loadSignatureInfo(for: commit(id, references: state.references.referencesByCommit[id] ?? []))
        }

        let good = try await load(signed, home: signer)
        check(good?.commitStatus == .goodSignature, "good commit signature: \(String(describing: good))")
        check(good?.commitVerificationMessage.contains("Good signature") == true, "good commit message")
        check(good?.tagStatus == .oneGood && good?.tagVerificationMessage?.contains("Good signature") == true, "good tag signature")

        let missing = try await load(signed, home: empty)
        check(missing?.commitStatus == .missingPublicKey, "missing key commit: \(String(describing: missing))")
        check(missing?.tagStatus == .missingPublicKey, "missing key tag")

        let unknown = try await load(signed, home: untrusted)
        check(unknown?.commitStatus == .signatureError, "untrusted key commit: \(String(describing: unknown))")

        let plain = try await load(base, home: signer)
        check(plain?.commitStatus == .noSignature && plain?.tagStatus == .tagNotSigned, "unsigned annotated tag, lightweight ignored: \(String(describing: plain))")
        check(RevisionGPGPresentationResolver.resolve(info: plain).tag?.message == "Tag is not signed", "unsigned tag presentation")

        let multiple = try await load(many, home: signer)
        check(multiple?.tagStatus == .many, "many tags")
        check(multiple?.tagVerificationMessage?.contains("m-one\n") == true && multiple?.tagVerificationMessage?.contains("m-two\n") == true, "many tag messages")

        let unsignedOnly = try await load(try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo)), home: signer)
        check(unsignedOnly?.commitStatus == .noSignature, "unsigned commit with tags")
        let lightweightModule = GitRepositoryModule(repositoryURL: repo, git: EnvironmentGit(environment: ["GNUPGHOME": signer.path]))
        _ = try await lightweightModule.loadRepositoryState()
        let lightOnly = try await lightweightModule.loadSignatureInfo(for: commit(base, references: [RevisionReference(id: "refs/tags/light", name: "light", kind: .tag)]))
        check(lightOnly == nil, "unsigned commit with lightweight tag only is not signed")

        let cancelled = Task { try await lightweightModule.loadSignatureInfo(for: commit(signed, references: [])) }
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "cancellation ignored") } catch is CancellationError {}
    }

    static func repository(_ name: String) throws -> URL {
        let repo = try temporaryDirectory(name)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"], ["config", "user.email", "tester@example.invalid"]] {
            _ = try git(arguments, in: repo)
        }
        return repo
    }

    static func module(_ repo: URL) -> GitRepositoryModule {
        GitRepositoryModule(repositoryURL: repo, git: EnvironmentGit(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]))
    }

    @MainActor
    static func metadataEncoding() async throws {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        let repo = try repository("metadata")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "seed"], in: repo)
        let tree = try git(["rev-parse", "HEAD^{tree}"], in: repo)
        let seed = try git(["rev-parse", "HEAD"], in: repo)
        let identity = Data("Zo".utf8) + Data([0xEB]) + Data(" <zoe@example.invalid> 1700000000 +0000\n".utf8)
        let headered = Data("tree \(tree)\nparent \(seed)\nauthor ".utf8) + identity + Data("committer ".utf8) + identity
            + Data("encoding ISO-8859-1\n\n".utf8) + latin1 + Data("\n\nbody ".utf8) + latin1 + Data("\n".utf8)
        let first = try ObjectID.parse(try git(["hash-object", "-w", "-t", "commit", "--stdin"], in: repo, input: headered))
        let legacy = Data("tree \(tree)\nparent \(first.string)\nauthor ".utf8) + identity + Data("committer ".utf8) + identity
            + Data("\n".utf8) + Data([0x6F, 0x6C, 0xE9]) + Data("\n".utf8)
        let second = try ObjectID.parse(try git(["hash-object", "-w", "-t", "commit", "--stdin"], in: repo, input: legacy))
        _ = try git(["reset", "-q", "--soft", second.string], in: repo)
        _ = try git(["commit", "-q", "--allow-empty", "-m", "naïve"], in: repo)
        _ = try git(["config", "i18n.logOutputEncoding", "ISO-8859-1"], in: repo)

        let raw = try shell("/usr/bin/env", ["git", "log", "-1", "--format=%s", "HEAD"], in: repo)
        check(!String(decoding: raw, as: UTF8.self).contains("naïve"), "fixture: Git emits configured Latin1 log output")
        check(GitLogOutputEncoding.resolve(fromGetRegexp: "i18n.commitencoding ISO-8859-1\n") == .isoLatin1, "commit encoding fallback")
        check(GitLogOutputEncoding.resolve(fromGetRegexp: "i18n.commitencoding UTF-8\ni18n.logoutputencoding ISO-8859-1\n") == .isoLatin1, "log output encoding wins")
        check(GitLogOutputEncoding.resolve(fromGetRegexp: "") == .utf8, "default UTF-8")

        let module = module(repo)
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        defer { browser.viewWillDisappear(); window.close() }
        let deadline = ContinuousClock.now + .seconds(20)
        while browser.revisions.filter({ !$0.isArtificial }).count < 4 {
            check(ContinuousClock.now < deadline, "grid loaded")
            try await Task.sleep(for: .milliseconds(20))
        }
        let commits = browser.revisions.filter { !$0.isArtificial }
        check(commits[0].subject == "naïve", "grid: UTF-8 commit under Latin1 log output: \(commits.map(\.subject))")
        check(commits[1].subject == "olé", "grid: legacy headerless Latin1 commit decoded with logOutputEncoding")
        check(commits[2].subject == "café" && commits[2].body.contains("body café") && commits[2].authorName == "Zoë", "grid: Latin1 commit and author")
        let detail = try await module.git.run(CommitInfoCommands.messageAndNotes(first), in: repo)
        check(String(decoding: detail.standardOutput, as: UTF8.self).hasPrefix("café\n\nbody café"), "commit info body")
        let unflagged = try await module.git.run(GitCommand(arguments: ["log", "-1", "--format=%s", first.string], accessesRemote: false, changesRepositoryState: false), in: repo)
        check(String(data: unflagged.standardOutput, encoding: .utf8) == nil, "only metadata commands are transcoded")
    }

    static func diffEncoding() async throws {
        let repo = try repository("diff-encoding")
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = repo.appendingPathComponent("latin.txt")
        try Data([0x61, 0x0A, 0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: path)
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        try Data([0x61, 0x0A, 0x63, 0x61, 0x66, 0xE9, 0x73, 0x0A, 0x6E, 0x61, 0xEF, 0x66, 0x0A]).write(to: path)
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let file = ChangedFile(id: "latin.txt", path: "latin.txt", oldPath: nil, changeType: .modified, additions: 2, deletions: 1)
        let group = FileStatusGroup(first: .index, second: .workingDirectory, summary: "", files: [file])
        func lines(_ options: FileDiffOptions) async throws -> FileDiff {
            guard case .diff(let diff?) = try await module.loadFileStatusDiff(group: group, file: file, options: options, grep: GitGrepOptions()) else {
                check(false, "diff loaded"); fatalError()
            }
            return diff
        }
        var options = FileDiffOptions()
        let utf8 = try await lines(options)
        check(!utf8.lines.contains { $0.text == "café" } && utf8.lines.contains { $0.text.hasPrefix("caf") }, "default UTF-8 cannot decode Latin1")
        options.textEncoding = .westernISO88591
        let latin = try await lines(options)
        check(latin.lines.contains { $0.kind == .deletion && $0.text == "café" } && latin.lines.contains { $0.kind == .addition && $0.text == "naïf" },
              "selected encoding decodes diff body: \(latin.lines.map(\.text))")
        check(latin.lines.contains { $0.text.hasPrefix("diff --git a/latin.txt") }, "header remains UTF-8")
        options.useGitColoring = true
        let colored = try await lines(options)
        check(colored.lines.contains { $0.text == "naïf" }, "git-colored patch uses the selected encoding")
        options.useGitColoring = false
        options.appearance = .gitWordDiff
        let words = try await lines(options)
        check(words.lines.contains { $0.text.contains("naïf") }, "word diff uses the selected encoding: \(words.lines.map(\.text))")
        options.appearance = .patch
        options.textEncoding = .automatic
        _ = try git(["config", "i18n.filesEncoding", "ISO-8859-1"], in: repo)
        let configured = try await lines(options)
        check(configured.lines.contains { $0.text == "naïf" }, "i18n.filesEncoding backs the automatic encoding")
        let commitDiff = try await module.loadDiff(for: Commit(id: .workingDirectory, shortID: "", subject: "", body: "", authorName: "", authorEmail: "",
                                                               authorDate: Date(), committerName: "", committerEmail: "", commitDate: Date(),
                                                               parentIDs: [], references: [], kind: .workingDirectory), file: file, options: options)
        check(commitDiff?.lines.contains { $0.text == "naïf" } == true, "Commit loader uses the configured encoding")

        let added = latin.lines.filter { $0.kind == .addition && $0.text == "naïf" }.map(\.id)
        let result = try await module.applyLinePatch(.stage, file: file, diff: latin, lineIDs: Set(added))
        check(result.succeeded, "Latin1 line stage: \(result.output)")
        let staged = try shell("/usr/bin/env", ["git", "show", ":latin.txt"], in: repo)
        check(staged == Data([0x61, 0x0A, 0x63, 0x61, 0x66, 0xE9, 0x0A, 0x6E, 0x61, 0xEF, 0x66, 0x0A]), "staged Latin1 bytes preserved: \([UInt8](staged))")
    }

    static func materialization() async throws {
        let repo = try repository("materialize")
        defer { try? FileManager.default.removeItem(at: repo) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89,
                         0, 0, 0, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0, 1, 0, 0, 5, 0, 1, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        let binary = Data([0, 1, 2, 0, 0, 0x0A, 0, 0, 0xFF, 0x0A, 0, 0])
        let hasLFS = (try? shell("/usr/bin/env", ["git", "lfs", "version"], in: repo)) != nil
        if hasLFS {
            _ = try git(["lfs", "install", "--local"], in: repo)
            _ = try git(["lfs", "track", "*.png"], in: repo)
        }
        try png.write(to: repo.appendingPathComponent("image.png"))
        try binary.write(to: repo.appendingPathComponent("blob.dat"))
        try Data("one\ntwo\n".utf8).write(to: repo.appendingPathComponent("text.txt"))
        let missingPointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 12\n".utf8)
        try missingPointer.write(to: repo.appendingPathComponent("missing.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "files"], in: repo)
        let head = try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo))
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let output = try temporaryDirectory("export")
        defer { try? FileManager.default.removeItem(at: output) }

        func exported(_ path: String, _ revision: RevisionID = .object(head)) async throws -> Data {
            let url = output.appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent)
            try await module.exportFile(path: path, at: revision, to: url)
            return try Data(contentsOf: url)
        }
        if hasLFS {
            let rawPNG = try shell("/usr/bin/env", ["git", "cat-file", "blob", "\(head.string):image.png"], in: repo)
            check(rawPNG.starts(with: GitRepositoryModule.lfsPointerPrefix), "fixture: image is stored as an LFS pointer")
            check(try await exported("image.png") == png, "LFS export is smudged")
            let entries = try await module.loadRepositoryFiles(for: commit(head, references: []))
            let entry = entries.first { $0.path == "image.png" }!
            let presentation = try await module.loadFilePresentation(for: commit(head, references: []), file: entry, encoding: .automatic)
            check(presentation.kind == .image, "LFS image preview is materialized")
        } else {
            print("BackendParityTests: git-lfs unavailable; LFS smudge skipped")
        }
        check(try await exported("missing.txt") == missingPointer, "unavailable LFS object falls back to the pointer")
        check(try await exported("blob.dat") == binary, "binary bytes preserved")
        check(try await exported("text.txt") == Data("one\ntwo\n".utf8), "no autocrlf keeps LF")
        _ = try git(["config", "core.autocrlf", "true"], in: repo)
        check(try await exported("text.txt") == Data("one\r\ntwo\r\n".utf8), "autocrlf=true exports CRLF")
        check(try await exported("text.txt", .index) == Data("one\r\ntwo\r\n".utf8), "index export uses the same policy")
        check(try await exported("blob.dat") == binary, "autocrlf leaves binary content")
        _ = try git(["config", "core.autocrlf", "input"], in: repo)
        check(try await exported("text.txt") == Data("one\ntwo\n".utf8), "autocrlf=input keeps LF")
    }

    static func mergeFastForward() async throws {
        let repo = try repository("merge-ff")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["checkout", "-q", "-b", "topic"], in: repo)
        try Data("b\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-a", "-m", "topic"], in: repo)
        let topic = try git(["rev-parse", "HEAD"], in: repo)
        _ = try git(["checkout", "-q", "main"], in: repo)
        let base = try git(["rev-parse", "HEAD"], in: repo)
        _ = try git(["config", "merge.ff", "false"], in: repo)
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        _ = try await module.performMerge(RepositoryMergeRequest(targets: ["topic"]), output: { _ in })
        check(try git(["rev-parse", "HEAD"], in: repo) == topic, "allowed fast-forward overrides merge.ff=false")
        _ = try git(["reset", "-q", "--hard", base], in: repo)
        _ = try git(["config", "--unset", "merge.ff"], in: repo)
        _ = try await module.loadRepositoryState()
        _ = try await module.performMerge(RepositoryMergeRequest(targets: ["topic"], allowFastForward: false), output: { _ in })
        let parents = try git(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo).split(separator: " ").map(String.init)
        check(parents.count == 3 && parents[1] == base && parents[2] == topic, "disallowed fast-forward creates a merge commit")
    }

    static func nonInteractiveCredentials() async throws {
        check(RepositoryHostingCommands.credentialFill.arguments == ["-c", "credential.interactive=false", "credential", "fill"], "credential fill arguments")
        check(RepositoryHostingCommands.credentialFillEnvironment == ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"], "credential fill environment")
        let repo = try repository("credentials")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try git(["config", "--add", "credential.helper", ""], in: repo)
        _ = try git(["config", "--add", "credential.helper",
                     "!f() { test \"$1\" = get && printf \"username=u\\npassword=%s-%s-%s\\n\" \"$GCM_INTERACTIVE\" \"$GIT_TERMINAL_PROMPT\" \"$(git config credential.interactive)\"; }; f"], in: repo)
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let password = await module.hostCredentialPassword(for: URL(string: "https://dev.azure.com.invalid/org/Proj")!)
        check(password == "never-0-false", "helper runs non-interactively: \(String(describing: password))")
    }

    static func conflictingBranches(_ name: String) throws -> URL {
        let repo = try repository(name)
        _ = try git(["config", "rerere.enabled", "true"], in: repo)
        _ = try git(["config", "rerere.autoupdate", "true"], in: repo)
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["checkout", "-q", "-b", "topic"], in: repo)
        try Data("topic\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-a", "-m", "topic"], in: repo)
        _ = try git(["checkout", "-q", "main"], in: repo)
        try Data("main\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-a", "-m", "main"], in: repo)
        return repo
    }

    static func rerereContinuation() async throws {
        func state(merge: Bool = false, rebase: Bool = false, conflicts: [String] = []) -> RepositoryMutationState {
            RepositoryMutationState(currentBranch: "main", headID: nil, hasStagedChanges: false, hasUnstagedChanges: false, hasUntrackedFiles: false,
                                    conflictedPaths: conflicts, mergeInProgress: merge, cherryPickInProgress: false, revertInProgress: false, rebaseInProgress: rebase)
        }
        let resolved = "Resolved 'a.txt' using previous resolution.\nAutomatic merge failed; fix conflicts and then commit the result."
        check(GitActionContinuation.canContinueAction(output: resolved, state: state(merge: true)), "rerere merge can continue")
        check(GitActionContinuation.canContinueAction(output: resolved, state: state(rebase: true)), "rerere rebase can continue")
        check(!GitActionContinuation.canContinueAction(output: resolved, state: state()), "no operation in progress")
        check(!GitActionContinuation.canContinueAction(output: resolved, state: state(merge: true, conflicts: ["a.txt"])), "remaining conflicts block")
        check(!GitActionContinuation.canContinueAction(output: resolved + "\nAborted\n", state: state(merge: true)), "aborted output blocks")
        check(!GitActionContinuation.canContinueAction(output: "CONFLICT (content)", state: state(merge: true)), "no recorded resolution")

        let merge = try conflictingBranches("rerere-merge")
        defer { try? FileManager.default.removeItem(at: merge) }
        let mainHead = try git(["rev-parse", "HEAD"], in: merge)
        _ = try shell("/usr/bin/env", ["git", "merge", "topic"], in: merge, allowFailure: true)
        try Data("resolved\n".utf8).write(to: merge.appendingPathComponent("a.txt"))
        _ = try git(["add", "a.txt"], in: merge)
        _ = try git(["commit", "-q", "--no-edit"], in: merge)
        _ = try git(["reset", "-q", "--hard", mainHead], in: merge)
        let mergeModule = module(merge)
        _ = try await mergeModule.loadRepositoryState()
        let mergeResult = try await mergeModule.performMerge(RepositoryMergeRequest(targets: ["topic"]), output: { _ in })
        check(!mergeResult.command.succeeded && mergeResult.outcome == .readyToCommit, "rerere-resolved merge is ready to commit: \(mergeResult.outcome)")
        check(try String(contentsOf: merge.appendingPathComponent("a.txt"), encoding: .utf8) == "resolved\n", "recorded resolution applied")

        let rebase = try conflictingBranches("rerere-rebase")
        defer { try? FileManager.default.removeItem(at: rebase) }
        _ = try git(["checkout", "-q", "topic"], in: rebase)
        let topicHead = try git(["rev-parse", "HEAD"], in: rebase)
        _ = try shell("/usr/bin/env", ["git", "rebase", "main"], in: rebase, allowFailure: true)
        try Data("resolved\n".utf8).write(to: rebase.appendingPathComponent("a.txt"))
        _ = try git(["add", "a.txt"], in: rebase)
        _ = try git(["rebase", "--continue"], in: rebase, environment: ["GIT_EDITOR": "true"])
        _ = try git(["reset", "-q", "--hard", topicHead], in: rebase)
        let rebaseModule = module(rebase)
        _ = try await rebaseModule.loadRepositoryState()
        let rebaseResult = try await rebaseModule.rebase(RepositoryRebaseRequest(upstream: "main", autoStash: false))
        check(rebaseResult.outcome == .completed, "rerere-resolved rebase continues automatically: \(rebaseResult.outcome)")
        check(try git(["rev-parse", "HEAD^"], in: rebase) == (try git(["rev-parse", "main"], in: rebase)), "rebased onto main")
        check(try git(["show", "HEAD:a.txt"], in: rebase) == "resolved", "recorded rebase resolution committed")
        check(!FileManager.default.fileExists(atPath: rebase.appendingPathComponent(".git/rebase-merge").path), "rebase finished")
    }

    static func stashPromptAnswers() {
        check(StashReapplyAnswer(.alertFirstButtonReturn) == .apply && StashReapplyAnswer(.alertSecondButtonReturn) == .keep, "apply/keep")
        check(StashReapplyAnswer(.alertThirdButtonReturn) == .cancel && StashReapplyAnswer(.abort) == .cancel, "cancel")
        check(StashReapplyAnswer.apply.shouldApply && !StashReapplyAnswer.keep.shouldApply && !StashReapplyAnswer.cancel.shouldApply, "only apply pops")
        check(StashReapplyAnswer.apply.rememberedChoice(remember: true) == true, "remember apply")
        check(StashReapplyAnswer.keep.rememberedChoice(remember: true) == false, "remember keep")
        check(StashReapplyAnswer.cancel.rememberedChoice(remember: true) == nil, "cancel never persists")
        check(StashReapplyAnswer.keep.rememberedChoice(remember: false) == nil, "unchecked never persists")
    }

    static func deletionCandidates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gem-delete-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ path: String, _ type: FileChangeType, oldPath: String? = nil, tracked: Bool = true) -> ChangedFile {
            var value = ChangedFile(id: path, path: path, oldPath: oldPath, changeType: type, additions: 0, deletions: 0)
            value.isTracked = tracked
            return value
        }
        check(!FileStatusCommands.hasFilesWhichMayBeDeleted([file("deleted.txt", .deleted)], root: root), "deleted in revision")
        try? Data().write(to: root.appendingPathComponent("deleted.txt"))
        check(FileStatusCommands.hasFilesWhichMayBeDeleted([file("deleted.txt", .deleted)], root: root), "existing path")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("submodule"), withIntermediateDirectories: true)
        check(FileStatusCommands.hasFilesWhichMayBeDeleted([file("submodule", .added, tracked: false)], root: root), "existing directory")
        try? Data().write(to: root.appendingPathComponent("changed.txt"))
        check(!FileStatusCommands.hasFilesWhichMayBeDeleted([file("changed.txt", .modified)], root: root), "changed files are never deleted")
        try? Data().write(to: root.appendingPathComponent("old.txt"))
        check(FileStatusCommands.hasFilesWhichMayBeDeleted([file("new.txt", .renamed, oldPath: "old.txt")], root: root), "old rename name")
        try? Data().write(to: root.appendingPathComponent("added.txt"))
        check(FileStatusCommands.hasFilesWhichMayBeDeleted([file("gone.txt", .deleted), file("added.txt", .added, tracked: false)], root: root), "any item")
    }

    static func bothDeletedConflict() async throws {
        let repo = try repository("both-deleted")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("shared content\nline two\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["checkout", "-q", "-b", "side"], in: repo)
        _ = try git(["mv", "a.txt", "b.txt"], in: repo)
        _ = try git(["commit", "-q", "-m", "rename to b"], in: repo)
        _ = try git(["checkout", "-q", "main"], in: repo)
        _ = try git(["mv", "a.txt", "c.txt"], in: repo)
        _ = try git(["commit", "-q", "-m", "rename to c"], in: repo)
        _ = try shell("/usr/bin/env", ["git", "merge", "side"], in: repo, allowFailure: true)
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let conflicts = try await module.loadConflicts()
        let original = conflicts.first { $0.path == "a.txt" }
        check(original?.kind == .bothDeleted && original?.base != nil && original?.local == nil && original?.remote == nil,
              "base-only stage is both deleted: \(conflicts.map { ($0.path, $0.kind) })")
        check(RepositoryConflictDescription.text(for: .bothDeleted, rebase: false) == "The file has been deleted both locally (ours) and remotely (theirs).", "merge description")
        check(RepositoryConflictDescription.text(for: .bothDeleted, rebase: true) == "The file has been deleted both locally (theirs) and remotely (ours).", "rebase description")
        check(RepositoryConflictDescription.text(for: .unmerged, rebase: false).isEmpty, "unsupported combination has no description")
    }

    static func copiedLinePatching() {
        let diff = FileDiff(id: "d", fileID: "f", lines: [DiffLine(id: "0", oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "@@ -0,0 +1 @@"),
                                                          DiffLine(id: "1", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "x")])
        var copied = ChangedFile(id: "c", path: "copy.txt", oldPath: "orig.txt", changeType: .copied, additions: 1, deletions: 0)
        check(RevisionDiffViewController.supportsLinePatching(file: copied, diff: diff, fileExists: false, isBareRepository: false), "copied file without worktree file")
        copied.staged = .index
        check(RevisionDiffViewController.supportsLinePatching(file: copied, diff: diff, fileExists: true, isBareRepository: false), "copied file at index")
        var modified = ChangedFile(id: "m", path: "m.txt", oldPath: nil, changeType: .modified, additions: 1, deletions: 0)
        check(!RevisionDiffViewController.supportsLinePatching(file: modified, diff: diff, fileExists: false, isBareRepository: false), "modified file missing in worktree")
        modified.staged = .workTree
        check(RevisionDiffViewController.supportsLinePatching(file: modified, diff: diff, fileExists: true, isBareRepository: false), "existing file with hunks")
        check(!RevisionDiffViewController.supportsLinePatching(file: copied, diff: diff, fileExists: false, isBareRepository: true), "bare repository")
        let words = FileDiff(id: "d", fileID: "f", lines: diff.lines, appearance: .gitWordDiff)
        check(!RevisionDiffViewController.supportsLinePatching(file: copied, diff: words, fileExists: false, isBareRepository: false), "word diff")
    }

    @MainActor
    static func truthfulBrowserStatus() async throws {
        let repo = try repository("status")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        let browser = RepositoryBrowserViewController(repositoryModule: module(repo))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        defer { browser.viewWillDisappear(); window.close() }
        let deadline = ContinuousClock.now + .seconds(20)
        while browser.repositoryIdentity == nil {
            check(ContinuousClock.now < deadline, "browser loaded")
            try await Task.sleep(for: .milliseconds(20))
        }
        browser.uiCommands.completeSubmoduleOperation(RepositorySubmoduleResult(succeeded: true, changed: false, output: ""))
        check(browser.statusLabel.stringValue == "Submodules refreshed.", "real submodule completion: \(browser.statusLabel.stringValue)")
        browser.uiCommands.completeSubmoduleOperation(RepositorySubmoduleResult(succeeded: false, changed: false, output: "fatal: no submodule"))
        check(browser.statusLabel.stringValue == "fatal: no submodule", "real submodule error is reported verbatim")
        check(!browser.statusLabel.stringValue.contains("not implemented"), "no placeholder suffix")
    }

    @MainActor
    static func commitFileListControls() async throws {
        let repo = try repository("commit-controls")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("ignored.log\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("skip.txt"))
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("ignored.log"))
        _ = try git(["update-index", "--skip-worktree", "skip.txt"], in: repo)
        try Data("b\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let discovered = try await module.workingTreeDiscoveryFiles(ignored: true, assumeUnchanged: false, skipWorktree: true)
        check(discovered.contains { $0.path == "ignored.log" && $0.isIgnored } && discovered.contains { $0.path == "skip.txt" && $0.isSkipWorktree },
              "discovery capability: \(discovered.map(\.path))")

        let store = AppSettingsStore.shared
        let savedFileList = store.fileStatusListPreferences
        defer { store.saveFileStatusListPreferences(savedFileList) }
        var cleared = savedFileList; cleared.hiddenToolbarItems = []; store.saveFileStatusListPreferences(cleared)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let controller = CommitWorkflowDialog.present(source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                                                      onRepositoryChanged: { _ in }, onClose: {})
        let commitWindow = controller.window!
        defer { commitWindow.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func unstagedPaths() -> [String] {
            let lists = descendants(commitWindow.contentView!).compactMap { $0 as? NSOutlineView }
            guard let list = lists.first else { return [] }
            return (0..<list.numberOfRows).compactMap { (list.item(atRow: $0) as? ChangedFileNode)?.file?.path }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !unstagedPaths().contains("tracked.txt") {
            check(ContinuousClock.now < deadline, "commit loaded")
            try await Task.sleep(for: .milliseconds(20))
        }
        check(!unstagedPaths().contains("ignored.log") && !unstagedPaths().contains("skip.txt"), "hidden by default")
        let menus = descendants(commitWindow.contentView!).compactMap { $0 as? NSPopUpButton }.filter { $0.toolTip == "File list settings" }
        check(menus.count == 2, "two file list settings menus")
        let unstagedMenu = menus[0].menu!
        for title in ["Show ignored files", "Show skip-worktree files", "Show assumed-unchanged files", "Toolbar"] {
            check(unstagedMenu.items.first { $0.title == title }?.isEnabled == true, "\(title) enabled")
        }
        for title in ["Show ignored files", "Show skip-worktree files"] {
            let index = unstagedMenu.index(of: unstagedMenu.items.first { $0.title == title }!)
            unstagedMenu.performActionForItem(at: index)
        }
        let reload = ContinuousClock.now + .seconds(20)
        while !(unstagedPaths().contains("ignored.log") && unstagedPaths().contains("skip.txt")) {
            check(ContinuousClock.now < reload, "discovered files listed: \(unstagedPaths())")
            try await Task.sleep(for: .milliseconds(20))
        }
        let toolbarMenu = unstagedMenu.items.first { $0.title == "Toolbar" }!.submenu!
        check(toolbarMenu.items.first { $0.title == "Settings" }?.isEnabled == false, "settings button cannot be hidden")
        let byPath = toolbarMenu.items.first { $0.title == "Group by file path" }!
        check(byPath.state == .on, "toolbar item visible")
        toolbarMenu.performActionForItem(at: toolbarMenu.index(of: byPath))
        check(store.fileStatusListPreferences.hiddenToolbarItems.contains("btnByPath"), "toolbar visibility persisted")
        let pathButtons = descendants(commitWindow.contentView!).compactMap { $0 as? NSButton }.filter { $0.toolTip == "Group by file path" }
        check(!pathButtons.isEmpty && pathButtons.allSatisfy(\.isHidden) && byPath.state == .off, "toolbar item hidden in both lists")
    }

    static func agentRefsFilter() throws {
        let repo = try repository("agents")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["checkout", "-q", "-b", "agent-work"], in: repo)
        _ = try git(["commit", "-q", "--allow-empty", "-m", "agent only"], in: repo)
        let agent = try git(["rev-parse", "HEAD"], in: repo)
        _ = try git(["update-ref", "refs/agents/run/1", agent], in: repo)
        _ = try git(["checkout", "-q", "main"], in: repo)
        _ = try git(["branch", "-D", "agent-work"], in: repo)
        let head = try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo))
        let hidden = RevisionGridFilter().revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: false, showGitNotes: false, showSessionRefs: false)
        check(hidden.contains("--exclude=refs/agents/**") && hidden.firstIndex(of: "--exclude=refs/agents/**")! < hidden.firstIndex(of: "--exclude=refs/sessions/**")!, "agents excluded first")
        let hiddenLog = try git(["log", "--format=%H"] + hidden, in: repo)
        check(!hiddenLog.contains(agent), "agent history hidden")
        let shown = RevisionGridFilter().revisionArguments(currentCheckout: head, defaultCommitsLimit: 0, showStashes: false, showGitNotes: false, showSessionRefs: true)
        let shownLog = try git(["log", "--format=%H"] + shown, in: repo)
        check(!shown.contains("--exclude=refs/agents/**") && shownLog.contains(agent), "agent history shown when enabled")
    }

    @MainActor
    static func simplifyMergesDependency() {
        var filter = RevisionGridFilter()
        filter.showFullHistory = false
        filter.showSimplifyMerges = true
        let controller = RevisionFilterDialogController(filter: filter, defaultLimit: 100) { _ in }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        let fullHistory = buttons.first { $0.title == "Full history" }!
        let simplify = buttons.first { $0.title == "Simplify merges" }!
        check(!simplify.isEnabled && simplify.state == .on, "simplify merges disabled without full history, value kept")
        fullHistory.state = .on
        NSApp.sendAction(fullHistory.action!, to: fullHistory.target, from: fullHistory)
        check(simplify.isEnabled, "enabled with full history")
        fullHistory.state = .off
        NSApp.sendAction(fullHistory.action!, to: fullHistory.target, from: fullHistory)
        check(!simplify.isEnabled, "disabled again")
    }

    @MainActor
    static func cloneRecursivePreference() async throws {
        let legacy = try JSONDecoder().decode(RepositoryCreationPreferences.self, from: Data(#"{"recentSources":["x"],"cloneDestinationPath":"/tmp"}"#.utf8))
        check(legacy.cloneInitializeAllSubmodules && legacy.recentSources == ["x"], "legacy preferences keep data and default to recursive")
        let store = AppSettingsStore.shared
        let saved = store.repositoryCreationPreferences
        defer { store.saveRepositoryCreationPreferences(saved) }
        var preferences = saved; preferences.cloneInitializeAllSubmodules = false; store.saveRepositoryCreationPreferences(preferences)

        let origin = try repository("clone-origin")
        let destination = try temporaryDirectory("clone-destination")
        defer { try? FileManager.default.removeItem(at: origin); try? FileManager.default.removeItem(at: destination) }
        try Data("a\n".utf8).write(to: origin.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: origin)
        _ = try git(["commit", "-q", "-m", "base"], in: origin)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.makeKeyAndOrderFront(nil)
        defer { owner.close() }
        var created = false
        GitUICommands.startCloneRepository(source: GitRepositoryCreator(git: EnvironmentGit(environment: [:])), owner: owner, initialSource: origin.path, initialDestination: destination) { _ in created = true }
        let deadline = ContinuousClock.now + .seconds(10)
        while owner.attachedSheet == nil {
            check(ContinuousClock.now < deadline, "clone sheet")
            try await Task.sleep(for: .milliseconds(20))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let sheet = owner.attachedSheet!
        let buttons = descendants(sheet.contentView!).compactMap { $0 as? NSButton }
        let recursive = buttons.first { $0.title == "Initialize all submodules" }!
        check(recursive.state == .off, "remembered choice loaded")
        recursive.state = .on
        let fields = descendants(sheet.contentView!).compactMap { $0 as? NSComboBox }
        fields[0].stringValue = origin.path
        fields[1].stringValue = destination.path
        descendants(sheet.contentView!).compactMap { $0 as? NSTextField }.first { !($0 is NSComboBox) && $0.isEditable }!.stringValue = "cloned"
        let clone = buttons.first { $0.title == "Clone" }!
        NSApp.sendAction(clone.action!, to: clone.target, from: clone)
        check(store.repositoryCreationPreferences.cloneInitializeAllSubmodules, "choice saved when the clone starts")
        let finished = ContinuousClock.now + .seconds(30)
        while !created {
            check(ContinuousClock.now < finished, "clone finished")
            if let progress = sheet.attachedSheet,
               let ok = descendants(progress.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "OK" && $0.isEnabled }) {
                NSApp.sendAction(ok.action!, to: ok.target, from: ok)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("cloned").appendingPathComponent("a.txt").path), "clone created")
    }

    static func syntaxRegistry() {
        check(FileViewerSyntaxRegistry.modes.count == 91, "all upstream modes: \(FileViewerSyntaxRegistry.modes.count)")
        for (path, name) in [("a.lua", "Lua"), ("a.ps1", "PowerShell"), ("a.fs", "F#"), ("a.hs", "Haskell"), ("a.ini", "INI"),
                             (".editorconfig", "INI"), ("a.c", "C++"), ("a.h", "C++"), ("page.xhtml", "XML"), ("a.PY", "Python"),
                             ("x.vcxproj.filters", "XML"), ("a.yml", "YAML")] {
            check(FileViewerSyntaxRegistry.mode(for: path)?.name == name, "\(path) -> \(name): \(String(describing: FileViewerSyntaxRegistry.mode(for: path)?.name))")
        }
        check(FileViewerSyntaxRegistry.mode(for: "Dockerfile") == nil, "no upstream mode")
        func kinds(_ text: String, _ path: String) -> [(String, FileViewerSyntaxTokenKind)] {
            let mode = FileViewerSyntaxRegistry.mode(for: path)!
            return FileViewerSyntaxLexer.tokens(text, mode: mode).tokens.map { ((text as NSString).substring(with: $0.range), $0.kind) }
        }
        let python = kinds("def f(x): return 'a' # done", "a.py")
        check(python.contains { $0 == ("def", .keyword) } && python.contains { $0 == ("'a'", .string) } && python.contains { $0 == ("# done", .comment) }, "python \(python)")
        let python3 = FileViewerSyntaxLexer.lineStates(["x = \"\"\"doc", "still doc", "end\"\"\" + y"], mode: FileViewerSyntaxRegistry.mode(for: "a.py"))
        check(python3[0] == nil && python3[1] != nil && python3[2] != nil, "python triple-quoted block spans lines")
        let lua = FileViewerSyntaxLexer.lineStates(["--[[ start", "inside", "]] local x = 1"], mode: FileViewerSyntaxRegistry.mode(for: "a.lua"))
        check(lua[1] != nil && lua[2] != nil, "lua block comment spans lines")
        let luaEnd = kinds("]] local x", "a.lua")
        check(luaEnd.isEmpty || !luaEnd.contains { $0.0 == "local" && $0.1 == .comment }, "lua tokens")
        check(kinds("Get-Item -PATH $x # note", "a.ps1").contains { $0.1 == .comment }, "powershell comment")
        let csharp = kinds(#"var s = @"a""b"; // c"#, "a.cs")
        check(csharp.contains { $0 == (#"@"a""b""#, .string) } && csharp.contains { $0 == ("// c", .comment) } && csharp.contains { $0 == ("var", .keyword) }, "c# verbatim \(csharp)")
        check(kinds("let x = 1 (* note *)", "a.fs").contains { $0 == ("(* note *)", .comment) }, "f# comment")
        check(kinds("; setting", "a.ini").map { "\($0.0)|\($0.1)" } == ["; setting|comment"], "ini comment")
        check(kinds("key: true # c", "a.yaml").contains { $0 == ("true", .keyword) }, "yaml keyword")
        check(kinds("main = do -- c", "a.hs").contains { $0 == ("-- c", .comment) }, "haskell comment")
    }

    @MainActor
    static func commitSpelling() async throws {
        check(CommitSpelling.language(for: "none") == nil && CommitSpelling.language(for: "NONE") == nil, "none disables")
        check(CommitSpelling.dictionaryName(language: "en_US") == "en-US", "dictionary names")
        check(CommitSpelling.language(for: "en-US") != nil, "default dictionary maps to an available language")
        let store = AppSettingsStore.shared
        let saved = store.spellingDictionary
        defer { store.spellingDictionary = saved }
        store.spellingDictionary = "en-US"
        let repo = try repository("spelling")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let controller = CommitWorkflowDialog.present(source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                                                      onRepositoryChanged: { _ in }, onClose: {})
        let commitWindow = controller.window!
        defer { commitWindow.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let message = descendants(commitWindow.contentView!).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.delegate is NSViewController }!
        check(message.isContinuousSpellCheckingEnabled, "spell checking enabled for the dictionary")
        message.string = "teh"
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: commitWindow.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = message.delegate!.textView!(message, menu: NSMenu(), for: event, at: 1)!
        let titles = menu.items.map(\.title)
        check(titles.contains("the") && titles.contains("Add to dictionary") && titles.contains("Ignore word") && titles.contains("Remove word"),
              "spelling actions \(titles)")
        let dictionary = menu.items.first { $0.title == "Dictionary" }!.submenu!
        let effective = CommitSpelling.effectiveDictionary("en-US")
        check(dictionary.items.first?.title == "None" && dictionary.items.filter { $0.state == .on }.map(\.title) == [effective], "dictionary submenu checks the dictionary in effect")
        let none = dictionary.items.first!
        NSApp.sendAction(none.action!, to: none.target, from: none)
        check(store.spellingDictionary == "none" && !message.isContinuousSpellCheckingEnabled, "None disables live")
        message.string = "teh"
        let plain = message.delegate!.textView!(message, menu: NSMenu(), for: event, at: 1)!
        check(!plain.items.contains { $0.title == "Add to dictionary" }, "no spelling actions without a dictionary")
    }

    static func hoverCommit(_ id: String, _ parents: [String], _ refs: [RevisionReference] = [], date: Double = 1) -> Commit {
        Commit(id: testRevisionID(id), shortID: id, subject: id, body: "", authorName: "T", authorEmail: "t@example.com",
               authorDate: Date(timeIntervalSince1970: date), committerName: "T", committerEmail: "t@example.com",
               commitDate: Date(timeIntervalSince1970: date), parentIDs: parents.map(testObjectID), references: refs, kind: .revision)
    }

    @MainActor
    static func graphHoverCalculator() async {
        let main = RevisionReference(id: "refs/heads/main", name: "main", kind: .localBranch, trackingRemote: "origin", mergeWith: "main")
        let untracked = RevisionReference(id: "refs/heads/main", name: "main", kind: .localBranch)
        let origin = RevisionReference(id: "refs/remotes/origin/main", name: "origin/main", kind: .remoteBranch)
        let feature = RevisionReference(id: "refs/heads/feature", name: "feature", kind: .localBranch)
        let tag = RevisionReference(id: "refs/tags/v1", name: "v1", kind: .tag)

        func calculator(_ commits: [Commit], visible: @escaping () -> Range<Int>) -> (RevisionGraphHoverHighlight, (String) -> Int) {
            let layout = RevisionGraphLayout.build(commits: commits)
            let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
            let graph = RevisionGraphHoverHighlight.Graph(layout: layout, commits: byID)
            let rows = layout.rows.map(\.commitID)
            return (RevisionGraphHoverHighlight(graph: { graph }, visibleRange: visible), { rows.firstIndex(of: testRevisionID($0))! })
        }
        func ids(_ labels: String...) -> Set<RevisionID> { Set(labels.map(testRevisionID)) }

        let simple = [hoverCommit("tip", ["parent"], [untracked], date: 4), hoverCommit("other", ["root"], [feature], date: 3),
                      hoverCommit("parent", ["root"], date: 2), hoverCommit("root", [], date: 1)]
        var (hover, row) = calculator(simple) { 0..<4 }
        hover.compute(RevisionGraphHoverRef(untracked), row: row("tip"))
        check(hover.highlightedIDs == ids("tip", "parent", "root"), "local branch hover: tip and visible ancestors only")
        check(hover.consumeIsDirty() && !hover.consumeIsDirty(), "dirty is consumed once")
        check(!hover.compute(RevisionGraphHoverRef(untracked), row: row("tip")) && !hover.isDirty, "unchanged hover does not dirty")
        hover.compute(nil, row: -1)
        check(hover.highlightedIDs == nil && hover.isDirty, "null ref clears and dirties")

        let line = [hoverCommit("tip", ["parent"], [untracked], date: 3), hoverCommit("parent", ["root"], date: 2), hoverCommit("root", [], date: 1)]
        (hover, row) = calculator(line) { 0..<2 }
        hover.compute(RevisionGraphHoverRef(untracked), row: row("tip"))
        check(hover.highlightedIDs == ids("tip", "parent", "root"), "segment parent just below the visible range is included")
        (hover, row) = calculator(line) { 0..<1 }
        hover.compute(RevisionGraphHoverRef(untracked), row: row("tip"))
        check(hover.highlightedIDs == ids("tip", "parent"), "ancestors beyond the visible segment endpoints are not stored")

        let tracking = [hoverCommit("local", ["local0"], [main], date: 6), hoverCommit("feat", ["base"], [feature], date: 5),
                        hoverCommit("remote", ["base"], [origin], date: 4), hoverCommit("local0", ["base"], date: 3),
                        hoverCommit("base", [], date: 1)]
        (hover, row) = calculator(tracking) { 0..<5 }
        let pair = ids("local", "local0", "remote", "base")
        hover.compute(RevisionGraphHoverRef(main), row: row("local"))
        check(hover.highlightedIDs == pair, "local hover includes the tracked remote below: \(String(describing: hover.highlightedIDs))")
        hover.compute(RevisionGraphHoverRef(origin), row: row("remote"))
        check(hover.highlightedIDs == pair, "remote hover searches upward for the tracking local")
        hover.compute(RevisionGraphHoverRef(untracked), row: row("local"))
        check(hover.highlightedIDs == ids("local", "local0", "base"), "untracked local has no partner")
        hover.compute(RevisionGraphHoverRef(tag), row: row("feat"))
        check(hover.highlightedIDs == ids("feat", "base"), "tags highlight only their own ancestry")

        let virtualRemote = RevisionGraphHoverRef(nestled: main, completeName: "refs/remotes/origin/main", trackingBranchIsGone: false)
        check(virtualRemote.isRemote && virtualRemote.localName == "main" && virtualRemote.remote == "origin", "nestled remote identity")
        hover.compute(virtualRemote, row: row("local"))
        check(hover.highlightedIDs == pair, "nestled tracked-remote label includes the real remote")
        let gone = RevisionGraphHoverRef(nestled: main, completeName: "refs/remotes/origin/main", trackingBranchIsGone: true)
        hover.compute(gone, row: row("local"))
        check(hover.highlightedIDs == ids("local", "local0", "base"), "gone tracking branch does not search partners")
        let virtualLocal = RevisionGraphHoverRef(nestled: origin, completeName: "refs/heads/main", trackingBranchIsGone: false)
        check(virtualLocal.isHead && virtualLocal.mergeWith == "main" && virtualLocal.trackingRemote == "origin", "nestled local identity")
        hover.compute(virtualLocal, row: row("remote"))
        check(hover.highlightedIDs == pair, "nestled tracking-local label on a remote includes the real local")
        let hit = RevisionLabelHit(reference: RevisionReference(id: "refs/remotes/origin/main", name: "↑", kind: .remoteBranch),
                                   virtualTarget: "refs/remotes/origin/main", virtualSource: main)
        check(RevisionGraphHoverRef(hit: hit) == virtualRemote, "virtual label hit maps to a nestled ref")
        check(RevisionGraphHoverRef(hit: RevisionLabelHit(reference: main, isStash: true)) == nil, "stash labels clear")

        (hover, row) = calculator(tracking) { 0..<5 }
        let first = Task { @MainActor in await hover.set(RevisionGraphHoverRef(untracked), row: row("local")) }
        await Task.yield()
        let second = Task { @MainActor in await hover.set(RevisionGraphHoverRef(feature), row: row("feat")) }
        await first.value; await second.value
        check(hover.highlightedIDs == ids("feat", "base"), "rapid hover change publishes only the latest ref")
        _ = hover.consumeIsDirty()
        let pending = Task { @MainActor in await hover.set(RevisionGraphHoverRef(main), row: row("local")) }
        try? await Task.sleep(for: .milliseconds(20))
        await hover.set(nil)
        await pending.value
        check(hover.highlightedIDs == nil, "leaving before the debounce suppresses the stale hover")
        let started = ContinuousClock.now
        await hover.set(RevisionGraphHoverRef(main), row: row("local"))
        check(ContinuousClock.now - started >= .milliseconds(100) && hover.highlightedIDs == pair, "debounced by 100 ms")
    }

    @MainActor
    static func graphHoverGrid() async throws {
        let main = RevisionReference(id: "refs/heads/main", name: "main", kind: .currentBranch, trackingRemote: "origin", mergeWith: "main")
        let origin = RevisionReference(id: "refs/remotes/origin/main", name: "origin/main", kind: .remoteBranch)
        let side = RevisionReference(id: "refs/heads/side", name: "side", kind: .localBranch)
        var commits = [hoverCommit("m0", ["m1"], [main], date: 1_000), hoverCommit("s0", ["base"], [side], date: 999),
                       hoverCommit("m1", ["o0"], date: 998), hoverCommit("o0", ["base"], [origin], date: 997)]
        for index in 0..<120 {
            let id = index == 0 ? "base" : "old\(index)"
            let parents: [String] = index == 119 ? [] : ["old\(index + 1)"]
            commits.append(hoverCommit(id, parents, date: Double(900 - index)))
        }

        let grid = RevisionGridViewController()
        let window = NSWindow(contentViewController: grid)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 300))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        grid.apply(commits: commits)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = descendants(grid.view).compactMap { $0 as? NSTableView }.first!
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !predicate() {
                check(ContinuousClock.now < deadline, "grid hover: timed out waiting for \(label)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait("graph") { grid.cachedGraphRowCount >= 20 && table.numberOfRows == commits.count }
        let graphColumn = table.column(withIdentifier: .init("Graph"))
        let messageColumn = table.column(withIdentifier: .init("Message"))
        func row(_ id: String) -> Int { (0..<table.numberOfRows).first { grid.revisionID(atRow: $0) == testRevisionID(id) }! }
        func graphCell(_ row: Int) -> CommitGraphCellView { table.view(atColumn: graphColumn, row: row, makeIfNecessary: true) as! CommitGraphCellView }
        func labelPoint(_ row: Int, name: String? = nil) -> (RevisionMessageCellView, NSPoint, RevisionLabelHit)? {
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            guard let cell = table.view(atColumn: messageColumn, row: row, makeIfNecessary: false) as? RevisionMessageCellView else { return nil }
            cell.display()
            for x in stride(from: 2.0, to: cell.bounds.width, by: 2) {
                let point = cell.convert(NSPoint(x: x, y: cell.bounds.midY), to: nil)
                if let hit = cell.label(atWindowPoint: point), name == nil || hit.reference.name == name { return (cell, point, hit) }
            }
            return nil
        }
        func move(_ cell: RevisionMessageCellView, to point: NSPoint) {
            cell.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        }
        func exit(_ cell: RevisionMessageCellView) {
            cell.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        }
        func ids(_ labels: String...) -> Set<RevisionID> { Set(labels.map(testRevisionID)) }

        let m0 = row("m0"), s0 = row("s0"), o0 = row("o0")
        let baseline = (0..<8).map { graphCell($0).nodeDrawnGray }
        let (mainCell, mainPoint, mainHit) = labelPoint(m0, name: "main")!
        check(mainHit.reference.id == "refs/heads/main", "hovered label is the local branch")
        move(mainCell, to: mainPoint)
        check(grid.hoverHighlight.highlightedIDs == nil, "hover is debounced")
        try await wait("hover highlight") { graphCell(m0).hoverHighlightedIDs != nil }
        let highlighted = grid.hoverHighlight.highlightedIDs!
        check(highlighted.isSuperset(of: ids("m0", "m1", "o0", "base")) && !highlighted.contains(testRevisionID("s0")),
              "grid hover: local + tracked remote ancestry without the side branch")
        check(graphCell(m0).hoverHighlightedIDs == highlighted && graphCell(s0).hoverHighlightedIDs == highlighted, "visible graph cells refreshed")
        check(graphCell(s0).nodeDrawnGray && !graphCell(o0).nodeDrawnGray,
              "non-hovered ancestry is gray, hovered ancestry keeps lane color")

        exit(mainCell)
        try await wait("clear on leave") { graphCell(s0).hoverHighlightedIDs == nil }
        check(graphCell(s0).hoverHighlightedIDs == nil && (0..<8).map { graphCell($0).nodeDrawnGray } == baseline, "leave restores normal colors")

        move(mainCell, to: mainPoint)
        let (sideCell, sidePoint, _) = labelPoint(s0, name: "side")!
        exit(mainCell)
        move(sideCell, to: sidePoint)
        try await wait("rapid change") { grid.hoverHighlight.highlightedIDs?.contains(testRevisionID("s0")) == true }
        try await Task.sleep(for: .milliseconds(150))
        check(!grid.hoverHighlight.highlightedIDs!.contains(testRevisionID("m0")), "rapid hover keeps only the latest label")
        exit(sideCell)
        try await wait("clear side") { grid.hoverHighlight.highlightedIDs == nil }

        move(mainCell, to: mainPoint)
        try await wait("hover before scroll") { grid.hoverHighlight.highlightedIDs != nil }
        let before = grid.hoverHighlight.highlightedIDs!
        let scroll = table.enclosingScrollView!
        let target = row("old60")
        grid.hoverLocationInWindow = {
            let rect = table.rect(ofRow: target)
            return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: target).minY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await wait("scroll off the label clears") { grid.hoverHighlight.highlightedIDs == nil }
        check(!before.contains(testRevisionID("old60")), "initial highlight was limited to the visible range")

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let (originCell, originPoint, originHit) = labelPoint(o0, name: "origin/main")!
        move(originCell, to: originPoint)
        try await wait("hover remote") { graphCell(o0).hoverHighlightedIDs != nil }
        check(originHit.reference.kind == .remoteBranch, "remote label hit")
        func lastVisibleID() -> RevisionID {
            let visible = table.rows(in: table.visibleRect)
            return grid.revisionID(atRow: visible.location + visible.length - 1)!
        }
        let previousBottom = lastVisibleID()
        check(grid.hoverHighlight.highlightedIDs!.isSuperset(of: ids("m0", "m1", "o0", "base")), "remote hover includes the tracking local above")
        grid.hoverLocationInWindow = {
            guard let cell = table.view(atColumn: messageColumn, row: o0, makeIfNecessary: false) as? RevisionMessageCellView else { return .zero }
            for x in stride(from: 2.0, to: cell.bounds.width, by: 2) {
                let point = cell.convert(NSPoint(x: x, y: cell.bounds.midY), to: nil)
                if cell.label(atWindowPoint: point)?.reference.name == "origin/main" { return point }
            }
            return .zero
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 2).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        let newBottom = lastVisibleID()
        check(newBottom != previousBottom && !(grid.hoverHighlight.highlightedIDs ?? []).contains(newBottom), "scroll exposes rows outside the old set")
        try await wait("visible range update") {
            let visible = table.rows(in: table.visibleRect)
            return graphCell(visible.location + visible.length - 1).hoverHighlightedIDs?.contains(newBottom) == true
        }
        check(graphCell(table.rows(in: table.visibleRect).location + table.rows(in: table.visibleRect).length - 1).hoverHighlightedIDs?.contains(newBottom) == true,
              "newly visible graph cells use the recomputed set")
        grid.hoverLocationInWindow = nil
        exit(originCell)
        try await wait("clear before selection test") { grid.hoverHighlight.highlightedIDs == nil }

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        grid.selectCommit(id: testRevisionID("s0"))
        grid.highlightSelectedBranch()
        try await wait("selected branch") { grid.graphDrawStyle == .highlightSelected && graphCell(o0).nodeDrawnGray }
        check(!graphCell(s0).nodeDrawnGray, "selected branch colored")
        let (selCell, selPoint, _) = labelPoint(m0, name: "main")!
        move(selCell, to: selPoint)
        try await wait("hover over selected highlight") { graphCell(o0).hoverHighlightedIDs != nil && graphCell(s0).hoverHighlightedIDs != nil }
        check(!graphCell(o0).nodeDrawnGray && graphCell(s0).nodeDrawnGray,
              "hover overrides selected-branch coloring while active")
        check(grid.graphDrawStyle == .highlightSelected && grid.selectedCommits.map(\.id) == [testRevisionID("s0")], "hover leaves selection and draw style")
        exit(selCell)
        try await wait("clear over selected highlight") { graphCell(o0).hoverHighlightedIDs == nil }
        check(graphCell(o0).nodeDrawnGray && !graphCell(s0).nodeDrawnGray,
              "clearing hover restores selected-branch highlighting")
    }

    static func impactParsing() {
        let command = ImpactLog.command(respectMailmap: true)
        check(command.arguments == ["log", "--pretty=tformat:--- %ad --- %aN", "--numstat", "--date=short", "--find-copies", "--all", "--no-merges"]
              && command.decodesLogOutput && !command.changesRepositoryState, "impact log arguments")
        check(ImpactLog.command(respectMailmap: false).arguments[1] == "--pretty=tformat:--- %ad --- %an", "mailmap off uses raw author")
        check(ImpactLog.week(of: "2024-01-03", firstDayOfWeek: 0) == ImpactWeek(year: 2023, month: 12, day: 31), "Sunday-first week")
        check(ImpactLog.week(of: "2024-01-03", firstDayOfWeek: 1) == ImpactWeek(year: 2024, month: 1, day: 1), "Monday-first week")
        check(ImpactLog.week(of: "2024-01-07", firstDayOfWeek: 1) == ImpactWeek(year: 2024, month: 1, day: 8), "upstream Sunday rule with Monday-first")
        check(ImpactLog.week(of: "2024-02-30", firstDayOfWeek: 0) == nil, "invalid dates rejected")
        let output = "--- 2024-01-03 --- Alice\n\n3\t1\ta.txt\n-\t-\tbin.dat\n--- 2024-01-04 --- Bob --- Jr\n2\t0\tb.txt\n--- bad\n--- 2024-01-05 --- \n1\t1\tc.txt\n--- 2024-01-06 --- Carol\n"
        let commits = ImpactLog.parse(output, firstDayOfWeek: 0)
        check(commits.map(\.author) == ["Alice", "Bob --- Jr", "Carol"], "headers \(commits.map(\.author))")
        check(commits[0].data == ImpactDataPoint(commits: 1, addedLines: 3, deletedLines: 1), "numstat sums skip binary")
        check(commits[2].data == ImpactDataPoint(commits: 1, addedLines: 0, deletedLines: 0), "commit without files")
        var calls = 0
        check(ImpactLog.parse(output, firstDayOfWeek: 0, isCancelled: { calls += 1; return calls > 3 }).count < commits.count, "parsing stops on cancellation")
    }

    static func impactFixture() throws -> URL {
        let repo = try repository("impact")
        func commit(_ message: String, _ name: String, _ email: String, _ date: String, extra: [String] = []) throws {
            let environment = ["GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_AUTHOR_DATE": "\(date)T12:00:00",
                               "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email, "GIT_COMMITTER_DATE": "\(date)T12:00:00"]
            _ = try git(["commit", "-q", "-m", message] + extra, in: repo, environment: environment)
        }
        try Data("1\n2\n3\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "a.txt"], in: repo)
        try commit("c1", "Alice", "alice@example.invalid", "2024-01-03")
        try Data("1\nX\n3\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        try Data([0, 1, 2, 0, 255]).write(to: repo.appendingPathComponent("bin.dat"))
        _ = try git(["add", "."], in: repo)
        try commit("c2", "Bob", "bob@example.invalid", "2024-01-10")
        _ = try git(["checkout", "-q", "-b", "side", "HEAD~1"], in: repo)
        try Data("x\ny\n".utf8).write(to: repo.appendingPathComponent("b.txt"))
        _ = try git(["add", "b.txt"], in: repo)
        try commit("c3", "alias", "alice@old.invalid", "2024-01-17")
        _ = try git(["checkout", "-q", "main"], in: repo)
        let mergeEnvironment = ["GIT_AUTHOR_NAME": "Bob", "GIT_AUTHOR_EMAIL": "bob@example.invalid", "GIT_AUTHOR_DATE": "2024-01-24T12:00:00",
                                "GIT_COMMITTER_NAME": "Bob", "GIT_COMMITTER_EMAIL": "bob@example.invalid", "GIT_COMMITTER_DATE": "2024-01-24T12:00:00"]
        _ = try git(["merge", "-q", "--no-ff", "-m", "merge", "side"], in: repo, environment: mergeEnvironment)
        _ = try git(["checkout", "-q", "-b", "other"], in: repo)
        try Data("p\nq\nr\n".utf8).write(to: repo.appendingPathComponent("c.txt"))
        _ = try git(["add", "c.txt"], in: repo)
        try commit("c4", "Carol", "carol@example.invalid", "2024-01-31")
        _ = try git(["checkout", "-q", "main"], in: repo)
        try Data("Alice <alice@example.invalid> <alice@old.invalid>\n".utf8).write(to: repo.appendingPathComponent(".mailmap"))
        return repo
    }

    static func impactRepository() async throws {
        let repo = try impactFixture()
        defer { try? FileManager.default.removeItem(at: repo) }
        let source = module(repo)
        _ = try await source.loadRepositoryState()
        func summary(_ commits: [ImpactCommit]) -> [String] {
            commits.map { "\($0.author)|\($0.week.year)-\($0.week.month)-\($0.week.day)|\($0.data.commits)/\($0.data.addedLines)/\($0.data.deletedLines)" }.sorted()
        }
        let mapped = try await source.impactCommits(submodulePath: nil, respectMailmap: true, firstDayOfWeek: 0)
        check(summary(mapped) == ["Alice|2023-12-31|1/3/0", "Alice|2024-1-14|1/2/0", "Bob|2024-1-7|1/1/1", "Carol|2024-1-28|1/3/0"],
              "real history: --all, --no-merges, mailmap, binary skipped: \(summary(mapped))")
        let raw = try await source.impactCommits(submodulePath: nil, respectMailmap: false, firstDayOfWeek: 0)
        check(Set(raw.map(\.author)) == ["Alice", "Bob", "alias", "Carol"], "mailmap off keeps raw names")
        let noSubmodules = try await source.impactSubmodulePaths()
        check(noSubmodules.isEmpty, "no submodules")

        let sub = try repository("impact-sub")
        defer { try? FileManager.default.removeItem(at: sub) }
        try Data("s\n".utf8).write(to: sub.appendingPathComponent("s.txt"))
        _ = try git(["add", "."], in: sub)
        _ = try git(["commit", "-q", "-m", "sub"], in: sub, environment: ["GIT_AUTHOR_NAME": "Dana", "GIT_AUTHOR_EMAIL": "dana@example.invalid",
                                                                          "GIT_AUTHOR_DATE": "2024-02-07T12:00:00"])
        _ = try git(["-c", "protocol.file.allow=always", "submodule", "-q", "add", sub.path, "mods/sub"], in: repo)
        _ = try git(["config", "-f", ".gitmodules", "submodule.ghost.path", "ghost"], in: repo)
        _ = try git(["config", "-f", ".gitmodules", "submodule.ghost.url", "./ghost"], in: repo)
        let submodulePaths = try await source.impactSubmodulePaths()
        check(submodulePaths == ["mods/sub"], "only initialized submodules from .gitmodules: \(submodulePaths)")
        let subCommits = try await source.impactCommits(submodulePath: "mods/sub", respectMailmap: true, firstDayOfWeek: 0)
        check(subCommits.map(\.author) == ["Dana"], "submodule history")
        do {
            _ = try await source.impactCommits(submodulePath: "missing-dir", respectMailmap: true, firstDayOfWeek: 0)
            check(false, "missing submodule directory must fail")
        } catch {}
    }

    final class FakeImpactSource: RepositoryImpactDataSource, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var delays: [String: Duration] = [:]
        var failures: Set<String> = []
        var submodules: [String] = []
        var results: [String: [ImpactCommit]] = [:]
        var recorded: [String] { lock.withLock { calls } }
        func impactCommits(submodulePath: String?, respectMailmap: Bool, firstDayOfWeek: Int) async throws -> [ImpactCommit] {
            let key = submodulePath ?? ""
            let (delay, fails, result) = lock.withLock { () -> (Duration?, Bool, [ImpactCommit]) in
                calls.append(key + (respectMailmap ? "" : "!"))
                return (delays[key], failures.contains(key), results[key] ?? [])
            }
            if let delay { try await Task.sleep(for: delay) }
            if fails { throw NSError(domain: "impact", code: 1, userInfo: [NSLocalizedDescriptionKey: "impact failure \(key)"]) }
            return result
        }
        func impactSubmodulePaths() async throws -> [String] { lock.withLock { submodules } }
    }

    static func impactCommitFixture(_ author: String, _ day: Int, added: Int = 1) -> ImpactCommit {
        ImpactCommit(week: ImpactWeek(year: 2024, month: 1, day: day), author: author, data: ImpactDataPoint(commits: 1, addedLines: added, deletedLines: 0))
    }

    @MainActor
    static func impactLoaderLifecycle() async throws {
        let fake = FakeImpactSource()
        fake.results = ["": [impactCommitFixture("A", 1)], "sub": [impactCommitFixture("S", 8)], "slow": [impactCommitFixture("L", 15)]]
        fake.delays = ["slow": .milliseconds(300)]
        let loader = ImpactLoader(source: fake, respectMailmap: true, firstDayOfWeek: 0)
        var batches: [[String]] = []
        var exits = 0
        var errors: [String] = []
        loader.onCommitsLoaded = { batches.append($0.map(\.author)) }
        loader.onExited = { exits += 1 }
        loader.onError = { errors.append($0.localizedDescription) }
        func settle(_ duration: Duration = .milliseconds(80)) async throws { try await Task.sleep(for: duration) }
        try await settle()
        check(fake.recorded == [""], "main history prefetched before execution")
        loader.execute()
        try await settle()
        check(batches == [["A"]] && exits == 1 && fake.recorded == [""], "start replays the prefetched main history")
        loader.execute()
        try await settle()
        check(batches == [["A"], ["A"]] && exits == 2 && fake.recorded == [""], "restart replays cached history")

        fake.submodules = ["sub"]
        loader.showSubmodules = true
        loader.execute()
        try await settle()
        check(batches.suffix(2).map { $0 } .sorted { $0[0] < $1[0] } == [["A"], ["S"]] && exits == 3 && fake.recorded == ["", "sub"], "initialized submodules included")

        batches = []
        fake.submodules = ["slow"]
        loader.execute()
        try await settle(.milliseconds(50))
        loader.stop()
        try await settle(.milliseconds(400))
        check(!batches.contains(["L"]) && exits == 3, "stop suppresses the in-flight result and exit")
        loader.execute()
        try await settle(.milliseconds(30))
        loader.showSubmodules = false
        try await settle(.milliseconds(400))
        check(!batches.contains(["L"]) && exits == 3, "toggling submodules stops the current run")
        check(fake.recorded.filter { $0 == "slow" }.count == 2, "cancelled loads are not cached")

        fake.submodules = ["bad"]
        fake.failures = ["bad"]
        loader.showSubmodules = true
        loader.execute()
        try await settle()
        check(errors == ["impact failure bad"] && exits == 4, "errors are reported and the run still exits")
        loader.execute()
        try await settle()
        check(fake.recorded.filter { $0 == "bad" }.count == 2 && errors.count == 2, "failures are retried on restart")

        loader.dispose()
        let before = (batches.count, exits)
        loader.execute()
        try await settle()
        check(batches.count == before.0 && exits == before.1, "disposed loader does nothing")

        let raw = ImpactLoader(source: fake, respectMailmap: false, firstDayOfWeek: 0)
        try await settle()
        check(fake.recorded.last == "!", "mailmap flag reaches the history read")
        raw.dispose()
    }

    @MainActor
    static func impactModel() {
        var model = ImpactGraphModel()
        model.add([impactCommitFixture("A", 1, added: 10), impactCommitFixture("B", 8, added: 5), impactCommitFixture("A", 15, added: 1),
                   impactCommitFixture("A", 1, added: 2)])
        check(model.authorStack == ["B", "A"], "new authors are inserted at the front")
        check(model.authorInfo("A") == ImpactDataPoint(commits: 3, addedLines: 13, deletedLines: 0), "author totals")
        check(model.impact[ImpactWeek(year: 2024, month: 1, day: 1)]!.values["A"]!.addedLines == 12, "weekly sums")
        check(model.impact[ImpactWeek(year: 2024, month: 1, day: 8)]!.values["A"] == .zero, "intermediate empty week for A")
        check(model.impact[ImpactWeek(year: 2024, month: 1, day: 15)]!.values["B"] == nil, "no trailing weeks for B")
        check(ImpactGraphModel.blockHeight(changedLines: 0) == 1 && ImpactGraphModel.blockHeight(changedLines: 1) == 1
              && ImpactGraphModel.blockHeight(changedLines: 100) == 40, "upstream block height formula")
        let layout = model.layout(height: 400)
        check(layout.width == 3 * 110 - 50 && layout.weekLabels.count == 3, "graph width and week labels")
        let first = layout.blocks["A"]!
        check(first.count == 3 && first[0].rect.minY == 0 && first[0].rect.minX == 0 && first[1].rect.minX == 110, "A blocks across weeks")
        let week2 = (layout.blocks["B"]![0].rect, layout.blocks["A"]![1].rect)
        check(week2.0.minY == 0 && week2.1.minY > week2.0.maxY, "larger change stacks first")
        let tallest = layout.blocks.values.flatMap { $0 }.map(\.rect.maxY).max()!
        check(tallest <= 400 * 0.9 + 1 && tallest > 300, "heights scaled to 90% of the view")
        check(layout.lineLabels["A"]!.map(\.text).contains("12"), "line labels on tall blocks")
        check(model.layout(height: 10).lineLabels.values.allSatisfy(\.isEmpty), "no line labels on short blocks")
        let view = ImpactGraphView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.viewportHeight = 400
        view.add([impactCommitFixture("A", 1, added: 10), impactCommitFixture("B", 8, added: 5), impactCommitFixture("A", 15, added: 1)])
        let block = view.layout.blocks["B"]![0].rect
        check(view.selectAuthor(at: NSPoint(x: block.midX, y: block.midY)) && view.selectedAuthor == "B", "hit-test selects the author path")
        check(!view.selectAuthor(at: NSPoint(x: block.midX, y: block.midY)), "same author does not reselect")
        check(!view.selectAuthor(at: NSPoint(x: 5, y: 399)) && view.selectedAuthor == "B", "empty space keeps the selection")
        check(ImpactGraphModel.color(for: "A", dark: false) == ImpactGraphModel.color(for: "A", dark: false), "stable author colors")
    }

    @MainActor
    static func impactWorkflow() async throws {
        let plugin = BuiltInPlugins.make().first { $0.kind == .impact }!
        let settingsPage = try plugin.settingsController(in: GitExtensionPluginHost(refresh: {}, navigate: { _ in },
                                                                                    readSetting: { _, _ in nil }, writeSetting: { _, _, _ in }))
        check(plugin.identifier == UUID(uuidString: "F1ACFE42-6A5E-4C30-AC10-9A7C4BB8B480") && plugin.name == "Impact Graph"
              && plugin.requiresRepository && plugin.settings.isEmpty && settingsPage == nil, "Impact Graph registration")
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !predicate() {
                check(ContinuousClock.now < deadline, "impact: timed out waiting for \(label)")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        let repo = try impactFixture()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sub = try repository("impact-window-sub")
        defer { try? FileManager.default.removeItem(at: sub) }
        try Data("s\n".utf8).write(to: sub.appendingPathComponent("s.txt"))
        _ = try git(["add", "."], in: sub)
        _ = try git(["commit", "-q", "-m", "sub"], in: sub, environment: ["GIT_AUTHOR_NAME": "Dana", "GIT_AUTHOR_EMAIL": "dana@example.invalid"])
        _ = try git(["-c", "protocol.file.allow=always", "submodule", "-q", "add", sub.path, "mods/sub"], in: repo)
        _ = try git(["commit", "-q", "-m", "add sub"], in: repo, environment: ["GIT_AUTHOR_NAME": "Alice", "GIT_AUTHOR_EMAIL": "alice@example.invalid"])
        let source = module(repo)
        _ = try await source.loadRepositoryState()

        let controller = ImpactWindowController(source: source, firstDayOfWeek: 0)
        controller.present(owner: nil) {}
        check(controller.window?.title == "Impact" && controller.submodules.title == "Including submodules" && controller.submodules.state == .off, "Impact window")
        check(controller.authorLabel.isHidden && controller.authorColor.isHidden, "no author shown initially")
        try await wait("history") { controller.graph.model.authorStack.count == 3 }
        check(Set(controller.graph.model.authorStack) == ["Alice", "Bob", "Carol"] && controller.progress.isHidden, "mailmap-aware graph loaded")
        let alice = controller.graph.layout.blocks["Alice"]!.last!.rect
        check(controller.graph.selectAuthor(at: NSPoint(x: alice.midX, y: alice.midY)), "pointer selects an author")
        let info = controller.graph.model.authorInfo("Alice")
        check(!controller.authorLabel.isHidden && controller.authorLabel.stringValue == "Alice (\(info.commits) Commits, \(info.changedLines) Changed Lines)"
              && info.commits == 3, "author info: \(controller.authorLabel.stringValue)")
        controller.submodules.state = .on
        NSApp.sendAction(controller.submodules.action!, to: controller.submodules.target, from: controller.submodules)
        check(controller.authorLabel.isHidden, "toggling submodules hides author info")
        try await wait("submodule history") { controller.graph.model.authorStack.contains("Dana") }
        check(controller.graph.model.authorStack.count == 4, "main and submodule history combined")
        controller.submodules.state = .off
        NSApp.sendAction(controller.submodules.action!, to: controller.submodules.target, from: controller.submodules)
        try await wait("main only") { controller.graph.model.authorStack.count == 3 }
        check(!controller.graph.model.authorStack.contains("Dana"), "submodules excluded again")
        controller.close()
        controller.loader.execute()
        try await Task.sleep(for: .milliseconds(100))
        check(controller.graph.model.authorStack.count == 3, "closing disposes the loader")

        let failing = FakeImpactSource()
        failing.failures = [""]
        let broken = ImpactWindowController(source: failing, firstDayOfWeek: 0)
        broken.present(owner: nil) {}
        try await wait("error") { !broken.errorLabel.isHidden }
        check(broken.errorLabel.stringValue == "impact failure " && broken.progress.isHidden, "error surfaced")
        broken.close()

        let host = GitExtensionPluginHost(refresh: {}, navigate: { _ in }, readSetting: { _, _ in nil }, writeSetting: { _, _, _ in })
        let withoutRepository = try await plugin.execute(in: host)
        check(withoutRepository == false, "no repository: nothing to show")
        host.update(context: ["WorkingDir": [repo.path]], owner: nil)
        host.builtInRepository = source
        let run = Task { @MainActor in try await plugin.execute(in: host) }
        var shown: NSWindow?
        try await wait("plugin window") {
            shown = NSApp.windows.first { $0.title == "Impact" && $0.isVisible }
            return shown != nil
        }
        shown!.close()
        let executed = try await run.value
        check(executed == false, "plugin returns without requesting a refresh")
    }

    @MainActor
    static func commitPushTarget() async throws {
        func target(_ remote: String, _ merge: String, _ remotes: [String]) -> String {
            CommitPushTarget.describe(RepositoryBranchTracking(branch: "main", trackingRemote: remote, mergeWith: merge, remotes: remotes))
        }
        check(target("upstream", "trunk", ["origin"]) == "upstream/trunk", "tracked remote/merge")
        check(target("origin", "", ["origin"]) == "origin/", "tracking remote without merge is still tracked")
        check(target("", "", ["zeta", "origin"]) == "origin/main (untracked)", "origin preferred")
        check(target("", "", ["zeta", "alpha"]) == "alpha/main (untracked)", "alphabetical fallback")
        check(target("", "", []) == "(remote not configured)", "no remotes")

        let repo = try repository("push-target")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["remote", "add", "origin", "https://example.invalid/r.git"], in: repo)
        _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        _ = try git(["config", "branch.main.remote", "origin"], in: repo)
        _ = try git(["config", "branch.main.merge", "refs/heads/main"], in: repo)
        let module = module(repo)
        _ = try await module.loadRepositoryState()
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        var managed: (String?, String?)?
        let controller = CommitWorkflowDialog.present(source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                                                      onManageRemotes: { managed = ($0, $1) }, onRepositoryChanged: { _ in }, onClose: {})
        let commitWindow = controller.window!
        defer { commitWindow.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func statusText() -> String? { descendants(commitWindow.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue).first { $0.contains(" staged / ") } }
        let deadline = ContinuousClock.now + .seconds(10)
        while statusText()?.contains("main \u{2192} origin/main") != true {
            check(ContinuousClock.now < deadline, "commit push target: \(statusText() ?? "nil")")
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try git(["config", "--unset", "branch.main.remote"], in: repo)
        _ = try git(["config", "--unset", "branch.main.merge"], in: repo)
        let manage = descendants(commitWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Manage tracking…" }!
        NSApp.sendAction(manage.action!, to: manage.target, from: manage)
        check(managed?.0 == nil && managed?.1 == "main", "manage tracking opens remotes for the current branch")
        for _ in 0..<2 { commitWindow.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: commitWindow)) }
        let refreshed = ContinuousClock.now + .seconds(10)
        while statusText()?.contains("main \u{2192} origin/main (untracked)") != true {
            check(ContinuousClock.now < refreshed, "push target refreshed after tracking changes: \(statusText() ?? "nil")")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func scriptOptionSelection() async throws {
        let base: [String: [String]] = [
            "sBranch": ["feature", "origin/feature"], "sLocalBranch": ["feature"], "sTag": [""],
            "sRemoteBranch": ["origin/feature", "fork/feature"], "sRemoteBranchName": ["feature", "feature"],
            "sRemote": ["fork", "origin"], "sRemoteUrl": ["", "https://example.invalid/o.git"], "sRemotePathFromUrl": ["", "/o"],
            "cBranch": ["main"], "cDefaultRemote": [""], "cDefaultRemoteUrl": [""], "cDefaultRemotePathFromUrl": [""],
            ScriptOptionSelection.defaultRemoteBranches: ["a", "b"], ScriptOptionSelection.defaultRemoteRemotes: ["up", "origin"],
            ScriptOptionSelection.defaultRemoteURLs: ["git@example.invalid:up/r.git", "https://example.invalid/o.git"]]
        var asked: [(String, [String])] = []
        func resolve(_ arguments: String, _ answers: [Int?]) -> [String: [String]] {
            var queue = answers
            asked = []
            return ScriptOptionSelection.resolve(base, arguments: arguments) { option, choices in
                asked.append((option, choices))
                return queue.isEmpty ? nil : queue.removeFirst()
            }
        }
        var result = resolve("{sLocalBranch} {sTag} {sHash}", [])
        check(asked.isEmpty && result["sLocalBranch"] == ["feature"] && result["sTag"] == [""], "single and empty candidates do not prompt")
        result = resolve("{{sRemoteUrl}} {sBranch}", [1, 0])
        check(asked.map(\.0) == ["sBranch", "sRemoteUrl"] && asked[1].1 == ["fork", "origin"], "upstream option order; URL chosen by remote: \(asked.map(\.0))")
        check(result["sBranch"] == ["origin/feature"] && result["sRemoteUrl"] == [""], "choices map by index, including an empty URL")
        result = resolve("{sRemoteBranchName}", [1])
        check(asked.first?.1 == ["origin/feature", "fork/feature"] && result["sRemoteBranchName"] == ["feature"], "branch name chosen from remote branches")
        result = resolve("{sBranch} {sRemote}", [nil, nil])
        check(asked.count == 2 && result["sBranch"] == [""] && result["sRemote"] == [""], "cancel substitutes an empty value and continues")
        result = resolve("{cBranch} {cDefaultRemotePathFromUrl}", [0])
        check(asked.map(\.0) == ["cDefaultRemote"] && asked[0].1 == ["a", "b"] && result["cDefaultRemote"] == ["up"]
              && result["cDefaultRemotePathFromUrl"] == ["/up/r"], "current remote asked among local branches at HEAD")
        check(result[ScriptOptionSelection.defaultRemoteBranches] == nil, "internal candidates removed")
        result = resolve("{HEAD}", [nil])
        check(asked.count == 1 && result["cDefaultRemote"] == [""], "HEAD also resolves the current remote; cancel leaves it empty")

        let repo = try repository("script-options")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["remote", "add", "up", "git@example.invalid:up/r.git"], in: repo)
        _ = try git(["branch", "other"], in: repo)
        _ = try git(["config", "branch.other.remote", "up"], in: repo)
        _ = try git(["checkout", "-q", "--detach"], in: repo)
        let source = module(repo)
        _ = try await source.loadRepositoryState()
        let context = try await source.scriptContext(selected: [], arguments: "{cDefaultRemote}")
        check(context[ScriptOptionSelection.defaultRemoteBranches] == ["main", "other"] && context[ScriptOptionSelection.defaultRemoteRemotes] == ["", "up"],
              "detached HEAD with several local branches offers a choice: \(context)")
        _ = try git(["branch", "-D", "main"], in: repo)
        let single = try await source.scriptContext(selected: [], arguments: "{cDefaultRemote}")
        check(single["cDefaultRemote"] == ["up"] && single["cDefaultRemoteUrl"] == ["git@example.invalid:up/r.git"], "single local branch at HEAD supplies the remote")
    }

    @MainActor
    static func sortingSettings() async throws {
        let defaultPatterns = CommitInfoPresentation.prioritizedBranchNames
        check(["main", "master2", "release/1.0"].allSatisfy { CommitInfoPresentation.priorityIndex($0, patterns: defaultPatterns) == 0 }
              && CommitInfoPresentation.priorityIndex("feature", patterns: defaultPatterns) == nil, "upstream default is one priority level")
        check(CommitInfoPresentation.priorityIndex("main", patterns: " release/.* ; main ") == 1
              && CommitInfoPresentation.priorityIndex("release/x", patterns: "release/.*;main") == 0
              && CommitInfoPresentation.priorityIndex("mainline", patterns: "main") == nil, "';' separates anchored priority levels")
        let legacy = try JSONDecoder().decode(RepositoryTreePreferences.self, from: Data(#"{"sortBy":"alphaNumeric","sortOrder":"descending"}"#.utf8))
        check(legacy.prioritizedBranchNames == defaultPatterns && legacy.prioritizedRemoteNames == "origin|upstream" && legacy.sortOrder == .descending,
              "older tree preferences keep values and get upstream defaults")

        let id = testObjectID("sorting")
        func branch(_ name: String, remote: Bool = false) -> Branch {
            Branch(id: (remote ? "refs/remotes/" : "refs/heads/") + name, name: name, commitID: id, isCurrent: false, isRemote: remote, remoteName: nil, ahead: 0, behind: 0)
        }
        let references = RepositoryReferenceState(branches: [branch("alpha"), branch("main"), branch("zeta")], tags: [], referencesByCommit: [:])
        let remotes = ["aaa", "fork", "origin"].map { Remote(id: $0, name: $0, fetchURL: "https://example.invalid/\($0).git", branches: [], isDisabled: false) }
        let navigation = RepositoryNavigationState(remotes: remotes, stashes: [], worktrees: [], submodules: [])
        var preferences = RepositoryTreePreferences()
        var roots = RepositoryTreeBuilder.build(references: references, navigation: navigation, preferences: preferences)
        check(roots[0].children.map(\.title) == ["main", "alpha", "zeta"] && roots[1].children.map(\.title) == ["origin", "aaa", "fork"], "default priorities")
        preferences.prioritizedBranchNames = "zeta;main"
        preferences.prioritizedRemoteNames = "fork"
        roots = RepositoryTreeBuilder.build(references: references, navigation: navigation, preferences: preferences)
        check(roots[0].children.map(\.title) == ["zeta", "main", "alpha"] && roots[1].children.map(\.title) == ["fork", "aaa", "origin"],
              "configured priorities drive the left panel: \(roots[0].children.map(\.title)) \(roots[1].children.map(\.title))")
        let sortedInfo = CommitInfoPresentation.sortBranches(["alpha", "zeta", "remotes/origin/zeta", "remotes/fork/alpha"], currentBranch: "main",
                                                             prioritizedBranches: "zeta", prioritizedRemotes: "fork")
        check(sortedInfo.first == "zeta", "commit info uses the configured branch priority: \(sortedInfo)")

        let suite = "GitExtensionsMac.SortingSettingsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        var notifications = 0
        let controller = SettingsViewController(store: store, source: nil, initialPage: "sorting", repositoryChanged: { notifications += 1 })
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func row(_ label: String) -> NSView? {
            descendants(controller.view).first { view in
                view.subviews.contains { ($0 as? NSTextField)?.stringValue == label } && view.subviews.count >= 2
            }
        }
        let labels = descendants(controller.view).compactMap { $0 as? NSTextField }.filter { !$0.isEditable }.map(\.stringValue)
        let expected = ["Sort revisions by:", "Sort branches by:", "Order branches:", "Prioritized branches:", "Prioritized remotes:"]
        let positions = expected.compactMap { labels.firstIndex(of: $0) }
        check(positions.count == 5 && positions == positions.sorted(), "upstream Sorting controls in order: \(labels)")
        check(row("Sort revisions by:")?.toolTip == "Sorting revisions may delay rendering of the revision graph.", "revision sort warning")
        let revisionPopup = descendants(row("Sort revisions by:")!).compactMap { $0 as? NSPopUpButton }.first!
        check(revisionPopup.itemTitles == ["GitDefault", "AuthorDate", "Topology"], "revision sort values")
        revisionPopup.selectItem(withTitle: "Topology")
        NSApp.sendAction(revisionPopup.action!, to: revisionPopup.target, from: revisionPopup)
        let branchField = descendants(row("Prioritized branches:")!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        check(branchField.stringValue == defaultPatterns, "default branch priority shown")
        branchField.stringValue = "develop;main"
        NSApp.sendAction(branchField.action!, to: branchField.target, from: branchField)
        let apply = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
        NSApp.sendAction(apply.action!, to: apply.target, from: apply)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.repositoryTreePreferences.prioritizedBranchNames != "develop;main" {
            check(ContinuousClock.now < deadline, "sorting settings applied")
            try await Task.sleep(for: .milliseconds(20))
        }
        check(store.revisionGridRuntime.sortOrder == .topology && store.revisionGridRuntimeDefaults.sortOrder == .topology, "revision sort applies now and persists")
        check(notifications > 0, "views refresh after sorting changes")
        let reloaded = AppSettingsStore(defaults: defaults)
        check(reloaded.repositoryTreePreferences.prioritizedBranchNames == "develop;main" && reloaded.revisionGridRuntime.sortOrder == .topology, "persisted")
    }

    @MainActor
    static func hostedSettings(_ page: String, _ body: (SettingsViewController, AppSettingsStore, () -> Void) async throws -> Void) async throws {
        let suite = "GitExtensionsMac.BackendSettingsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = SettingsViewController(store: store, source: nil, initialPage: page, repositoryChanged: {})
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1040, height: 900))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let apply = {
            let button = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
            NSApp.sendAction(button.action!, to: button.target, from: button)
        }
        try await body(controller, store, apply)
    }

    @MainActor
    static func settingsViews(_ controller: SettingsViewController) -> [NSView] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(controller.view)
    }

    @MainActor
    static func settingsCheckbox(_ controller: SettingsViewController, _ title: String) -> NSButton {
        settingsViews(controller).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }

    @MainActor
    static func settingsPopup(_ controller: SettingsViewController, _ label: String) -> NSPopUpButton {
        let row = settingsViews(controller).first { view in
            view.subviews.contains { ($0 as? NSTextField)?.stringValue == label } && view.subviews.contains { $0 is NSPopUpButton }
        }!
        return row.subviews.compactMap { $0 as? NSPopUpButton }.first!
    }

    @MainActor
    static func click(_ control: NSControl) { NSApp.sendAction(control.action!, to: control.target, from: control) }

    @MainActor
    static func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            check(ContinuousClock.now < deadline, "timed out: \(label)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    static func confirmationSettings() async throws {
        let legacy = try JSONDecoder().decode(ConfirmationPreferences.self, from: Data(#"{"dontConfirmRebase":true}"#.utf8))
        check(legacy.dontConfirmRebase && !legacy.dontConfirmResolveConflicts && legacy.dontConfirmUpdateSubmodulesOnCheckout == nil, "tolerant confirmation decoding")
        let suite = "GitExtensionsMac.LegacyWorktree.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: suite)!
        defer { legacyDefaults.removePersistentDomain(forName: suite) }
        legacyDefaults.set(true, forKey: "GitExtensionsMac.DontConfirmSwitchWorktree")
        check(AppSettingsStore(defaults: legacyDefaults).confirmationPreferences.dontConfirmSwitchWorktree, "legacy switch-worktree suppression migrates")

        try await hostedSettings("confirmations") { controller, store, apply in
            let labels = settingsViews(controller).compactMap { view -> String? in
                if let button = view as? NSButton, button.bezelStyle != .rounded || button.title.isEmpty == false { return button.title }
                return (view as? NSTextField)?.stringValue
            }
            let groups = settingsViews(controller).compactMap { $0 as? NSBox }.map(\.title)
            check(groups == ["Commits:", "Branches:", "Stash:", "Rebase / conflict resolution:", "Submodules:", "Worktrees:"], "upstream groups \(groups)")
            let expected = ["Commits:", "Amend last commit", "Undo last commit", "Commit when no branch is currently checked out (headless state)",
                            "Rebase on top of selected commit", "Branches:", "Fetch and prune branches", "Push a new branch for the remote",
                            "Add a tracking reference for newly pushed branch", "Delete unmerged branches", "Checkout branch using left panel",
                            "Stash:", "Apply stashed changes after successful checkout:", "Apply stashed changes after successful pull:", "Drop stash",
                            "Rebase / conflict resolution:", "Resolve conflicts", "Commit changes after conflicts have been resolved",
                            "Confirm for the second time to abort a merge", "Submodules:", "Update submodules on checkout:", "Worktrees:", "Switch worktree"]
            let positions = expected.filter { !groups.contains($0) }.map { labels.firstIndex(of: $0) }
            check(!positions.contains(nil) && positions.compactMap { $0 } == positions.compactMap { $0 }.sorted(),
                  "upstream confirmation order")
            for title in ["Rebase on top of selected commit", "Resolve conflicts", "Commit changes after conflicts have been resolved",
                          "Confirm for the second time to abort a merge", "Switch worktree"] {
                let box = settingsCheckbox(controller, title)
                check(box.state == .on, "\(title) confirms by default")
                box.state = .off; click(box)
            }
            let checkoutPop = settingsPopup(controller, "Apply stashed changes after successful checkout:")
            check(checkoutPop.itemTitles == ["Ask", "Apply stash automatically", "Keep stash"], "stash tri-state values")
            checkoutPop.selectItem(withTitle: "Keep stash"); click(checkoutPop)
            let pullPop = settingsPopup(controller, "Apply stashed changes after successful pull:")
            pullPop.selectItem(withTitle: "Apply stash automatically"); click(pullPop)
            let submodules = settingsPopup(controller, "Update submodules on checkout:")
            submodules.selectItem(withTitle: "No"); click(submodules)
            apply()
            try await waitUntil("confirmations applied") { store.confirmationPreferences.dontConfirmRebase }
            let saved = store.confirmationPreferences
            check(saved.dontConfirmResolveConflicts && saved.dontConfirmCommitAfterConflictsResolved && saved.dontConfirmSecondAbortConfirmation
                  && saved.dontConfirmSwitchWorktree && saved.dontConfirmUpdateSubmodulesOnCheckout == false, "confirmations persisted")
            check(store.checkoutBranchPreferences.autoPopStash == .never && store.pullPreferences.autoPopStash == .always, "stash answers persisted")
            check(store.effectiveUpdateSubmodulesOnCheckout == false, "remembered submodule answer applies when the General setting is unset")
            var checkout = store.checkoutBranchPreferences
            checkout.updateSubmodulesOnCheckout = true
            store.saveCheckoutBranchPreferences(checkout)
            check(store.effectiveUpdateSubmodulesOnCheckout == true, "General setting wins over the remembered answer")
            store.rememberUpdateSubmodulesOnCheckout(false)
            check(store.confirmationPreferences.dontConfirmUpdateSubmodulesOnCheckout == false && store.checkoutBranchPreferences.updateSubmodulesOnCheckout == false,
                  "remember choice sets both settings")
        }
    }

    @MainActor
    static func suppressibleConfirmations() async throws {
        let suite = "GitExtensionsMac.Suppressible.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.makeKeyAndOrderFront(nil)
        defer { owner.close() }
        func ask(answer: String, suppress: Bool) async throws -> Bool {
            let alert = NSAlert()
            alert.messageText = "Merge conflicts"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            let task = Task { @MainActor in await MutationDialogs.confirmSuppressible(alert, window: owner, suppressedBy: \.dontConfirmResolveConflicts, store: store) }
            try await waitUntil("sheet") { owner.attachedSheet != nil }
            check(alert.suppressionButton?.title == "Don't show me this message again", "upstream suppression caption")
            alert.suppressionButton?.state = suppress ? .on : .off
            let button = alert.buttons.first { $0.title == answer }!
            button.performClick(nil)
            return await task.value
        }
        check(try await ask(answer: "No", suppress: false) == false && !store.confirmationPreferences.dontConfirmResolveConflicts, "No without suppression")
        check(try await ask(answer: "No", suppress: true) == false && store.confirmationPreferences.dontConfirmResolveConflicts,
              "suppression persists even when answered No, as ConfirmSuppressible")
        let suppressed = await MutationDialogs.confirmSuppressible(NSAlert(), window: owner, suppressedBy: \.dontConfirmResolveConflicts, store: store)
        check(suppressed && owner.attachedSheet == nil, "suppressed confirmation returns true without prompting")

        let shared = AppSettingsStore.shared
        let saved = shared.confirmationPreferences
        defer { shared.saveConfirmationPreferences(saved) }
        var preferences = saved
        preferences.dontConfirmRebase = true; preferences.dontConfirmResolveConflicts = true
        shared.saveConfirmationPreferences(preferences)
        let rebase = await MutationDialogs.confirmRebaseOnSelected(interactive: true, window: owner)
        let resolve = await MutationDialogs.confirmResolveUnresolvedConflicts(window: owner)
        let merge = await MutationDialogs.confirmResolveMergeConflicts(paths: ["a"], window: owner)
        check(rebase && resolve && merge && owner.attachedSheet == nil, "rebase and resolve-conflict prompts honour their settings")
        preferences.dontConfirmRebase = false
        shared.saveConfirmationPreferences(preferences)
        let pending = Task { @MainActor in await MutationDialogs.confirmRebaseOnSelected(interactive: false, window: owner) }
        try await waitUntil("rebase sheet") { owner.attachedSheet != nil }
        let sheetText = owner.attachedSheet.map { settingsTexts($0.contentView!) } ?? []
        check(sheetText.contains("Rebase branch.") && sheetText.contains("Are you sure you want to rebase? This action will rewrite commit history."), "upstream rebase confirmation \(sheetText)")
        owner.attachedSheet.flatMap { sheet in (sheet.contentView.map(allButtons) ?? []).first { $0.title == "No" } }?.performClick(nil)
        check(await pending.value == false, "declining the rebase confirmation")
    }

    @MainActor
    static func settingsTexts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(settingsTexts)
    }

    @MainActor
    static func allButtons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(allButtons)
    }

    @MainActor
    static func diffViewerSettings() async throws {
        let merge = try ObjectID.parse(String(repeating: "c", count: 40))
        check(FileStatusCommands.combinedDiff(merge, path: "a", options: FileDiffOptions()).arguments.prefix(4) == ["diff-tree", "-c", "-p", "--no-commit-id"],
              "upstream default combined diff is -c -p")
        var omit = FileDiffOptions(); omit.omitsUninterestingCombinedDiff = true
        check(FileStatusCommands.combinedDiff(merge, path: "a", options: omit).arguments.prefix(3) == ["diff-tree", "--cc", "--no-commit-id"], "omit uses --cc")
        var viewer = FileViewerPreferences()
        check(viewer.verticalRulerPosition == 0 && !viewer.omitUninterestingDiff && viewer.showAvailableDiffTools, "upstream defaults")
        check(viewer.availableDiffTools(["a"]).isEmpty && viewer.availableDiffTools(["a", "b"]) == ["a", "b"], "tool menus need more than one tool")
        viewer.showAvailableDiffTools = false
        check(viewer.availableDiffTools(["a", "b"]).isEmpty, "disabled tool list")
        viewer.omitUninterestingDiff = true
        check(viewer.diffOptions.omitsUninterestingCombinedDiff, "setting reaches diff options")
        let decoded = try JSONDecoder().decode(FileViewerPreferences.self, from: Data(#"{"contextLines":5,"verticalRulerPosition":5000}"#.utf8))
        check(decoded.contextLines == 5 && decoded.verticalRulerPosition == 1000 && decoded.showAvailableDiffTools, "tolerant viewer decoding clamps the ruler")
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        check(DiffLineCellView.verticalRulerX(position: 0, textOrigin: 50, font: font) == nil
              && DiffLineCellView.verticalRulerX(position: 81, textOrigin: 50, font: font) == 50 + 80 * width, "ruler column offset")
        let parent = RevisionID.object(try ObjectID.parse(String(repeating: "a", count: 40)))
        let headRevision = RevisionID.object(try ObjectID.parse(String(repeating: "b", count: 40)))
        var context = ChangedFileContextMenuContext(selectedFiles: [ChangedFile(id: "f", path: "f.txt", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)],
                                                    firstRevisions: [parent], secondRevisions: [headRevision])
        context.firstToSelectedEnabled = true
        context.diffTools = ["opendiff", "meld"]
        func titles(_ entries: [ContextMenuEntry]) -> [String] {
            entries.flatMap { entry -> [String] in
                switch entry {
                case .command(_, let title, _): return [title]
                case .submenu(_, let title, _, let children): return [title] + titles(children)
                case .separator: return []
                }
            }
        }
        let menuTitles = titles(ChangedFileContextMenuBuilder.build(context))
        check(menuTitles.contains("Disable") && menuTitles.contains("meld"), "difftool submenu offers Disable")

        let repo = try repository("combined")
        defer { try? FileManager.default.removeItem(at: repo) }
        func lines(_ first: String, _ last: String) -> Data {
            Data(([first] + (2...19).map(String.init) + [last]).joined(separator: "\n").appending("\n").utf8)
        }
        try lines("1", "20").write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo); _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["checkout", "-q", "-b", "side"], in: repo)
        try lines("side1", "side20").write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-am", "side"], in: repo)
        _ = try git(["checkout", "-q", "main"], in: repo)
        try lines("main1", "main20").write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-am", "main"], in: repo)
        _ = try shell("/usr/bin/env", ["git", "merge", "-q", "side"], in: repo, allowFailure: true)
        try lines("main1", "new20").write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["commit", "-q", "-am", "merge"], in: repo)
        let head = try ObjectID.parse(try git(["rev-parse", "HEAD"], in: repo))
        func hunks(_ options: FileDiffOptions) throws -> Int {
            try git(FileStatusCommands.combinedDiff(head, path: "a.txt", options: options).arguments, in: repo)
                .split(separator: "\n").filter { $0.hasPrefix("@@@") }.count
        }
        check(try hunks(FileDiffOptions()) == 2 && hunks(omit) == 1, "real combined diff: --cc omits the hunk resolved like a parent")

        try await hostedSettings("diff") { controller, store, apply in
            for title in ["Omit uninteresting changes from combined diff", "Show file differences for all parents in browse dialog", "Show all available difftools"] {
                check(settingsViews(controller).compactMap { $0 as? NSButton }.contains { $0.title == title }, "diff control \(title)")
            }
            let omitBox = settingsCheckbox(controller, "Omit uninteresting changes from combined diff")
            omitBox.state = .on; click(omitBox)
            let tools = settingsCheckbox(controller, "Show all available difftools")
            tools.state = .off; click(tools)
            let parents = settingsCheckbox(controller, "Show file differences for all parents in browse dialog")
            parents.state = .off; click(parents)
            let rulerRow = settingsViews(controller).first { view in
                view.subviews.contains { ($0 as? NSTextField)?.stringValue == "Vertical ruler position [chars]:" }
            }!
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let field = descendants(rulerRow).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
            field.stringValue = "80"
            (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            apply()
            try await waitUntil("diff settings") { store.fileViewerPreferences.omitUninterestingDiff }
            check(!store.fileViewerPreferences.showAvailableDiffTools && store.fileViewerPreferences.verticalRulerPosition == 80
                  && !store.fileStatusListPreferences.showDiffForAllParents, "diff settings persisted")
        }
    }

    @MainActor
    static func commitDialogSettings() async throws {
        check(StagingCommands.add(["a"], showErrors: true) == ["add", "--all", "--", "a"]
              && StagingCommands.add(["a"], showErrors: false) == ["-c", "core.safecrlf=false", "add", "--all", "--", "a"], "upstream safecrlf staging switch")
        let repo = try repository("safecrlf")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo); _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["config", "core.autocrlf", "input"], in: repo)
        _ = try git(["config", "core.safecrlf", "true"], in: repo)
        try Data("one\r\ntwo\r\n".utf8).write(to: repo.appendingPathComponent("crlf.txt"))
        let source = module(repo)
        _ = try await source.loadRepositoryState()
        do {
            _ = try await source.stage(paths: ["crlf.txt"], showErrors: true)
            check(false, "safecrlf failure surfaces when errors are shown")
        } catch {}
        _ = try await source.stage(paths: ["crlf.txt"], showErrors: false)
        check(try git(["diff", "--cached", "--name-only"], in: repo) == "crlf.txt", "suppressed safecrlf stages the file")

        try await hostedSettings("commit") { controller, store, apply in
            let completion = settingsCheckbox(controller, "Provide auto-completion in commit dialog")
            let errors = settingsCheckbox(controller, "Show errors when staging files")
            check(completion.state == .on && errors.state == .on, "upstream defaults")
            completion.state = .off; click(completion)
            errors.state = .off; click(errors)
            apply()
            try await waitUntil("commit settings") { !store.preferences.provideAutocompletion }
            check(!store.preferences.showErrorsWhenStagingFiles, "staging errors setting persisted")
        }

        let shared = AppSettingsStore.shared
        let saved = shared.preferences
        defer { shared.save(saved) }
        var preferences = saved; preferences.provideAutocompletion = false; shared.save(preferences)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let controller = CommitWorkflowDialog.present(source: source, initialMode: .normal, head: nil, draft: nil, owner: owner,
                                                      onRepositoryChanged: { _ in }, onClose: {})
        let commitWindow = controller.window!
        defer { commitWindow.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let message = descendants(commitWindow.contentView!).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.delegate is NSViewController }!
        check(!message.isAutomaticTextCompletionEnabled, "completion off")
        message.string = "cr"
        let none = message.delegate!.textView!(message, completions: ["crab"], forPartialWordRange: NSRange(location: 0, length: 2), indexOfSelectedItem: nil)
        check(none.isEmpty, "no completions when disabled")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: commitWindow.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = message.delegate!.textView!(message, menu: NSMenu(), for: event, at: 0)!
        let toggle = menu.items.first { $0.title == "Provide auto completion" }!
        check(toggle.state == .off, "context toggle reflects setting")
        NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        check(shared.preferences.provideAutocompletion && message.isAutomaticTextCompletionEnabled, "context toggle enables completion")
        try await waitUntil("completions include changed file names") {
            message.delegate!.textView!(message, completions: ["crab"], forPartialWordRange: NSRange(location: 0, length: 2), indexOfSelectedItem: nil)
                .contains("crlf.txt")
        }
    }

    @MainActor
    static func advancedAppearanceSettings() async throws {
        let method = TruncatePathMethod.fileNameOnly
        check(method.title(path: "dir/sub/a.txt", oldPath: "old/a.txt") == "a.txt" && method.title(path: "dir/b.txt", oldPath: "x/c.txt") == "b.txt (c.txt)",
              "FileNameOnly titles")
        check(TruncatePathMethod.none.title(path: "dir/b.txt", oldPath: "x/c.txt") == "dir/b.txt (x/c.txt)", "full titles")
        check(method.filterKeys(path: "dir/a.txt/", oldPath: nil) == ["a.txt"] && TruncatePathMethod.trimStart.filterKeys(path: "dir/a.txt", oldPath: "b") == ["dir/a.txt", "b"],
              "filter keys")
        check(TruncatePathMethod.none.lineBreakMode == .byClipping && TruncatePathMethod.compact.lineBreakMode == .byTruncatingMiddle
              && TruncatePathMethod.trimStart.lineBreakMode == .byTruncatingHead, "line break modes")
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"theme":"Dark"}"#.utf8))
        check(decoded.provideAutocompletion && decoded.showErrorsWhenStagingFiles && !decoded.dontShowHelpImages && decoded.truncatePathMethod == .none,
              "older preferences decode with upstream defaults")

        try await hostedSettings("advanced") { controller, store, apply in
            let labels = settingsTexts(controller.view) + allButtons(controller.view).map(\.title)
            for title in ["Always show checkout dialog", "Don't show help images", "Always show advanced options", "Auto normalise branch name", "Symbol to use:"] {
                check(labels.contains(title), "advanced control \(title)")
            }
            check(labels.contains { $0.hasPrefix("Use last chosen \"local changes\" action as default action.") }
                  && labels.contains("Push forced with lease when Commit & Push action is performed with Amend option checked"), "checkout/commit groups")
            let always = settingsCheckbox(controller, "Always show checkout dialog"); always.state = .on; click(always)
            let help = settingsCheckbox(controller, "Don't show help images"); help.state = .on; click(help)
            let symbol = settingsPopup(controller, "Symbol to use:")
            check(symbol.itemTitles == ["_", "-", "(none)"] && symbol.isEnabled, "normalise symbols")
            symbol.selectItem(withTitle: "(none)"); click(symbol)
            let normalise = settingsCheckbox(controller, "Auto normalise branch name"); normalise.state = .off; click(normalise)
            check(!symbol.isEnabled, "symbol follows normalise toggle")
            apply()
            try await waitUntil("advanced settings") { store.checkoutBranchPreferences.alwaysShowDialog }
            check(store.preferences.dontShowHelpImages && store.checkoutBranchPreferences.branchNameReplacement == ""
                  && !store.checkoutBranchPreferences.autoNormaliseBranchName, "advanced settings persisted")
        }
        try await hostedSettings("browse") { controller, store, apply in
            let grep = settingsCheckbox(controller, "Show 'Find in commit files using git-grep'")
            check(grep.state == .off, "git-grep toggle default")
            grep.state = .on; click(grep)
            apply()
            try await waitUntil("browse settings") { store.fileStatusListPreferences.showFindInCommitFilesGitGrep }
        }
        try await hostedSettings("appearance") { controller, store, apply in
            let relative = settingsCheckbox(controller, "Show relative date instead of full date")
            relative.state = .on; click(relative)
            let truncate = settingsPopup(controller, "Truncate long filenames:")
            check(truncate.itemTitles == ["None", "Compact", "TrimStart", "FileNameOnly"], "truncation values")
            truncate.selectItem(withTitle: "FileNameOnly"); click(truncate)
            apply()
            try await waitUntil("appearance settings") { store.preferences.truncatePathMethod == .fileNameOnly }
            check(store.revisionGridPreferences.relativeDate, "relative date persisted")
        }

        let shared = AppSettingsStore.shared
        let saved = shared.preferences
        defer { shared.save(saved) }
        var preferences = saved; preferences.dontShowHelpImages = true; shared.save(preferences)
        let repo = try repository("help-images")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo); _ = try git(["commit", "-q", "-m", "base"], in: repo)
        let source = module(repo)
        let state = try await source.loadRepositoryState()
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let mergeWindow = MergeDialog.present(source: source, context: state.mergeContext, initialTarget: nil, owner: owner,
                                              onRepositoryChanged: { _ in }, onClose: {})
        defer { mergeWindow.close() }
        let images = (mergeWindow.window?.contentView).map { view -> [NSImageView] in
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return descendants(view).compactMap { $0 as? NSImageView }
        } ?? []
        check(images.allSatisfy { $0.isHiddenOrHasHiddenAncestor }, "help image hidden in Merge")
    }

    @MainActor
    static func editorComposedCommits() async throws {
        let inheritedEditor = ProcessInfo.processInfo.environment["GIT_EDITOR"]
        unsetenv("GIT_EDITOR")
        defer { if let inheritedEditor { setenv("GIT_EDITOR", inheritedEditor, 1) } }
        let dialogRequest = RepositoryCommitRequest(message: "", mode: .normal, stageAllBeforeCommit: false, allowEmpty: false, signOff: false,
                                                    author: nil, resetAuthor: false, composesMessage: false)
        check(GitCommitCommandBuilder.arguments(request: dialogRequest, messageFile: nil, hasStagedChanges: true) == ["commit"]
              && GitCommitCommandBuilder.arguments(request: dialogRequest, messageFile: "/m", hasStagedChanges: true) == ["commit", "-F", "/m"],
              "-F only when the dialog composes the message")
        check(AppPreferences().composeCommitMessages, "upstream default composes in the dialog")

        let repo = try repository("editor-commit")
        let tools = try temporaryDirectory("editor-tools")
        defer { try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: tools) }
        let editor = tools.appendingPathComponent("editor.sh")
        try Data("#!/bin/sh\nprintf 'From editor\\n\\nbody\\n' > \"$1\"\n".utf8).write(to: editor)
        let failing = tools.appendingPathComponent("failing.sh")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: failing)
        for script in [editor, failing] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."], in: repo); _ = try git(["commit", "-q", "-m", "base"], in: repo)
        _ = try git(["config", "core.editor", editor.path], in: repo)
        try Data("b\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "a.txt"], in: repo)
        let source = module(repo)
        _ = try await source.loadRepositoryState()
        _ = try await source.commit(dialogRequest)
        check(try git(["log", "-1", "--format=%B"], in: repo) == "From editor\n\nbody", "real commit message comes from core.editor")
        check(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/COMMITMESSAGE").path), "no dialog message file written")
        let amendRequest = RepositoryCommitRequest(message: "", mode: .amend, stageAllBeforeCommit: false, allowEmpty: false, signOff: false,
                                                   author: nil, resetAuthor: false, composesMessage: false)
        _ = try git(["config", "core.editor", "sed -i '' -e 's/From editor/Amended in editor/'"], in: repo)
        _ = try await source.commit(amendRequest)
        check(try git(["log", "-1", "--format=%s"], in: repo) == "Amended in editor" && (try git(["rev-list", "--count", "HEAD"], in: repo)) == "2",
              "amend edits the previous message in the editor")
        _ = try git(["config", "core.editor", failing.path], in: repo)
        try Data("c\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "a.txt"], in: repo)
        let before = try git(["rev-parse", "HEAD"], in: repo)
        do {
            _ = try await source.commit(dialogRequest)
            check(false, "a failing editor must abort the commit")
        } catch {
            check(error.localizedDescription.lowercased().contains("editor"), "editor failure surfaced: \(error.localizedDescription)")
        }
        check(try git(["rev-parse", "HEAD"], in: repo) == before && (try git(["diff", "--cached", "--name-only"], in: repo)) == "a.txt",
              "aborted commit leaves HEAD and the index unchanged")
        _ = try git(["config", "core.editor", editor.path], in: repo)

        try await hostedSettings("commit") { controller, store, apply in
            let toggle = settingsCheckbox(controller, "Compose commit messages in Commit dialog\n(otherwise the message will be requested during commit)")
            check(toggle.state == .on, "toggle default")
            toggle.state = .off; click(toggle)
            apply()
            try await waitUntil("compose setting") { !store.preferences.composeCommitMessages }
        }

        let shared = AppSettingsStore.shared
        let saved = shared.preferences
        let savedCommit = shared.commitPreferences
        defer { shared.save(saved); shared.saveCommitPreferences(savedCommit) }
        var preferences = saved; preferences.composeCommitMessages = false; shared.save(preferences)
        var commitPreferences = savedCommit
        commitPreferences.lastCommitMessage = "unchanged"
        commitPreferences.closeAfterCommit = false
        commitPreferences.closeAfterLastCommit = false
        shared.saveCommitPreferences(commitPreferences)
        try Data("dialog\n".utf8).write(to: repo.appendingPathComponent(".git/COMMITMESSAGE"))
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        var changed = 0
        let controller = CommitWorkflowDialog.present(source: source, initialMode: .normal, head: nil, draft: nil, owner: owner,
                                                      onRepositoryChanged: { _ in changed += 1 }, onClose: {})
        let commitWindow = controller.window!
        defer { commitWindow.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let message = descendants(commitWindow.contentView!).compactMap { $0 as? NSTextView }.first { $0.delegate is NSViewController }!
        try await waitUntil("commit dialog loaded") {
            descendants(commitWindow.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(" staged / ") && !$0.stringValue.contains("0 staged") }
        }
        check(!message.isEditable && message.string.isEmpty, "message box locked and the saved draft is not loaded")
        let texts = descendants(commitWindow.contentView!).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        check(texts.contains("Commit Message is requested during commit"), "upstream watermark")
        let popups = descendants(commitWindow.contentView!).compactMap { $0 as? NSPopUpButton }
        check(popups.filter { ["Commit message", "Commit templates"].contains($0.itemTitle(at: 0)) }.allSatisfy { !$0.isEnabled }, "message and template menus disabled")
        let commitButton = descendants(commitWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Commit" }!
        click(commitButton)
        try await waitUntil("editor commit from the dialog") { (try? git(["log", "-1", "--format=%s"], in: repo)) == "From editor" }
        try await waitUntil("repository change notified") { changed > 0 }
        try await Task.sleep(for: .milliseconds(300))
        check(shared.commitPreferences.lastCommitMessage == "unchanged", "dialog message not remembered: \(shared.commitPreferences.lastCommitMessage)")
        check(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/COMMITMESSAGE").path), "message file reset after commit")

        let editMessage = repo.appendingPathComponent(".git/COMMIT_EDITMSG")
        try Data("draft\n".utf8).write(to: editMessage)
        var presented: [(String, String)] = []
        let savedPresent = CommandLineSession.present, savedStatus = CommandLineSession.exitStatus
        CommandLineSession.present = { presented.append(($0, $1)) }
        defer { CommandLineSession.present = savedPresent; CommandLineSession.exitStatus = savedStatus }
        CommandLineSession.exitStatus = 0
        let request = try CommandLineRequest.parse(["GitExtensionsMac", "fileeditor", editMessage.path], currentDirectory: repo)!
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        let host = ApplicationHostViewController(launch: .commandLine(request))
        let hostWindow = NSWindow(contentViewController: host); hostWindow.isReleasedWhenClosed = false
        hostWindow.makeKeyAndOrderFront(nil)
        defer { hostWindow.close() }
        host.viewDidAppear()
        try await waitUntil("editor for the commit message file") {
            !presented.isEmpty || NSApp.windows.contains { !windowsBefore.contains(ObjectIdentifier($0)) && $0 !== hostWindow && $0.isVisible && $0.title.contains("COMMIT_EDITMSG") }
        }
        check(presented.isEmpty, "fileeditor inside .git opens without a command-line error: \(presented)")
        NSApp.windows.first { $0.title.contains("COMMIT_EDITMSG") }?.close()
    }
}
