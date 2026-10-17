import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Recover lost objects")
    enum RecoverLostObjectsTests {

        private static let sha = String(repeating: "a", count: 40)

        @Test("Parsing") private static func testParsing() {
            #expect(LostObjectsCommands.parse("dangling commit \(sha)")?.objectType == .commit, "dangling commit")
            #expect(LostObjectsCommands.parse("unreachable blob \(sha)")?.rawType == "unreachable blob", "unreachable blob raw type")
            #expect(LostObjectsCommands.parse("missing tree \(sha)")?.objectType == .tree, "missing tree")
            #expect(LostObjectsCommands.parse("dangling tag \(sha)")?.objectType == .tag, "dangling tag")
            let warning = LostObjectsCommands.parse("warning in tree \(sha): contains zero-padded file modes")
            #expect(warning?.objectType == .other && warning?.rawType == "warning in tree", "warning in tree")
            #expect(LostObjectsCommands.parse("dangling commit \(sha.uppercased())") == nil, "uppercase hash rejected")
            #expect(
                LostObjectsCommands.parse("Checking object directories") == nil && LostObjectsCommands.parse("broken link from tree x") == nil,
                "other lines skipped")
            #expect(LostObjectsCommands.parse("dangling blob \(String(repeating: "b", count: 64))")?.objectID.string.count == 64, "SHA-256 hash")

            var commit = LostObject(objectType: .commit, objectID: try! ObjectID.parse(sha), rawType: "dangling commit")
            LostObjectsCommands.fillCommit(
                &commit,
                metadata: "\(sha)\u{1F}Ada\u{1F}Subject line\u{1F}1700000000\u{1F}\(String(repeating: "c", count: 40)) \(String(repeating: "d", count: 40))")
            #expect(
                commit.author == "Ada" && commit.subject == "Subject line" && commit.date == Date(timeIntervalSince1970: 1_700_000_000)
                    && commit.parent?.string == String(repeating: "c", count: 40), "commit metadata (first parent)")
            var anonymous = LostObject(objectType: .commit, objectID: try! ObjectID.parse(sha), rawType: "dangling commit")
            LostObjectsCommands.fillCommit(&anonymous, metadata: "\(sha)\u{1F}\u{1F}s\u{1F}1\u{1F}")
            #expect(anonymous.author == nil && anonymous.date == nil, "LogRegex needs an author")

            var tag = LostObject(objectType: .tag, objectID: try! ObjectID.parse(sha), rawType: "dangling tag")
            LostObjectsCommands.fillTag(
                &tag,
                catFile:
                    "object \(String(repeating: "c", count: 40))\ntype commit\ntag v1\ntagger Ada Lovelace <ada@example.com> 1700000000 +0100\n\nRelease one\n")
            #expect(
                tag.tagName == "v1" && tag.subject == "v1:Release one" && tag.author == "Ada Lovelace"
                    && tag.date == Date(timeIntervalSince1970: 1_700_000_000) && tag.parent?.string == String(repeating: "c", count: 40), "tag metadata")
            var treeTag = LostObject(objectType: .tag, objectID: try! ObjectID.parse(sha), rawType: "dangling tag")
            LostObjectsCommands.fillTag(&treeTag, catFile: "object \(sha)\ntype tree\ntag t\ntagger A <a> 1 +0000\n\nx\n")
            #expect(treeTag.tagName == nil, "only tags of commits are described")

            #expect(LostObjectsCommands.guessFileType(Data("#!/bin/sh\n".utf8)) == "sh", "shebang")
            #expect(LostObjectsCommands.guessFileType(Data([0x89, 0x50, 0x4E, 0x47])) == "png", "PNG signature")
            #expect(LostObjectsCommands.guessFileType(Data("<SVG width".utf8)) == "svg", "case-insensitive")
            #expect(LostObjectsCommands.guessFileType(Data("hello".utf8)) == "txt", "text fallback")
            #expect(LostObjectsCommands.guessFileName(Data("{}".utf8), id: try! ObjectID.parse(sha)) == "LOST_FOUND_\(sha).json", "file name")

            #expect(LostObjectsCommands.convertCrLfToWorktree(Data("a\nb\n".utf8)) == Data("a\r\nb\r\n".utf8), "LF to CRLF")
            #expect(LostObjectsCommands.convertCrLfToWorktree(Data("a\r\nb\n".utf8)) == Data("a\r\nb\r\n".utf8), "mixed endings")
            #expect(LostObjectsCommands.convertCrLfToWorktree(Data("a\r\nb\r\n".utf8)) == Data("a\r\nb\r\n".utf8), "already CRLF")
            #expect(LostObjectsCommands.convertCrLfToWorktree(Data([0x61, 0x0A, 0x00])) == Data([0x61, 0x0A, 0x00]), "binary kept")
            #expect(LostObjectsCommands.convertCrLfToWorktree(Data("a\rb\n".utf8)) == Data("a\rb\n".utf8), "lone CR kept")
            #expect(
                LostObjectsCommands.binaryAccordingToAttributes("f\0diff\0unset\0f\0text\0unspecified\0f\0crlf\0unspecified\0f\0eol\0unspecified\0") == true,
                "diff unset")
            #expect(
                LostObjectsCommands.binaryAccordingToAttributes("f\0diff\0unspecified\0f\0text\0set\0f\0crlf\0unspecified\0f\0eol\0unspecified\0") == false,
                "text set")
            #expect(
                LostObjectsCommands.binaryAccordingToAttributes("f\0diff\0unspecified\0f\0text\0unspecified\0f\0crlf\0unspecified\0f\0eol\0unspecified\0")
                    == nil, "no information")
            #expect(
                LostObjectsOptions().arguments == ["--no-reflogs"]
                    && LostObjectsOptions(unreachable: true, fullCheck: true, noReflogs: false).arguments == ["--unreachable", "--full"], "options")
            #expect(
                LostObjectsCommands.fsck(LostObjectsOptions(), lostFound: true).arguments == ["fsck-objects", "--lost-found", "--no-reflogs"],
                "lost-found command")

            let patch = FixedPatchLines.lines(
                "commit x\nAuthor: A\n\n    msg\n\ndiff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -3,2 +3,2 @@\n ctx\n-old\n+new\n")
            #expect(
                patch.map(\.kind) == [
                    .context, .context, .context, .context, .context, .header, .header, .header, .header, .hunk, .context, .deletion, .addition,
                ],
                "fixed patch kinds \(patch.map(\.kind))")
            #expect(patch[10].oldLineNumber == 3 && patch[11].oldLineNumber == 4 && patch[12].newLineNumber == 4, "fixed patch line numbers")
            #expect(
                patch[10].text == "ctx" && patch[11].text == "old" && patch[12].text == "new" && patch[3].text == "    msg", "prefixes stripped in hunks only")
        }

        private struct Scenario {
            let fixture: FileStatusFixture
            let base: ObjectID
            let lostCommit: ObjectID
            let tagObject: ObjectID
            let blob: ObjectID
        }

        private static func makeScenario() throws -> Scenario {
            let fixture = try FileStatusFixture.make()
            try fixture.write("a.txt", "a\n")
            try fixture.commitAll("base")
            let base = try fixture.head()
            try fixture.write("a.txt", "lost\n")
            try fixture.commitAll("Lost work")
            let lost = try fixture.head()
            try fixture.git(["reset", "-q", "--hard", base.string])
            try fixture.git(["tag", "-a", "release", "-m", "Release notes", base.string])
            let tagObject = try ObjectID.parse(try fixture.git(["rev-parse", "refs/tags/release"]).trimmingCharacters(in: .whitespacesAndNewlines))
            try fixture.git(["tag", "-d", "release"])
            try fixture.write("orphan.sh", "#!/bin/sh\necho lost\n")
            let blob = try ObjectID.parse(try fixture.git(["hash-object", "-w", "orphan.sh"]).trimmingCharacters(in: .whitespacesAndNewlines))
            try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("orphan.sh"))
            return Scenario(fixture: fixture, base: base, lostCommit: lost, tagObject: tagObject, blob: blob)
        }

        @Test("Git layer") private static func testGitLayer() async throws {
            let scenario = try makeScenario()
            let fixture = scenario.fixture
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()

            let result = try await module.checkObjects(LostObjectsOptions()) { _ in }
            #expect(result.succeeded, "fsck succeeded")
            let objects = try await module.lostObjects(fromFsckOutput: result.standardOutputString)
            let commit = objects.first { $0.objectID == scenario.lostCommit }
            #expect(
                commit?.rawType == "dangling commit" && commit?.subject == "Lost work" && commit?.author == "Fixture"
                    && commit?.parent == scenario.base && commit?.date != nil, "dangling commit with metadata")
            let tag = objects.first { $0.objectID == scenario.tagObject }
            #expect(
                tag?.objectType == .tag && tag?.tagName == "release" && tag?.subject == "release:Release notes" && tag?.parent == scenario.base,
                "dangling annotated tag")
            let blob = objects.first { $0.objectID == scenario.blob }
            #expect(blob?.objectType == .blob && blob?.date != nil, "dangling loose blob with its file date")
            let dated = objects.compactMap(\.date)
            #expect(dated == dated.sorted(by: >), "newest first")

            let withReflogs = try await module.lostObjects(
                fromFsckOutput: try await module.checkObjects(LostObjectsOptions(noReflogs: false)) { _ in }.standardOutputString)
            #expect(!withReflogs.contains { $0.objectID == scenario.lostCommit }, "--no-reflogs off keeps reflog commits reachable")

            #expect(
                String(decoding: try await module.showObject(scenario.lostCommit), as: UTF8.self).hasPrefix("commit \(scenario.lostCommit.string)"),
                "show commit")
            #expect(String(decoding: try await module.showObject(scenario.blob), as: UTF8.self) == "#!/bin/sh\necho lost\n", "show blob raw")

            let saved = fixture.root.appendingPathComponent("saved.sh")
            try await module.saveBlob(scenario.blob, to: saved)
            #expect(try Data(contentsOf: saved) == Data("#!/bin/sh\necho lost\n".utf8), "blob saved")
            try fixture.git(["config", "core.autocrlf", "true"])
            try await module.saveBlob(scenario.blob, to: saved)
            #expect(try Data(contentsOf: saved) == Data("#!/bin/sh\r\necho lost\r\n".utf8), "autocrlf converts text")
            let png = fixture.root.appendingPathComponent("image.png")
            try await module.saveBlob(scenario.blob, to: png)
            #expect(try Data(contentsOf: png) == Data("#!/bin/sh\necho lost\n".utf8), "binary file names are not converted")
            try fixture.git(["config", "--unset", "core.autocrlf"])

            _ = try await module.saveLostObjects(LostObjectsOptions()) { _ in }
            #expect(
                FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".git/lost-found/commit/\(scenario.lostCommit.string)").path)
                    && FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".git/lost-found/other/\(scenario.blob.string)").path),
                "lost-found written")

            let pruned = try await module.pruneObjects { _ in }
            #expect(pruned.succeeded, "prune succeeded")
            #expect((try? fixture.git(["cat-file", "-e", scenario.blob.string])) == nil, "dangling blob pruned")
            #expect((try? fixture.git(["cat-file", "-e", scenario.lostCommit.string])) != nil, "reflog commit kept")
        }

        private static func makeDialog(_ module: GitRepositoryModule, calls: Calls, runOperations: Bool = true) -> RecoverLostObjectsWindowController {
            let actions = RecoverLostObjectsWindowController.Actions(
                runProcess: { _, operation in
                    calls.processes += 1
                    guard runOperations else { return false }
                    return (try? await operation { _ in }) ?? false
                },
                createTag: { id, _, finished in
                    calls.tagDialogs.append(id)
                    finished(true)
                },
                createBranch: { id, _, finished in
                    calls.branchDialogs.append(id)
                    finished(false)
                },
                createLightweightTag: { name, id in _ = try await module.createTag(RepositoryCreateTagRequest(name: name, target: id)) },
                deleteTag: { name in _ = try await module.deleteTag(named: name) })
            return RecoverLostObjectsWindowController(source: module, actions: actions, workingDirectory: nil, onClose: { calls.closed += 1 })
        }

        private final class Calls {
            var processes = 0
            var tagDialogs: [ObjectID] = []
            var branchDialogs: [ObjectID] = []
            var closed = 0
        }

        @Test("Dialog") private static func testDialog() async throws {
            let scenario = try makeScenario()
            let fixture = scenario.fixture
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            try fixture.git(["tag", "LOST_FOUND_old", scenario.base.string])

            let calls = Calls()
            let dialog = makeDialog(module, calls: calls)
            dialog.showWindow(nil)
            defer { dialog.window?.close() }
            #expect(
                dialog.showCommitsAndTags.state == .on && dialog.showOtherObjects.state == .off && dialog.noReflogs.state == .on
                    && dialog.unreachable.state == .off && dialog.fullCheck.state == .off, "designer defaults")
            #expect(await dialog.updateLostObjects(), "loaded")
            #expect(calls.processes == 1, "fsck ran in the process dialog")
            #expect(Set(dialog.displayed.map(\.objectID)) == [scenario.lostCommit, scenario.tagObject], "commits and tags shown by default")
            #expect(dialog.table.tableColumn(withIdentifier: .init("author"))?.isHidden == false, "commit columns visible")
            func checkColumnLayout() {
                dialog.window!.layoutIfNeeded()
                dialog.window!.contentView!.layoutSubtreeIfNeeded()
                let visibleColumns = dialog.table.tableColumns.enumerated().filter { !$0.element.isHidden }
                let lastColumn = visibleColumns.last!
                let clipWidth = dialog.table.enclosingScrollView!.contentView.bounds.width
                let lastRect = dialog.table.rect(ofColumn: lastColumn.offset)
                let checkbox = dialog.tableView(dialog.table, viewFor: dialog.table.tableColumn(withIdentifier: .init("check")), row: 0) as! NSButton
                #expect(
                    checkbox.cell!.cellSize.width <= dialog.table.tableColumn(withIdentifier: .init("check"))!.width,
                    "native checkbox fits source-width selection column without clipping")
                #expect(
                    dialog.table.tableColumn(withIdentifier: .init("parent"))!.headerCell.wraps && dialog.table.headerView!.frame.height >= 32,
                    "narrow parent heading retains the source two-line presentation")
                let parentColumn = dialog.table.tableColumn(withIdentifier: .init("parent"))!
                #expect(
                    parentColumn.headerCell.titleRect(forBounds: NSRect(x: 0, y: 0, width: parentColumn.width, height: dialog.table.headerView!.frame.height))
                        .height >= 28, "native header provides a real multiline drawing rect")
                #expect(
                    lastRect.maxX <= clipWidth + 1,
                    "all default commit columns fit actual native viewport, last \(lastRect), clip \(clipWidth), widths \(visibleColumns.map { ($0.element.identifier.rawValue, $0.element.width) })"
                )
                for (id, width) in [("author", CGFloat(150)), ("hash", 60), ("parent", 60)] {
                    #expect(
                        abs(dialog.table.tableColumn(withIdentifier: .init(id))!.width - width) <= 1,
                        "source fixed \(id) width stays \(width), actual \(dialog.table.tableColumn(withIdentifier: .init(id))!.width)")
                }
                for id in ["date", "type"] {
                    let column = dialog.table.tableColumn(withIdentifier: .init(id))!
                    for row in dialog.displayed.indices {
                        let field = dialog.tableView(dialog.table, viewFor: column, row: row) as! NSTextField
                        #expect(column.width >= field.intrinsicContentSize.width, "autosized \(id) retains complete displayed values")
                    }
                }
            }
            checkColumnLayout()

            dialog.showCommitsAndTags.state = .off
            NSApp.sendAction(dialog.showCommitsAndTags.action!, to: dialog.showCommitsAndTags.target, from: dialog.showCommitsAndTags)
            #expect(dialog.showOtherObjects.state == .on && dialog.displayed.map(\.objectID) == [scenario.blob], "blobs only")
            #expect(dialog.table.tableColumn(withIdentifier: .init("author"))?.isHidden == true, "commit columns hidden for blobs")
            try await wait("type detection") { dialog.displayed.first?.rawType == "dangling blob (seemingly: sh)" }
            try await wait("blob preview") { dialog.defaultFileName == "LOST_FOUND_\(scenario.blob.string).sh" }
            var menu = dialog.contextMenu()
            if #available(macOS 27.0, *) {
                #expect(
                    menu.items.count == 6 && menu.items.allSatisfy { $0.preferredImageVisibility == .visible },
                    "all source object action icons visible including disabled actions")
            }
            func item(_ id: String) -> NSMenuItem? { menu.items.first { $0.identifier?.rawValue == "lostObjects.\(id)" } }
            #expect(
                item("saveAs")?.isEnabled == true && item("createTag")?.isEnabled == false && item("createBranch")?.isEnabled == false
                    && item("copyParent")?.isEnabled == false && item("view")?.isEnabled == true, "blob menu")
            dialog.showCommitsAndTags.state = .on
            NSApp.sendAction(dialog.showCommitsAndTags.action!, to: dialog.showCommitsAndTags.target, from: dialog.showCommitsAndTags)
            #expect(dialog.displayed.count == 3, "all types")
            checkColumnLayout()
            let blobRow = dialog.displayed.firstIndex { $0.objectID == scenario.blob }!
            let parentField = dialog.tableView(dialog.table, viewFor: dialog.table.tableColumn(withIdentifier: .init("parent")), row: blobRow) as! NSTextField
            #expect(parentField.stringValue == String(repeating: "0", count: 40), "combined blob row displays the zero parent ObjectId")
            let originalFrame = dialog.window!.frame
            let subjectWidth = dialog.table.tableColumn(withIdentifier: .init("subject"))!.width
            let split = dialog.table.enclosingScrollView!.superview as! NSSplitView
            let originalDivider = split.arrangedSubviews[0].frame.width
            var widerFrame = originalFrame
            widerFrame.size.width += 200
            dialog.window!.setFrame(widerFrame, display: true)
            split.setPosition(originalDivider + 150, ofDividerAt: 0)
            checkColumnLayout()
            #expect(dialog.table.tableColumn(withIdentifier: .init("subject"))!.width > subjectWidth, "Subject consumes extra viewport width on resize")
            dialog.window!.setFrame(originalFrame, display: true)
            split.setPosition(originalDivider, ofDividerAt: 0)
            checkColumnLayout()

            let commitRow = try #require(dialog.displayed.firstIndex { $0.objectID == scenario.lostCommit }, "commit row")
            dialog.table.selectRowIndexes(IndexSet(integer: commitRow), byExtendingSelection: false)
            try await wait("commit preview") { dialog.currentItem?.objectID == scenario.lostCommit && dialog.defaultFileName == "commit.patch" }
            menu = dialog.contextMenu()
            #expect(
                item("createTag")?.isEnabled == true && item("createBranch")?.isEnabled == true && item("copyParent")?.isEnabled == true
                    && item("saveAs")?.isEnabled == false, "commit menu")
            dialog.copyParentClicked()
            #expect(NSPasteboard.general.string(forType: .string) == scenario.base.string, "copy parent hash")
            dialog.copyHashClicked()
            #expect(NSPasteboard.general.string(forType: .string) == scenario.lostCommit.string, "copy object hash")
            dialog.createTagClicked()
            try await wait("rescan after tag") { calls.processes == 2 && !dialog.isBusy }
            #expect(calls.tagDialogs == [scenario.lostCommit], "Create tag on the lost commit")

            dialog.table.selectRowIndexes(IndexSet(integer: dialog.displayed.firstIndex { $0.objectID == scenario.lostCommit }!), byExtendingSelection: false)
            dialog.createBranchClicked()
            #expect(calls.branchDialogs == [scenario.lostCommit] && calls.processes == 2, "cancelled branch does not rescan")
            dialog.viewCurrentItem()
            try await wait("view window") { !dialog.openViewWindows.isEmpty && NSApp.modalWindow === dialog.openViewWindows[0].window }
            let viewer = dialog.openViewWindows[0] as! ReadOnlyTextWindowController
            #expect(
                viewer.window?.title == "View" && viewer.sourceText.hasPrefix("commit \(scenario.lostCommit.string)") && viewer.viewer.onLinePatch == nil,
                "read-only view preserves original object text")
            #expect(
                viewer.viewer.numberOfRows(in: dialog.table) > 0 && viewer.viewer.showsLocalToolbar && viewer.viewer.toolbarMode == .fixedDiff,
                "shared fixed patch viewer")
            #expect(viewer.window!.contentView!.bounds.size == NSSize(width: 733, height: 571), "attaching shared viewer retains upstream client dimensions")
            viewer.window!.cancelOperation(nil)
            try await wait("cancel owned view") { dialog.openViewWindows.isEmpty && NSApp.modalWindow !== viewer.window }
            #expect(dialog.window?.isVisible == true, "cancelling View retains its owner")

            let restoreEmpty = Task { await dialog.restoreSelectedObjects() }
            try await wait("select warning") { dialog.window?.attachedSheet != nil }
            dialog.window!.endSheet(dialog.window!.attachedSheet!)
            await restoreEmpty.value
            #expect(try !fixture.git(["tag", "-l"]).contains("LOST_FOUND_old"), "existing LOST_FOUND tags deleted")

            let rows = dialog.displayed
            dialog.setChecked([scenario.lostCommit, scenario.tagObject])
            let restore = Task { await dialog.restoreSelectedObjects() }
            try await wait("tags created message") { dialog.window?.attachedSheet != nil }
            func texts(_ view: NSView) -> [String] { [(view as? NSTextField)?.stringValue].compactMap { $0 } + view.subviews.flatMap(texts) }
            #expect(
                texts(dialog.window!.attachedSheet!.contentView!).contains("2 Tags created.\n\nDo not forget to delete these tags when finished."),
                "created message")
            dialog.window!.endSheet(dialog.window!.attachedSheet!)
            await restore.value
            let commitIndex =
                rows.filter { [scenario.lostCommit, scenario.tagObject].contains($0.objectID) }.firstIndex { $0.objectID == scenario.lostCommit }! + 1
            #expect(
                try fixture.git(["rev-parse", "LOST_FOUND_\(commitIndex)"]).trimmingCharacters(in: .whitespacesAndNewlines) == scenario.lostCommit.string,
                "numbered commit tag")
            #expect(
                try fixture.git(["rev-parse", "LOST_FOUND_release"]).trimmingCharacters(in: .whitespacesAndNewlines) == scenario.tagObject.string,
                "tag object keeps its name")
            #expect(!dialog.displayed.contains { $0.objectID == scenario.lostCommit } && calls.closed == 0, "restored objects are reachable; the form stays")

            await dialog.deleteLostFoundTags()
            #expect(try !fixture.git(["tag", "-l"]).contains("LOST_FOUND_"), "all LOST_FOUND tags deleted")

            #expect(await dialog.updateLostObjects(), "reloaded")
            dialog.setChecked(Set(dialog.displayed.map(\.objectID)))
            let all = Task { await dialog.restoreSelectedObjects() }
            try await wait("message") { dialog.window?.attachedSheet != nil }
            dialog.window!.endSheet(dialog.window!.attachedSheet!)
            await all.value
            #expect(calls.closed == 1 && dialog.window?.isVisible == false, "everything restored closes the form")

            let abortedCalls = Calls()
            let aborted = makeDialog(module, calls: abortedCalls, runOperations: false)
            aborted.showWindow(nil)
            #expect(await aborted.updateLostObjects() == false && abortedCalls.closed == 1, "aborted fsck closes")
        }

        @Test("Edge repositories") private static func testEdgeRepositories() async throws {

            let empty = try FileStatusFixture.make()
            defer { empty.remove() }
            let emptyModule = GitRepositoryModule(repositoryURL: empty.repo, git: FileStatusFixtureGit())
            _ = try? await emptyModule.loadRepositoryState()
            let emptyResult = try await emptyModule.checkObjects(LostObjectsOptions()) { _ in }
            #expect(try await emptyModule.lostObjects(fromFsckOutput: emptyResult.standardOutputString).isEmpty, "empty repository")

            let scenario = try makeScenario()
            defer { scenario.fixture.remove() }
            let bare = scenario.fixture.root.appendingPathComponent("bare.git", isDirectory: true)
            try scenario.fixture.git(["clone", "-q", "--bare", scenario.fixture.repo.path, bare.path])
            let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
            _ = try await bareModule.loadRepositoryState()
            let bareResult = try await bareModule.checkObjects(LostObjectsOptions(unreachable: true)) { _ in }
            #expect(bareResult.succeeded, "bare fsck")

            let module = GitRepositoryModule(repositoryURL: scenario.fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let tracked = try scenario.fixture.git(["rev-parse", "HEAD:a.txt"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let object = scenario.fixture.repo.appendingPathComponent(".git/objects/\(tracked.prefix(2))/\(tracked.dropFirst(2))")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: object.path)
            try FileManager.default.removeItem(at: object)
            let corrupt = try await module.checkObjects(LostObjectsOptions()) { _ in }
            #expect(!corrupt.succeeded, "fsck reports the corruption")
            let found = try await module.lostObjects(fromFsckOutput: corrupt.standardOutputString)
            #expect(found.contains { $0.objectID.string == tracked && $0.rawType == "missing blob" }, "missing blob listed \(found.map(\.rawType))")
        }

        private static func wait(_ message: @autoclosure () -> String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw TestFailure(description: "RecoverLostObjectsTests: timed out waiting for \(message())") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

    }
}

typealias RecoverLostObjectsTests = UIIntegrationTests.RecoverLostObjectsTests
