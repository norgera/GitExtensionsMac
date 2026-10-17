import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Settings and history")
    enum SettingsAndHistoryTests {
        @Test("Scenarios") static func run() async throws {

            cloneVectors()
            history()
            upstreamRemoteHistoryVectors()
            try hiddenSettings()
            try browse()
            try templates()
            toolSettings()
            try await repositoryCases()
            try await settingsPresentation()
        }
        static func cloneVectors() {
            let names: [(String?, String)] = [
                ("https://github.com/gitextensions/gitextensions.git", "gitextensions"),
                ("https://github.com/jeffqc/gitextensions", "gitextensions"),
                ("git://mygitserver/git/test.git", "test"),
                ("ssh://mygitserver/git/test.git", "test"),
                ("ssh://john.doe@mygitserver/git/test.git", "test"),
                ("ssh://john-abraham.doe@mygitserver/git/MyAwesomeRepo.git", "MyAwesomeRepo"),
                ("git@anotherserver.mysubnet.com:project/somerepo.git", "somerepo"),
                ("http://anotherserver.mysubnet.com/project/somerepo.git", "somerepo"),
                ("http://anotherserver.mysubnet.com/project/Hello+G%C3%BCnter.git", "Hello Günter"),
                ("ssh://anotherserver.mysubnet.com/project/Hello+G%C3%BCnter.git", "Hello Günter"),
                ("git://anotherserver.mysubnet.com/project/Hello+G%C3%BCnter.git", "Hello Günter"),
                ("git@anotherserver.mysubnet.com:project/Hello+G%C3%BCnter.git", "Hello Günter"),
                ("", ""),
                (nil, ""),
                ("C:\\dev\\my_repo", "my_repo"),
                ("C:\\dev\\Hello+G%C3%BCnter", "Hello+G%C3%BCnter"),
                ("\\\\networkshare\\folder1\\folder2\\gitextensions", "gitextensions"),
                ("/dev/my_repo", "my_repo"),
                ("/dev/Hello+G%C3%BCnter", "Hello+G%C3%BCnter"),
                ("//networkshare/folder1/folder2/gitextensions", "gitextensions"),
            ]
            for (source, expected) in names { #expect(CloneSourcePath.repositoryName(source) == expected, "upstream repository name: \(source ?? "nil")") }
            let urls: [(String?, Bool)] = [
                (nil, false),
                ("", false),
                (" ", false),
                ("blah", false),
                ("https://github.com/gitextensions/gitextensions", true),
                ("https://github.com/gitextensions/gitextensions.git", true),
                ("github.com/gitextensions/gitextensions.git", true),
                ("HTTPS://MYPRIVATEGITHUB.COM:8080/LOUDREPO.GIT", true),
                ("git://myurl/myrepo.git", true),
                ("git@github.com:gitextensions/gitextensions.git", true),
                ("git@github.com:gitextensions/gitextensions.git/", true),
                ("https://github.com/gitextensions/gitextensions/issues/12210#issuecomment-2672903979", false),
                ("https://github.com/gitextensions/gitextensions?query=param", false),
                ("github.com/gitextensions", false),
                ("github.com/gitextensions/gitextensions/pull/9018", false),
                ("http://", false),
                ("HTTPS://www", true),
                ("git://", true),
                ("file:", false),
                ("SSH:", true),
                ("SSH", false),
                ("https://myhost:12368/", true),
            ]
            for (source, expected) in urls {
                #expect(CloneSourcePath.canBeGitURL(source, isGitDirectory: { _ in false }) == expected, "upstream Git URL: \(source ?? "nil")")
            }
            let extract: [(String?, String?)] = [
                (nil, nil), ("", nil), (" ", nil), ("blah", nil),
                ("git clone https://github.com/gitextensions/gitextensions && cd gitextensions", "https://github.com/gitextensions/gitextensions"),
                ("git clone ssh://username@gerrit-server:/PROJECT", "ssh://username@gerrit-server:/PROJECT"),
                (
                    "git clone https://github.com/gitextensions/gitextensions && git clone https://github.com/gitextensions/git.hub",
                    "https://github.com/gitextensions/gitextensions"
                ),
            ]
            for (source, expected) in extract { #expect(CloneSourcePath.extract(source) == expected, "upstream FormClone extraction") }
            #expect(CloneSourcePath.repositoryName("https://host/NAME.GIT/") == "NAME.GIT", "case-sensitive suffix")
            #expect(CloneSourcePath.repositoryName("git@host:repo.git").isEmpty, "no path separator")
            #expect(CloneSourcePath.repositoryName("https://host/%E6%97%A5%E6%9C%AC.git") == "日本", "percent Unicode")
        }
        static func withStore(_ body: (AppSettingsStore, UserDefaults) throws -> Void) rethrows {
            let name = "SettingsAndHistory-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try body(AppSettingsStore(defaults: defaults), defaults)
        }
        static func history() {
            withStore { store, defaults in
                var clone = store.repositoryCreationPreferences
                clone.recentSources = ["clone", "same"]
                var pull = store.pullPreferences
                pull.recentURLs = ["pull", "SAME"]
                var push = store.pushPreferences
                push.recentURLs = ["push"]
                var remote = store.remoteManagementPreferences
                remote.recentURLs = ["remote"]
                store.saveRepositoryCreationPreferences(clone)
                store.savePullPreferences(pull)
                store.savePushPreferences(push)
                store.saveRemoteManagementPreferences(remote)
                #expect(store.remoteRepositoryHistory == ["clone", "pull", "push", "remote", "same"], "interleaved legacy migration")
                store.recordPullURL("shared")
                store.recordPushURL("SHARED")
                store.recordCloneSource("shared")
                store.recordRemoteURL("shared")
                #expect(
                    AppSettingsStore(defaults: defaults).remoteRepositoryHistory.first == "shared",
                    "all wrappers use canonical history preserving first spelling")
                store.recordRemoteURL("pull")
                #expect(store.remoteRepositoryHistory.prefix(2) == ["pull", "shared"], "MRU move")
                store.recordRemoteURL(" ")
                #expect(store.remoteRepositoryHistory.first == "pull", "reject whitespace")
                for i in 0..<40 { store.recordRemoteURL("url-\(i)") }
                #expect(store.remoteRepositoryHistory.count == 30 && store.remoteRepositoryHistory.first == "url-39", "30-entry persistence/load default")
                store.remotesCacheLength = 12
                #expect(store.remoteRepositoryHistory.count == 12, "load override")
                var recent = store.recentRepositorySettings
                recent.historySize = 50
                store.saveRecentRepositorySettings(recent)
                store.remotesCacheLength = 100
                store.saveRemoteRepositoryHistory((0..<60).map { "\($0)" })
                #expect(AppSettingsStore(defaults: defaults).remoteRepositoryHistory.count == 50, "separate persistence override")
                store.saveRemoteRepositoryHistory(["a", "b", "A"])
                store.recordRemoteURL("B")
                #expect(store.remoteRepositoryHistory == ["b", "a", "A"], "first duplicate only")
                store.replaceRemoteURLHistory("a", with: "b")
                #expect(store.remoteRepositoryHistory == ["b", "A"], "RemoteUpdate exact existing does not move")
                store.removeRemoteURL("B")
                #expect(store.remoteRepositoryHistory == ["A"], "remove first ignore case")
            }
        }
        static func upstreamRemoteHistoryVectors() {
            withStore { store, defaults in
                let path = "https://path.to/add"
                for (initial, count, duplicateIndex) in [
                    (["http://path1/", "http://path3/", "http://path4/", "http://path5/"], 5, nil as Int?),
                    (["git://path1/", "git://path3/", "git://path4/", path, "git://path5/"], 5, nil),
                    (["ssh://path1/", "ssh://path3/", path, "ssh://path4/", path, "http://path5/"], 6, 4),
                ] {
                    store.saveRemoteRepositoryHistory(initial)
                    store.recordRemoteURL(path)
                    #expect(
                        store.remoteRepositoryHistory.count == count && store.remoteRepositoryHistory.first == path,
                        "RemoteRepositoryManager literal insertion/move vectors")
                    if let duplicateIndex { #expect(store.remoteRepositoryHistory[duplicateIndex] == path, "literal first-duplicate vector") }
                }
                let prior = store.remoteRepositoryHistory
                store.recordRemoteURL(path)
                #expect(store.remoteRepositoryHistory == prior, "already top vector")
                store.saveRemoteRepositoryHistory(["path1", "path to delete", "path3", "path4", "path5"])
                store.removeRemoteURL("path to delete")
                #expect(store.remoteRepositoryHistory == ["path1", "path3", "path4", "path5"], "literal remove-existing vector")
                store.removeRemoteURL("path to delete")
                #expect(store.remoteRepositoryHistory == ["path1", "path3", "path4", "path5"], "literal remove-absent vector")
                var settings = store.recentRepositorySettings
                settings.historySize = 3
                store.saveRecentRepositorySettings(settings)
                store.saveRemoteRepositoryHistory(["path1", "path2", "path3", "path4"])
                #expect(AppSettingsStore(defaults: defaults).remoteRepositoryHistory == ["path1", "path2", "path3"], "literal persistence-size vector")
            }
            withStore { store, defaults in
                var old = store.repositoryCreationPreferences
                old.recentSources = (0..<35).map { "legacy-\($0)" }
                store.saveRepositoryCreationPreferences(old)
                #expect(store.remoteRepositoryHistory.count == 30, "migrated history uses default limit")
                #expect(
                    defaults.stringArray(forKey: "GitExtensionsMac.remoteRepositoryHistory.legacy.v1")?.count == 35,
                    "all useful legacy history retained in migration archive")
            }
        }

        static func hiddenSettings() throws {
            withStore { store, _ in
                #expect(
                    store.customGenericRemoteNames.isEmpty && store.uninformativeRepoNameRegex == "app|(repo(sitory)?)"
                        && store.prioritizedBuildServerRemoteNames == "upstream|origin|remote" && store.authorImageSizeInCommitInfo == 80, "four defaults")
                store.customGenericRemoteNames = ["company", " custom"]
                store.uninformativeRepoNameRegex = "sources"
                store.prioritizedBuildServerRemoteNames = " company | origin "
                store.authorImageSizeInCommitInfo = 96
                #expect(
                    store.customGenericRemoteNames == ["company", " custom"] && store.authorImageSizeInCommitInfo == 96,
                    "hidden overrides, no trimming generic names")
                let remotes = [remote("origin", "first"), remote("company", "preferred")]
                #expect(
                    BuildServerAutoDetector.orderedRemoteURLs(remotes, prioritized: store.prioritizedBuildServerRemoteNames) == ["preferred", "first"],
                    "build server consumer override")
                #expect(
                    RemoteURLSuggestions.replacementName("company", customGenericNames: store.customGenericRemoteNames) == "TO_REPLACE",
                    "remote name consumer override")
                #expect(
                    RemoteURLSuggestions.replacementName("project", customGenericNames: store.customGenericRemoteNames) == "project", "ordinary remote name")
                let original = AppSettingsStore.shared.authorImageSizeInCommitInfo
                AppSettingsStore.shared.authorImageSizeInCommitInfo = 96
                let info = CommitDetailViewController()
                _ = info.view
                #expect(info.displayedAvatarSize == 96, "CommitInfo avatar consumer override")
                AppSettingsStore.shared.authorImageSizeInCommitInfo = original
                store.authorImageSizeInCommitInfo = 0
                #expect(store.authorImageSizeInCommitInfo == 80, "nonpositive native size fallback")
                do {
                    _ = try BrowserPresentation.repositoryDescription(URL(fileURLWithPath: "/fixture"), uninformativePattern: "[")
                    Issue.record("invalid regex swallowed")
                } catch {}
            }
        }
        static func remote(_ name: String, _ url: String) -> RepositoryRemoteConfiguration {
            .init(name: name, fetchURL: url, pushURL: nil, puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: false)
        }
        static func browse() throws {
            let branches = (0..<102).map { i in
                Branch(id: "b\(i)", name: "b\(i)", commitID: testObjectID("b\(i)"), isCurrent: i == 101, isRemote: false, remoteName: nil, ahead: 0, behind: 0)
            }
            for count in [0, 1, 100, 102] {
                let items = BrowserBranchMenu.items(Array(branches.prefix(count))) { $0 == branches[0].commitID }
                #expect(items.count == min(count, 100), "branch cap")
                if count > 0 { #expect(!items[0].hidden, "visible branch") }
                if count > 1 { #expect(items[1].hidden, "hidden by actual visible commit predicate") }
            }
            let button = BrowserBranchPopUpButton()
            var checkout = false
            button.onCheckout = { checkout = true }
            let event = NSEvent.mouseEvent(
                with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            )!
            button.rightMouseUp(with: event)
            #expect(checkout, "right click routes to Checkout")
            let grid = RevisionGridViewController()
            var patches: [URL] = []
            grid.onApplyPatch = { patches.append($0) }
            let patch = URL(fileURLWithPath: "/fixture/change.patch")
            #expect(grid.dropPatchFiles([patch]) && patches == [patch], "patch drop preserved")
            #expect(!grid.dropPatchFiles([URL(fileURLWithPath: "/fixture/code.swift")]) && patches == [patch], "ordinary repository file is not a patch")
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("nested/a 日本.txt", "text")
            let file = fixture.repo.appendingPathComponent("nested/a 日本.txt")
            #expect(BrowserRepositoryDrop.relativePath(text: file.path, files: [], repository: fixture.repo) == "nested/a 日本.txt", "text spaces Unicode nested")
            #expect(BrowserRepositoryDrop.relativePath(text: nil, files: [file], repository: fixture.repo) == "nested/a 日本.txt", "Finder file")
            #expect(BrowserRepositoryDrop.relativePath(text: nil, files: [file.deletingLastPathComponent()], repository: fixture.repo) == "nested", "folder")
            #expect(BrowserRepositoryDrop.relativePath(text: fixture.root.path, files: [], repository: fixture.repo) == nil, "outside reject")
            try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent("escape"), withDestinationURL: fixture.root)
            #expect(
                BrowserRepositoryDrop.relativePath(text: fixture.repo.appendingPathComponent("escape/repo").path, files: [], repository: fixture.repo)
                    == "escape/repo", "symlink resolves within repository")
            #expect(
                BrowserRepositoryDrop.relativePath(text: fixture.repo.appendingPathComponent("escape").path, files: [], repository: fixture.repo) == nil,
                "symlink escape reject")
            #expect(
                BrowserRepositoryDrop.relativePath(text: fixture.repo.appendingPathComponent("../").path, files: [], repository: fixture.repo) == nil,
                "parent traversal reject")
        }
        static func templates() throws {
            for url in [
                "https://github.com/owner/repo.git", "http://github.com/owner/repo.git", "https://github.com/owner/repo", "ssh://git@github.com/owner/repo.git",
                "git@github.com/owner/repo.git",
            ] {
                let defs = RevisionLinkTemplates.gitHub.definitions(url: url)
                #expect(defs.count == 3 && defs.flatMap(\.formats).allSatisfy { $0.format.contains("owner/repo") }, "upstream GitHub extractor vectors")
            }
            let github = RevisionLinkTemplates.gitHub.definitions(url: "https://github.com/owner/repo")
            #expect(github.map(\.name) == ["GitHub - Code", "GitHub - Issues", "GitHub - Pull Requests"], "GitHub order")
            #expect(
                github[1].searchPattern == #"(?i)(?<!pull request |pr[ _]?)(#|(((feat(ure)?)|fix)[/_-]))\d+"# && github[1].nestedSearchPattern == #"\d+"#,
                "exact issue regex")
            #expect(
                github[2].searchPattern == #"(?i)(pull request |pr[ _]?)#?\d+"# && github[2].searchInParts == ["Message", "LocalBranches", "RemoteBranches"],
                "exact pull regex/parts")
            #expect(
                github.allSatisfy { $0.enabled && !$0.useOnlyFirstRemote && $0.remoteSearchInParts.isEmpty && $0.useRemotesPattern.isEmpty },
                "exact unused upstream defaults")
            for url in [
                "https://owner@dev.azure.com/owner/project/_git/repo", "git@ssh.dev.azure.com:v3/owner/project/repo",
                "https://owner.visualstudio.com/project/_git/repo", "owner@vs-ssh.visualstudio.com:v3/owner/project/repo",
            ] {
                let defs = RevisionLinkTemplates.azureDevOps.definitions(url: url)
                #expect(
                    defs.count == 2 && defs.flatMap(\.formats).allSatisfy { $0.format.contains("owner") && $0.format.contains("repo") },
                    "all Azure extractor vectors")
            }
            for provider in RevisionLinkTemplates.allCases {
                let placeholder = provider.definitions(url: nil)
                #expect(
                    placeholder.flatMap(\.formats).allSatisfy {
                        $0.format.contains("REPO_NAME") && $0.format.contains(provider == .gitHub ? "ORGANIZATION_NAME" : "ACCOUNT_NAME")
                    }, "provider placeholders")
                for definition in placeholder { _ = try NSRegularExpression(pattern: definition.searchPattern) }
            }
            let azure = RevisionLinkTemplates.azureDevOps.definitions(url: "git@ssh.dev.azure.com:v3/owner/project/repo")
            #expect(
                azure.map(\.name) == ["Azure DevOps - Code", "Azure DevOps - Issues"] && azure[1].searchPattern == #"#(\d+)"#
                    && azure[1].formats[0].format == "https://dev.azure.com/owner/repo/_workitems/edit/{0}", "Azure exact fields")
            #expect(
                azure[0].formats.map(\.format) == ["https://dev.azure.com/owner/_git/repo/commit/%COMMIT_HASH%", "https://dev.azure.com/owner/repo"],
                "Azure code formats")
            var inserted: [RevisionLinkDefinition] = []
            RevisionLinkTemplates.insert(github + azure, into: &inserted)
            RevisionLinkTemplates.insert(github, into: &inserted)
            #expect(inserted == github + azure, "duplicates skip preserving order")
            var scopes: [DistributedSettingsScope: [RevisionLinkDefinition]] = [:]
            #expect(RevisionLinkTemplates.insert(github, into: &scopes, startingAt: .local) == [.global], "upstream lowest available level insertion")
            #expect(
                RevisionLinkTemplates.insert(github, into: &scopes, startingAt: .local) == [.distributed], "upstream lower-level name produces higher override")
            #expect(RevisionLinkTemplates.insert(github, into: &scopes, startingAt: .local) == [.local], "upstream local override insertion")
            #expect(
                RevisionLinkTemplates.insert(github, into: &scopes, startingAt: .local).isEmpty && scopes[.local] == github, "per-level duplicate suppression")
            let restored = try RevisionLinkDefinition.decode(RevisionLinkDefinition.encode(inserted))
            #expect(Set(restored.map(\.name)) == Set(inserted.map(\.name)), "XML persistence")
            let azureLinks = azure[1].links(commitID: testObjectID("azure-links"), message: "fix #18", localRefs: [], remoteRefs: [], remotes: [])
            #expect(azureLinks.map(\.destination) == ["https://dev.azure.com/owner/repo/_workitems/edit/18"], "Azure runtime captured issue")
            let links = github[1].links(commitID: testObjectID("links"), message: "fix #12 and PR #34", localRefs: [], remoteRefs: [], remotes: [])
            #expect(links.map(\.destination) == ["https://github.com/owner/repo/issues/12"], "runtime issue extraction excludes PR")
            #expect(
                RevisionLinkTemplates.gitHub.definitions(remotes: [
                    remote("origin", "https://github.com/o/origin"), remote("fork", "https://github.com/o/fork"),
                ])[0].formats[1].format == "https://github.com/o/fork", "source-defined fork preference")
        }
        static func toolSettings() {
            for merge in [false, true] {
                for tool in GitSettingsTools.names {
                    let config = GitSettingsToolConfiguration.load(tool: tool, merge: merge, values: [:], locate: { "/tools/" + $0 })
                    #expect(config.path.hasPrefix("/tools/") && config.command.hasPrefix("\"/tools/"), "known tool defaults")
                    let edits = config.edits(merge: merge)
                    #expect(edits.count == 3 && edits[merge ? "merge.guitool" : "diff.guitool"] == tool, "always persist three keys")
                    let reloaded = GitSettingsToolConfiguration.load(tool: tool, merge: merge, values: edits.mapValues { [$0] }, locate: { _ in nil })
                    #expect(reloaded == config, "tool reload")
                }
                let custom = GitSettingsToolConfiguration.load(tool: "custom", merge: merge, values: [:], locate: { _ in nil })
                #expect(custom.path.isEmpty && custom.command.isEmpty, "unknown absent tool")
                let prefix = merge ? "mergetool" : "difftool"
                let values = ["\(prefix).custom.path": ["/custom"], "\(prefix).custom.cmd": ["command"]]
                #expect(GitSettingsToolConfiguration.load(tool: "custom", merge: merge, values: values).command == "command", "custom command preserved")
            }
            #expect(
                GitSettingsToolConfiguration.load(tool: "vscode", merge: false, values: ["mergetool.vscode.path": ["/configured"]]).path == "/configured",
                "upstream merge path fallback for diff")
            let split = GitSettingsToolConfiguration.load(
                tool: "vscode", merge: false, values: ["difftool.vscode.path": ["/diff"], "mergetool.vscode.path": ["/merge"]], locate: { _ in nil })
            #expect(split.path == "/diff" && split.command.hasPrefix("\"/merge\""), "upstream command fallback independent of configured diff path")
            #expect(
                GitSettingsToolConfiguration.load(tool: "custom", merge: false, values: ["mergetool.custom.path": ["/merge"]], locate: { _ in nil }).path
                    .isEmpty, "custom diff does not inherit merge path")
            #expect(
                GitSettingsTools.applicationSearchPaths(tool: "vscode", roots: [URL(fileURLWithPath: "/fixture/Applications")]).contains(
                    "/fixture/Applications/Visual Studio Code.app/Contents/Resources/app/bin"), "native registered search folder translation")
            #expect(GitSettingsTools.applicationSearchPaths(tool: "custom", roots: []).isEmpty, "custom values get no invented application folders")
            #expect(GitSettingsTools.credentialHelpers == ["oauth", "store", "cache"], "helper suggestions")
        }
        static func repositoryCases(includeWorkflowCases: Bool = true) async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let limit = FilePreview<String>.threshold
            let texts = [
                ("below.txt", String(repeating: "a", count: limit - 1)), ("equal.txt", String(repeating: "a", count: limit)),
                ("above.txt", String(repeating: "a", count: limit + 1)), ("multi.txt", String(repeating: "é", count: limit / 2 + 1)),
                ("multiOver.txt", String(repeating: "é", count: limit + 1)), ("emoji.txt", String(repeating: "😀", count: limit / 2)),
            ]
            #expect(FileContentDecoder.previewText("a\u{1b}[31mred\u{1b}[0m", path: "a.txt", historical: true) == "ared", "upstream historical ANSI stripping")
            #expect(FileContentDecoder.previewText("\u{1b}[31m", path: "a.patch", historical: true) == "\u{1b}[31m", "patch ANSI preserved")
            for (name, text) in texts { try fixture.write(name, text) }
            try (Data([0xef, 0xbb, 0xbf]) + Data(repeating: 97, count: limit)).write(to: fixture.repo.appendingPathComponent("bom.txt"))
            try Data(repeating: 0, count: limit + 1).write(to: fixture.repo.appendingPathComponent("large.bin"))
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")!
            try (png + Data(repeating: 0, count: limit + 1)).write(to: fixture.repo.appendingPathComponent("large.png"))
            try fixture.commitAll("base")
            let base = try fixture.head()
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let commit = try await module.loadBlameRevision(base)
            let entries = try await module.loadRepositoryFiles(for: commit)
            for (name, text) in texts {
                let preview = try await module.prepareFilePresentation(for: commit, file: entries.first { $0.path == name }!, encoding: .automatic)
                switch preview {
                case .ready(let content): #expect(text.utf16.count <= limit && content.text == text, "decoded UTF16 ready boundary \(name)")
                case .deferred(let length, _):
                    #expect(text.utf16.count > limit && length == text.utf16.count, "decoded UTF16 deferral boundary \(name)")
                    #expect(try await preview.resolve().text == text, "show original \(name)")
                }
            }
            let bom = try await module.prepareFilePresentation(for: commit, file: entries.first { $0.path == "bom.txt" }!, encoding: .automatic)
            guard case .deferred(let bomLength, _) = bom else { throw TestFailure(description: "historical decoded BOM code unit lost") }
            let confirmedBOM = try await bom.resolve()
            #expect(bomLength == limit + 1 && confirmedBOM.text.utf16.count == limit, "GetString BOM length with existing decoder presentation unchanged")
            let image = try await module.prepareFilePresentation(for: commit, file: entries.first { $0.path == "large.png" }!, encoding: .automatic)
            guard case .ready(let imageContent) = image else { throw TestFailure(description: "historical image deferred") }
            #expect(imageContent.kind == .image, "historical image bypass intact")
            let binary = try await module.prepareFilePresentation(for: commit, file: entries.first { $0.path == "large.bin" }!, encoding: .automatic)
            guard case .deferred = binary else { throw TestFailure(description: "large binary not deferred") }
            #expect(try await binary.resolve().kind == .binary, "binary decoder preserved on confirmation")
            let worktree = RevisionCommitBuilder.artificialRevisions(headID: base).first { $0.id == .workingDirectory }!
            let workingMulti = try await module.prepareFilePresentation(for: worktree, file: .init(path: "multi.txt", content: ""), encoding: .automatic)
            guard case .deferred(let byteLength, _) = workingMulti else { throw TestFailure(description: "worktree byte gate lost") }
            #expect(byteLength == texts.first { $0.0 == "multi.txt" }!.1.utf8.count, "worktree retains byte quantity")
            let workingImage = try await module.prepareFilePresentation(for: worktree, file: .init(path: "large.png", content: ""), encoding: .automatic)
            guard case .deferred = workingImage else { throw TestFailure(description: "worktree image byte gate lost") }
            guard includeWorkflowCases else { return }
            try fixture.write("small", "second")
            try fixture.commitAll("main one")
            let one = try fixture.head()
            try fixture.write("small", "third")
            try fixture.commitAll("main two")
            let two = try fixture.head()
            let linear = try await module.rebaseCommitChoice(onto: base.string, from: "")
            #expect(linear.preselect == .object(one) && linear.mergeBase == base, "linear HEAD~ preselect and boundary")
            let changed = try await module.rebaseCommitChoice(onto: base.string, from: two.string)
            #expect(changed.preselect == .object(two), "existing from preselect")
            try fixture.git(["checkout", "-q", "-b", "onto", base.string])
            try fixture.write("onto", "onto")
            try fixture.commitAll("divergent onto")
            try fixture.git(["checkout", "-q", "main"])
            let divergent = try await module.rebaseCommitChoice(onto: "onto", from: "")
            #expect(divergent.mergeBase == base, "divergent merge base")
            let options = divergent.options(RevisionGridFilter())
            #expect(options.showCurrentBranchOnly && !options.showReflogReferences && options.lastRevisionToDisplay == base.string, "chooser scope")
            let history = try fixture.git(["log", "--format=%H", "HEAD", "..." + base.string]).split(separator: "\n").map(String.init)
            #expect(history == [two.string, one.string], "merge-base history excludes boundary/onto")
            try fixture.git(["merge", "--no-ff", "-q", "onto", "-m", "merge onto"])
            let merged = try await module.rebaseCommitChoice(onto: "onto", from: "")
            let ontoID = try ObjectID.parse(try fixture.git(["rev-parse", "onto"]).trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(merged.mergeBase == ontoID && merged.preselect == .object(two), "merge history boundary and first parent HEAD~")
            let nested = fixture.repo.appendingPathComponent("holder/sources")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            #expect(
                try BrowserPresentation.repositoryDescription(nested, uninformativePattern: "sources") == "holder < repo", "repository name consumer override")
            let rebase = RebaseManagerViewController(source: module)
            _ = rebase.view
            rebase.specificRangeOption.performClick(nil)
            #expect(rebase.chooseFromButton.isEnabled, "range chooser enabled without grid supplied from")
            rebase.fromField.stringValue = "prior"
            rebase.acceptFromRevision(nil)
            #expect(rebase.fromField.stringValue == "prior", "cancel preserves from")
            rebase.acceptFromRevision(commit)
            #expect(rebase.fromField.stringValue == base.shortString, "accept updates from")
            #expect(CloneSourcePath.canBeGitURL(fixture.repo.path), "valid local Git directory")
            let tool = GitSettingsToolConfiguration(tool: "custom", path: "/bin/echo", command: #""/bin/echo" "$LOCAL" "$REMOTE""#)
            for (key, value) in tool.edits(merge: false) { try await module.saveGitSetting(key, value: value, scope: .local) }
            let saved = try await module.loadGitSettings(.local)
            for (key, value) in tool.edits(merge: true) { try await module.saveGitSetting(key, value: value, scope: .local) }
            let consumer = try await module.loadMergeToolConfiguration()!
            #expect(consumer.command == tool.command && consumer.executablePath == "/bin/echo", "C29 reads persisted Settings values")
            let arguments = try MergeToolInvocation.arguments(
                command: consumer.command!, tool: consumer.name, twoWay: false, base: nil, local: "space local", remote: "日本 remote", merged: "merged",
                executable: consumer.executablePath, configuredPath: consumer.path)
            #expect(arguments == ["space local", "日本 remote"], "full command executable removed for direct launch")
            #expect(
                try await module.runExternalMergeTool(executable: consumer.executablePath!, arguments: arguments) == 0,
                "actual external launch with saved configuration")
            #expect(saved["difftool.custom.cmd"]?.last == tool.command && saved["diff.guitool"]?.last == "custom", "actual Git launch configuration persisted")
        }
    }
}

typealias SettingsAndHistoryTests = UIIntegrationTests.SettingsAndHistoryTests

extension SettingsAndHistoryTests {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func wait(_ name: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predicate(), Comment(rawValue: "timed out: " + name))
    }
    static func settingsPresentation() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let domain = "SettingsAndHistory-Settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppSettingsStore(defaults: defaults)
        func field<T: NSControl>(_ controller: SettingsViewController, _ label: String, _ type: T.Type) -> T? {
            guard let title = descendants(controller.view).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == label }) else { return nil }
            return title.superview?.subviews.filter { $0 !== title }.compactMap { $0 as? T }.first
        }
        func select(_ popup: NSPopUpButton, _ title: String) {
            popup.selectItem(withTitle: title)
            _ = popup.sendAction(popup.action!, to: popup.target)
        }
        func selectTool(_ combo: NSComboBox, _ title: String) {
            combo.selectItem(withObjectValue: title)
            combo.delegate?.comboBoxSelectionDidChange?(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
        }
        func edit(_ control: NSTextField, _ text: String) {
            control.stringValue = text
            control.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
        }
        func make() -> (SettingsViewController, NSPanel) {
            let controller = SettingsViewController(store: store, source: module, initialPage: "git_config", repositoryChanged: {})
            let panel = NSPanel(contentViewController: controller)
            panel.isReleasedWhenClosed = false
            controller.panel = panel
            panel.setContentSize(NSSize(width: 1040, height: 720))
            return (controller, panel)
        }
        let (controller, panel) = make()
        defer { panel.close() }
        try await wait("effective settings") { field(controller, "Difftool", NSComboBox.self) != nil }
        select(field(controller, "Settings source:", NSPopUpButton.self)!, "local")
        try await wait("local settings") { field(controller, "Difftool", NSComboBox.self) != nil }
        let merge = field(controller, "Mergetool", NSComboBox.self)!
        let diff = field(controller, "Difftool", NSComboBox.self)!
        let rows = descendants(controller.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        let expectedRows = ["Mergetool", "Path to mergetool", "Mergetool command", "Difftool", "Path to difftool", "Difftool command"]
        let positions = expectedRows.map { rows.firstIndex(of: $0)! }
        #expect(positions == positions.sorted() && !rows.contains("Known tools:"), "source merge-before-diff hierarchy with no separate known-tool popup")
        let gridLabels = [
            "User name", "User email", "Editor", "Mergetool", "Path to mergetool", "Mergetool command", "Difftool", "Path to difftool", "Difftool command",
            "Path to commit template", "Files content encoding",
        ]
        let labelViews = gridLabels.map { title in descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == title } }
        #expect(labelViews.allSatisfy { $0 != nil }, "upstream Config captions without colons")
        controller.view.layoutSubtreeIfNeeded()
        let labelLefts = labelViews.compactMap { $0.map { $0.convert($0.bounds, to: nil).minX } }
        #expect(Set(labelLefts.map { Int($0.rounded()) }).count == 1, "Config captions share one leading column")
        let controlLefts = labelViews.compactMap { label -> CGFloat? in
            guard let label, let row = label.superview as? NSStackView, row.arrangedSubviews.count > 1 else { return nil }
            return row.arrangedSubviews[1].convert(row.arrangedSubviews[1].bounds, to: nil).minX
        }
        #expect(
            controlLefts.count == gridLabels.count && Set(controlLefts.map { Int($0.rounded()) }).count == 1,
            "Config fields start in one column \(controlLefts)")
        let buttonRows = [
            "Path to mergetool", "Mergetool command", "Path to difftool", "Difftool command", "Path to commit template", "Files content encoding",
        ]
        let buttonFrames = buttonRows.compactMap { title -> NSRect? in
            guard let row = labelViews[gridLabels.firstIndex(of: title)!]?.superview as? NSStackView, let button = row.arrangedSubviews.last as? NSButton else {
                return nil
            }
            return button.convert(button.bounds, to: nil)
        }
        #expect(
            buttonFrames.count == buttonRows.count && Set(buttonFrames.map { Int($0.width.rounded()) }) == [Int(SettingsGridLayout.buttonColumnWidth)]
                && Set(buttonFrames.map { Int($0.minX.rounded()) }).count == 1,
            "Browse/Suggest/Configure share the upstream 123-point button column in their own rows")
        let mergeFrame = merge.convert(merge.bounds, to: nil)
        let pathFrame = field(controller, "Path to mergetool", NSTextField.self)!.convert(
            field(controller, "Path to mergetool", NSTextField.self)!.bounds, to: nil)
        #expect(
            abs(mergeFrame.width - SettingsGridLayout.fixedControlWidth) <= 1 && pathFrame.width > mergeFrame.width,
            "tool combo fixed 241 while path field stretches")
        let lineEndings = descendants(controller.view).compactMap { $0 as? SettingsRadioGroup }.first
        #expect(
            lineEndings?.title == "Line endings" && lineEndings?.buttons.map(\.title) == GitSettingsLineEndings.options.map(\.title),
            "upstream Line endings radio group")
        lineEndings?.buttons[1].performClick(nil)
        #expect(lineEndings?.selectedValue == "input" && lineEndings?.buttons.filter { $0.state == .on }.count == 1, "one Line endings choice")
        lineEndings?.buttons[3].performClick(nil)
        for label in ["Path to mergetool", "Mergetool command", "Path to difftool", "Difftool command"] {
            #expect(field(controller, label, NSTextField.self)?.isEnabled == false, Comment(rawValue: "empty tool retains visible disabled row: " + label))
        }
        #expect(
            merge.isEditable && diff.isEditable && merge.objectValues as? [String] == GitSettingsTools.names
                && diff.objectValues as? [String] == GitSettingsTools.names, "source editable tool combos reuse existing registry")
        selectTool(merge, "kdiff3")
        #expect(field(controller, "Path to mergetool", NSTextField.self)?.isEnabled == true, "merge selection enables existing rows")
        edit(merge, "customMerge")
        edit(field(controller, "Path to mergetool", NSTextField.self)!, "/bin/echo")
        edit(field(controller, "Mergetool command", NSTextField.self)!, #""/bin/echo" "$LOCAL" "$REMOTE" "$MERGED""#)
        edit(diff, "")
        #expect(field(controller, "Path to difftool", NSTextField.self)?.isEnabled == false, "clearing diff leaves disabled rows present and merge intact")
        selectTool(diff, "vscode")
        #expect(
            field(controller, "Mergetool command", NSTextField.self)?.stringValue == #""/bin/echo" "$LOCAL" "$REMOTE" "$MERGED""#,
            "diff selection preserves custom merge draft")
        #expect(field(controller, "Path to difftool", NSTextField.self)?.stringValue.isEmpty == false, "known choice populated path before Apply")
        #expect(field(controller, "Difftool command", NSTextField.self)?.stringValue.contains("--diff") == true, "known choice populated command before Apply")
        #expect(try await module.loadGitSettings(.local)["diff.guitool"] == nil, "draft not persisted")
        let apply = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
        apply.performClick(nil)
        try await wait("Apply completes") { apply.isEnabled }
        let saved = try await module.loadGitSettings(.local)
        #expect(
            saved["diff.guitool"]?.last == "vscode" && saved["difftool.vscode.path"]?.last?.isEmpty == false
                && saved["difftool.vscode.cmd"]?.last?.contains("--diff") == true, "Apply persisted all tool fields")
        #expect(
            saved["merge.guitool"]?.last == "customMerge" && saved["mergetool.customMerge.path"]?.last == "/bin/echo",
            "independent custom merge fields persist through existing Apply")
        let mergeConsumer = try await module.loadMergeToolConfiguration()
        #expect(
            mergeConsumer?.name == "customMerge" && mergeConsumer?.executablePath == "/bin/echo"
                && mergeConsumer?.command == saved["mergetool.customMerge.cmd"]?.last, "actual C29 launcher consumes the saved combo/path/command")
        let (cancelled, cancelPanel) = make()
        defer { cancelPanel.close() }
        try await wait("reopen settings") { field(cancelled, "Difftool", NSComboBox.self) != nil }
        select(field(cancelled, "Settings source:", NSPopUpButton.self)!, "local")
        try await wait("reopen local") { field(cancelled, "Difftool command", NSTextField.self) != nil }
        #expect(field(cancelled, "Difftool command", NSTextField.self)?.stringValue == saved["difftool.vscode.cmd"]?.last, "reopen saved command")
        selectTool(field(cancelled, "Difftool", NSComboBox.self)!, "kdiff3")
        descendants(cancelled.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        #expect(try await module.loadGitSettings(.local)["diff.guitool"]?.last == "vscode", "Cancel preserves saved config")
        controller.goToCategory("revision_links")
        try await wait("revision scopes") { descendants(controller.view).contains { ($0 as? NSControl)?.accessibilityIdentifier() == "Settings.appScope" } }
        let scope = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "Settings.appScope" }!
        select(scope, DistributedSettingsScope.global.title)
        func insert(_ provider: RevisionLinkTemplates) {
            let popup = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first {
                $0.menu?.items.contains(where: { $0.title == provider.actionTitle }) == true
            }!
            let item = popup.menu!.items.first { $0.title == provider.actionTitle }!
            _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        }
        insert(.gitHub)
        try await wait("templates inserted") { descendants(controller.view).compactMap { $0 as? RevisionLinksSettingsEditor }.first?.definitions.count == 3 }
        let insertedEditor = descendants(controller.view).compactMap { $0 as? RevisionLinksSettingsEditor }.first!
        #expect(insertedEditor.selectedIndex == 0 && insertedEditor.definitions[0].name == "GitHub - Code", "first inserted provider definition selected")
        #expect(store.revisionLinksXML == nil, "template draft not persisted")
        descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!.performClick(nil)
        try await wait("templates persisted") { store.revisionLinksXML != nil }
        #expect(try RevisionLinkDefinition.decode(store.revisionLinksXML).count == 3, "UI action persists exact provider list")
        let inheritedScope = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "Settings.appScope" }!
        select(inheritedScope, DistributedSettingsScope.local.title)
        let inherited = descendants(controller.view).compactMap { $0 as? RevisionLinksSettingsEditor }.first!
        #expect(inherited.definitions.count == 3 && inherited.addButton.isEnabled, "writable Local includes inherited Global categories like upstream manager")
        let effectiveScope = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "Settings.appScope" }!
        select(effectiveScope, DistributedSettingsScope.effective.title)
        let effective = descendants(controller.view).compactMap { $0 as? RevisionLinksSettingsEditor }.first!
        #expect(
            effective.definitions.count == 3 && effective.categories.isEnabled && !effective.addButton.isEnabled && !effective.templates.isEnabled,
            "effective categories readable with mutation controls disabled")
        let currentScope = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "Settings.appScope" }!
        select(currentScope, DistributedSettingsScope.global.title)
        insert(.gitHub)
        try await wait("duplicate template leaves no new selection") {
            descendants(controller.view).compactMap { $0 as? RevisionLinksSettingsEditor }.first?.selectedIndex == -1
        }
        let editor = descendants(controller.view).compactMap { $0 as? RevisionLinksSettingsEditor }.first!
        editor.categories.selectRowIndexes(IndexSet(integer: editor.definitions.firstIndex { $0.name == "GitHub - Code" }!), byExtendingSelection: false)
        let name = field(controller, "Name:", NSTextField.self)!
        name.stringValue = "Edited GitHub Code"
        name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
        insert(.azureDevOps)
        try await Task.sleep(for: .milliseconds(100))
        var response: NSApplication.ModalResponse?
        controller.onClose = { response = $0 }
        descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
        try await wait("OK persisted templates") { response == .OK }
        let final = try RevisionLinkDefinition.decode(store.revisionLinksXML)
        #expect(final.count == 5 && final.contains { $0.name == "Edited GitHub Code" }, "duplicate skip, edits and both providers persisted by OK")
        let cancellation = SettingsViewController(store: store, source: module, initialPage: "revision_links", initialScope: .global, repositoryChanged: {})
        let cancellationPanel = NSPanel(contentViewController: cancellation)
        cancellationPanel.isReleasedWhenClosed = false
        cancellation.panel = cancellationPanel
        defer { cancellationPanel.close() }
        try await wait("template Cancel scope loaded") {
            descendants(cancellation.view).compactMap { $0 as? NSPopUpButton }.contains { $0.accessibilityIdentifier() == "Settings.appScope" }
        }
        let priorXML = store.revisionLinksXML
        if let field = field(cancellation, "Name:", NSTextField.self) {
            field.stringValue = "Cancelled change"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        descendants(cancellation.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        #expect(store.revisionLinksXML == priorXML, "Cancel discards template edits")
    }
}
