import Foundation
@testable import GitExtensionsCore
@testable import GitCommands

enum GitPatchTests {
    static func run() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw GitError.malformedOutput(command: "Patch test", detail: message) }
        }
        let review = try PatchPreviewParser.parse(Data("""
        From ignored mailbox header

        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/image.bin b/image.bin
        new file mode 100644
        index 0000000..1234567
        GIT binary patch
        literal 3
        ignored payload
        diff --cc merged.txt
        index 1234567,2345678..3456789
        --- a/merged.txt
        +++ b/merged.txt
        @@@ -1,1 -1,1 +1,1 @@@
        ++merged result
        diff --git a/script b/script
        old mode 100644
        new mode 100755
        """.utf8))
        try require(review.files.count == 4 && review.diffs.count == 4, "review-only rename/binary/combined/mode sections")
        try require(review.files[0].oldPath == "old name.txt" && review.files[0].path == "new name.txt", "rename identities with spaces")
        try require(review.metadata[review.files[1].id]?.fileType == .binary, "binary metadata")
        try require(review.diffs[review.files[1].id]?.lines.contains { $0.text.contains("ignored payload") } == false, "binary payload is not displayed as text")
        try require(review.files[2].path == "merged.txt", "combined review identity")
        try require(review.metadata[review.files[3].id]?.change == .changeMode, "mode-only metadata")
        var latin = Data("diff --git a/text b/text\n--- a/text\n+++ b/text\n@@ -1 +1 @@\n-old\n+caf".utf8)
        latin.append(0xe9); latin.append(10)
        let latinPreview = try PatchPreviewParser.parse(latin)
        try require(latinPreview.diffs.values.first?.lines.contains { $0.text == "café" } == true, "non-UTF-8 preview decoding")
        try require(try PatchPreviewParser.parse(Data("not a patch".utf8)).files.isEmpty, "non-patch file has no fabricated revision")
        for pair in [("before:/", "after:/"), ("b/", "a/"), ("./", "./")] {
            let prefix = try PatchPreviewParser.parse(Data("diff --git \(pair.0)old file \(pair.1)new file\nold mode 100644\nnew mode 100755\n".utf8))
            try require(prefix.files.first?.oldPath == "old file" && prefix.files.first?.path == "new file", "custom/reversed filename prefixes")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Patches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let patches = root.appendingPathComponent("patch output é")
        for url in [source, patches] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let runner = GitProcess()
        func git(_ args: [String], at url: URL) async throws -> String {
            let result = try await runner.run(GitCommand(arguments: args, accessesRemote: false, changesRepositoryState: true), in: url)
            guard result.succeeded else { throw GitError.commandFailed(arguments: args, status: result.exitStatus, stderr: result.standardErrorString) }
            return result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-b", "main"], at: source)
        _ = try await git(["config", "user.name", "Patch Test"], at: source)
        _ = try await git(["config", "user.email", "patch@example.invalid"], at: source)
        try Data("base\n".utf8).write(to: source.appendingPathComponent("file é.txt"))
        _ = try await git(["add", "."], at: source)
        _ = try await git(["commit", "-m", "Base"], at: source)
        let base = try ObjectID.parse(await git(["rev-parse", "HEAD"], at: source))
        _ = try await git(["clone", source.path, target.path], at: root)
        _ = try await git(["config", "user.name", "Patch Recipient"], at: target)
        _ = try await git(["config", "user.email", "recipient@example.invalid"], at: target)
        var revisions: [PatchRevision] = []
        var parent = base
        for number in 1...3 {
            try Data("change \(number)\n".utf8).write(to: source.appendingPathComponent("file é.txt"))
            _ = try await git(["commit", "-am", "Change \(number)\n\nMessage body \(number)"], at: source)
            let id = try ObjectID.parse(await git(["rev-parse", "HEAD"], at: source))
            revisions.append(PatchRevision(id: id, firstParent: parent))
            parent = id
        }
        let module = GitRepositoryModule(repositoryURL: source)
        _ = try await module.loadRepositoryState()
        let commands = GitPatchCommands.format(revisions, outputDirectory: patches)
        try require(commands.count == 3 && commands[1].arguments[4...5] == ["--start-number", "2"], "numbered individual patches")
        try require(GitPatchCommands.format([revisions[0], revisions[2]], outputDirectory: patches).count == 1, "two endpoints form one range")
        try require(GitPatchCommands.apply(isDiff: false, file: nil, signOff: true, ignoreWhitespace: true).arguments == ["am", "--3way", "--signoff", "--ignore-whitespace"], "mailbox ordering")
        try require(GitPatchCommands.apply(isDiff: true, file: patches, signOff: true, ignoreWhitespace: true).arguments == ["apply", "--ignore-whitespace", patches.path], "raw diff ignores signoff")
        try require(GitPatchCommands.isDiff(Data("\u{feff}diff --git a/x b/x\n".utf8)), "BOM/raw detection")
        try require(!GitPatchCommands.isDiff(Data("From abc Mon Sep 17\n".utf8)), "mailbox detection")
        _ = try await module.formatPatches([revisions[0], revisions[2]], outputDirectory: patches)
        let files = try FileManager.default.contentsOfDirectory(at: patches, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        try require(files.count == 3, "inclusive commit range")
        var mailbox = Data()
        for file in files { mailbox.append(try Data(contentsOf: file)) }
        let series = root.appendingPathComponent("series.patch")
        try mailbox.write(to: series)
        let preview = try await module.loadPatchPreview(series)
        try require(preview.files.count == 3 && preview.diffs.count == 3, "series preview preserves repeated filenames")
        try require(preview.files.allSatisfy { $0.path == "file é.txt" }, "quoted Unicode paths: \(preview.files.map(\.path))")
        try require(preview.diffs.values.allSatisfy { $0.lines.contains { $0.kind == .hunk } }, "shared parser receives each patch body")
        let recipient = GitRepositoryModule(repositoryURL: target)
        _ = try await recipient.loadRepositoryState()
        let applied = try await recipient.applyPatches(.file(series), signOff: false, ignoreWhitespace: false, output: { _ in })
        try require(applied.succeeded && applied.changed && !applied.state.isApplying, "clean series outcome")
        try require(try await git(["log", "--format=%s", "--reverse", "\(base.string)..HEAD"], at: target) == "Change 1\nChange 2\nChange 3", "commit order/messages")
        try require(try await git(["log", "-1", "--format=%ae"], at: target) == "patch@example.invalid", "author preservation")
        try require(try Data(contentsOf: target.appendingPathComponent("file é.txt")) == Data("change 3\n".utf8), "worktree result")
        _ = try await git(["reset", "--hard", base.string], at: target)
        try Data("conflict\n".utf8).write(to: target.appendingPathComponent("file é.txt"))
        _ = try await git(["commit", "-am", "Conflicting change"], at: target)
        let before = try await git(["rev-parse", "HEAD"], at: target)
        let stopped = try await recipient.applyPatches(.file(series), signOff: false, ignoreWhitespace: false, output: { _ in })
        try require(!stopped.succeeded && stopped.changed && stopped.state.isApplying && stopped.state.hasConflicts, "conflict and am state")
        let mutationState = try await recipient.loadMutationState()
        try require(!mutationState.rebaseInProgress, "am is not a rebase")
        let aborted = try await recipient.continuePatches(.abort, output: { _ in })
        try require(aborted.succeeded && aborted.changed && !aborted.state.isApplying, "abort clears operation")
        try require(try await git(["rev-parse", "HEAD"], at: target) == before, "abort restores original HEAD")
        try require(try await git(["status", "--porcelain"], at: target) == "", "abort restores index/worktree")
        _ = try await recipient.applyPatches(.file(series), signOff: true, ignoreWhitespace: false, output: { _ in })
        try Data("change 1\n".utf8).write(to: target.appendingPathComponent("file é.txt"))
        let staged = try await recipient.addPatchFiles(["file é.txt"], force: false, preview: false)
        try require(staged.succeeded && staged.changed && !staged.state.hasConflicts, "manual resolution stages actual index")
        let continued = try await recipient.continuePatches(.resolved, output: { _ in })
        try require(continued.succeeded && continued.changed && !continued.state.isApplying, "resolved continues remaining series")
        try require(try await git(["log", "-1", "--format=%B"], at: target).contains("Signed-off-by: Patch Recipient <recipient@example.invalid>"), "signoff preserved")
        _ = try await git(["reset", "--hard", before], at: target)
        _ = try await recipient.applyPatches(.file(files[0]), signOff: false, ignoreWhitespace: false, output: { _ in })
        let skipped = try await recipient.continuePatches(.skip, output: { _ in })
        try require(skipped.succeeded && skipped.changed && !skipped.state.isApplying, "skip final conflicted patch clears operation")
        try require(try await git(["rev-parse", "HEAD"], at: target) == before, "skip does not commit conflict")
        _ = try await git(["reset", "--hard", base.string], at: target)
        let directoryApplied = try await recipient.applyPatches(.directory(patches), signOff: false, ignoreWhitespace: false, output: { _ in })
        if directoryApplied.state.isApplying { _ = try await recipient.continuePatches(.abort, output: { _ in }) }
        try require(directoryApplied.changed, "directory mode invokes a mailbox series")
        _ = try await git(["reset", "--hard", base.string], at: target)
        let rawPatch = root.appendingPathComponent("raw.patch")
        let raw = try await runner.run(GitCommand(arguments: ["diff", base.string, revisions[0].id.string], accessesRemote: false, changesRepositoryState: false), in: source)
        try raw.standardOutput.write(to: rawPatch)
        let rawApplied = try await recipient.applyPatches(.file(rawPatch), signOff: true, ignoreWhitespace: false, output: { _ in })
        try require(rawApplied.succeeded && rawApplied.changed && !rawApplied.state.isApplying, "raw diff applies without am")
        try require(try await git(["rev-parse", "HEAD"], at: target) == base.string, "raw diff does not commit")
        try require(try await git(["diff", "--cached", "--name-only"], at: target) == "", "raw diff leaves index untouched")
        let bad = root.appendingPathComponent("invalid.patch")
        try Data("diff --git invalid\n".utf8).write(to: bad)
        let failed = try await recipient.applyPatches(.file(bad), signOff: false, ignoreWhitespace: false, output: { _ in })
        try require(!failed.succeeded && !failed.changed, "invalid raw diff has no refresh")
        let ignored = target.appendingPathComponent("ignored.txt")
        try Data("ignored.txt\n".utf8).write(to: target.appendingPathComponent(".git/info/exclude"))
        try Data("before\n".utf8).write(to: ignored)
        let ignoredPatch = root.appendingPathComponent("ignored.patch")
        try Data("diff --git a/ignored.txt b/ignored.txt\n--- a/ignored.txt\n+++ b/ignored.txt\n@@ -1 +1 @@\n-before\n+after\n".utf8).write(to: ignoredPatch)
        let ignoredResult = try await recipient.applyPatches(.file(ignoredPatch), signOff: false, ignoreWhitespace: false, output: { _ in })
        try require(ignoredResult.succeeded && ignoredResult.changed, "ignored target mutation requests refresh")
        try require(try Data(contentsOf: ignored) == Data("after\n".utf8), "ignored target contents actually changed")
        let dryRun = try await recipient.addPatchFiles(["file é.txt"], force: false, preview: true)
        try require(dryRun.succeeded && !dryRun.changed, "staging preview never requests mutation refresh")
        print("GitPatchTests: passed")
    }
}
