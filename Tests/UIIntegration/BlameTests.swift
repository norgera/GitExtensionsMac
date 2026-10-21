import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Blame")
    enum BlameTests {
        @Test("Scenarios") static func run() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            do {
                _ = try await module.loadBlameRevision(nil)
                Issue.record("unborn HEAD must fail")
            } catch {}
            try fixture.write("source.swift", "one\ntwo\nthree\n")
            try fixture.commitAll("base")
            let base = try fixture.head()
            try fixture.write("source.swift", "zero\none\nTWO\nthree\n")
            try fixture.commitAll("change")
            let head = try fixture.head()
            let revision = try await module.loadBlameRevision(nil)
            #expect(revision.objectID == head && revision.parentIDs == [base], "actual revision")
            let result = try await module.blame(file: "source.swift", revision: head, encoding: .utf8, options: BlameOptions())
            #expect(result.lines.map(\.text) == ["zero", "one", "TWO", "three"], "file content")
            #expect(result.lines.map(\.commit.objectID) == [head, base, head, base], "line ownership")
            #expect(result.lines.map(\.originLineNumber) == [1, 1, 3, 3], "original lines")
            #expect(result.lines[0].commit === result.lines[2].commit, "porcelain commit cache")
            let parents = await module.actualParentsMap([head, base])
            #expect(parents[head] == [base] && parents[base] == [], "batched actual parents")
            let mapped = await module.originalLineInPreviousCommit(commit: head, parent: base, file: "source.swift", line: 4, options: BlameOptions())
            #expect(mapped == 3, "previous revision line mapping")
            let options = BlameOptions(ignoreWhitespace: true, detectCopyInFile: true, detectCopyInAll: true, histogramDiffAlgorithm: true)
            let command = BlameCommands.blame(file: "a b.swift", revision: head, options: options)
            #expect(command.arguments == ["blame", "--porcelain", "-M", "-C", "-w", "-l", head.string, "--", "a b.swift"], "exact argv")
            #expect(!command.accessesRemote && !command.changesRepositoryState, "read-only metadata")
            #expect(
                BlameCommands.previousRevisionDiff(parent: base, commit: head, file: "f", options: options).arguments == [
                    "diff", "--no-ext-diff", "-U0", "--diff-algorithm=histogram", "--find-renames", "--find-copies", "--ignore-all-space", base.string,
                    head.string, "--", "f",
                ], "mapping argv")
            try fixture.write("source.swift", "zero\n  one\nTWO\nthree\n")
            try fixture.commitAll("whitespace")
            let whitespace = try fixture.head()
            let ignored = try await module.blame(file: "source.swift", revision: whitespace, encoding: .utf8, options: .init())
            let included = try await module.blame(file: "source.swift", revision: whitespace, encoding: .utf8, options: .init(ignoreWhitespace: false))
            #expect(ignored.lines[1].commit.objectID == base && included.lines[1].commit.objectID == whitespace, "whitespace option")
            let renamed = "renamed ü\tfile.swift"
            try fixture.git(["mv", "source.swift", renamed])
            try fixture.commitAll("rename")
            let renamedResult = try await module.blame(file: renamed, revision: try fixture.head(), encoding: .utf8, options: .init())
            #expect(renamedResult.lines[1].commit.fileName == "source.swift", "follow original file through rename")
            try fixture.write(renamed, "zero\n  one\nTWO\nthree\nnew\n")
            try fixture.commitAll("unicode path")
            let quoted = try await module.blame(file: renamed, revision: try fixture.head(), encoding: .utf8, options: .init())
            #expect(quoted.lines.last?.commit.fileName == renamed, "Git C-quoted Unicode/tab path")
            do {
                _ = try await module.blame(file: "missing", revision: head, encoding: .utf8, options: .init())
                Issue.record("missing file")
            } catch {}
            try fixture.git(["clone", "--bare", fixture.repo.path, fixture.root.appendingPathComponent("bare.git").path])
            let bare = GitRepositoryModule(repositoryURL: fixture.root.appendingPathComponent("bare.git"), git: FileStatusFixtureGit())
            _ = try await bare.loadRepositoryState()
            let bareBlame = try await bare.blame(file: "source.swift", revision: head, encoding: .utf8, options: .init())
            #expect(bareBlame.lines.map(\.text) == result.lines.map(\.text), "bare historical blame")
            #expect(BlameCommands.parse(Data("garbage\n\tno header\n".utf8), encoding: .utf8).lines.isEmpty, "malformed")
            #expect(BlameCommands.parse(Data(), encoding: .utf8).lines.isEmpty, "empty")
            let latinHeader = "\(head.string) 1 1 1\nauthor André\nsummary encoding\nfilename latin.txt\n\t"
            let latin = BlameCommands.parse(Data(latinHeader.utf8) + Data([0x63, 0x61, 0x66, 0xe9, 10]), encoding: .windows1252)
            #expect(latin.lines.first?.text == "café" && latin.lines.first?.commit.author == "André", "content encoding separate from metadata")
            let sha256 = String(repeating: "a", count: 64)
            let hashed = BlameCommands.parse(Data("\(sha256) 1 1\nauthor A\nfilename f\n\tx\n".utf8), encoding: .utf8)
            #expect(hashed.lines.first?.commit.objectID.string == sha256, "SHA256")
            try await presentation(module: module, revision: revision, result: result, base: base)
            try await browse(module: module, revision: revision)
            try await standalone(module: module, revision: revision)
            try await cancellation(revision: revision, result: result)
            try await wideLines(revision: revision, result: result)
        }

        private static func presentation(module: GitRepositoryModule, revision: Commit, result: BlameResult, base: ObjectID) async throws {
            let controller = BlameViewController()
            controller.source = module
            var selected: ObjectID?
            var navigated: (ObjectID, String)?
            controller.onSelectedCommit = { selected = $0.objectID }
            controller.context = .init(
                revisionInGrid: { id in
                    id == base ? FileStatusTests.commitModel(base, parents: []) : id == revision.objectID ? revision : nil
                },
                selectFileInRevision: { id, file in
                    navigated = (id, file)
                    return true
                })
            var changes: ObjectID?
            controller.onShowChanges = { changes = $0 }
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 900, height: 500))
            window.orderFront(nil)
            defer {
                controller.cancel()
                window.orderOut(nil)
            }
            controller.load(revision: revision.objectID!, file: "source.swift", encoding: .utf8)
            try await wait { !controller.isLoading }
            #expect(controller.blame?.lines.count == 4 && selected == nil, "loading does not replace requested CommitInfo")
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            #expect(abs((controller.authorSplitter?.distance ?? 0) - 186) <= 1, "standalone author splitter designer distance 186")
            #expect(
                BlameViewController.authorDistance(restored: nil, default: 186, size: 900, divider: 1) == 186
                    && BlameViewController.authorDistance(restored: 300, default: 26, size: 900, divider: 1) == 300
                    && BlameViewController.authorDistance(restored: 890, default: 26, size: 900, divider: 1) == 26
                    && BlameViewController.authorDistance(restored: 25, default: 186, size: 900, divider: 1) == 186,
                "SetSplitterDistance validity and default fallback")
            #expect(controller.table.numberOfRows == 5, "upstream AppendLine presentation includes trailing empty line without adding a Git blame line")
            let lineColumn = controller.table.tableColumns.firstIndex { $0.identifier.rawValue == "line" }!
            let trailing = controller.table.view(atColumn: lineColumn, row: 4, makeIfNecessary: true) as? NSTextField
            #expect(trailing?.stringValue == "5", "trailing empty presentation line has its gutter number")
            let originalText = controller.blame!.lines.map(\.text)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let toolbar = descendants(controller.view).compactMap { $0 as? DiffViewerToolbar }.first!
            let controls = descendants(toolbar).compactMap { $0 as? NSControl }.filter { !$0.isHidden }
            #expect(
                !toolbar.isHidden && controls.compactMap { ($0 as? NSButton)?.toolTip } == ["Show nonprinting characters", "Encoding", "Settings"],
                "shared Text-mode toolbar")
            let nonprinting = controls.compactMap { $0 as? NSButton }.first { $0.toolTip == "Show nonprinting characters" }!
            let savedViewer = AppSettingsStore.shared.fileViewerPreferences
            nonprinting.state = .on
            NSApp.sendAction(nonprinting.action!, to: nonprinting.target, from: nonprinting)
            #expect(controller.blame!.lines.map(\.text) == originalText, "display controls leave original blame text unchanged")
            nonprinting.state = savedViewer.showsNonPrintingCharacters ? .on : .off
            NSApp.sendAction(nonprinting.action!, to: nonprinting.target, from: nonprinting)
            let authors = descendants(controller.view).compactMap { $0 as? BlameTableView }.first { $0 !== controller.table }!
            let column = authors.tableColumn(withIdentifier: .init("author"))!
            let requiredWidth =
                BlameViewController.gutter(result, fileName: "source.swift", preferences: AppSettingsStore.shared.blamePreferences)
                .map { ($0 as NSString).size(withAttributes: [.font: AppSettingsStore.shared.codeFont]).width }.max() ?? 0
            #expect(column.width >= requiredWidth, "author text has its full native measured width and can be revealed horizontally")
            #expect(
                abs(authors.enclosingScrollView!.frame.width - 186) <= 1 && authors.enclosingScrollView!.hasHorizontalScroller,
                "initial author pane uses designer distance and reveals measured columns by scrolling")
            controller.goToLine(3)
            #expect(selected == revision.objectID, "user line selection")
            controller.goToLine(2)
            #expect(selected == base && controller.currentFileLine == 2, "line commit selection")
            controller.findNext(forward: true, query: "three")
            #expect(
                controller.currentFileLine == 4,
                "shared search: selected row \(controller.table.selectedRow), lines \(controller.blame?.lines.map(\.text) ?? [])")
            controller.findNext(forward: false, query: "TWO")
            #expect(controller.currentFileLine == 3, "search previous preserves the selected match through highlighting repaint")
            controller.findNext(forward: true, query: "three")
            #expect(controller.currentFileLine == 4, "search next restores its result after query changes")
            controller.hover(row: 0)
            #expect(controller.highlightedCommit?.objectID == revision.objectID, "hover association")
            #expect(controller.previousRevision(of: result.lines[0].commit).target == base, "actual previous")
            let menu = controller.contextMenu(forRow: 0)
            #expect(menu.items.first?.isEnabled == true, "grid eligibility")
            let authorMenu = controller.contextMenu(forRow: 0, authorPane: true)
            if #available(macOS 27.0, *) {
                let actions = authorMenu.items.filter { !$0.isSeparatorItem } + (authorMenu.items.last?.submenu?.items ?? [])
                #expect(actions.allSatisfy { $0.preferredImageVisibility == .visible }, "all source blame author/copy icons explicitly visible")
            }
            #expect(
                authorMenu.items.map(\.title) == ["Blame this revision", "Blame previous revision", "Show changes", "", "Copy to clipboard"],
                "author pane has only dedicated blame/navigation/copy actions")
            #expect(
                menu.items.contains { $0.title == "Find…" } && menu.items.contains { $0.title == "Go to line…" },
                "file-pane native viewer commands remain available")
            if let item = menu.items.first(where: { $0.identifier?.rawValue == "blame.showChanges" }), let action = item.action {
                _ = NSApp.sendAction(action, to: item.target, from: item)
            }
            #expect(changes == revision.objectID, "Show changes handoff")
            controller.goToLine(3)
            controller.load(revision: revision.objectID!, file: "source.swift", encoding: .utf8, force: true)
            try await wait { !controller.isLoading }
            #expect(controller.currentFileLine == 3, "same-file reload keeps line")
            controller.blameRevision(base, fileName: "source.swift", line: result.lines[1])
            #expect(navigated?.0 == base && navigated?.1 == "source.swift", "grid file handoff")
            controller.context = nil
            #expect(
                !controller.contextMenu(forRow: 0).items[0].isEnabled && !controller.contextMenu(forRow: 0).items[1].isEnabled, "standalone no grid navigation")
            var preferences = BlamePreferences()
            preferences.showAuthorDate = false
            let gutter = BlameViewController.gutter(result, fileName: "source.swift", preferences: preferences)
            #expect(gutter.allSatisfy { $0 == "Fixture" }, "author runs")
            let repeated = BlameResult(lines: [result.lines[0], result.lines[0]])
            #expect(BlameViewController.gutter(repeated, fileName: "source.swift", preferences: preferences) == ["Fixture", ""], "run grouping")
            let restored = try JSONDecoder().decode(BlamePreferences.self, from: JSONEncoder().encode(preferences))
            #expect(restored == preferences, "preference roundtrip")
            #expect(try JSONDecoder().decode(BlamePreferences.self, from: Data("{}".utf8)) == BlamePreferences(), "migration defaults")
            let suite = "GitExtensionsMac-BlameTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            store.saveBlamePreferences(preferences)
            #expect(AppSettingsStore(defaults: defaults).blamePreferences == preferences, "settings persistence")
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let boundary = Calendar.current.date(byAdding: .year, value: -3, to: now)!
            #expect(BlameViewController.ageBuckets([boundary.addingTimeInterval(-1), now, .distantPast], now: now) == [0, 6, 0], "age boundaries")
        }

        private static func wideLines(revision: Commit, result: BlameResult) async throws {
            let long = "let value = \"" + String(repeating: "x", count: 400) + "\""
            let wide = BlameResult(lines: [BlameLine(commit: result.lines[0].commit, finalLineNumber: 1, originLineNumber: 1, text: long)])
            let controller = BlameViewController()
            controller.source = DelayedBlameSource(revision: revision, result: wide)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 500, height: 300))
            defer { window.close() }
            controller.load(revision: revision.objectID!, file: "fast", encoding: .utf8)
            try await wait { !controller.isLoading && controller.blame?.lines.count == 1 }
            controller.view.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first { $0.accessibilityIdentifier() == "Blame.Lines" })
            let content = try #require(table.tableColumn(withIdentifier: .init("content")))
            let textWidth = ceil((long as NSString).size(withAttributes: [.font: AppSettingsStore.shared.codeFont]).width)
            #expect(content.width >= textWidth, "blame code column keeps the full width of its longest line")
            #expect(table.frame.width > (table.enclosingScrollView?.contentView.bounds.width ?? 0), "long blame lines scroll horizontally instead of being cut off")
        }

        private static func cancellation(revision: Commit, result: BlameResult) async throws {
            let controller = BlameViewController()
            let source = DelayedBlameSource(revision: revision, result: result)
            controller.source = source
            controller.load(revision: revision.objectID!, file: "slow", encoding: .utf8)
            try await Task.sleep(nanoseconds: 20_000_000)
            controller.load(revision: revision.objectID!, file: "fast", encoding: .utf8)
            try await wait { !controller.isLoading }
            try await Task.sleep(nanoseconds: 180_000_000)
            #expect(controller.fileName == "fast" && controller.blame?.lines.count == 4, "stale cancelled result suppressed")
            controller.load(revision: revision.objectID!, file: "slow", encoding: .utf8)
            controller.cancel()
            try await Task.sleep(nanoseconds: 180_000_000)
            #expect(controller.blame == nil, "cancel prevents publishing")
        }

        private static func standalone(module: GitRepositoryModule, revision: Commit) async throws {
            let blame = BlameWindowController(
                source: module, infoSource: module, revision: revision, file: "source.swift",
                initialLine: 3, hostedRemotes: { [] }, showChanges: { _ in })
            blame.showWindow(nil)
            defer { blame.close() }
            try await wait { !blame.blameController.isLoading && blame.blameController.blame != nil }
            blame.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(blame.infoController.view.frame.height >= 100 && blame.blameController.view.frame.height >= 100, "standalone both panes visible")
            #expect(abs(blame.infoController.view.frame.height - 160) <= 1, "standalone CommitInfo designer distance 160")
            #expect(blame.blameController.currentFileLine == 3, "standalone initial line")
            #expect(blame.infoController.commit?.objectID == revision.objectID, "standalone initially describes requested revision")
            blame.blameController.goToLine(2)
            try await wait { blame.infoController.commit?.objectID == revision.parentIDs.first }
            let diff = CommitDiffWindowController(
                revision: revision, source: module, infoSource: module,
                repositoryURL: nil, command: { _ in })
            diff.showWindow(nil)
            defer { diff.close() }
            try await wait { !diff.diffController.filesController.allItems.isEmpty }
            diff.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(diff.infoController.view.frame.height >= 100 && diff.diffController.view.frame.height >= 100, "Show changes both panes visible")
            #expect(diff.diffController.filesController.allItems.first?.first == revision.parentIDs.first.map(RevisionID.object), "Show changes actual parent")
        }

        private static func browse(module: GitRepositoryModule, revision: Commit) async throws {
            let saved = AppSettingsStore.shared.blamePreferences
            defer { AppSettingsStore.shared.saveBlamePreferences(saved) }
            AppSettingsStore.shared.saveBlamePreferences(BlamePreferences())
            let diff = RevisionDiffViewController(mode: .diff)
            diff.fileStatusSource = module
            diff.blameSource = module
            diff.blameController.defaultAuthorDistance = BlameViewController.authorPanelMinSize + 1
            let window = NSWindow(contentViewController: diff)
            window.setContentSize(NSSize(width: 1000, height: 600))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            diff.setDiffs(revisions: [revision], headID: revision.objectID)
            try await wait { !diff.filesController.allItems.isEmpty }
            diff.selectFileOrFolder("source.swift")
            var forwarded: String?
            diff.onBlameInFileTree = { path, _ in forwarded = path }
            diff.toggleBlame()
            #expect(forwarded == "source.swift" && !diff.filesController.isBlameShown, "default Diff forwards to File tree")
            var preferences = saved
            preferences.useDiffViewerForBlame = true
            AppSettingsStore.shared.saveBlamePreferences(preferences)
            diff.toggleBlame()
            try await wait { !diff.blameController.isLoading && diff.blameController.blame != nil }
            #expect(diff.blameController.blameID == revision.objectID && !diff.blameController.view.isHidden, "inline diff blame")
            diff.blameController.view.layoutSubtreeIfNeeded()
            #expect(abs((diff.blameController.authorSplitter?.distance ?? 0) - 26) <= 1, "Browse author splitter default Panel1MinSize + 1")
            #expect(diff.scriptFileContext["LineNumber"] == ["1"], "blame line context")
            diff.toggleBlame()
            #expect(diff.blameController.view.isHidden, "toggle restores shared diff")
            let tree = RevisionDiffViewController(mode: .fileTree)
            tree.fileStatusSource = module
            tree.blameSource = module
            var restoreSize: CGFloat?
            tree.blameController.restoredAuthorDistance = {
                restoreSize = $0
                return 300
            }
            let treeWindow = NSWindow(contentViewController: tree)
            treeWindow.setContentSize(NSSize(width: 1000, height: 600))
            treeWindow.orderFront(nil)
            defer { treeWindow.orderOut(nil) }
            tree.setDiffs(revisions: [revision], headID: revision.objectID)
            try await wait { !tree.filesController.allItems.isEmpty }
            tree.selectFileOrFolder("source.swift", requestBlame: true, line: 3)
            try await wait { !tree.blameController.isLoading && tree.blameController.blame != nil }
            #expect(tree.blameController.currentFileLine == 3, "File tree requested line")
            tree.blameController.view.layoutSubtreeIfNeeded()
            #expect(restoreSize != nil && abs((tree.blameController.authorSplitter?.distance ?? 0) - 300) <= 1, "File tree restores persisted author splitter")

            let current = try await module.loadBlameRevision(nil)
            let index = FileStatusTests.artificial(.index, head: current.objectID!)
            tree.setDiffs(revisions: [index], headID: current.objectID)
            try await wait { tree.filesController.allItems.first?.second == .index }
            tree.selectFileOrFolder("renamed ü\tfile.swift", requestBlame: true)
            try await wait { !tree.blameController.isLoading }
            #expect(tree.blameController.blameID == current.objectID && tree.blameController.blame?.lines.last?.text == "new", "artificial revision uses HEAD")
            var context = ChangedFileContextMenuContext(selectedFiles: [
                ChangedFile(id: "f", path: "f", oldPath: nil, changeType: .deleted, additions: 0, deletions: 1)
            ])
            context.canBlame = true
            context.blameInFileTree = true
            func blameEnabled() -> Bool {
                ChangedFileContextMenuBuilder.build(context).contains {
                    if case .command("file.blame", _, let enabled) = $0 { return enabled }
                    return false
                }
            }
            #expect(!blameEnabled(), "deleted file cannot be opened in File tree")
            context.blameInFileTree = false
            #expect(blameEnabled(), "direct historical blame eligibility")
            context.selectedFolder = "dir"
            #expect(!blameEnabled(), "direct blame excludes folders")
            tree.setDiffs(revisions: [FileStatusTests.artificial(.index, head: current.objectID!)], headID: nil)
            #expect(!tree.filesController.canBlame, "unborn artificial row has no blame target")
            diff.blameController.cancel()
            tree.blameController.cancel()
        }

        private static func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<500 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            Issue.record("async timeout")
        }
    }
}

typealias BlameTests = UIIntegrationTests.BlameTests

private struct DelayedBlameSource: RepositoryBlameDataSource {
    let revision: Commit
    let result: BlameResult
    func loadBlameRevision(_ id: ObjectID?) async throws -> Commit { revision }
    func blame(file: String, revision: ObjectID, encoding: RepositoryTextEncoding, options: BlameOptions) async throws -> BlameResult {

        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + (file == "slow" ? 0.12 : 0.01)) { continuation.resume() }
        }
        return file == "slow" ? BlameResult(lines: []) : result
    }
    func originalLineInPreviousCommit(commit: ObjectID, parent: ObjectID?, file: String, line: Int, options: BlameOptions) async -> Int { line }
    func actualParents(of commit: ObjectID) async -> [ObjectID] { [] }
    func actualParentsMap(_ commits: [ObjectID]) async -> [ObjectID: [ObjectID]] { [:] }
}
