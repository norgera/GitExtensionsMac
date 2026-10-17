import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("File preview and search")
    enum FilePreviewAndSearchTests {

        static func file(_ path: String, old: String? = nil, type: FileChangeType = .modified) -> ChangedFile {
            ChangedFile(id: path, path: path, oldPath: old, changeType: type, additions: 0, deletions: 0)
        }

        @Test("Paths") static func paths() {
            let root = URL(fileURLWithPath: "/fixture/repository", isDirectory: true)
            let files = [
                file("one.txt"), file("nested/a b.txt"), file("日本/é.txt"), file("new name", old: "old name", type: .renamed),
                file("copy/new", old: "copy/original", type: .copied), file("one.txt"),
            ]
            let relative = "one.txt\nnested/a b.txt\n日本/é.txt\nnew name\ncopy/new"
            for kind in [FileStatusCopyPathKind.relativeNative, .relativePOSIX] {
                #expect(
                    FileStatusCopyPathKind.payload(files: files, repositoryURL: root, kind: kind) == relative, "relative path order, distinct and new names")
                #expect(FileStatusCopyPathKind.payload(files: [files[0]], repositoryURL: root, kind: kind) == "one.txt", "one relative")
                #expect(FileStatusCopyPathKind.payload(files: files, folder: "", repositoryURL: root, kind: kind) == ".", "root folder relative")
            }
            #expect(
                FileStatusCopyPathKind.payload(files: files, repositoryURL: root, kind: .fullNative)
                    == relative.split(separator: "\n").map { root.path + "/" + $0 }.joined(separator: "\n"), "full paths")
            #expect(
                FileStatusCopyPathKind.payload(files: files, folder: "nested", repositoryURL: root, kind: .fullNative) == root.path + "/nested",
                "folder overrides selected files")
            #expect(FileStatusCopyPathKind.payload(files: [], repositoryURL: root, kind: .fullNative).isEmpty, "empty selection")
            #expect(
                FileStatusCopyPathKind.payload(files: [file("é"), file("e\u{301}")], repositoryURL: root, kind: .relativePOSIX).split(separator: "\n").count
                    == 2, "upstream ordinal distinct keeps differently encoded Unicode paths")
            #expect(FileStatusCopyPathKind.allCases == [.relativePOSIX, .relativeNative, .fullNative], "Designer order and no Windows variants")
        }

        @Test("Search") static func search() {
            let state = FileViewerSearchState()
            for (query, matchCase, expected) in [
                ("one", false, NSRange(location: 5, length: 3) as NSRange?), ("ONE", false, NSRange(location: 5, length: 3)),
                ("one", true, NSRange(location: 5, length: 3)), ("ONE", true, nil),
            ] {
                state.setText("line one")
                state.query = query
                state.matchCase = matchCase
                state.wholeWord = false
                #expect(state.find(.next) == expected, "upstream MatchCase vector")
            }
            for (query, expected) in [("one", NSRange(location: 5, length: 3) as NSRange?), ("on", nil)] {
                state.setText("line one")
                state.query = query
                state.matchCase = false
                state.wholeWord = true
                #expect(state.find(.previous) == expected, "upstream MatchWholeWordOnly backward vector")
            }
            for direction in [FileViewerSearchState.Direction.next, .previous] {
                state.setText("line odd\r\nline even\r\nline odd")
                state.query = "odd"
                state.wholeWord = false
                let offsets = direction == .next ? [5, 26, 5] : [26, 5, 26]
                for offset in offsets { #expect(state.find(direction) == NSRange(location: offset, length: 3), "upstream LoopAround entire document") }
                #expect(state.wrapped, "third search wraps")
                state.setText("line odd\r\nline even\r\nline odd")
                state.query = "line"
                state.scanRegion = NSRange(location: 10, length: 16)
                let regionOffsets = direction == .next ? [10, 21, 10] : [21, 10, 21]
                for offset in regionOffsets { #expect(state.find(direction) == NSRange(location: offset, length: 4), "upstream LoopAround scan region") }
            }
            state.setText("line one\r\nline two\r\nline three")
            state.query = "line"
            state.scanRegion = NSRange(location: 0, length: 10)
            #expect(state.find(.next, caret: 10) == NSRange(location: 0, length: 4), "scan region wraps")
            #expect(
                state.find(.next, caret: 11, viaKeyboard: true) == NSRange(location: 20, length: 4) && state.scanRegion == nil,
                "upstream F3 clears outside scan region")
            state.setText("one one tone one_ _one one-é 日本 日本語")
            state.query = "one"
            state.wholeWord = true
            #expect(state.matches().map(\.location) == [0, 4, 23], "underscore and letter boundaries, punctuation boundary")
            state.markAll()
            #expect(state.highlightedRanges == state.matches(), "explicit highlight ranges")
            #expect(state.find(.next)?.location == 0 && state.currentIndex == 0, "active first result")
            #expect(state.find(.next)?.location == 4 && state.currentIndex == 1, "second result in same line")
            state.query = "日本"
            state.markAll()
            #expect(state.currentMatch == nil && state.currentIndex == nil && state.highlightedRanges.count == 1, "Unicode whole word and query reset")
            state.setText("é É e\u{301} Straße STRASSE 😀word😀")
            state.query = "É"
            state.wholeWord = false
            state.matchCase = false
            #expect(state.matches().map(\.location) == [0, 2], "invariant accented case, no normalization")
            state.query = "STRASSE"
            #expect(state.matches().count == 1, "no full Unicode case expansion")
            state.query = "word"
            state.wholeWord = true
            #expect(state.matches().count == 1, "UTF16 surrogate boundary")
            state.setText("😀 😁 𐐨 𐐀")
            state.query = "😀"
            state.wholeWord = false
            #expect(state.matches() == [NSRange(location: 0, length: 2)], "distinct supplementary scalars in case-insensitive search")
            state.query = "𐐀"
            #expect(state.matches().count == 2, "supplementary letter invariant case mapping")
            state.query = "missing"
            state.markAll()
            #expect(state.find(.next) == nil && state.highlightedRanges.isEmpty, "no matches")
            state.query = ""
            state.markAll()
            #expect(!state.highlightAll && state.find(.next) == nil, "empty clears highlights")
            state.query = "word"
            state.scanRegion = NSRange(location: 0, length: 2)
            state.setText("new file")
            #expect(
                state.scanRegion == nil && state.currentMatch == nil && state.highlightedRanges.isEmpty && state.query == "word",
                "upstream text reset retains query and clears document state")
        }

        @Test("Multi file search") static func multiFileSearch() async {
            let texts = ["line one\r\nline two\r\nline three", "content one\r\ncontent two\r\ncontent three"]
            let state = FileViewerSearchState()
            state.query = "two"
            state.setText(texts[0])
            var index = 0
            let loader: (FileViewerSearchState.Direction) async -> String? = { direction in
                index = (index + (direction == .next ? 1 : texts.count - 1)) % texts.count
                state.setText(texts[index])
                return String(index)
            }
            for offset in [15, 21, 15] {
                let result = await state.findAcrossFiles(.next, caret: state.currentMatch.map(NSMaxRange) ?? 0, allowsNavigation: true, loadNext: loader)
                #expect(result == NSRange(location: offset, length: 3), "upstream MultiFileSearch full documents")
            }
            index = 0
            state.setText(texts[0])
            state.scanRegion = NSRange(location: 10, length: 10)
            for _ in 0..<2 {
                let result = await state.findAcrossFiles(.next, caret: state.currentMatch.map(NSMaxRange) ?? 20, allowsNavigation: true, loadNext: loader)
                #expect(result == NSRange(location: 15, length: 3) && index == 0, "upstream MultiFileSearch scan region stays in file")
            }
            state.scanRegion = nil
            let closed = await state.findAcrossFiles(.next, caret: 100, allowsNavigation: false, loadNext: loader)
            #expect(closed == nil && index == 0, "closed upstream dialog does not navigate or wrap with file loader")
            state.setText(texts[0])
            state.query = "missing"
            let missing = await state.findAcrossFiles(.next, caret: 0, allowsNavigation: true, loadNext: loader)
            #expect(missing == nil, "no matches terminates one traversal")
            state.setText("")
            state.query = "two"
            var visits = 0
            let skipping: (FileViewerSearchState.Direction) async -> String? = { _ in
                visits += 1
                state.setText(visits == 1 ? "" : texts[1])
                return String(visits)
            }
            let result = await state.findAcrossFiles(.next, caret: 0, allowsNavigation: true, loadNext: skipping)
            #expect(result?.location == 21 && visits == 2, "deferred preview is skipped without requesting Show anyway")
        }

        @Test("Icons") static func icons() {
            let provider = FileAssociatedIconProvider()
            for ext in ["txt", "py", "png", "pdf", "previewunknown"] {
                let path = "/nonexistent/generic/file." + ext
                #expect(FileAssociatedIconProvider.key(path: path) == .fileExtension(ext), "extension classification")
                let first = provider.icon(path: path)
                #expect(first === provider.icon(path: "another/FILE." + ext.uppercased()), "case independent extension cache")
                #expect(first.size.width > 0 && first.size.height > 0, "native image has size")
            }
            #expect(provider.cacheCount == 5, "one entry per extension, no per path cache")
            #expect(FileAssociatedIconProvider.key(path: "README") == .generic, "extensionless")
            #expect(FileAssociatedIconProvider.key(path: "folder/") == .folder, "trailing folder separator")
            #expect(FileAssociatedIconProvider.key(path: "folder.txt", isDirectory: true) == .folder, "explicit directory wins")
            #expect(provider.icon(path: "README") === provider.icon(path: "LICENSE"), "generic reuse")
            #expect(provider.icon(path: "dir", isDirectory: true) === provider.icon(path: "nested/dir/"), "folder cache reuse")
        }

        @Test("Syntax") static func syntax() throws {
            #expect(FileViewerSyntaxRegistry.modes.count == 91, "single existing registry")
            for (path, name) in [("test.xml", "XML"), ("test.vcxproj.filters", "XML"), ("test.cs", "C#"), ("test.CS", "C#"), ("test.htm", "HTML")] {
                guard case .ordinary(let mode) = FileEditorHighlighting.mode(for: path) else { throw TestFailure(description: path) }
                #expect(mode.name == name, "upstream HighlightingManagerTests vector")
            }
            #expect(FileEditorHighlighting.mode(for: "test.unkown") == .plain, "upstream unknown suffix")
            for path in ["file.py", "nested/test.cs", "file.lua", "file.yaml", ".editorconfig"] {
                guard case .ordinary(let mode) = FileEditorHighlighting.mode(for: path) else { throw TestFailure(description: path) }
                #expect(mode == FileViewerSyntaxRegistry.mode(for: path), "same FileViewer registry selection")
            }
            #expect(FileEditorHighlighting.mode(for: "unknown.preview") == .plain, "unknown plain")
            #expect(FileEditorHighlighting.mode(for: ".git/COMMIT_EDITMSG") == .commitMessage, "commit path")
            #expect(FileEditorHighlighting.mode(for: "COMMIT_EDITMSG") == .commitMessage, "commit name")
            #expect(FileEditorHighlighting.mode(for: ".git/rebase-merge/git-rebase-todo") == .rebaseTodo, "rebase path")
            #expect(FileEditorHighlighting.mode(for: "git-rebase-todo") == .rebaseTodo, "rebase name")
            let commit =
                "# help\r\n  # status\r\n" + String(repeating: "s", count: 51) + "\r\n" + String(repeating: "b", count: 81)
                + "\r\n# ------------------------ >8 ------------------------\r\n"
            let original = Data(commit.utf8)
            let result = FileEditorHighlighting.build(text: commit, path: "COMMIT_EDITMSG")
            #expect(result.tokens.filter { $0.kind == .comment }.count == 3, "comments/help/status/scissors same comment region")
            #expect(result.tokens.filter { $0.kind == .summary }.count == 1, "bold first noncomment summary")
            #expect(
                result.markers.map(\.message) == ["Summary line is too long.", "There must be a blank line after the summary.", "Line is too long."],
                "upstream diagnostic regions")
            let proper = FileEditorHighlighting.build(text: "subject\n\n" + String(repeating: "b", count: 81), path: "COMMIT_EDITMSG")
            #expect(proper.markers.isEmpty, "pinned strategy leaves descriptionStart unset after dividing blank")
            let custom = FileEditorHighlighting.build(text: "; comment\nsubject\n", path: "COMMIT_EDITMSG", commentSetting: ";")
            #expect(custom.tokens.first?.kind == .comment, "core.commentchar")
            #expect(
                FileEditorHighlighting.build(text: "# comment\nsubject", path: "COMMIT_EDITMSG", commentSetting: "auto").tokens.first?.kind == .comment,
                "auto upstream fallback")
            let todo =
                "pick abcd subject\nreword abcde subject\ne abcdef subject\nsquash abcdef subject\nfixup -C abcdef subject\nf -cabcdef subject\nexec abcdef command\ndrop abcdef subject\n# comment\n break\nbreak\nlabel name\nreset name\nmerge abcdef subject\nupdate-ref refs/heads/main\npick ABCD subject\npick abc subject\npick abcdef\nexec echo hello\n pick abcd subject\n"
            let rebase = FileEditorHighlighting.build(text: todo, path: "git-rebase-todo")
            #expect(
                rebase.tokens.compactMap {
                    if case .command(let name) = $0.kind { return name }
                    return nil
                } == ["pick", "reword", "edit", "squash", "fixup", "fixup", "exec", "drop"], "pinned seven commands, aliases and fixup options")
            #expect(
                rebase.tokens.filter {
                    if case .commitID = $0.kind { return true }
                    return false
                }.count == 8, "IDs and subject separation")
            #expect(rebase.tokens.filter { $0.kind == .comment }.count == 1, "todo comments")
            let ordinary = FileEditorHighlighting.build(text: "def value():\n    return \"text\" # comment\n", path: "sample.py")
            #expect(
                ordinary.tokens.contains { $0.kind == .syntax(.keyword) } && ordinary.tokens.contains { $0.kind == .syntax(.string) }
                    && ordinary.tokens.contains { $0.kind == .syntax(.comment) }, "ordinary lexer spans")
            #expect(Data(commit.utf8) == original, "source byte unchanged")
            let editor = EditableFileTextView()
            editor.syntaxPath = "COMMIT_EDITMSG"
            editor.text = commit
            editor.textView.setSelectedRange(NSRange(location: 5, length: 2))
            let selected = editor.textView.selectedRange()
            let typing = editor.textView.typingAttributes as NSDictionary
            editor.updateHighlighting()
            #expect(Data(editor.text.utf8) == original && editor.textView.selectedRange() == selected, "temporary attributes preserve source and selection")
            #expect(editor.textView.typingAttributes as NSDictionary == typing, "typing attributes untouched")
            editor.textView.updateTrackingAreas()
            #expect(
                editor.textView.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.inVisibleRect) },
                "semantic marker tooltip tracks the visible editor")
            #expect(
                editor.textView.textStorage?.attribute(.font, at: 20, effectiveRange: nil) as? NSFont
                    != NSFontManager.shared.convert(AppSettingsStore.shared.codeFont, toHaveTrait: .boldFontMask), "no persisted bold display attribute")
            editor.syntaxPath = "sample.py"
            editor.text = "def f():\n    return 1\n"
            #expect(editor.textView.syntaxMarkers.isEmpty, "different file clears semantic markers")
            editor.syntaxPath = "unknown.preview"
            #expect(editor.text == "def f():\n    return 1\n", "plain re-selection preserves text")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Test-edit-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for encoding in [RepositoryTextEncoding.utf8, .utf16LittleEndian, .windows1252] {
                let url = root.appendingPathComponent(encoding.rawValue)
                let value = "subject é\r\n\r\nbody\r\n"
                let bom: [UInt8] = encoding == .utf16LittleEndian ? [0xff, 0xfe] : []
                try (Data(bom) + value.data(using: encoding.foundationEncoding)!).write(to: url)
                let before = try Data(contentsOf: url)
                let loaded = try EditableFileIO.load(url, configuredEncoding: encoding)
                editor.syntaxPath = "COMMIT_EDITMSG"
                editor.text = loaded.text
                editor.updateHighlighting()
                try EditableFileIO.saveInPlace(editor.text, to: url, encoding: loaded.encoding, preamble: loaded.preamble)
                #expect(try Data(contentsOf: url) == before, "save bytes/encoding/preamble/line endings unchanged")
            }
        }

        @Test("Preview lifecycle") static func previewLifecycle() async throws {
            let counter = PreviewCounter()
            for length in [FilePreview<String>.threshold - 1, FilePreview<String>.threshold, FilePreview<String>.threshold + 1] {
                let before = await counter.count
                let preview = try await FilePreview<String>.prepare(length: length) {
                    await counter.increment()
                    return "original"
                }
                if length <= FilePreview<String>.threshold {
                    #expect(await counter.count == before + 1, "below/equal renders")
                    if case .ready(let value) = preview { #expect(value == "original", "ready content") } else { Issue.record("small deferred") }
                } else {
                    #expect(await counter.count == before, "above threshold not loaded")
                    #expect(try await preview.resolve() == "original", "resolve original requested content")
                }
            }
            let presenter = FilePreviewPresentation<String>()
            var displayed: [String] = []
            let deferred = try await FilePreview<String>.prepare(length: FilePreview<String>.threshold + 1) {
                await counter.increment()
                return "old"
            }
            presenter.present(deferred, display: { displayed.append($0) }, failure: { _ in Issue.record("unexpected") })
            #expect(presenter.state == .deferred && !presenter.button.isHidden, "native prompt state")
            presenter.cancel()
            presenter.showAnyway()
            #expect(displayed.isEmpty, "navigation invalidates confirmation")
            presenter.present(deferred, display: { displayed.append($0) }, failure: { _ in Issue.record("unexpected") })
            presenter.showAnyway()
            for _ in 0..<100 where displayed.isEmpty { await Task.yield() }
            #expect(displayed == ["old"] && presenter.state == .displayed, "show anyway original")
            presenter.present(deferred, display: { displayed.append($0) }, failure: { _ in Issue.record("unexpected") })
            #expect(presenter.state == .deferred, "repeated display re-prompts upstream lifecycle")
            let suspended = PreviewSuspendedLoad()
            presenter.present(
                .deferred(length: FilePreview<String>.threshold + 1, load: { await suspended.load() }), display: { displayed.append($0) },
                failure: { _ in Issue.record("unexpected") })
            presenter.showAnyway()
            while !(await suspended.started) { await Task.yield() }
            #expect(presenter.state == .loading, "show transitions loading")
            presenter.present(.ready("second"), display: { displayed.append($0) }, failure: { _ in Issue.record("unexpected") })
            await suspended.finish()
            for _ in 0..<20 { await Task.yield() }
            #expect(displayed == ["old", "second"], "cancelled stale completion cannot render old file")
            let task = Task { () throws -> FilePreview<String> in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await FilePreview.prepare(length: 1) { throw TestFailure(description: "cancelled loader called") }
            }
            do {
                _ = try await task.value
                Issue.record("cancellation missed")
            } catch is CancellationError {}
        }

        @Test("Presentation deferral") static func presentationDeferral() async throws {
            let file = file("large.txt")
            let viewer = DiffContentViewController()
            _ = viewer.view
            let large = FileDiff(
                id: file.id, fileID: file.id,
                lines: [
                    DiffLine(
                        id: "0", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: String(repeating: "a", count: FilePreview<String>.threshold + 1))
                ])
            viewer.apply(file: file, diff: large)
            #expect(viewer.previewPresentation.state == .deferred && viewer.searchState.text.isEmpty, "direct large diff defers presentation/search allocation")
            let menu = NSMenu()
            viewer.menuNeedsUpdate(menu)
            #expect(
                menu.items.first { $0.title == "Find…" }?.isEnabled == true && viewer.previewPresentation.state == .deferred,
                "Find stays available for a deferred preview without forcing the load (upstream FindAndReplaceForm)")
            let small = FileDiff(
                id: "small", fileID: file.id, lines: [DiffLine(id: "small", oldLineNumber: nil, newLineNumber: 1, kind: .context, text: "second")])
            viewer.apply(file: file, diff: small)
            viewer.previewPresentation.showAnyway()
            #expect(viewer.searchState.text == "second", "selection change drops old pending diff")
            let content = RevisionFileContentViewController()
            _ = content.view
            content.apply(
                content: RepositoryFileContent(path: "large.txt", kind: .text, text: String(repeating: "x", count: FilePreview<String>.threshold + 1)),
                revisionLabel: "HEAD")
            #expect(
                content.previewPresentation.state == .deferred && content.textView.string.isEmpty && content.searchState.text.isEmpty,
                "large supplied text defers attributed rendering")
            content.apply(content: RepositoryFileContent(path: "small.txt", kind: .text, text: "one one"), revisionLabel: "HEAD")
            content.previewPresentation.showAnyway()
            #expect(content.textView.string == "one one", "second selection replaces deferred text")
            content.searchState.query = "one"
            content.searchState.markAll()
            #expect(
                content.searchState.highlightedRanges == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)],
                "confirmed text has searchable ranges")
            let line = DiffLine(id: "search-render", oldLineNumber: 1, newLineNumber: 1, kind: .context, text: "one one")
            let presentation = DiffLinePresentation.build(from: [line])[0]
            let cell = DiffLineCellView()
            cell.apply(
                presentation: presentation, gutterMetrics: .empty, showsNonPrintingCharacters: false, showsSyntaxHighlighting: false,
                searchRanges: [NSRange(location: 0, length: 3)], activeSearchRanges: [NSRange(location: 4, length: 3)])
            let stack = cell.subviews.first as! NSStackView
            let rendered = (stack.arrangedSubviews.last as! NSTextField).attributedStringValue
            #expect(
                rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil
                    && rendered.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil, "all ranges actually render in Diff cells")
            #expect(
                rendered.attribute(.underlineStyle, at: 4, effectiveRange: nil) != nil
                    && rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil,
                "active range distinguishable without mutating diff-inline ranges")
            #expect(presentation.line == line, "search rendering preserves diff model")
            let commitView = CommitDiffView()
            commitView.apply(file: file, preview: .deferred(length: FilePreview<FileDiff?>.threshold + 1, load: { large }), direction: .stage)
            #expect(commitView.previewPresentation.state == .deferred && commitView.searchState.text.isEmpty, "Commit consumer defers before presentation")
            commitView.apply(file: file, diff: small, direction: .stage)
            commitView.previewPresentation.showAnyway()
            #expect(commitView.searchState.text == "second", "Commit consumer drops old confirmation")
            let id = testObjectID("preview-blame")
            let parsed = BlameCommands.parse(
                Data(
                    (id.string + " 1 1 1\nauthor Fixture\nsummary Fixture\nfilename large.txt\n\t"
                        + String(repeating: "a", count: FilePreview<BlameResult>.threshold + 1) + "\n").utf8), encoding: .utf8)
            let blame = BlameViewController()
            blame.process(parsed, revision: id, file: "large.txt", line: 1)
            #expect(
                blame.previewPresentation.state == .deferred && blame.blame == nil && blame.searchState.text.isEmpty, "Blame text gate precedes syntax/layout")
            blame.cancel()
            blame.previewPresentation.showAnyway()
            #expect(blame.blame == nil, "Blame cancelled confirmation remains empty")
            let editor = EditableFileTextView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            defer { window.close() }
            editor.syntaxPath = "sample.py"
            editor.text = "def f():\n    return 1\n"
            editor.enableViewerToolbar(resolvedEncoding: .utf8)
            let before = editor.text
            window.makeFirstResponder(editor.textView)
            editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            let after = editor.text
            guard let undo = editor.textView.undoManager else { throw TestFailure(description: "editor undo manager missing") }
            #expect(undo.canUndo, "editing registers undo")
            editor.updateHighlighting()
            #expect(undo.canUndo && editor.text == after, "syntax does not consume undo")
            undo.undo()
            #expect(editor.text == before && undo.canRedo, "undo original edit after highlighting")
            editor.updateHighlighting()
            undo.redo()
            #expect(editor.text == after, "redo survives highlighting")
        }

        @Test("Repository previews") static func repositoryPreviews() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let limit = FilePreview<String>.threshold
            for (name, count) in [("below.txt", limit - 1), ("equal.txt", limit), ("above.txt", limit + 1)] {
                try Data(repeating: 97, count: count).write(to: fixture.repo.appendingPathComponent(name))
            }
            try Data(repeating: 0, count: limit + 1).write(to: fixture.repo.appendingPathComponent("large.bin"))
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")!
            try (png + Data(repeating: 0, count: limit + 1 - png.count)).write(to: fixture.repo.appendingPathComponent("large.png"))
            try fixture.write("small.py", "def value():\n    return 1\n")
            try fixture.commitAll("base")
            let spy = PreviewRecordingGit()
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: spy)
            let state = try await module.loadRepositoryState()
            let commit = try await module.loadBlameRevision(state.identity.headID!)
            let entries = try await module.loadRepositoryFiles(for: commit)
            for name in ["above.txt", "large.bin"] {
                let entry = entries.first { $0.path == name }!
                let before = await spy.blobReads
                let preview = try await module.prepareFilePresentation(for: commit, file: entry, encoding: .automatic)
                #expect(await spy.blobReads > before, Comment(rawValue: "decoded length requires raw blob load: " + name))
                guard case .deferred(let length, _) = preview else { throw TestFailure(description: "large blob not deferred") }
                #expect(length == limit + 1, "decoded UTF-16 size")
                let content = try await preview.resolve()
                #expect(content.data.count == limit + 1 && content.kind == (name == "large.bin" ? .binary : .text), "original decoded content on confirmation")
                if name == "large.bin" { #expect(content.text.contains("[Truncated]"), "C45 binary presentation preserved") }
                let again = try await module.prepareFilePresentation(for: commit, file: entry, encoding: .automatic)
                guard case .deferred = again else { throw TestFailure(description: "second blob view did not prompt") }
            }
            for name in ["below.txt", "equal.txt"] {
                let preview = try await module.prepareFilePresentation(for: commit, file: entries.first { $0.path == name }!, encoding: .automatic)
                guard case .ready(let content) = preview else { throw TestFailure(description: "boundary wrongly gated") }
                #expect(content.kind == .text, "boundary text")
            }
            let blobImage = try await module.prepareFilePresentation(for: commit, file: entries.first { $0.path == "large.png" }!, encoding: .automatic)
            guard case .ready(let image) = blobImage else { throw TestFailure(description: "upstream blob image should bypass text gate") }
            #expect(image.kind == .image, "blob image intact")
            let working = Commit(
                id: .workingDirectory, shortID: "", subject: "", body: "", authorName: "", authorEmail: "", authorDate: Date(timeIntervalSince1970: 0),
                committerName: "", committerEmail: "", commitDate: Date(timeIntervalSince1970: 0), parentIDs: [], references: [], kind: .workingDirectory)
            for name in ["above.txt", "large.bin", "large.png"] {
                let preview = try await module.prepareFilePresentation(for: working, file: RepositoryFileEntry(path: name, content: ""), encoding: .automatic)
                guard case .deferred = preview else { throw TestFailure(description: "working file/image byte gate") }
            }
            let index = Commit(
                id: .index, shortID: "", subject: "", body: "", authorName: "", authorEmail: "", authorDate: Date(timeIntervalSince1970: 0), committerName: "",
                committerEmail: "", commitDate: Date(timeIntervalSince1970: 0), parentIDs: [], references: [], kind: .index)
            let indexEntry = try await module.loadRepositoryFiles(for: index).first { $0.path == "above.txt" }!
            let warmBefore = await spy.blobReads
            let warmIndex = try await module.prepareFilePresentation(for: index, file: indexEntry, encoding: .automatic)
            guard case .deferred(let warmLength, _) = warmIndex else { throw TestFailure(description: "cached index blob lost rendering deferral") }
            let warmContent = try await warmIndex.resolve()
            #expect(
                warmLength == limit + 1 && warmContent.data.count == limit + 1 && warmContent.kind == .text, "cached index gate and confirmed original bytes")
            #expect(await spy.blobReads == warmBefore, "upstream immutable blob cache reused across historical/index presentations")
            CommandCache.shared.clear()
            let before = await spy.blobReads
            let indexPreview = try await module.prepareFilePresentation(for: index, file: indexEntry, encoding: .automatic)
            guard case .deferred = indexPreview else { throw TestFailure(description: "index metadata gate") }
            #expect(await spy.blobReads > before, "index decoded length requires materializing")
            try fixture.write("large-diff.txt", String(repeating: String(repeating: "x", count: 120) + "\n", count: 44_000))
            var changed = file("large-diff.txt", type: .added)
            changed.isTracked = false
            let group = FileStatusGroup(first: .index, second: .workingDirectory, summary: "", files: [changed])
            for color in [false, true] {
                var options = FileDiffOptions()
                options.useGitColoring = color
                let preview = try await module.prepareFileStatusPreview(group: group, file: changed, options: options, grep: GitGrepOptions())
                guard case .deferred(let length, _) = preview else { throw TestFailure(description: "large diff not gated before parse") }
                #expect(length > limit, "diff text size threshold")
                let result = try await preview.resolve()
                guard case .diff(let diff?) = result else { throw TestFailure(description: "confirmed diff missing") }
                #expect(diff.lines.filter { $0.kind == .addition }.count == 44_000, "original diff renders after confirmation")
            }
            _ = try await module.loadRepositoryState()
            for appearance in [DiffDisplayAppearance.patch, .gitWordDiff] {
                let preview = try await module.prepareDiff(for: working, file: changed, options: FileDiffOptions(appearance: appearance))
                guard case .deferred = preview else { throw TestFailure(description: "Commit raw appearance gate") }
                if appearance == .patch {
                    let displayed = try await preview.resolve()
                    #expect(displayed?.lines.filter { $0.kind == .addition }.count == 44_000, "Commit confirmed original patch")
                    let cached = try await module.prepareDiff(for: working, file: changed, options: FileDiffOptions(appearance: appearance))
                    guard case .deferred = cached else { throw TestFailure(description: "cached Commit diff failed to re-prompt") }
                }
            }
            try fixture.git(["config", "difftool.difftastic.cmd", "cat large-diff.txt"])
            let dft = try await module.prepareDiff(for: working, file: changed, options: FileDiffOptions(appearance: .difftastic))
            guard case .deferred = dft else { throw TestFailure(description: "Difftastic raw output gate") }
            let editable = try await module.prepareEditableFile(at: fixture.repo.appendingPathComponent("above.txt"))
            guard case .deferred = editable else { throw TestFailure(description: "repository file editor metadata gate") }
            try fixture.git(["config", "core.commentchar", ";"])
            #expect(try await module.editorCommentCharacter() == ";", "effective editor commentchar")
            try fixture.git(["config", "core.commentchar", "auto"])
            #expect(try await module.editorCommentCharacter() == "#", "effective auto fallback")
        }
    }
}

typealias FilePreviewAndSearchTests = UIIntegrationTests.FilePreviewAndSearchTests

private actor PreviewCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor PreviewSuspendedLoad {
    var started = false
    private var continuation: CheckedContinuation<String, Never>?
    func load() async -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: "stale")
        continuation = nil
    }
}

private actor PreviewRecordingGit: GitCommandRunning {
    var blobReads = 0
    func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
        if arguments.contains("cat-file") && !arguments.contains("-s") && !arguments.contains("-e") { blobReads += 1 }
        return try await FileStatusFixtureGit().run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
    }
    func runStreaming(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler)
        async throws -> GitCommandResult
    {
        if arguments.contains("cat-file") && !arguments.contains("-s") && !arguments.contains("-e") { blobReads += 1 }
        return try await FileStatusFixtureGit().runStreaming(
            arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: output)
    }
}
