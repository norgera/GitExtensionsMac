import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @Suite("File viewer")
    enum FileViewerTests {

        @Test("Diff arguments") private static func testDiffArguments() {
            #expect(FileDiffOptions().gitArguments.isEmpty, "default diff options preserve the normal Git arguments")
            #expect(
                FileDiffOptions(whitespace: .changes, usesHistogram: true).gitArguments == ["--histogram", "--ignore-space-change"],
                "histogram precedes additional diff options")
            #expect(
                FileDiffOptions(whitespace: .endOfLine, contextLines: 5, treatsAllFilesAsText: true).gitArguments
                    == ["--ignore-space-at-eol", "--unified=5", "--text"],
                "diff options preserve intentional argument ordering"
            )
            #expect(
                FileDiffOptions(whitespace: .all, showsEntireFile: true).gitArguments
                    == ["--ignore-all-space", "--inter-hunk-context=9000", "--unified=9000"],
                "entire-file mode uses the upstream inter-hunk and unified arguments"
            )
        }

        @Test("Encoding and binary presentation") private static func testEncodingAndBinaryPresentation() {
            let bom = FileContentDecoder.decode(Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8)), path: "note.txt", requestedEncoding: .automatic)
            #expect(bom.kind == .text && bom.text == "héllo" && bom.encoding == .utf8, "UTF-8 BOM is detected and removed")

            let utf16 = Data([0xFF, 0xFE, 0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F, 0x00])
            let utf16Content = FileContentDecoder.decode(utf16, path: "note.txt", requestedEncoding: .automatic)
            #expect(utf16Content.text == "hello" && utf16Content.encoding == .utf16LittleEndian, "UTF-16 BOM is detected")

            let binary = FileContentDecoder.decode(Data([0x00, 0x01, 0x41]), path: "sample.bin", requestedEncoding: .automatic)
            #expect(binary.kind == .binary && binary.text.contains("0000   "), "binary content uses the upstream hex presentation")

            let png = FileContentDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), path: "image.png", requestedEncoding: .automatic)
            #expect(png.kind == .image, "known image content remains image data")
        }

        @Test("Syntax detection") private static func testSyntaxDetection() {
            #expect(FileViewerSyntaxRegistry.mode(for: "Sources/App.swift")?.name == "Swift", "Swift extension detection")
            #expect(FileViewerSyntaxRegistry.mode(for: ".editorconfig")?.name == "INI", "suffix-based detection")
            #expect(FileViewerSyntaxRegistry.mode(for: "config.yaml")?.name == "YAML", "YAML detection")
            #expect(FileViewerSyntaxRegistry.mode(for: "LICENSE") == nil, "unknown names use plain text")
        }

        @Test("Difftool commands") private static func testDifftoolCommands() throws {
            let parent = testObjectID("parent")
            let object = testObjectID("object")
            let commit = makeCommit(object, parents: [parent])
            let renamed = ChangedFile(id: "new.swift", path: "new.swift", oldPath: "old.swift", changeType: .renamed, additions: 1, deletions: 1)
            let command = try FileViewerCommandBuilder.difftool(commit: commit, file: renamed)
            #expect(
                command.arguments == ["difftool", "--no-prompt", parent.string, object.string, "--", "old.swift", "new.swift"],
                "revision difftool keeps revisions and rename paths separate and ordered"
            )
            #expect(!command.accessesRemote && !command.changesRepositoryState, "difftool is a local read/presentation command")
            let custom = try FileViewerCommandBuilder.difftool(commit: commit, file: renamed, customToolPath: "/Applications/Diff Tool.app/Contents/MacOS/diff")
            #expect(
                custom.arguments[2] == "--extcmd=/Applications/Diff Tool.app/Contents/MacOS/diff",
                "custom macOS difftool paths remain one argument"
            )

            let artificial = makeCommit(object, kind: .workingDirectory)
            let artificialCommand = try FileViewerCommandBuilder.difftool(commit: artificial, file: renamed)
            #expect(
                artificialCommand.arguments
                    == ["difftool", "--no-prompt", "--", "old.swift", "new.swift"],
                "working-directory rows do not masquerade as object IDs"
            )
        }

        @Test("Inline presentation") private static func testInlinePresentation() {
            let lines = [
                DiffLine(id: "d", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "let old = 1"),
                DiffLine(id: "a", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "let new = 1"),
            ]
            let presentation = DiffLinePresentation.build(from: lines)
            #expect(presentation.count == 2 && presentation.allSatisfy { $0.inlineChange != nil }, "paired lines retain word-level changed ranges")
            #expect(DiffGutterMetrics(lines: lines).numberColumnWidth >= 1, "gutter metrics cover both line-number columns")
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

    }
}

typealias FileViewerTests = UIIntegrationTests.FileViewerTests

extension UIIntegrationTests {
    @MainActor
    @Suite("File viewer parity")
    enum FileViewerParityTests {

        private static func item(_ type: FileChangeType = .modified) -> ChangedFile {
            ChangedFile(id: "a.txt", path: "a.txt", oldPath: nil, changeType: type, additions: 1, deletions: 1)
        }

        @Test("Parsers and navigation") private static func testParsersAndNavigation() {
            let esc = "\u{1b}["
            let parsed = AnsiEscapeParser.parse("α😀\(esc)31;7mold\(esc)0m \(esc)38;2;12;34;56mnew\(esc)0m")
            #expect(parsed.text == "α😀old new", "ANSI text and Unicode preservation")
            #expect(
                parsed.styles.first?.location == 3 && parsed.styles.first?.length == 3 && parsed.styles.first?.background == .palette(1, dim: false),
                "UTF16 reverse style")
            #expect(parsed.styles.last?.foreground == .rgb(12, 34, 56), "RGB style")
            let word = GitDiffAppearance.parseWordDiff(
                Data(
                    "diff --git a/a.txt b/a.txt\n@@ -1,3 +1,3 @@\n\(esc)31;7mold\(esc)0m\n\(esc)32;7mnew\(esc)0m\nkeep \(esc)31;7mx\(esc)0m\(esc)32;7my\(esc)0m\nplain\n"
                        .utf8), file: item())
            #expect(
                word.appearance == .gitWordDiff && word.lines.map(\.kind) == [.header, .hunk, .deletion, .addition, .context, .context],
                "word diff classifications")
            #expect(
                word.lines[2].oldLineNumber == 1 && word.lines[3].newLineNumber == 1 && word.lines[4].isMixedChange && word.lines[5].newLineNumber == 3,
                "word diff gutters and mixed changes")
            let normal = GitDiffAppearance.parseWordDiff(Data("@@ -1 +1 @@\n\(esc)31mold\(esc)0m\n\(esc)32mnew\(esc)0m\n".utf8), file: item())
            #expect(normal.lines[1].kind == .deletion && normal.lines[2].kind == .addition, "non-reversed Git coloring")
            let configured = GitDiffAppearance.colorConfiguration(configured: ["color.diff.old"])
            #expect(
                !configured.contains(where: { $0.hasPrefix("color.diff.old=") }) && configured.contains("color.diff.new=green reverse"),
                "user Git colors are preserved")
            let notReversed = GitDiffAppearance.colorConfiguration(configured: [], reverse: false)
            #expect(
                !notReversed.contains(where: { $0.contains("reverse") || $0.hasPrefix("color.diff.oldmoved=") }),
                "reverse preference controls configuration defaults")
            let arguments = GitDiffAppearance.wordDiffCommand(["diff", "--patch", "--no-color", "--", "a.txt"], configured: [])
            #expect(arguments.suffix(6) == ["diff", "--word-diff=color", "--color=always", "--patch", "--", "a.txt"], "word arguments and path boundary")
            var options = FileDiffOptions(appearance: .difftastic)
            options.difftasticWidth = 120
            options.difftasticSyntaxHighlighting = false
            #expect(
                GitDiffAppearance.difftasticArguments(revisions: ["--cached", "HEAD"], paths: ["a.txt"], noIndex: false, options: options) == [
                    "--no-pager", "difftool", "--find-renames", "--find-copies", "-y", "--tool=difftastic", "--cached", "HEAD", "--", "a.txt",
                ], "Difftastic command ordering")
            #expect(
                GitDiffAppearance.difftasticEnvironment(options)["DFT_SYNTAX_HIGHLIGHT"] == "off"
                    && GitDiffAppearance.difftasticEnvironment(options)["DFT_WIDTH"] == "120", "Difftastic environment")
            let dft = GitDiffAppearance.parseDifftastic(Data("a.txt --- Text\n1 \(esc)31mold\(esc)0m\n2 \(esc)32mnew\(esc)0m\n".utf8), file: item(), width: 120)
            #expect(
                dft.appearance == .difftastic && dft.lines.first?.kind == .header && dft.lines.allSatisfy { !$0.text.contains("\u{1b}") },
                "Difftastic header and ANSI parsing")
            let numbered = GitDiffAppearance.parseDifftastic(
                Data("a.txt --- Text\n\(esc)31m1 old\(esc)0m\n\(esc)32m2 new\(esc)0m\n".utf8), file: item(), width: 120)
            #expect(
                numbered.lines[1].oldLineNumber == 1 && numbered.lines[1].newLineNumber == nil && numbered.lines[1].kind == .deletion
                    && numbered.lines[2].oldLineNumber == nil && numbered.lines[2].newLineNumber == 2 && numbered.lines[2].kind == .addition,
                "Difftastic numbered single-column changes")
            let foregroundDft = GitDiffAppearance.parseDifftastic(
                Data("a.txt --- Text\n\(esc)31m1 old\(esc)0m\n".utf8), file: item(), width: 120, reverse: false)
            #expect(
                foregroundDft.lines[1].styles.first?.foreground == .palette(1, dim: false)
                    && foregroundDft.lines[1].styles.first?.background == nil, "Difftastic respects reverse coloring setting")
            var occurrences = FileViewerOccurrences(term: "foo")
            let lines = ["😀 Foo foo", "food FOO"]
            #expect(occurrences.next(in: lines, forward: true) && occurrences.row == 0 && occurrences.column == 3, "first occurrence UTF16")
            #expect(occurrences.next(in: lines, forward: true) && occurrences.column == 7, "next occurrence on same line")
            #expect(occurrences.next(in: lines, forward: true) && occurrences.row == 1 && occurrences.column == 0, "next occurrence on next line")
            #expect(occurrences.next(in: lines, forward: true) && occurrences.column == 5, "case insensitive occurrences")
            #expect(!occurrences.next(in: lines, forward: true) && occurrences.column == 5, "occurrences do not wrap")
            #expect(occurrences.next(in: lines, forward: false) && occurrences.column == 0, "previous occurrence")
            #expect(FileViewerOccurrences.ranges(of: " ", in: " ").isEmpty, "whitespace selection ignored")
        }

        @Test("Preferences") private static func testPreferences() throws {
            let old = try JSONDecoder().decode(FileViewerPreferences.self, from: Data("{}".utf8))
            let remember = try JSONDecoder().decode(FileViewerRememberPreferences.self, from: Data("{\"whitespace\":false}".utf8))
            #expect(
                old.diffAppearance == .patch && old.useGitColoring && old.reverseGitColoring && !remember.diffAppearance,
                "backward compatible preference defaults")
            let suite = "FileViewerParityTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            var preferences = store.fileViewerPreferences
            preferences.diffAppearance = .gitWordDiff
            preferences.reverseGitColoring = false
            store.updateFileViewerPreferences(preferences)
            #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences.diffAppearance == .patch, "runtime appearance not saved implicitly")
            #expect(!AppSettingsStore(defaults: defaults).fileViewerPreferences.reverseGitColoring, "Git coloring setting persists")
            store.saveCurrentViewSettingsAsDefault()
            #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences.diffAppearance == .gitWordDiff, "explicit appearance default persists")
        }

        @Test("Repository commands") private static func testRepositoryCommands() async throws {
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
            #expect(try reset.succeeded && fixture.read("a.txt") == "one\ntwo\nTHREE\n", Comment(rawValue: "reset selected worktree lines: " + reset.output))
            #expect(try fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n", "worktree reset leaves index")
            _ = try await module.loadRepositoryState()
            let remaining = try await module.loadDiff(for: work, file: file)!
            let ids = Set(remaining.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
            let staged = try await module.applyLinePatch(.stage, file: file, diff: remaining, lineIDs: ids)
            #expect(
                try staged.succeeded && fixture.git(["show", ":a.txt"]) == "one\ntwo\nTHREE\n",
                Comment(rawValue: "stage lines: " + staged.output + staged.patch))
            _ = try await module.loadRepositoryState()
            let stagedDiff = try await module.loadDiff(for: index, file: file)!
            let stagedIDs = Set(stagedDiff.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
            let unstaged = try await module.applyLinePatch(.unstage, file: file, diff: stagedDiff, lineIDs: stagedIDs)
            #expect(
                try unstaged.succeeded && fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n" && fixture.read("a.txt") == "one\ntwo\nTHREE\n",
                "unstage keeps worktree")
            try fixture.git(["add", "a.txt"])
            let resetIndex = try await module.applyLinePatch(.resetIndex, file: file, diff: stagedDiff, lineIDs: stagedIDs)
            #expect(
                try resetIndex.succeeded && fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n" && fixture.read("a.txt") == "one\ntwo\nthree\n",
                "index reset updates both index and worktree")
            try fixture.write("a.txt", "ONE\ntwo\nthree\n")
            _ = try await module.loadRepositoryState()
            let changed = try await module.loadDiff(for: work, file: file)!
            var appearance = FileDiffOptions(appearance: .gitWordDiff)
            let word = try await module.loadDiff(for: work, file: file, options: appearance)!
            #expect(
                word.appearance == .gitWordDiff && word.lines.contains { !$0.styles.isEmpty } && !word.lines.contains { $0.text.contains("\u{1b}") },
                "real Git word diff")
            #expect(word.lines.contains { $0.text == "oneONE" }, "structured arguments do not include shell regex quoting")
            appearance.appearance = .patch
            appearance.useGitColoring = true
            let colored = try await module.loadDiff(for: work, file: file, options: appearance)!
            #expect(
                colored.lines.map(\.text) == changed.lines.map(\.text) && colored.lines.contains { !$0.styles.isEmpty },
                "colored patch preserves line patch data")
            try fixture.commitAll("change")
            let changedHead = try fixture.head()
            let commit = FileStatusTests.commitModel(changedHead, parents: [head])
            let committed = try await module.loadDiff(for: commit, file: file)!
            let all = Set(committed.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
            let reverted = try await module.applyLinePatch(.revertToWorkTree, file: file, diff: committed, lineIDs: all)
            #expect(
                try reverted.succeeded && fixture.read("a.txt") == "one\ntwo\nthree\n" && fixture.git(["show", ":a.txt"]) == "one\ntwo\nthree\n",
                Comment(rawValue: "committed selected line revert: " + reverted.output))
            let applied = try await module.applyLinePatch(.applyToWorkTree, file: file, diff: committed, lineIDs: all)
            #expect(
                try applied.succeeded && fixture.read("a.txt") == "ONE\ntwo\nthree\n", Comment(rawValue: "committed selected line apply: " + applied.output))
            #expect(try fixture.head() == changedHead, "line operations do not move HEAD")
            try fixture.write("new.txt", "keep\nremove\n")
            _ = try await module.loadRepositoryState()
            var newFile = ChangedFile(id: "new.txt", path: "new.txt", oldPath: nil, changeType: .added, additions: 2, deletions: 0)
            newFile.isTracked = false
            let newDiff = try await module.loadDiff(for: work, file: newFile)!
            let newReset = try await module.applyLinePatch(
                .resetWorkTree, file: newFile, diff: newDiff, lineIDs: Set(newDiff.lines.filter { $0.text == "remove" }.map(\.id)))
            #expect(try newReset.succeeded && fixture.read("new.txt") == "keep\n", Comment(rawValue: "partial new file reset: " + newReset.output))
            #expect(try fixture.git(["ls-files", "new.txt"]).isEmpty, "new file reset does not stage")
            try fixture.git(["config", "difftool.difftastic.cmd", "printf 'a.txt --- Text\\n1 old\\n2 new\\n'"])
            _ = try await module.loadRepositoryState()
            #expect(await module.isDifftasticEnabled(), "configured Difftastic eligible")
            let dft = try await module.loadDiff(for: commit, file: file, options: FileDiffOptions(appearance: .difftastic))!
            #expect(dft.appearance == .difftastic && dft.lines.first?.text == "a.txt --- Text", "configured Difftastic process and parser")
        }

        @Test("Text viewer") private static func testTextViewer() {
            let text = FileViewerTextView()
            text.string = "foo FOO foo"
            text.setSelectedRange(NSRange(location: 0, length: 3))
            text.moveOccurrence(forward: true)
            #expect(text.selectedRange().location == 4, "text view next occurrence")
            text.moveOccurrence(forward: true)
            #expect(text.selectedRange().location == 8, "text view remembers term with empty caret")
            text.moveOccurrence(forward: true)
            #expect(text.selectedRange().location == 8, "text view does not wrap")
            text.moveOccurrence(forward: false)
            #expect(text.selectedRange().location == 4, "text view previous occurrence")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            scroll.documentView = text
            text.frame = scroll.bounds
            text.isEditable = true
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            let replace = NSMenuItem()
            replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            text.usesFindBar = true
            text.performTextFinderAction(replace)
            #expect(scroll.isFindBarVisible, "native Replace bar displayed in editable viewer")
            let controller = DiffContentViewController()
            controller.selectionScope = .workingTree
            controller.linePatchingSupported = { true }
            var calls = 0
            controller.onLinePatch = { kind, _, _, ids in
                #expect(kind == .stage && ids == ["a"], "shared line patch dispatch")
                calls += 1
            }
            _ = controller.view
            let file = item()
            let patch = FileDiff(
                id: file.id, fileID: file.id,
                lines: [
                    DiffLine(id: "h", oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "@@ -0,0 +1 @@"),
                    DiffLine(id: "a", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "foo"),
                ])
            controller.apply(file: file, diff: patch)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let coloredLines = [
                DiffLine(
                    id: "old", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "let old = 1",
                    styles: [DiffTextStyle(location: 0, length: 11, foreground: .palette(1, dim: false), background: nil)]),
                DiffLine(
                    id: "new", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "let new = 1",
                    styles: [DiffTextStyle(location: 0, length: 11, foreground: .palette(2, dim: false), background: nil)]),
            ]
            let coloredCell = DiffLineCellView()
            coloredCell.apply(
                presentation: DiffLinePresentation.build(from: coloredLines)[1], gutterMetrics: DiffGutterMetrics(lines: coloredLines),
                showsNonPrintingCharacters: false, showsSyntaxHighlighting: false)
            let coloredText = descendants(coloredCell).compactMap { $0 as? NSTextField }.first { $0.stringValue == "let new = 1" }!.attributedStringValue
            #expect(
                coloredText.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil
                    && coloredText.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil,
                "Git-colored patch dims common spans without overriding changed styles")
            let table = descendants(controller.view).compactMap { $0 as? FileViewerTableView }.first!
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            #expect(table.onShortcut?(.stageLines) == true && calls == 1, "shared viewer handles staging shortcut")
            #expect(table.onShortcut?(.stageLines) == false && calls == 1, "patch blocked until reload")
            controller.apply(file: file, diff: FileDiff(id: file.id, fileID: file.id, lines: patch.lines, appearance: .gitWordDiff))
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            #expect(table.onShortcut?(.stageLines) == false, "word diff cannot be line patched")
        }

        @Test("Text chrome") private static func testTextChrome() {
            let fixtures: [(String, [Int])] = [("", [0]), ("one", [0]), ("one\n", [0, 4]), ("one\r\ntwo\r", [0, 5, 9]), ("α😀\nβ", [0, 4])]
            for (text, expected) in fixtures {
                #expect(FileViewerTextLines.starts(in: text) == expected, "logical line offsets preserve Unicode, CRLF and trailing empty line")
            }
            let editor = EditableFileTextView()
            editor.text = "one\r\ntwo\r\n"
            let scroll = editor.textView.enclosingScrollView!
            let ruler = scroll.verticalRulerView as! FileViewerLineNumberRuler
            #expect(scroll.rulersVisible && ruler.lineStarts == [0, 5, 10], "editable file uses shared line gutter")
            let original = Data(editor.text.utf8)
            editor.textView.setSelectedRange(NSRange(location: 5, length: 3))
            ruler.refresh()
            #expect(
                Data(editor.text.utf8) == original && editor.textView.selectedRange() == NSRange(location: 5, length: 3),
                "gutter refresh does not change text bytes or selection")
            editor.replaceAll(with: "three\n")
            #expect(ruler.lineStarts == [0, 6], "gutter tracks edits")
            let input = FileViewerLineNumberInput(maximum: 3)
            #expect(
                input.value == 1 && input.stepper.minValue == 1 && input.stepper.maxValue == 3 && !input.stepper.valueWraps,
                "Go to line defaults to bounded numeric one")
            input.field.integerValue = 99
            input.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            #expect(input.value == 3 && input.stepper.integerValue == 3, "Go to line clamps above maximum")
            input.field.integerValue = 0
            #expect(input.value == 1, "Go to line clamps below minimum")
            var navigationCalls = 0
            let textView = FileViewerTextView()
            textView.onGoToLine = { navigationCalls += 1 }
            let chord = ApplicationHotkeys.shared.chord(for: "viewer.goToLine")!
            let key = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: chord.modifiers), timestamp: 0, windowNumber: 0, context: nil,
                characters: chord.key, charactersIgnoringModifiers: chord.key, isARepeat: false, keyCode: 5)!
            #expect(textView.performKeyEquivalent(with: key) && navigationCalls == 1, "Go to line dispatches through the existing configured keyboard command")
            let lines = [
                DiffLine(id: "h", oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "@@"),
                DiffLine(id: "a", oldLineNumber: 10, newLineNumber: 10, kind: .context, text: "a"),
                DiffLine(id: "b", oldLineNumber: 20, newLineNumber: 20, kind: .context, text: "b"),
            ]
            #expect(
                FileViewerNavigationDialogs.row(for: 1, in: lines) == 1 && FileViewerNavigationDialogs.row(for: 11, in: lines) == 2
                    && FileViewerNavigationDialogs.row(for: 21, in: lines) == 0,
                "diff navigation uses upstream first right-side line at or after requested number and zero fallback")
            let deleted = [DiffLine(id: "old", oldLineNumber: 30, newLineNumber: nil, kind: .deletion, text: "old")]
            #expect(
                FileViewerNavigationDialogs.maximumLine(in: deleted) == 30 && FileViewerNavigationDialogs.row(for: 30, in: deleted) == 0,
                "diff range includes left-side maximum while caret prefers right-side mapping")
            let viewer = RevisionFileContentViewController()
            _ = viewer.view
            viewer.apply(content: RepositoryFileContent(path: "note.txt", kind: .text, text: "one\ntwo\n"), revisionLabel: "HEAD")
            let menu = viewer.textView.menu!
            viewer.menuNeedsUpdate(menu)
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)!
            #expect(viewer.textView.menu(for: event) === menu, "read-only text returns its owned FileViewer menu rather than native Share")
            #expect(
                menu.items.map(\.title) == ["Copy", "", "Show nonprinting characters", "Find…", "Find next", "Find previous", "Go to line…"],
                "text mode source menu capabilities and order")
            #expect(!menu.items[0].isEnabled && menu.items.last!.isEnabled, "Copy disabled without selection and Go enabled for loaded text")
            viewer.textView.setSelectedRange(NSRange(location: 0, length: 3))
            viewer.menuNeedsUpdate(menu)
            #expect(menu.items[0].isEnabled, "Copy follows actual selection")
            let viewerRuler = viewer.textView.enclosingScrollView!.verticalRulerView as! FileViewerLineNumberRuler
            #expect(viewerRuler.lineStarts == [0, 4, 8], "read-only text uses shared gutter and trailing empty line")
            let originalPreferences = AppSettingsStore.shared.fileViewerPreferences
            var visiblePreferences = originalPreferences
            visiblePreferences.showsNonPrintingCharacters = false
            AppSettingsStore.shared.updateFileViewerPreferences(visiblePreferences)
            viewer.apply(content: RepositoryFileContent(path: "note.txt", kind: .text, text: "one\ntwo\n"), revisionLabel: "HEAD")
            viewer.menuNeedsUpdate(menu)
            let nonPrinting = menu.items.first { $0.title == "Show nonprinting characters" }!
            NSApp.sendAction(nonPrinting.action!, to: nonPrinting.target, from: nonPrinting)
            #expect(
                viewer.textView.string == "one\ntwo\n" && viewer.textView.layoutManager?.showsInvisibleCharacters == true,
                "read-only nonprinting characters use layout glyphs without changing searchable/copy source")
            #expect(
                FileViewerCopy.payload(
                    .selection, text: viewer.textView.string, selection: NSRange(location: 0, length: 4), isDiff: false, normalizeLineEndings: false)
                    == "one\n", "nonprinting glyphs do not leak into copy payload")
            AppSettingsStore.shared.updateFileViewerPreferences(originalPreferences)
            viewer.apply(content: RepositoryFileContent(path: "image.png", kind: .image, data: Data()), revisionLabel: "HEAD")
            viewer.menuNeedsUpdate(menu)
            #expect(!menu.items.last!.isEnabled, "Go to line unavailable for image content")
        }

        @Test("Fixed patch toolbar") private static func testFixedPatchToolbar() {
            let viewer = DiffContentViewController()
            viewer.showsLocalToolbar = true
            viewer.toolbarMode = .fixedDiff
            _ = viewer.view
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let toolbar = descendants(viewer.view).compactMap { $0 as? DiffViewerToolbar }.first!
            #expect(!toolbar.isHidden, "fixed patch consumer keeps the shared local toolbar visible")
            let buttons = descendants(toolbar).compactMap { $0 as? NSButton }.filter { !$0.isHidden }.compactMap(\.toolTip)
            #expect(
                buttons == ["Next change", "Previous change", "Show nonprinting characters", "Show syntax highlighting", "Encoding", "Settings"],
                "fixed diff toolbar source mode gates hide unsupported context and whitespace actions: \(buttons)")
            viewer.toolbarMode = .text
            let textButtons = descendants(toolbar).compactMap { $0 as? NSButton }.filter { !$0.isHidden }.compactMap(\.toolTip)
            #expect(
                textButtons == ["Show nonprinting characters", "Encoding", "Settings"], "ordinary text toolbar hides partial diff controls: \(textButtons)")
            viewer.toolbarMode = .fixedDiff
            let restored = descendants(toolbar).compactMap { $0 as? NSButton }.filter { !$0.isHidden }.compactMap(\.toolTip)
            #expect(restored == buttons, "reused toolbar restores mode-specific controls")
        }

        @Test("Standalone editor toolbar") private static func testStandaloneEditorToolbar() async throws {
            let originalPreferences = AppSettingsStore.shared.fileViewerPreferences
            defer { AppSettingsStore.shared.updateFileViewerPreferences(originalPreferences) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileViewer-editor-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("README.md")
            let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# café\r\n\r\ntext\r\n".utf8)
            try bytes.write(to: url)
            let controller = FileEditorWindowController(
                fileURL: url, source: StandaloneFileEditingDataSource(), showWarning: false, displayName: "README.md", onClose: {})
            defer { controller.close() }
            try await controller.load()
            #expect(
                controller.window?.title == "README.md" && !controller.hasChanges, "standalone editor preserves source argument title and initial clean state")
            let editor = controller.editor
            let toolbar = editor.viewerToolbar!
            #expect(
                !toolbar.isHidden && FileViewerSyntaxRegistry.mode(for: editor.syntaxPath!)?.name == "Markdown",
                "standalone editor reuses syntax and text toolbar")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(toolbar).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            #expect(buttons.compactMap(\.toolTip) == ["Show nonprinting characters", "Encoding", "Settings"], "editor text-mode source toolbar controls")
            let popup = buttons.compactMap { $0 as? NSPopUpButton }.first!
            #expect(popup.title == RepositoryTextEncoding.utf8.title, "editor displays detected BOM encoding")
            let text = editor.text
            let nonPrinting = buttons.first { $0.toolTip == "Show nonprinting characters" }!
            nonPrinting.state = .on
            NSApp.sendAction(nonPrinting.action!, to: nonPrinting.target, from: nonPrinting)
            #expect(
                editor.textView.layoutManager?.showsInvisibleCharacters == true && editor.text == text && !controller.hasChanges,
                "nonprinting uses layout presentation without editing source")
            popup.selectItem(at: popup.itemArray.firstIndex { $0.representedObject as? String == RepositoryTextEncoding.windows1252.rawValue }!)
            NSApp.sendAction(popup.action!, to: popup.target, from: popup)
            #expect(
                editor.viewerPreferences.textEncoding == .windows1252 && editor.text == text && !controller.hasChanges,
                "encoding selection updates viewer state without changing loaded source")
            try controller.saveChanges()
            #expect(try Data(contentsOf: url) == bytes, "display controls preserve original BOM, line endings and save encoding")
        }

        @Test("Patch context menu") private static func testPatchContextMenu() {
            let store = AppSettingsStore.shared
            let original = store.preferences
            let defaults = store.fileViewerDefaults
            let runtime = store.fileViewerPreferences
            defer {
                store.save(original)
                store.saveFileViewerPreferences(defaults)
                store.updateFileViewerPreferences(runtime)
            }
            store.saveFileViewerPreferences(FileViewerPreferences())
            let file = item()
            let diff = FileDiff(
                id: file.id, fileID: file.id,
                lines: [
                    DiffLine(id: "h", oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "@@ -1 +1 @@"),
                    DiffLine(id: "old", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "old"),
                    DiffLine(id: "new", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "new"),
                ])
            let controller = DiffContentViewController()
            controller.supportsDiffAppearance = true
            controller.onScrollBoundary = { _ in }
            _ = controller.view
            controller.apply(file: file, diff: diff)
            func descendantsForEncoding(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantsForEncoding) }
            let encoding = descendantsForEncoding(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.toolTip == "Encoding" }!
            #expect(
                encoding.title == RepositoryTextEncoding.utf8.title
                    && encoding.selectedItem?.representedObject as? String == RepositoryTextEncoding.automatic.rawValue,
                "resolved UTF8 encoding presented while repository-aware automatic decoding remains selected")
            let western = FileDiff(id: file.id, fileID: file.id, lines: diff.lines, contentEncoding: .isoLatin1)
            controller.apply(file: file, diff: western)
            #expect(
                encoding.title == RepositoryTextEncoding.westernISO88591.title,
                "encoding presentation follows repository-resolved content instead of always assuming UTF8")
            controller.apply(file: file, diff: diff)
            let menu = NSMenu()
            controller.menuNeedsUpdate(menu)
            menu.update()
            #expect(
                !menu.autoenablesItems && menu.items.first { $0.title == "Find next" }?.isEnabled == false,
                "native menu validation preserves search eligibility")
            for (title, id) in [
                ("Find…", "viewer.find"), ("Find next", "viewer.findNext"), ("Find previous", "viewer.findPrevious"), ("Go to line…", "viewer.goToLine"),
            ] {
                let item = menu.items.first { $0.title == title }!
                let chord = ApplicationHotkeys.shared.chord(for: id)!
                #expect(
                    item.keyEquivalent == chord.key && item.keyEquivalentModifierMask.rawValue == chord.modifiers,
                    "context exposes configured search/navigation cue")
            }
            let appearance = menu.items.first { $0.title == "Diff appearance" }!.submenu!
            for (index, id) in [(1, "viewer.wordDiff"), (2, "viewer.difftastic")] {
                let item = appearance.items[index]
                let chord = ApplicationHotkeys.shared.chord(for: id)!
                #expect(item.keyEquivalent == chord.key && item.keyEquivalentModifierMask.rawValue == chord.modifiers, "appearance exposes configured cue")
                if #available(macOS 27.0, *) { #expect(item.preferredImageVisibility == .visible, "native appearance icon visible") }
            }
            #expect(
                menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
                    "Copy", "Copy patch", "Copy new version", "Copy old version", "|",
                    "Increase the number of lines of context", "Decrease the number of lines of context", "Show entire file",
                    "Show nonprinting characters", "Show syntax highlighting", "Ignore whitespace changes at end of line",
                    "Ignore changes in amount of whitespace", "Ignore all whitespace changes", "Diff appearance", "|",
                    "Treat all files as text", "Enable automatic continuous scroll (without Option key)",
                    "Find…", "Find next", "Find previous", "Go to line…",
                ], "source patch menu hierarchy and copy ordering, retaining first-class native search commands")
            func click(_ id: String) {
                controller.menuNeedsUpdate(menu)
                let entry = menu.items.first { $0.identifier?.rawValue == "viewer.display." + id }!
                #expect(NSApp.sendAction(entry.action!, to: entry.target, from: entry), Comment(rawValue: "display action dispatch " + id))
            }
            var changed: [FileDiffOptions] = []
            controller.onOptionsChanged = { changed.append($0) }
            let before = controller.diffOptions.contextLines
            click("increaseContext")
            #expect(
                controller.diffOptions.contextLines == before + 1 && changed.last == controller.diffOptions,
                "context action requests original repository diff loader")
            click("decreaseContext")
            #expect(controller.diffOptions.contextLines == before, "context decrease")
            click("entireFile")
            #expect(controller.diffOptions.showsEntireFile, "entire-file action")
            let count = changed.count
            click("nonPrinting")
            #expect(
                changed.count == count && store.fileViewerPreferences.showsNonPrintingCharacters,
                "nonprinting renders existing content without a repository reload")
            click("syntax")
            #expect(!store.fileViewerPreferences.showsSyntaxHighlighting, "syntax context action shares presentation preference")
            click("treatAsText")
            #expect(controller.diffOptions.treatsAllFilesAsText, "treat-as-text reaches repository options")
            let continuous = store.preferences.automaticContinuousScroll
            click("continuousScroll")
            #expect(store.preferences.automaticContinuousScroll != continuous, "continuous scrolling updates existing native consumer preference")
            let vectors: [(DiffWhitespaceMode, DiffWhitespaceMode, String, [Bool])] = [
                (.none, .endOfLine, "whitespaceEOL", [true, false, false]),
                (.none, .changes, "whitespaceChanges", [true, true, false]),
                (.none, .all, "whitespaceAll", [true, true, true]),
                (.endOfLine, .changes, "whitespaceChanges", [true, true, false]),
                (.endOfLine, .all, "whitespaceAll", [true, true, true]),
                (.changes, .endOfLine, "whitespaceEOL", [true, false, false]),
                (.changes, .all, "whitespaceAll", [true, true, true]),
                (.all, .endOfLine, "whitespaceEOL", [true, false, false]),
                (.all, .changes, "whitespaceChanges", [true, true, false]),
            ]
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            for (old, new, id, checks) in vectors {
                var preferences = store.fileViewerPreferences
                preferences.whitespace = old
                store.updateFileViewerPreferences(preferences)
                click(id)
                #expect(controller.diffOptions.whitespace == new, "upstream one-click whitespace vector \(old) to \(new)")
                controller.menuNeedsUpdate(menu)
                for (index, key) in ["whitespaceEOL", "whitespaceChanges", "whitespaceAll"].enumerated() {
                    #expect(
                        (menu.items.first { $0.identifier?.rawValue == "viewer.display." + key }!.state == .on) == checks[index],
                        "cumulative menu whitespace check")
                }
                let titles = ["Ignore whitespace changes at end of line", "Ignore changes in amount of whitespace", "Ignore all whitespace changes"]
                let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
                for (index, title) in titles.enumerated() {
                    #expect((buttons.first { $0.toolTip == title }!.state == .on) == checks[index], "cumulative toolbar whitespace check")
                }
                click(id)
                #expect(controller.diffOptions.whitespace == .none, "upstream two-click whitespace vector resets to none")
                controller.menuNeedsUpdate(menu)
                #expect(
                    menu.items.filter { $0.identifier?.rawValue.hasPrefix("viewer.display.whitespace") == true }.allSatisfy { $0.state == .off },
                    "two-click resets all cumulative menu checks")
            }
            controller.onScrollBoundary = nil
            controller.menuNeedsUpdate(menu)
            #expect(
                !menu.items.contains { $0.identifier?.rawValue == "viewer.display.continuousScroll" }, "continuous scrolling only with a navigation consumer")
            controller.supportsDiffAppearance = false
            controller.menuNeedsUpdate(menu)
            #expect(
                !menu.items.contains {
                    $0.title == "Diff appearance" || $0.identifier?.rawValue == "viewer.display.entireFile"
                        || $0.identifier?.rawValue == "viewer.display.syntax" || $0.identifier?.rawValue.hasPrefix("viewer.display.whitespace") == true
                }, "fixed diff excludes reload-dependent display actions")
            #expect(
                menu.items.contains { $0.identifier?.rawValue == "viewer.display.nonPrinting" }
                    && menu.items.contains { $0.identifier?.rawValue == "viewer.display.treatAsText" },
                "fixed diff preserves applicable upstream display actions")
            controller.supportsDiffAppearance = true
            controller.apply(file: file, diff: FileDiff(id: file.id, fileID: file.id, lines: diff.lines, appearance: .difftastic))
            controller.menuNeedsUpdate(menu)
            #expect(
                menu.items.contains { $0.identifier?.rawValue == "viewer.display.whitespaceEOL" }
                    && !menu.items.contains {
                        $0.identifier?.rawValue == "viewer.display.whitespaceChanges" || $0.identifier?.rawValue == "viewer.display.whitespaceAll"
                            || $0.title == "Copy patch"
                    }, "Difftastic source whitespace and copy gates")
            controller.selectionScope = .workingTree
            controller.linePatchingSupported = { true }
            controller.onLinePatch = { _, _, _, _ in }
            controller.apply(file: file, diff: diff)
            controller.menuNeedsUpdate(menu)
            #expect(
                menu.items.prefix(3).map(\.title) == ["Stage selected line(s)", "Reset selected line(s)", "Copy"],
                "line-patching controls retain source ordering")
            controller.selectionScope = .index
            controller.menuNeedsUpdate(menu)
            #expect(menu.items.first?.title == "Unstage selected line(s)", "index retains unstage action")
        }

        @Test("Commit reset confirmation") private static func testCommitResetConfirmation() async throws {
            let preferences = AppSettingsStore.shared.commitPreferences
            let viewerDefaults = AppSettingsStore.shared.fileViewerDefaults
            let viewerPreferences = AppSettingsStore.shared.fileViewerPreferences
            var patchPreferences = FileViewerPreferences()
            patchPreferences.useGitColoring = false
            AppSettingsStore.shared.saveFileViewerPreferences(patchPreferences)
            var updated = preferences
            updated.refreshOnFocus = true
            AppSettingsStore.shared.saveCommitPreferences(updated)
            defer {
                AppSettingsStore.shared.saveCommitPreferences(preferences)
                AppSettingsStore.shared.saveFileViewerPreferences(viewerDefaults)
                AppSettingsStore.shared.updateFileViewerPreferences(viewerPreferences)
            }
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
            let controller = CommitWorkflowDialog.present(
                source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                onRepositoryChanged: { _ in }, onClose: {})
            let window = controller.window!
            defer { window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func wait(_ message: String, _ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                #expect(condition(), Comment(rawValue: message))
            }
            let table = descendants(window.contentView!).compactMap { $0 as? FileViewerTableView }.first!
            try await wait("Commit diff loaded") { table.numberOfRows >= 7 }
            window.makeFirstResponder(table)
            let changedRows = IndexSet(
                (0..<table.numberOfRows).filter { row in
                    guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return false }
                    return descendants(cell).compactMap { $0 as? NSTextField }.contains { ["+", "-", "−"].contains($0.stringValue) }
                })
            #expect(!changedRows.isEmpty, "Commit reset has actual changed rows")
            table.selectRowIndexes(changedRows, byExtendingSelection: false)
            #expect(table.onShortcut?(.resetLines) == true, "Commit reset shortcut")
            try await wait("Commit reset confirmation") { window.attachedSheet != nil }
            let no = descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "No" }!
            no.performClick(nil)
            try await wait("Commit reset cancelled") { window.attachedSheet == nil }
            #expect(
                try fixture.read("a.txt") == "changed\nkeep\n" && fixture.git(["show", ":a.txt"]) == "base\nkeep\n",
                "cancelled reset preserves worktree and index")
            #expect(table.onShortcut?(.resetLines) == true, "Commit reset can be retried after cancellation")
            try await wait("Commit reset confirmation retry") { window.attachedSheet != nil }
            window.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            let sheet = window.attachedSheet!
            let yes = descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Yes" }!
            yes.performClick(nil)
            try await wait("Commit reset completes despite focus refresh") { (try? fixture.read("a.txt")) == "base\nkeep\n" }
            #expect(try fixture.git(["show", ":a.txt"]) == "base\nkeep\n", "Commit worktree reset preserves index")
        }
    }
}

typealias FileViewerParityTests = UIIntegrationTests.FileViewerParityTests
