@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit



@MainActor
enum FileStatusTests {
    static func run() async throws {
        testParsers()
        try await testCalculator()
        try await testActions()
        try await testSubmoduleStatus()
        try await FileStatusUITests.run()
        print("FileStatusTests: passed")
    }

    private static func testParsers() {

        let a = testObjectID("a"), b = testObjectID("b")
        let interactive = FileStatusCommands.interactivePatch(path: "space ü.txt", stage: true)
        check(interactive.arguments == ["add", "--patch", "--", "space ü.txt"] && interactive.changesRepositoryState && !interactive.accessesRemote,
              "interactive add remains a structured mutation")
        check(FileStatusCommands.interactivePatch(path: "a", stage: false).arguments == ["checkout", "-p", "--", "a"], "interactive reset")
        let gitlink = FileStatusCommands.submoduleChanges("-Subproject commit \(a.string)\n+Subproject commit \(b.string)-dirty\n")
        check(gitlink?.first == a && gitlink?.second == b && gitlink?.isDirty == true, "typed gitlink patch parsing")
        let cases: [(RevisionID?, RevisionID?, [String])] = [
            (.object(a), .object(b), [a.string, b.string]),
            (.index, .workingDirectory, []),
            (.workingDirectory, .index, ["-R"]),
            (.object(a), .index, ["--cached", a.string]),
            (.object(a), .workingDirectory, [a.string]),
            (.workingDirectory, .object(a), ["-R", a.string]),
            (.index, .object(a), ["-R", "--cached", a.string])
        ]
        for (first, second, expected) in cases {
            let actual = FileStatusCommands.revisionArguments(first: first, second: second)
            check(actual == expected, "revision arguments \(String(describing: first)) \(String(describing: second)): \(actual)")
        }
        let zero = String(repeating: "0", count: 40)
        let status = [
            "1 .M N... 100644 100644 100644 \(zero) \(zero) src/changed.txt",
            "1 M. N... 100644 100644 100644 \(zero) \(zero) staged.txt",
            "1 AM N... 000000 100644 100644 \(zero) \(zero) both.txt",
            "2 R. N... 100644 100644 100644 \(zero) \(zero) R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 \(zero) \(zero) \(zero) conflict.txt",
            "1 .M SC.. 160000 160000 160000 \(zero) \(zero) sub",
            "? untracked.txt"
        ].joined(separator: "\0") + "\0"
        let parsed = FileStatusCommands.parseStatus(status)
        func find(_ path: String, _ staged: FileStagedStatus) -> ChangedFile? { parsed.first { $0.path == path && $0.staged == staged } }
        check(find("src/changed.txt", .workTree)?.changeType == .modified && find("src/changed.txt", .index) == nil, "worktree modified")
        check(find("staged.txt", .index)?.changeType == .modified, "index modified")
        check(find("both.txt", .index)?.changeType == .added && find("both.txt", .workTree)?.changeType == .modified, "both sides")
        let renamed = find("new name.txt", .index)
        check(renamed?.changeType == .renamed && renamed?.oldPath == "old name.txt" && renamed?.renameCopyPercentage == "100", "rename \(String(describing: renamed))")
        check(find("conflict.txt", .workTree)?.isConflict == true && find("conflict.txt", .index) == nil, "unmerged UU only worktree")
        let submodule = find("sub", .workTree)
        check(submodule?.isSubmodule == true && submodule?.submoduleCommitChanged == true, "submodule")
        let untracked = find("untracked.txt", .workTree)
        check(untracked?.isTracked == false && untracked?.changeType == .added, "untracked")

        let raw = ":100644 100644 \(zero) \(zero) M\0a.txt\0:100644 100644 \(zero) \(zero) R090\0old.txt\0new.txt\0:160000 160000 \(zero) \(zero) M\0sub\0"
        let diff = FileStatusCommands.parseRawDiff(raw, staged: .none)
        check(diff.count == 3 && diff[1].changeType == .renamed && diff[1].oldPath == "old.txt" && diff[1].path == "new.txt"
              && diff[1].renameCopyPercentage == "090" && diff[2].isSubmodule, "raw diff \(diff)")
        let verbose = FileStatusCommands.parseListFilesVerbose("H a.txt\0S skip.txt\0h assume.txt\0s both.txt\0", skipWorktree: true, assumeUnchanged: true)
        check(verbose.map(\.path) == ["skip.txt", "assume.txt", "both.txt"] && verbose[0].isSkipWorktree && verbose[1].isAssumeUnchanged
              && verbose[2].isAssumeUnchanged && !verbose[2].isSkipWorktree, "ls-files -v \(verbose.map(\.path))")
        check((try? FileStatusCommands.grepArguments(for: "needle here")) == ["-e", "needle here"], "grep plain")
        check((try? FileStatusCommands.grepArguments(for: "-e foo --and -e bar")) == ["-e", "foo", "--and", "-e", "bar"], "grep with -e")

        let grepLines = FileStatusCommands.parseGrepFile("3=func f() {\n--\n4-  a\n5:  needle\n--\n9:needle\n")
        check(grepLines.map { "\($0.kind)|\($0.newLineNumber.map(String.init) ?? "")|\($0.text)" }
              == ["hunk|3|func f() {", "context|4|  a", "addition|5|  needle", "hunk||--", "addition|9|needle"],
              "grep file parser \(grepLines.map(\.text))")
        check(FileStatusCommands.parseGrepFiles("\(a.string):x.txt\0\(a.string):dir/y.txt\0", revision: .object(a), grepText: "t").map(\.path) == ["x.txt", "dir/y.txt"], "grep files")
        check(FileStatusCommands.parseRangeCount("2\t3\n") == (2, 3), "range count")
        check(FileStatusDiffCalculator.stagedStatus(first: .index, second: .workingDirectory, parentToSecond: nil) == .workTree
              && FileStatusDiffCalculator.stagedStatus(first: .object(a), second: .index, parentToSecond: a) == .index
              && FileStatusDiffCalculator.stagedStatus(first: .object(a), second: .object(b), parentToSecond: a) == .none, "staged status")
    }

    static func commitModel(_ id: ObjectID, parents: [ObjectID]) -> Commit {
        Commit(id: .object(id), shortID: String(id.string.prefix(7)), subject: "s", body: "", authorName: "T", authorEmail: "t@e",
               authorDate: Date(), committerName: "T", committerEmail: "t@e", commitDate: Date(), parentIDs: parents, references: [])
    }

    static func artificial(_ kind: Commit.Kind, head: ObjectID) -> Commit {
        Commit(id: kind == .workingDirectory ? .workingDirectory : .index, shortID: "", subject: "", body: "", authorName: "", authorEmail: "",
               authorDate: Date(), committerName: "", committerEmail: "", commitDate: Date(), parentIDs: [head], references: [], kind: kind)
    }

    private static func testCalculator() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("base.txt", "base\n")
        try fixture.write("shared.txt", "one\n")
        try fixture.commitAll("base")
        let base = try fixture.head()
        try fixture.git(["checkout", "-q", "-b", "topic"])
        try fixture.write("a-only.txt", "a\n")
        try fixture.write("shared.txt", "one\ntopic\n")
        try fixture.commitAll("topic")
        let topic = try fixture.head()
        try fixture.git(["checkout", "-q", "main"])
        try fixture.write("b-only.txt", "b\n")
        try fixture.write("shared.txt", "main\none\n")
        try fixture.commitAll("main")
        let main = try fixture.head()
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let describe: @Sendable (ObjectID) -> String = { String($0.string.prefix(7)) }


        var groups = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base])], headID: main), describe: describe)
        check(groups.count == 1 && groups[0].first == .object(base) && Set(groups[0].files.map(\.path)) == ["b-only.txt", "shared.txt"]
              && groups[0].summary.hasPrefix("Diff with A: "), "single revision \(groups.map(\.summary))")

        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(base, parents: [])], headID: main), describe: describe)
        check(groups.count == 1 && groups[0].first == nil && groups[0].files.allSatisfy { $0.changeType == .added && !$0.isUnchanged }, "root commit")


        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base]), commitModel(topic, parents: [base])], headID: main),
                                                      describe: describe)
        check(groups.map(\.kind) == [.diff, .range, .diffB, .diffA], "A/B groups \(groups.map(\.kind))")
        func status(_ group: Int, _ path: String) -> DiffBranchStatus? { groups[group].files.first { $0.path == path }?.diffStatus }
        check(status(0, "a-only.txt") == .onlyA && status(0, "b-only.txt") == .onlyB && status(0, "shared.txt") == .unequal, "A->B marks")
        check(groups[1].files.first?.isRangeDiff == true && groups[1].summary.hasPrefix("Range diff 1↓ 1↑ BASE"), "range item \(groups[1].summary)")

        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base]), commitModel(base, parents: [])], headID: main),
                                                      describe: describe)
        check(groups.count == 1 && groups[0].first == .object(base), "linear pair")

        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base]), commitModel(topic, parents: [base])], headID: main,
                                                            showDiffForAllParents: false), describe: describe)
        check(groups.count == 1, "no multi diff without all parents")


        _ = try? fixture.git(["merge", "-q", "--no-edit", "topic"])
        try fixture.write("shared.txt", "resolved\n")
        try fixture.commitAll("merge")
        let merge = try fixture.head()
        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(merge, parents: [main, topic])], headID: merge), describe: describe)
        check(groups.map(\.kind) == [.diff, .diff, .combined] && groups[2].files.map(\.path) == ["shared.txt"], "merge groups \(groups.map(\.kind))")
        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(merge, parents: [main, topic])], headID: merge, showDiffForAllParents: false),
                                                      describe: describe)
        check(groups.count == 1, "first parent only")


        try fixture.write("base.txt", "changed\n")
        try fixture.write("new.txt", "new\n")
        try fixture.write("staged.txt", "s\n")
        try fixture.git(["add", "staged.txt"])
        try fixture.git(["update-index", "--skip-worktree", "b-only.txt"])
        let worktree = artificial(.workingDirectory, head: merge), index = artificial(.index, head: merge)
        groups = try await module.calculateFileStatus(.init(revisions: [worktree], headID: merge), describe: describe)
        check(groups.count == 1 && groups[0].first == .index && Set(groups[0].files.map(\.path)) == ["base.txt", "new.txt"]
              && groups[0].files.allSatisfy { $0.staged == .workTree }, "worktree group \(groups.first?.files.map(\.path) ?? [])")
        groups = try await module.calculateFileStatus(.init(revisions: [worktree], headID: merge, showUntrackedFiles: false), describe: describe)
        check(groups[0].files.map(\.path) == ["base.txt"], "untracked hidden")
        groups = try await module.calculateFileStatus(.init(revisions: [worktree], headID: merge, showSkipWorktreeFiles: true), describe: describe)
        check(groups[0].files.contains { $0.path == "b-only.txt" && $0.isSkipWorktree }, "skip-worktree shown")
        groups = try await module.calculateFileStatus(.init(revisions: [index], headID: merge), describe: describe)
        check(groups.count == 1 && groups[0].first == .object(merge) && groups[0].files.map(\.path) == ["staged.txt"]
              && groups[0].files[0].staged == .index, "index group")


        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base])], headID: main,
                                                            grepArguments: ["-e", "main"], grepText: "main"), describe: describe)
        check(groups.last?.kind == .grep && groups.last?.files.map(\.path) == ["shared.txt"], "grep group \(groups.last?.files.map(\.path) ?? [])")
        groups = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base])], headID: main, fileTreeMode: true), describe: describe)
        check(groups.count == 1 && groups[0].kind == .grep && Set(groups[0].files.map(\.path)) == ["base.txt", "shared.txt", "b-only.txt"], "file tree listing")
        var options = GitGrepOptions()
        options.ignoreCase = true
        var request = FileStatusDiffRequest(revisions: [commitModel(main, parents: [base])], headID: main, grepArguments: ["-e", "MAIN"], grepText: "MAIN")
        request.grepSettings = options
        groups = try await module.calculateFileStatus(request, describe: describe)
        check(groups.last?.files.map(\.path) == ["shared.txt"], "grep ignore case")


        let pair = try await module.calculateFileStatus(.init(revisions: [commitModel(main, parents: [base]), commitModel(topic, parents: [base])], headID: main),
                                                        describe: describe)
        if case .diff(let diff)? = try? await module.loadFileStatusDiff(group: pair[0], file: pair[0].files.first { $0.path == "shared.txt" }!,
                                                                         options: FileDiffOptions(), grep: GitGrepOptions()) {
            check(diff?.lines.contains { $0.kind == .addition } == true, "A->B diff lines")
        } else { check(false, "A->B diff") }
        if case .text(let text) = try await module.loadFileStatusDiff(group: pair[1], file: pair[1].files[0], options: FileDiffOptions(), grep: GitGrepOptions()) {
            check(text.contains("main") || text.contains("topic"), "range-diff text \(text)")
        } else { check(false, "range diff") }
        let grepGroup = FileStatusGroup(first: nil, second: .object(main), summary: "grep", kind: .grep,
                                        files: FileStatusCommands.parseGrepFiles("\(main.string):shared.txt\0", revision: .object(main), grepText: "main"))
        if case .diff(let grepDiff?) = try await module.loadFileStatusDiff(group: grepGroup, file: grepGroup.files[0], options: FileDiffOptions(), grep: GitGrepOptions()) {
            let lines = grepDiff.lines.map { "\($0.newLineNumber ?? 0)\($0.kind == .addition ? ":" : "-")\($0.text)" }
            check(lines == ["1:main", "2-one"], "grep lines with context \(lines)")
        } else { check(false, "grep content") }
        let worktreeGroups = try await module.calculateFileStatus(.init(revisions: [worktree], headID: merge), describe: describe)
        let newFile = worktreeGroups[0].files.first { $0.path == "new.txt" }!
        if case .diff(let diff) = try await module.loadFileStatusDiff(group: worktreeGroups[0], file: newFile, options: FileDiffOptions(), grep: GitGrepOptions()) {
            check(diff?.lines.contains { $0.kind == .addition && $0.text.contains("new") } == true, "untracked diff")
        } else { check(false, "untracked content") }
        let data = try await module.loadFileData(path: "shared.txt", at: .object(main))
        check(String(decoding: data, as: UTF8.self) == "main\none\n", "file data at revision")
        let blob = try await module.blobSpecifier(path: "shared.txt", at: .object(base))
        check(blob?.count == 40, "blob specifier")
    }

    private static func testActions() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "one\n")
        try fixture.write("b.txt", "one\n")
        try fixture.commitAll("first")
        let first = try fixture.head()
        try fixture.write("a.txt", "two\n")
        try fixture.commitAll("second")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        func item(_ path: String, staged: FileStagedStatus = .none, type: FileChangeType = .modified) -> ChangedFile {
            var file = FileStatusCommands.changedFile(path: path, oldPath: nil, status: type == .added ? "A" : "M", staged: staged)
            file.changeType = type
            return file
        }


        _ = try await module.resetFiles(to: .object(first), items: [item("a.txt")], resetAndDelete: false)
        let v1 = try fixture.read("a.txt")
        check(v1 == "one\n", "reset to parent")

        try fixture.write("b.txt", "staged\n")
        try fixture.git(["add", "b.txt"])
        try fixture.write("b.txt", "worktree\n")
        _ = try await module.resetFiles(to: .index, items: [item("b.txt", staged: .workTree)], resetAndDelete: false)
        let v2 = try fixture.read("b.txt")
        check(v2 == "staged\n", "reset to index")

        try fixture.write("new.txt", "n\n")
        try fixture.git(["add", "new.txt"])
        _ = try await module.resetFiles(to: .object(try fixture.head()), items: [item("new.txt", staged: .index, type: .added)], resetAndDelete: true)
        let staged = try fixture.git(["ls-files", "--stage", "new.txt"])
        check(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("new.txt").path)
              && !staged.contains("new.txt"), "reset and delete new file")


        try await module.setSkipWorktree(["a.txt"], true)
        let v3 = try fixture.git(["ls-files", "-v", "a.txt"])
        check(v3.hasPrefix("S "), "skip-worktree set")
        try await module.setSkipWorktree(["a.txt"], false)
        try await module.setAssumeUnchanged(["a.txt"], true)
        let v4 = try fixture.git(["ls-files", "-v", "a.txt"])
        check(v4.hasPrefix("h "), "assume-unchanged set")
        try await module.setAssumeUnchanged(["a.txt"], false)
        let v5 = try fixture.git(["ls-files", "-v", "a.txt"])
        check(v5.hasPrefix("H "), "flags cleared")


        try await module.move(from: "a.txt", to: "moved.txt", isFolder: false)
        let movedIndex = try fixture.git(["ls-files", "--", "a.txt", "moved.txt"])
        let movedContent = try fixture.git(["show", ":moved.txt"])
        check(movedIndex.trimmingCharacters(in: .newlines) == "moved.txt"
              && movedContent == "one\n"
              && !FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("a.txt").path),
              "git mv moves the index entry and worktree path without requiring rename heuristics")
        try await module.stopTracking("moved.txt")
        let tracked = try fixture.git(["ls-files", "moved.txt"])
        check(tracked.isEmpty && FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("moved.txt").path), "stop tracking")


        try fixture.write("gone.txt", "g\n")
        try fixture.git(["add", "gone.txt"])
        try await module.deleteFiles([item("gone.txt", staged: .index, type: .added)])
        let gone = try fixture.git(["ls-files", "gone.txt"])
        check(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("gone.txt").path) && gone.isEmpty, "delete file")


        try fixture.git(["config", "difftool.fake.cmd", "true"])
        try fixture.git(["config", "diff.tool", "fake"])
        let tools = try await module.loadDiffTools()
        check(tools == ["fake"], "diff tools \(tools)")
        try await module.openDifftool(first: .object(first), second: .object(try fixture.head()), path: "b.txt", oldPath: nil, isTracked: true, customTool: "fake", externalCommand: nil)

        let log = fixture.root.appendingPathComponent("difftool.log")
        try fixture.git(["config", "difftool.rec.cmd", "echo \"$(basename \"$MERGED\")\" >> '\(log.path)'"])
        try fixture.git(["config", "diff.tool", "rec"])
        try fixture.write("tool.txt", "one\n")
        try fixture.commitAll("tool one")
        let toolOne = try fixture.head()
        try fixture.write("tool.txt", "two\n")
        try fixture.commitAll("tool two")
        let toolTwo = try fixture.head()
        try await module.openDifftool(first: .object(toolOne), second: .object(toolTwo), path: "tool.txt", oldPath: nil, isTracked: true, customTool: nil, externalCommand: nil)
        try await module.openDifftool(firstBlob: "\(toolOne.string):tool.txt", secondBlob: "\(toolTwo.string):tool.txt", customTool: "rec", externalCommand: nil)
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check(logged.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2 && logged.hasPrefix("tool.txt"), "difftool runs \(logged)")


        try fixture.write("dir/x.txt", "x\n")
        try fixture.commitAll("dir")
        try await module.move(from: "dir", to: "nested/dir2", isFolder: true)
        let movedFolder = try fixture.git(["ls-files", "--", "dir", "nested"])
        check(movedFolder.trimmingCharacters(in: .newlines) == "nested/dir2/x.txt", "folder move \(movedFolder)")
        try await module.move(from: "nested", to: "nested", isFolder: true)
        try fixture.commitAll("moved")


        try fixture.write("c.txt", "c1\n")
        try fixture.commitAll("c1")
        try fixture.write("c.txt", "c2\n")
        try fixture.commitAll("c2")
        let c2 = try fixture.head()
        let c1 = try ObjectID.parse(try fixture.git(["rev-parse", "HEAD^"]).trimmingCharacters(in: .whitespacesAndNewlines))
        try fixture.write("c.txt", "c1\n")
        try fixture.commitAll("back")
        let applied = try await module.cherryPickChanges(group: FileStatusGroup(first: .object(c1), second: .object(c2), summary: "", files: []),
                                                          file: item("c.txt", staged: .none, type: .modified))
        let cIndex = try fixture.git(["show", ":c.txt"])
        let cWorktree = try fixture.read("c.txt")
        check(applied.succeeded && cIndex == "c2\n" && cWorktree == "c2\n", "cherry pick changes \(applied.output)")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure("FileStatusTests: \(message)") }
    }

    private static func testSubmoduleStatus() async throws {
        let child = try FileStatusFixture.make(), parent = try FileStatusFixture.make()
        defer { child.remove(); parent.remove() }
        try child.write("file", "old\n")
        try child.commitAll("old")
        let old = try child.head()
        try child.write("file", "new\n")
        try child.commitAll("new")
        let new = try child.head()
        try parent.git(["-c", "protocol.file.allow=always", "submodule", "add", child.repo.path, "nested child"])
        try parent.git(["-C", "nested child", "checkout", "--detach", old.string])
        try parent.commitAll("record old")
        let first = try parent.head()
        try parent.git(["-C", "nested child", "checkout", "--detach", new.string])
        try parent.commitAll("record new")
        let second = try parent.head()
        let module = GitRepositoryModule(repositoryURL: parent.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        var file = ChangedFile(id: "nested child", path: "nested child", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
        file.isSubmodule = true
        let group = FileStatusGroup(first: .object(first), second: .object(second), summary: "", files: [file])
        let forward = try await module.fileStatusSubmodule(group: group, file: file)
        check(forward?.first == old && forward?.second == new && forward?.state == .ahead && forward?.countSuffix == " (+1-0)", "gitlink ahead for selected pair")
        let reverse = try await module.fileStatusSubmodule(group: .init(first: .object(second), second: .object(first), summary: "", files: [file]), file: file)
        check(reverse?.state == .behind && reverse?.countSuffix == " (+0-1)", "reverse gitlink comparison is not HEAD state")
        try parent.write("nested child/file", "dirty\n")
        let dirty = try await module.fileStatusSubmodule(group: .init(first: .index, second: .workingDirectory, summary: "", files: [file]), file: file)
        check(dirty?.state == .same && dirty?.isDirty == true && dirty?.countSuffix == "", "dirty gitlink with unchanged commit")
        if let forward, let dirty {
            check(ChangedFileCellView.submoduleImage(forward, file: file) == "SubmoduleRevisionUp", "forward icon")
            check(ChangedFileCellView.submoduleImage(dirty, file: file) == "SubmoduleDirty", "dirty icon")
        }

        try parent.git(["submodule", "deinit", "--force", "--", "nested child"])
        let uninitialized = try await module.fileStatusSubmodule(group: group, file: file)
        check(uninitialized?.added == nil && uninitialized?.state == .modified && uninitialized?.second == new, "uninitialized retains identities without invented counts")
    }
}

struct FileStatusFixtureGit: GitCommandRunning {
    private func isolated(_ environment: [String: String]) -> [String: String] {
        environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], uniquingKeysWith: { _, fixture in fixture })
    }
    func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
        try await GitProcess().run(arguments: arguments, in: directory, standardInput: standardInput, environment: isolated(environment))
    }
    func runStreaming(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        try await GitProcess().runStreaming(arguments: arguments, in: directory, standardInput: standardInput, environment: isolated(environment), output: output)
    }
}

final class FileStatusFixture {
    let root: URL
    var repo: URL { root.appendingPathComponent("repo", isDirectory: true) }
    private init(root: URL) { self.root = root }

    static func make() throws -> FileStatusFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-FileStatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = FileStatusFixture(root: root.resolvingSymlinksInPath())
        try fixture.run(["init", "-q", "-b", "main", fixture.repo.path], in: fixture.root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.com"), ("commit.gpgsign", "false"), ("core.autocrlf", "false")] {
            try fixture.git(["config", key, value])
        }
        return fixture
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ content: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String { String(decoding: try Data(contentsOf: repo.appendingPathComponent(path)), as: UTF8.self) }

    func commitAll(_ message: String) throws {
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", message])
    }

    func head() throws -> ObjectID { try ObjectID.parse(try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) }

    @discardableResult
    func git(_ arguments: [String]) throws -> String { try run(arguments, in: repo) }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_EDITOR"] = "true"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
