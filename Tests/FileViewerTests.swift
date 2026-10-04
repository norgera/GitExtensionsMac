@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation
import AppKit

enum FileViewerTests {
    static func run() {
        testDiffArguments()
        testEncodingAndBinaryPresentation()
        testSyntaxDetection()
        try! testDifftoolCommands()
        testInlinePresentation()
        print("FileViewerTests: passed")
    }

    private static func testDiffArguments() {
        expect(FileDiffOptions().gitArguments.isEmpty, "default diff options preserve the normal Git arguments")
        expect(FileDiffOptions(whitespace: .changes, usesHistogram: true).gitArguments == ["--histogram", "--ignore-space-change"], "histogram precedes additional diff options")
        expect(
            FileDiffOptions(whitespace: .endOfLine, contextLines: 5, treatsAllFilesAsText: true).gitArguments
                == ["--ignore-space-at-eol", "--unified=5", "--text"],
            "diff options preserve intentional argument ordering"
        )
        expect(
            FileDiffOptions(whitespace: .all, showsEntireFile: true).gitArguments
                == ["--ignore-all-space", "--inter-hunk-context=9000", "--unified=9000"],
            "entire-file mode uses the upstream inter-hunk and unified arguments"
        )
    }

    private static func testEncodingAndBinaryPresentation() {
        let bom = FileContentDecoder.decode(Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8)), path: "note.txt", requestedEncoding: .automatic)
        expect(bom.kind == .text && bom.text == "héllo" && bom.encoding == .utf8, "UTF-8 BOM is detected and removed")

        let utf16 = Data([0xFF, 0xFE, 0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F, 0x00])
        let utf16Content = FileContentDecoder.decode(utf16, path: "note.txt", requestedEncoding: .automatic)
        expect(utf16Content.text == "hello" && utf16Content.encoding == .utf16LittleEndian, "UTF-16 BOM is detected")

        let binary = FileContentDecoder.decode(Data([0x00, 0x01, 0x41]), path: "sample.bin", requestedEncoding: .automatic)
        expect(binary.kind == .binary && binary.text.contains("00000000"), "binary content uses a stable hex presentation")

        let png = FileContentDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), path: "image.png", requestedEncoding: .automatic)
        expect(png.kind == .image, "known image content remains image data")
    }

    private static func testSyntaxDetection() {
        expect(FileViewerSyntaxRegistry.mode(for: "Sources/App.swift")?.name == "Swift", "Swift extension detection")
        expect(FileViewerSyntaxRegistry.mode(for: ".editorconfig")?.name == "INI", "suffix-based detection")
        expect(FileViewerSyntaxRegistry.mode(for: "config.yaml")?.name == "YAML", "YAML detection")
        expect(FileViewerSyntaxRegistry.mode(for: "LICENSE") == nil, "unknown names use plain text")
    }

    private static func testDifftoolCommands() throws {
        let parent = testObjectID("parent")
        let object = testObjectID("object")
        let commit = makeCommit(object, parents: [parent])
        let renamed = ChangedFile(id: "new.swift", path: "new.swift", oldPath: "old.swift", changeType: .renamed, additions: 1, deletions: 1)
        let command = try FileViewerCommandBuilder.difftool(commit: commit, file: renamed)
        expect(
            command.arguments == ["difftool", "--no-prompt", parent.string, object.string, "--", "old.swift", "new.swift"],
            "revision difftool keeps revisions and rename paths separate and ordered"
        )
        expect(!command.accessesRemote && !command.changesRepositoryState, "difftool is a local read/presentation command")
        let custom = try FileViewerCommandBuilder.difftool(commit: commit, file: renamed, customToolPath: "/Applications/Diff Tool.app/Contents/MacOS/diff")
        expect(
            custom.arguments[2] == "--extcmd=/Applications/Diff Tool.app/Contents/MacOS/diff",
            "custom macOS difftool paths remain one argument"
        )

        let artificial = makeCommit(object, kind: .workingDirectory)
        let artificialCommand = try FileViewerCommandBuilder.difftool(commit: artificial, file: renamed)
        expect(
            artificialCommand.arguments
                == ["difftool", "--no-prompt", "--", "old.swift", "new.swift"],
            "working-directory rows do not masquerade as object IDs"
        )
    }

    private static func testInlinePresentation() {
        let lines = [
            DiffLine(id: "d", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "let old = 1"),
            DiffLine(id: "a", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "let new = 1")
        ]
        let presentation = DiffLinePresentation.build(from: lines)
        expect(presentation.count == 2 && presentation.allSatisfy { $0.inlineChange != nil }, "paired lines retain word-level changed ranges")
        expect(DiffGutterMetrics(lines: lines).numberColumnWidth >= 1, "gutter metrics cover both line-number columns")
    }

    private static func makeCommit(_ object: ObjectID, parents: [ObjectID] = [], kind: Commit.Kind = .revision) -> Commit {
        Commit(
            id: kind == .workingDirectory ? .workingDirectory : .object(object),
            shortID: object.shortString,
            subject: "Test",
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: parents,
            references: [],
            kind: kind
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}

@MainActor
enum FileViewerParityTests {
    static func run() async throws {
        testParsersAndNavigation()
        try testPreferences()
        try await testRepositoryCommands()
        testTextViewer()
        try await testCommitResetConfirmation()
        print("FileViewerParityTests: passed")
    }

    private static func check(_ value: Bool, _ message: String) { precondition(value, "FileViewerParityTests: " + message) }

    private static func item(_ type: FileChangeType = .modified) -> ChangedFile {
        ChangedFile(id: "a.txt", path: "a.txt", oldPath: nil, changeType: type, additions: 1, deletions: 1)
    }

    private static func testParsersAndNavigation() {
        let esc = "\u{1b}["
        let parsed = AnsiEscapeParser.parse("α😀\(esc)31;7mold\(esc)0m \(esc)38;2;12;34;56mnew\(esc)0m")
        check(parsed.text == "α😀old new", "ANSI text and Unicode preservation")
        check(parsed.styles.first?.location == 3 && parsed.styles.first?.length == 3 && parsed.styles.first?.background == .palette(1, dim: false), "UTF16 reverse style")
        check(parsed.styles.last?.foreground == .rgb(12, 34, 56), "RGB style")
        let word = GitDiffAppearance.parseWordDiff(Data("diff --git a/a.txt b/a.txt\n@@ -1,3 +1,3 @@\n\(esc)31;7mold\(esc)0m\n\(esc)32;7mnew\(esc)0m\nkeep \(esc)31;7mx\(esc)0m\(esc)32;7my\(esc)0m\nplain\n".utf8), file: item())
        check(word.appearance == .gitWordDiff && word.lines.map(\.kind) == [.header, .hunk, .deletion, .addition, .context, .context], "word diff classifications")
        check(word.lines[2].oldLineNumber == 1 && word.lines[3].newLineNumber == 1 && word.lines[4].isMixedChange && word.lines[5].newLineNumber == 3, "word diff gutters and mixed changes")
        let normal = GitDiffAppearance.parseWordDiff(Data("@@ -1 +1 @@\n\(esc)31mold\(esc)0m\n\(esc)32mnew\(esc)0m\n".utf8), file: item())
        check(normal.lines[1].kind == .deletion && normal.lines[2].kind == .addition, "non-reversed Git coloring")
        let configured = GitDiffAppearance.colorConfiguration(configured: ["color.diff.old"])
        check(!configured.contains(where: { $0.hasPrefix("color.diff.old=") }) && configured.contains("color.diff.new=green reverse"), "user Git colors are preserved")
        let notReversed = GitDiffAppearance.colorConfiguration(configured: [], reverse: false)
        check(!notReversed.contains(where: { $0.contains("reverse") || $0.hasPrefix("color.diff.oldmoved=") }), "reverse preference controls configuration defaults")
        let arguments = GitDiffAppearance.wordDiffCommand(["diff", "--patch", "--no-color", "--", "a.txt"], configured: [])
        check(arguments.suffix(6) == ["diff", "--word-diff=color", "--color=always", "--patch", "--", "a.txt"], "word arguments and path boundary")
        var options = FileDiffOptions(appearance: .difftastic)
        options.difftasticWidth = 120
        options.difftasticSyntaxHighlighting = false
        check(GitDiffAppearance.difftasticArguments(revisions: ["--cached", "HEAD"], paths: ["a.txt"], noIndex: false, options: options) == ["--no-pager", "difftool", "--find-renames", "--find-copies", "-y", "--tool=difftastic", "--cached", "HEAD", "--", "a.txt"], "Difftastic command ordering")
        check(GitDiffAppearance.difftasticEnvironment(options)["DFT_SYNTAX_HIGHLIGHT"] == "off" && GitDiffAppearance.difftasticEnvironment(options)["DFT_WIDTH"] == "120", "Difftastic environment")
        let dft = GitDiffAppearance.parseDifftastic(Data("a.txt --- Text\n1 \(esc)31mold\(esc)0m\n2 \(esc)32mnew\(esc)0m\n".utf8), file: item(), width: 120)
        check(dft.appearance == .difftastic && dft.lines.first?.kind == .header && dft.lines.allSatisfy { !$0.text.contains("\u{1b}") }, "Difftastic header and ANSI parsing")
        let numbered = GitDiffAppearance.parseDifftastic(Data("a.txt --- Text\n\(esc)31m1 old\(esc)0m\n\(esc)32m2 new\(esc)0m\n".utf8), file: item(), width: 120)
        check(numbered.lines[1].oldLineNumber == 1 && numbered.lines[1].newLineNumber == nil && numbered.lines[1].kind == .deletion
              && numbered.lines[2].oldLineNumber == nil && numbered.lines[2].newLineNumber == 2 && numbered.lines[2].kind == .addition, "Difftastic numbered single-column changes")
        let foregroundDft = GitDiffAppearance.parseDifftastic(Data("a.txt --- Text\n\(esc)31m1 old\(esc)0m\n".utf8), file: item(), width: 120, reverse: false)
        check(foregroundDft.lines[1].styles.first?.foreground == .palette(1, dim: false)
              && foregroundDft.lines[1].styles.first?.background == nil, "Difftastic respects reverse coloring setting")
        var occurrences = FileViewerOccurrences(term: "foo")
        let lines = ["😀 Foo foo", "food FOO"]
        check(occurrences.next(in: lines, forward: true) && occurrences.row == 0 && occurrences.column == 3, "first occurrence UTF16")
        check(occurrences.next(in: lines, forward: true) && occurrences.column == 7, "next occurrence on same line")
        check(occurrences.next(in: lines, forward: true) && occurrences.row == 1 && occurrences.column == 0, "next occurrence on next line")
        check(occurrences.next(in: lines, forward: true) && occurrences.column == 5, "case insensitive occurrences")
        check(!occurrences.next(in: lines, forward: true) && occurrences.column == 5, "occurrences do not wrap")
        check(occurrences.next(in: lines, forward: false) && occurrences.column == 0, "previous occurrence")
        check(FileViewerOccurrences.ranges(of: " ", in: " ").isEmpty, "whitespace selection ignored")
    }

    private static func testPreferences() throws {
        let old = try JSONDecoder().decode(FileViewerPreferences.self, from: Data("{}".utf8))
        let remember = try JSONDecoder().decode(FileViewerRememberPreferences.self, from: Data("{\"whitespace\":false}".utf8))
        check(old.diffAppearance == .patch && old.useGitColoring && old.reverseGitColoring && !remember.diffAppearance, "backward compatible preference defaults")
        let suite = "FileViewerParityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        var preferences = store.fileViewerPreferences
        preferences.diffAppearance = .gitWordDiff
        preferences.reverseGitColoring = false
        store.updateFileViewerPreferences(preferences)
        check(AppSettingsStore(defaults: defaults).fileViewerPreferences.diffAppearance == .patch, "runtime appearance not saved implicitly")
        check(!AppSettingsStore(defaults: defaults).fileViewerPreferences.reverseGitColoring, "Git coloring setting persists")
        store.saveCurrentViewSettingsAsDefault()
        check(AppSettingsStore(defaults: defaults).fileViewerPreferences.diffAppearance == .gitWordDiff, "explicit appearance default persists")
    }

    private static func testRepositoryCommands() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "one\ntwo\nthree\n")
        try fixture.commitAll("base")
        let head = try fixture.head()
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let work = FileStatusTests.artificial(.workingDirectory, head: head)
        let index = FileStatusTests.artificial(.index, head: head)
        try fixture.write("a.txt", "ONE\ntwo\nTHREE\n")
        let file = item()
        let diff = try await module.loadDiff(for: work, file: file)!
        let selected = Set(diff.lines.filter { ["one", "ONE"].contains($0.text) }.map(\.id))
        let reset = try await module.applyLinePatch(.resetWorkTree, file: file, diff: diff, lineIDs: selected)
        check(try reset.succeeded && fixture.read("a.txt") == "one\ntwo\nTHREE\n", "reset selected worktree lines: " + reset.output)
        check(try fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n", "worktree reset leaves index")
        _ = try await module.loadRepositoryState()
        let remaining = try await module.loadDiff(for: work, file: file)!
        let ids = Set(remaining.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        let staged = try await module.applyLinePatch(.stage, file: file, diff: remaining, lineIDs: ids)
        check(try staged.succeeded && fixture.git(["show", ":a.txt"]) == "one\ntwo\nTHREE\n", "stage lines: " + staged.output + staged.patch)
        _ = try await module.loadRepositoryState()
        let stagedDiff = try await module.loadDiff(for: index, file: file)!
        let stagedIDs = Set(stagedDiff.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        let unstaged = try await module.applyLinePatch(.unstage, file: file, diff: stagedDiff, lineIDs: stagedIDs)
        check(try unstaged.succeeded && fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n" && fixture.read("a.txt") == "one\ntwo\nTHREE\n", "unstage keeps worktree")
        try fixture.git(["add", "a.txt"])
        let resetIndex = try await module.applyLinePatch(.resetIndex, file: file, diff: stagedDiff, lineIDs: stagedIDs)
        check(try resetIndex.succeeded && fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n" && fixture.read("a.txt") == "one\ntwo\nthree\n", "index reset updates both index and worktree")
        try fixture.write("a.txt", "ONE\ntwo\nthree\n")
        _ = try await module.loadRepositoryState()
        let changed = try await module.loadDiff(for: work, file: file)!
        var appearance = FileDiffOptions(appearance: .gitWordDiff)
        let word = try await module.loadDiff(for: work, file: file, options: appearance)!
        check(word.appearance == .gitWordDiff && word.lines.contains { !$0.styles.isEmpty } && !word.lines.contains { $0.text.contains("\u{1b}") }, "real Git word diff")
        check(word.lines.contains { $0.text == "oneONE" }, "structured arguments do not include shell regex quoting")
        appearance.appearance = .patch
        appearance.useGitColoring = true
        let colored = try await module.loadDiff(for: work, file: file, options: appearance)!
        check(colored.lines.map(\.text) == changed.lines.map(\.text) && colored.lines.contains { !$0.styles.isEmpty }, "colored patch preserves line patch data")
        try fixture.commitAll("change")
        let changedHead = try fixture.head()
        let commit = FileStatusTests.commitModel(changedHead, parents: [head])
        let committed = try await module.loadDiff(for: commit, file: file)!
        let all = Set(committed.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        let reverted = try await module.applyLinePatch(.revertToWorkTree, file: file, diff: committed, lineIDs: all)
        check(try reverted.succeeded && fixture.read("a.txt") == "one\ntwo\nthree\n" && fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n", "committed selected line revert: " + reverted.output)
        let applied = try await module.applyLinePatch(.applyToWorkTree, file: file, diff: committed, lineIDs: all)
        check(try applied.succeeded && fixture.read("a.txt") == "ONE\ntwo\nthree\n", "committed selected line apply: " + applied.output)
        check(try fixture.head() == changedHead, "line operations do not move HEAD")
        try fixture.write("new.txt", "keep\nremove\n")
        _ = try await module.loadRepositoryState()
        var newFile = ChangedFile(id: "new.txt", path: "new.txt", oldPath: nil, changeType: .added, additions: 2, deletions: 0)
        newFile.isTracked = false
        let newDiff = try await module.loadDiff(for: work, file: newFile)!
        let newReset = try await module.applyLinePatch(.resetWorkTree, file: newFile, diff: newDiff, lineIDs: Set(newDiff.lines.filter { $0.text == "remove" }.map(\.id)))
        check(try newReset.succeeded && fixture.read("new.txt") == "keep\n", "partial new file reset: " + newReset.output)
        check(try fixture.git(["ls-files", "new.txt"]).isEmpty, "new file reset does not stage")
        try fixture.git(["config", "difftool.difftastic.cmd", "printf 'a.txt --- Text\\n1 old\\n2 new\\n'"])
        _ = try await module.loadRepositoryState()
        check(await module.isDifftasticEnabled(), "configured Difftastic eligible")
        let dft = try await module.loadDiff(for: commit, file: file, options: FileDiffOptions(appearance: .difftastic))!
        check(dft.appearance == .difftastic && dft.lines.first?.text == "a.txt --- Text", "configured Difftastic process and parser")
    }

    private static func testTextViewer() {
        _ = NSApplication.shared
        let text = FileViewerTextView()
        text.string = "foo FOO foo"
        text.setSelectedRange(NSRange(location: 0, length: 3))
        text.moveOccurrence(forward: true)
        check(text.selectedRange().location == 4, "text view next occurrence")
        text.moveOccurrence(forward: true)
        check(text.selectedRange().location == 8, "text view remembers term with empty caret")
        text.moveOccurrence(forward: true)
        check(text.selectedRange().location == 8, "text view does not wrap")
        text.moveOccurrence(forward: false)
        check(text.selectedRange().location == 4, "text view previous occurrence")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = text
        text.frame = scroll.bounds
        text.isEditable = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let replace = NSMenuItem(); replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        text.usesFindBar = true
        text.performTextFinderAction(replace)
        check(scroll.isFindBarVisible, "native Replace bar displayed in editable viewer")
        let controller = DiffContentViewController()
        controller.selectionScope = .workingTree
        controller.linePatchingSupported = { true }
        var calls = 0
        controller.onLinePatch = { kind, _, _, ids in
            check(kind == .stage && ids == ["a"], "shared line patch dispatch")
            calls += 1
        }
        _ = controller.view
        let file = item()
        let patch = FileDiff(id: file.id, fileID: file.id, lines: [DiffLine(id: "h", oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "@@ -0,0 +1 @@"), DiffLine(id: "a", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "foo")])
        controller.apply(file: file, diff: patch)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let coloredLines = [
            DiffLine(id: "old", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "let old = 1", styles: [DiffTextStyle(location: 0, length: 11, foreground: .palette(1, dim: false), background: nil)]),
            DiffLine(id: "new", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "let new = 1", styles: [DiffTextStyle(location: 0, length: 11, foreground: .palette(2, dim: false), background: nil)])
        ]
        let coloredCell = DiffLineCellView()
        coloredCell.apply(presentation: DiffLinePresentation.build(from: coloredLines)[1], gutterMetrics: DiffGutterMetrics(lines: coloredLines), showsNonPrintingCharacters: false, showsSyntaxHighlighting: false)
        let coloredText = descendants(coloredCell).compactMap { $0 as? NSTextField }.first { $0.stringValue == "let new = 1" }!.attributedStringValue
        check(coloredText.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil
              && coloredText.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil, "Git-colored patch preserves inline emphasis")
        let table = descendants(controller.view).compactMap { $0 as? FileViewerTableView }.first!
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        check(table.onShortcut?(.stageLines) == true && calls == 1, "shared viewer handles staging shortcut")
        check(table.onShortcut?(.stageLines) == false && calls == 1, "patch blocked until reload")
        controller.apply(file: file, diff: FileDiff(id: file.id, fileID: file.id, lines: patch.lines, appearance: .gitWordDiff))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        check(table.onShortcut?(.stageLines) == false, "word diff cannot be line patched")
    }

    private static func testCommitResetConfirmation() async throws {
        let preferences = AppSettingsStore.shared.commitPreferences
        var updated = preferences; updated.refreshOnFocus = true
        AppSettingsStore.shared.saveCommitPreferences(updated)
        defer { AppSettingsStore.shared.saveCommitPreferences(preferences) }
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "base\nkeep\n")
        try fixture.commitAll("base")
        try fixture.write("a.txt", "changed\nkeep\n")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let controller = CommitWorkflowDialog.present(source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                                                      onRepositoryChanged: { _ in }, onClose: {})
        let window = controller.window!
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            check(condition(), message)
        }
        let table = descendants(window.contentView!).compactMap { $0 as? FileViewerTableView }.first!
        try await wait("Commit diff loaded") { table.numberOfRows >= 7 }
        table.selectRowIndexes(IndexSet([5, 6]), byExtendingSelection: false)
        window.makeFirstResponder(table)
        check(table.onShortcut?(.resetLines) == true, "Commit reset shortcut")
        try await wait("Commit reset confirmation") { window.attachedSheet != nil }
        let no = descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "No" }!
        no.performClick(nil)
        try await wait("Commit reset cancelled") { window.attachedSheet == nil }
        check(try fixture.read("a.txt") == "changed\nkeep\n" && fixture.git(["show", ":a.txt"]) == "base\nkeep\n", "cancelled reset preserves worktree and index")
        check(table.onShortcut?(.resetLines) == true, "Commit reset can be retried after cancellation")
        try await wait("Commit reset confirmation retry") { window.attachedSheet != nil }
        window.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        let sheet = window.attachedSheet!
        let yes = descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Yes" }!
        yes.performClick(nil)
        try await wait("Commit reset completes despite focus refresh") { (try? fixture.read("a.txt")) == "base\nkeep\n" }
        check(try fixture.git(["show", ":a.txt"]) == "base\nkeep\n", "Commit worktree reset preserves index")
    }
}
