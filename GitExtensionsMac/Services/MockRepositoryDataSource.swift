import Foundation

struct MockRepositoryDataSource: RepositoryBrowsingDataSource {
    func loadSnapshot() async throws -> RepositorySnapshot {
        Self.snapshot
    }

    func loadRevisionDetails(for commit: Commit) async throws -> RepositoryRevisionDetails {
        RepositoryRevisionDetails(
            files: Self.snapshot.filesByCommit[commit.id] ?? [],
            diffsByFile: Self.snapshot.diffsByFile,
            repositoryFiles: [],
            gpgInfo: Self.snapshot.gpgInfoByCommit[commit.id]
        )
    }

    func loadRepositoryFiles(for commit: Commit) async throws -> [RepositoryFileEntry] {
        Self.snapshot.repositoryFilesByCommit[commit.id] ?? []
    }

    func loadDiff(for commit: Commit, file: ChangedFile) async throws -> FileDiff? {
        Self.snapshot.diffsByFile[file.id]
    }

    func loadFileContent(for commit: Commit, file: RepositoryFileEntry) async throws -> RepositoryFileEntry {
        file
    }
}

private extension MockRepositoryDataSource {
    static let snapshot: RepositorySnapshot = {
        let repository = Repository(
            id: "gitextensions",
            name: "gitextensions",
            path: "/example/gitextensions",
            description: "Git Extensions — mock repository"
        )

        let repositories = [
            repository,
            Repository(id: "sample", name: "sample-project", path: "/example/sample-project", description: "Sample repository"),
            Repository(id: "app", name: "GitExtensionsMac", path: "/example/GitExtensionsMac", description: "macOS implementation")
        ]

        let branches = [
            Branch(id: "refs/heads/main", name: "main", commitID: "c18", isCurrent: true, isRemote: false, remoteName: nil, ahead: 2, behind: 0),
            Branch(id: "refs/heads/feature/command-palette", name: "feature/command-palette", commitID: "c14", isCurrent: false, isRemote: false, remoteName: nil, ahead: 3, behind: 1),
            Branch(id: "refs/heads/release/7.2", name: "release/7.2", commitID: "c16", isCurrent: false, isRemote: false, remoteName: nil, ahead: 0, behind: 2),
            Branch(id: "refs/heads/hotfix/diff-scroll", name: "hotfix/diff-scroll", commitID: "c10", isCurrent: false, isRemote: false, remoteName: nil, ahead: 1, behind: 5),
            Branch(id: "refs/heads/maintenance", name: "maintenance", commitID: "c07", isCurrent: false, isRemote: false, remoteName: nil, ahead: 0, behind: 9)
        ]

        let originBranches = [
            Branch(id: "refs/remotes/origin/main", name: "main", commitID: "c17", isCurrent: false, isRemote: true, remoteName: "origin", ahead: 0, behind: 2),
            Branch(id: "refs/remotes/origin/release/7.2", name: "release/7.2", commitID: "c16", isCurrent: false, isRemote: true, remoteName: "origin", ahead: 0, behind: 0),
            Branch(id: "refs/remotes/origin/feature/command-palette", name: "feature/command-palette", commitID: "c14", isCurrent: false, isRemote: true, remoteName: "origin", ahead: 0, behind: 0)
        ]
        let upstreamBranches = [
            Branch(id: "refs/remotes/upstream/main", name: "main", commitID: "c17", isCurrent: false, isRemote: true, remoteName: "upstream", ahead: 0, behind: 0),
            Branch(id: "refs/remotes/upstream/release/7.1", name: "release/7.1", commitID: "c09", isCurrent: false, isRemote: true, remoteName: "upstream", ahead: 0, behind: 0)
        ]
        let remotes = [
            Remote(id: "origin", name: "origin", fetchURL: "https://github.com/example/gitextensions.git", branches: originBranches),
            Remote(id: "upstream", name: "upstream", fetchURL: "https://github.com/gitextensions/gitextensions.git", branches: upstreamBranches)
        ]

        let tags = [
            Tag(id: "refs/tags/v7.2.0", name: "v7.2.0", commitID: "c16"),
            Tag(id: "refs/tags/v7.1.0", name: "v7.1.0", commitID: "c09"),
            Tag(id: "refs/tags/v7.0.1", name: "v7.0.1", commitID: "c04")
        ]
        let stashes = [
            Stash(id: "stash@{0}", selector: "stash@{0}", subject: "WIP on main: toolbar overflow", branchName: "main", commitID: "c18"),
            Stash(id: "stash@{1}", selector: "stash@{1}", subject: "On release/7.2: translation updates", branchName: "release/7.2", commitID: "c16")
        ]
        let worktrees = [
            Worktree(id: "main-worktree", name: "gitextensions", path: repository.path, branchName: "main", isCurrent: true),
            Worktree(id: "release-worktree", name: "gitextensions-release", path: "/example/gitextensions-release", branchName: "release/7.2", isCurrent: false)
        ]

        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 16, minute: 48))!
        func date(hoursAgo: Int) -> Date { calendar.date(byAdding: .hour, value: -hoursAgo, to: base)! }
        func ref(
            _ name: String,
            _ kind: RevisionReference.Kind,
            trackingRemote: String? = nil,
            mergeWith: String? = nil
        ) -> RevisionReference {
            RevisionReference(
                id: "\(name)-\(String(describing: kind))",
                name: name,
                kind: kind,
                trackingRemote: trackingRemote,
                mergeWith: mergeWith
            )
        }
        func commit(
            _ id: String,
            _ subject: String,
            _ hoursAgo: Int,
            _ author: String,
            parents: [String],
            refs: [RevisionReference] = [],
            body: String = ""
        ) -> Commit {
            let email = author.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
            return Commit(
                id: id,
                shortID: String("\(id)8cbe7c9f2fafe49163ac41e2e81b9e12".prefix(8)),
                subject: subject,
                body: body,
                authorName: author,
                authorEmail: email,
                authorDate: date(hoursAgo: hoursAgo),
                committerName: author,
                committerEmail: email,
                commitDate: date(hoursAgo: hoursAgo),
                parentIDs: parents,
                references: refs
            )
        }

        let repositoryCommits = [
            commit("c18", "Merge branch 'feature/command-palette'", 1, "Mara Klein", parents: ["c17", "c14"], refs: [ref("main", .currentBranch, trackingRemote: "origin", mergeWith: "main")], body: "Bring the command palette work into the main development branch.\n\nIncludes keyboard navigation and searchable actions."),
            commit("c17", "Improve revision label hover hit-testing", 3, "Donatas M.", parents: ["c16"], refs: [ref("origin/main", .remoteBranch), ref("upstream/main", .remoteBranch)]),
            commit("c16", "Prepare 7.2 release notes", 6, "Henrik Larsson", parents: ["c15"], refs: [ref("release/7.2", .localBranch, trackingRemote: "origin", mergeWith: "release/7.2"), ref("origin/release/7.2", .remoteBranch), ref("v7.2.0", .tag)]),
            commit("c14", "Add searchable command registry", 9, "Mara Klein", parents: ["c13"], refs: [ref("feature/command-palette", .localBranch, trackingRemote: "origin", mergeWith: "feature/command-palette"), ref("origin/feature/command-palette", .remoteBranch)]),
            commit("c13", "Add keyboard navigation to command palette", 12, "Mara Klein", parents: ["c12"]),
            commit("c15", "Avoid empty diff for multi-selection", 14, "Stefan V.", parents: ["c12"]),
            commit("c12", "Render ref labels using theme colors", 19, "Paul Miossec", parents: ["c11"]),
            commit("c11", "Merge hotfix/diff-scroll into main", 24, "Henrik Larsson", parents: ["c09", "c10"]),
            commit("c10", "Keep diff position when selecting files", 27, "Sara Kim", parents: ["c08"], refs: [ref("hotfix/diff-scroll", .localBranch)]),
            commit("c09", "Update translations for release", 31, "Translation Bot", parents: ["c08"], refs: [ref("v7.1.0", .tag), ref("upstream/release/7.1", .remoteBranch)]),
            commit("c08", "Show worktrees in the left panel", 40, "Gerhard O.", parents: ["c07"]),
            commit("c07", "Refactor revision loading pipeline", 51, "Mara Klein", parents: ["c06"], refs: [ref("maintenance", .localBranch)]),
            commit("c06", "Add remote branch ahead/behind indicators", 63, "Donatas M.", parents: ["c05"]),
            commit("c05", "Improve file tree context menu", 76, "Sara Kim", parents: ["c04"]),
            commit("c04", "Release version 7.0.1", 96, "Henrik Larsson", parents: ["c03"], refs: [ref("v7.0.1", .tag)]),
            commit("c03", "Support reftable repositories", 112, "Nikos G.", parents: ["c02"]),
            commit("c02", "Align file status icons", 126, "Gerhard O.", parents: ["c01"]),
            commit("c01", "Initial repository browser", 144, "Shawn H.", parents: [])
        ]

        let artificialAuthor = "John Doe"
        let artificialEmail = "john.doe@example.com"
        let workingDirectory = Commit(
            id: "$working-directory",
            shortID: "",
            subject: "Working directory",
            body: "",
            authorName: artificialAuthor,
            authorEmail: artificialEmail,
            authorDate: base,
            committerName: artificialAuthor,
            committerEmail: artificialEmail,
            commitDate: base,
            parentIDs: ["$index"],
            references: [],
            kind: .workingDirectory
        )
        let commitIndex = Commit(
            id: "$index",
            shortID: "",
            subject: "Commit index",
            body: "",
            authorName: artificialAuthor,
            authorEmail: artificialEmail,
            authorDate: base,
            committerName: artificialAuthor,
            committerEmail: artificialEmail,
            commitDate: base,
            parentIDs: ["c18"],
            references: [],
            kind: .index
        )
        let commits = [workingDirectory, commitIndex] + repositoryCommits

        let files = [
            ChangedFile(id: "palette", path: "src/app/GitUI/CommandsDialogs/CommandPalette.cs", oldPath: nil, changeType: .added, additions: 118, deletions: 0),
            ChangedFile(id: "formbrowse", path: "src/app/GitUI/CommandsDialogs/FormBrowse.cs", oldPath: nil, changeType: .modified, additions: 14, deletions: 5),
            ChangedFile(id: "menus", path: "src/app/GitUI/CommandsDialogs/BrowseDialog/FormBrowseMenus.cs", oldPath: nil, changeType: .modified, additions: 22, deletions: 8),
            ChangedFile(id: "strings", path: "src/app/GitUI/Properties/TranslatedStrings.cs", oldPath: nil, changeType: .modified, additions: 6, deletions: 1),
            ChangedFile(id: "tests", path: "tests/app/UnitTests/GitUI/CommandPaletteTests.cs", oldPath: nil, changeType: .added, additions: 87, deletions: 0)
        ]

        var filesByCommit: [String: [ChangedFile]] = [:]
        for (index, item) in commits.enumerated() {
            let count = max(1, min(files.count, (index % files.count) + 1))
            filesByCommit[item.id] = Array(files.prefix(count))
        }
        filesByCommit["c18"] = files
        filesByCommit[workingDirectory.id] = []
        filesByCommit[commitIndex.id] = []

        func line(_ id: String, _ old: Int?, _ new: Int?, _ kind: DiffLine.Kind, _ text: String) -> DiffLine {
            DiffLine(id: id, oldLineNumber: old, newLineNumber: new, kind: kind, text: text)
        }

        let paletteDiff = FileDiff(id: "palette-diff", fileID: "palette", lines: [
            line("p0", nil, nil, .header, "diff --git a/src/app/GitUI/CommandsDialogs/CommandPalette.cs b/src/app/GitUI/CommandsDialogs/CommandPalette.cs"),
            line("p1", nil, nil, .header, "new file mode 100644"),
            line("p2", nil, nil, .header, "--- /dev/null"),
            line("p3", nil, nil, .header, "+++ b/src/app/GitUI/CommandsDialogs/CommandPalette.cs"),
            line("p4", nil, nil, .hunk, "@@ -0,0 +1,18 @@"),
            line("p5", nil, 1, .addition, "using GitUI.CommandsDialogs.Menus;"),
            line("p6", nil, 2, .addition, ""),
            line("p7", nil, 3, .addition, "namespace GitUI.CommandsDialogs;"),
            line("p8", nil, 4, .addition, ""),
            line("p9", nil, 5, .addition, "internal sealed class CommandPalette : Form"),
            line("p10", nil, 6, .addition, "{"),
            line("p11", nil, 7, .addition, "    private readonly IReadOnlyList<MenuCommand> _commands;"),
            line("p12", nil, 8, .addition, ""),
            line("p13", nil, 9, .addition, "    public CommandPalette(IReadOnlyList<MenuCommand> commands)"),
            line("p14", nil, 10, .addition, "    {"),
            line("p15", nil, 11, .addition, "        _commands = commands;"),
            line("p16", nil, 12, .addition, "        InitializeComponent();"),
            line("p17", nil, 13, .addition, "    }"),
            line("p18", nil, 14, .addition, "}")
        ])

        let formDiff = FileDiff(id: "form-diff", fileID: "formbrowse", lines: [
            line("f0", nil, nil, .header, "diff --git a/src/app/GitUI/CommandsDialogs/FormBrowse.cs b/src/app/GitUI/CommandsDialogs/FormBrowse.cs"),
            line("f1", nil, nil, .header, "index b137df2..8cbe7c9 100644"),
            line("f2", nil, nil, .header, "--- a/src/app/GitUI/CommandsDialogs/FormBrowse.cs"),
            line("f3", nil, nil, .header, "+++ b/src/app/GitUI/CommandsDialogs/FormBrowse.cs"),
            line("f4", nil, nil, .hunk, "@@ -248,9 +248,14 @@ public sealed partial class FormBrowse"),
            line("f5", 248, 248, .context, "     private void InitializeCommands()"),
            line("f6", 249, 249, .context, "     {"),
            line("f7", 250, nil, .deletion, "         _commands = CreateDefaultCommands();"),
            line("f8", nil, 250, .addition, "         _commands = CreateDefaultCommands()"),
            line("f9", nil, 251, .addition, "             .Concat(CreatePluginCommands())"),
            line("f10", nil, 252, .addition, "             .OrderBy(command => command.Caption)"),
            line("f11", nil, 253, .addition, "             .ToArray();"),
            line("f12", 251, 254, .context, "     }"),
            line("f13", 252, 255, .context, "")
        ])

        let genericDiff = FileDiff(id: "generic-diff", fileID: "menus", lines: [
            line("g0", nil, nil, .header, "diff --git a/src/app/GitUI/CommandsDialogs/BrowseDialog/FormBrowseMenus.cs b/src/app/GitUI/CommandsDialogs/BrowseDialog/FormBrowseMenus.cs"),
            line("g1", nil, nil, .hunk, "@@ -74,6 +74,10 @@ internal sealed class FormBrowseMenus"),
            line("g2", 74, 74, .context, "         AddRepositoryCommands(menu);"),
            line("g3", nil, 75, .addition, "         AddCommandPalette(menu);"),
            line("g4", nil, 76, .addition, "         AddKeyboardShortcuts(menu);"),
            line("g5", 75, 77, .context, "         return menu;"),
            line("g6", 76, 78, .context, "     }")
        ])

        let diffsByFile = [
            "palette": paletteDiff,
            "formbrowse": formDiff,
            "menus": genericDiff,
            "strings": FileDiff(id: "strings-diff", fileID: "strings", lines: genericDiff.lines),
            "tests": FileDiff(id: "tests-diff", fileID: "tests", lines: paletteDiff.lines)
        ]

        let repositoryFiles = [
            RepositoryFileEntry(
                path: ".editorconfig",
                content: "root = true\n\n[*]\ncharset = utf-8\nindent_style = space\n"
            ),
            RepositoryFileEntry(
                path: "README.md",
                content: "# Git Extensions\n\nGit Extensions is a graphical user interface for Git.\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/CommandsDialogs/CommandPalette.cs",
                content: "using GitUI.CommandsDialogs.Menus;\n\nnamespace GitUI.CommandsDialogs;\n\ninternal sealed class CommandPalette : Form\n{\n    private readonly IReadOnlyList<MenuCommand> _commands;\n}\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/CommandsDialogs/FormBrowse.cs",
                content: "namespace GitUI.CommandsDialogs;\n\npublic sealed partial class FormBrowse : GitModuleForm\n{\n    private void InitializeCommands()\n    {\n        // Mock file content at the selected revision.\n    }\n}\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/CommandsDialogs/BrowseDialog/FormBrowseMenus.cs",
                content: "namespace GitUI.CommandsDialogs.BrowseDialog;\n\ninternal sealed class FormBrowseMenus\n{\n    public IReadOnlyList<MenuCommand> Create() => [];\n}\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/Properties/TranslatedStrings.cs",
                content: "namespace GitUI.Properties;\n\ninternal static class TranslatedStrings\n{\n    public const string Browse = \"Browse\";\n}\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/UserControls/RevisionGrid/RevisionGridControl.cs",
                content: "namespace GitUI.UserControls.RevisionGrid;\n\npublic partial class RevisionGridControl : GitModuleControl\n{\n}\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/UserControls/FileStatusList.cs",
                content: "namespace GitUI.UserControls;\n\npublic partial class FileStatusList : GitModuleControl\n{\n}\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitUI/GitUI.csproj",
                content: "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <TargetFramework>net9.0-windows</TargetFramework>\n  </PropertyGroup>\n</Project>\n"
            ),
            RepositoryFileEntry(
                path: "src/app/GitCommands/Git/Gpg/GpgInfo.cs",
                content: "namespace GitCommands.Git.Gpg;\n\npublic record GpgInfo(CommitStatus CommitStatus, string CommitVerificationMessage, TagStatus TagStatus, string? TagVerificationMessage);\n"
            ),
            RepositoryFileEntry(
                path: "tests/app/UnitTests/GitUI/CommandPaletteTests.cs",
                content: "namespace GitUI.Tests;\n\n[TestFixture]\npublic class CommandPaletteTests\n{\n    [Test]\n    public void Filters_commands() { }\n}\n"
            ),
            RepositoryFileEntry(
                path: "tests/app/UnitTests/GitUI/RevisionGraphTests.cs",
                content: "namespace GitUI.Tests.UserControls.RevisionGrid.Graph;\n\n[TestFixture]\npublic class RevisionGraphTests\n{\n}\n"
            ),
            RepositoryFileEntry(
                path: "scripts/build.sh",
                content: "#!/usr/bin/env bash\nset -euo pipefail\ndotnet build\n",
                isExecutable: true
            ),
            RepositoryFileEntry(
                path: "setup/GitExtensions.iss",
                content: "[Setup]\nAppName=Git Extensions\nAppVersion=7.2\n"
            )
        ]

        var repositoryFilesByCommit: [String: [RepositoryFileEntry]] = [:]
        for (index, item) in commits.enumerated() {
            let omittedTailCount = min(index % 4, repositoryFiles.count - 8)
            repositoryFilesByCommit[item.id] = Array(repositoryFiles.dropLast(omittedTailCount))
        }

        let gpgInfoByCommit: [String: RevisionGPGInfo] = [
            "c18": RevisionGPGInfo(
                commitStatus: .goodSignature,
                commitVerificationMessage: "Good signature from Mara Klein <mara.klein@example.com>\nPrimary key fingerprint: A18F 93B2 0D44 7A10 2F66  14C8 61A0 4B3C 889D 721E",
                tagStatus: .noTag,
                tagVerificationMessage: nil
            ),
            "c16": RevisionGPGInfo(
                commitStatus: .goodSignature,
                commitVerificationMessage: "Good signature from Henrik Larsson <henrik.larsson@example.com>\nKey ID: 22D4E7B8923A1710",
                tagStatus: .oneGood,
                tagVerificationMessage: "Good signature on tag v7.2.0 from Git Extensions Release Signing Key"
            ),
            "c09": RevisionGPGInfo(
                commitStatus: .missingPublicKey,
                commitVerificationMessage: "Can't check signature: No public key\nKey ID: 12A40E918D71C0BF",
                tagStatus: .missingPublicKey,
                tagVerificationMessage: "Tag v7.1.0 is signed, but the public key is unavailable."
            ),
            "c04": RevisionGPGInfo(
                commitStatus: .signatureError,
                commitVerificationMessage: "BAD signature from an unknown release key",
                tagStatus: .oneBad,
                tagVerificationMessage: "BAD signature on tag v7.0.1"
            )
        ]

        return RepositorySnapshot(
            repositories: repositories,
            currentRepository: repository,
            branches: branches,
            tags: tags,
            remotes: remotes,
            stashes: stashes,
            worktrees: worktrees,
            submodules: [
                Submodule(id: "externals/conemu-inside", name: "conemu-inside", path: "externals/conemu-inside", url: nil, commitID: nil, description: nil, state: .clean),
                Submodule(id: "externals/Git.hub", name: "Git.hub", path: "externals/Git.hub", url: nil, commitID: nil, description: nil, state: .clean)
            ],
            commits: commits,
            filesByCommit: filesByCommit,
            diffsByFile: diffsByFile,
            repositoryFilesByCommit: repositoryFilesByCommit,
            gpgInfoByCommit: gpgInfoByCommit,
            workingDirectoryChangeCount: 3
        )
    }()
}
