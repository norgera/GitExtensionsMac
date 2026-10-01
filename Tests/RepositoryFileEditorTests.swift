@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit


@MainActor
enum RepositoryFileEditorTests {
    static func run() async throws {
        _ = NSApplication.shared
        try await testLocationsAndPreview()
        try testFileIO()
        try await testIgnoreEditor()
        try await testAttributesAndMailMap()
        try await testAddToGitIgnore()
        try await testFileEditor()
        try await testBrowserEntryPoints()
        print("RepositoryFileEditorTests: passed")
    }



    private static func testLocationsAndPreview() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("tracked.log", "t\n")
        try fixture.write("keep.txt", "k\n")
        try fixture.commitAll("base")
        try fixture.write("tracked.log", "changed\n")
        try fixture.write("new.log", "n\n")
        try fixture.write("dir/inner.log", "i\n")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let gitDir = fixture.repo.appendingPathComponent(".git").standardizedFileURL

        await checkAsync(try await module.editableFileURL(.gitIgnore) == fixture.repo.appendingPathComponent(".gitignore"), ".gitignore in the working directory")
        await checkAsync(try await module.editableFileURL(.localExclude) == gitDir.appendingPathComponent("info/exclude"), "exclude under the git directory")
        await checkAsync(try await module.editableFileURL(.gitConfig) == gitDir.appendingPathComponent("config"), "config under the git directory")
        await checkAsync(try await module.editableFileURL(.gitAttributes) == fixture.repo.appendingPathComponent(".gitattributes"), ".gitattributes in the working directory")
        await checkAsync(try await module.editableFileURL(.mailMap) == fixture.repo.appendingPathComponent(".mailmap"), ".mailmap in the working directory")


        let linked = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try fixture.git(["worktree", "add", "-q", linked.path, "-b", "side"])
        let linkedModule = GitRepositoryModule(repositoryURL: linked, git: FileStatusFixtureGit())
        _ = try await linkedModule.loadRepositoryState()
        await checkAsync(try await linkedModule.editableFileURL(.localExclude) == gitDir.appendingPathComponent("info/exclude"), "worktree exclude is the common one")
        await checkAsync(try await linkedModule.editableFileURL(.gitConfig) == gitDir.appendingPathComponent("config"), "worktree config is the common one")
        let linkedIgnore = try await linkedModule.editableFileURL(.gitIgnore)
        check(linkedIgnore.resolvingSymlinksInPath() == linked.appendingPathComponent(".gitignore").resolvingSymlinksInPath(),
              "worktree .gitignore is in its own working directory")


        let bare = fixture.root.appendingPathComponent("bare.git", isDirectory: true)
        try fixture.git(["clone", "-q", "--bare", fixture.repo.path, bare.path])
        let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
        _ = try await bareModule.loadRepositoryState()
        let bareConfig = try await bareModule.editableFileURL(.gitConfig)
        check(bareConfig.resolvingSymlinksInPath() == bare.appendingPathComponent("config").resolvingSymlinksInPath(), "bare config: \(bareConfig.path)")


        check(RepositoryFileEditorCommands.ignoredFiles(["", "  "]) == nil, "blank patterns run no command")
        check(RepositoryFileEditorCommands.ignoredFiles(["*.log", " "])?.arguments == ["ls-files", "-z", "-o", "-m", "-c", "-i", "-x", "*.log"],
              "ls-files arguments")
        let matched = try await module.ignoredFiles(matching: ["*.log"])
        check(Set(matched) == ["tracked.log", "new.log", "dir/inner.log"] && matched.count == 3, "ignored preview: \(matched)")
        await checkAsync(try await module.ignoredFiles(matching: ["/dir/"]) == ["dir/inner.log"], "folder pattern preview")
        await checkAsync(try await module.ignoredFiles(matching: ["*.none"]).isEmpty, "no match")
        await checkAsync(try await module.ignoredFiles(matching: []).isEmpty, "no pattern")
    }

    private static func testFileIO() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Editors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")

        let missing = try EditableFileIO.load(file, configuredEncoding: nil)
        check(!missing.exists && missing.text.isEmpty && missing.encoding == .utf8, "missing file loads empty")

        try Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb".utf8)).write(to: file)
        let bom = try EditableFileIO.load(file, configuredEncoding: nil)
        check(bom.text == "a\r\nb" && bom.preamble == [0xEF, 0xBB, 0xBF], "BOM detected and CR LF kept")


        try EditableFileIO.saveInPlace("x\r\n", to: file, encoding: bom.encoding, preamble: bom.preamble)
        check(try Data(contentsOf: file) == Data([0xEF, 0xBB, 0xBF] + Array("x\r\n".utf8)), "in-place save keeps BOM and CR LF")
        do {
            try EditableFileIO.saveInPlace("x", to: root.appendingPathComponent("absent"), encoding: .utf8, preamble: [])
            check(false, "saving a missing file fails")
        } catch {}
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path), "FormEditor does not create files")


        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: file)
        let latin = try EditableFileIO.load(file, configuredEncoding: .westernISO88591)
        check(latin.text == "café" && latin.preamble.isEmpty, "configured encoding decodes")
        try EditableFileIO.saveInPlace("café!", to: file, encoding: latin.encoding, preamble: [])
        check(try Data(contentsOf: file) == Data([0x63, 0x61, 0x66, 0xE9, 0x21]), "configured encoding encodes")
        let utf16 = try Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!
        try utf16.write(to: file)
        let wide = try EditableFileIO.load(file, configuredEncoding: nil)
        check(wide.text == "hi" && wide.encoding == .utf16LittleEndian && wide.preamble == [0xFF, 0xFE], "UTF-16 BOM")


        let exclude = root.appendingPathComponent("info/exclude")
        try EditableFileIO.saveWithTrailingNewline("a", to: exclude, createDirectory: true)
        check(try String(contentsOf: exclude, encoding: .utf8) == "a\n", "trailing newline added, info/ created")
        try EditableFileIO.saveWithTrailingNewline("b\n", to: exclude, createDirectory: true)
        check(try String(contentsOf: exclude, encoding: .utf8) == "b\n", "existing trailing newline kept")
        do {
            try EditableFileIO.saveWithTrailingNewline("a", to: root.appendingPathComponent("nodir/file"), createDirectory: false)
            check(false, "no directory is created for attributes/mailmap")
        } catch {}


        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: exclude.path)
        try EditableFileIO.saveWithTrailingNewline("c", to: exclude, createDirectory: true)
        let permissions = (try FileManager.default.attributesOfItem(atPath: exclude.path)[.posixPermissions] as? NSNumber)?.int16Value
        check(try String(contentsOf: exclude, encoding: .utf8) == "c\n" && permissions == 0o444, "read-only file written, permissions restored")
        try EditableFileIO.appendPatterns(["d"], to: exclude)
        check(try String(contentsOf: exclude, encoding: .utf8) == "c\nd\n", "append after newline")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exclude.path)


        let ignore = root.appendingPathComponent(".gitignore")
        try Data("x".utf8).write(to: ignore)
        try EditableFileIO.appendPatterns(["/a", " "], to: ignore)
        check(try String(contentsOf: ignore, encoding: .utf8) == "x\n/a\n \n", "append separates and writes each pattern")
        try Data().write(to: ignore)
        try EditableFileIO.appendPatterns(["/b"], to: ignore)
        check(try String(contentsOf: ignore, encoding: .utf8) == "\n/b\n", "empty file gets the separator (ReadAllText is not newline-terminated)")
        let created = root.appendingPathComponent("new/info/exclude")
        try EditableFileIO.appendPatterns(["/c"], to: created)
        check(try String(contentsOf: created, encoding: .utf8) == "/c\n", "missing file and directory are created")
    }



    private static func testIgnoreEditor() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n")
        try fixture.commitAll("base")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()


        var closed = false
        let editor = RepositoryFileEditorWindowController(kind: .gitIgnore, source: module, onClose: { closed = true })
        await editor.load()
        check(editor.window?.title == "Edit .gitignore" && editor.editor.text.isEmpty && !editor.hasUnsavedChanges, "missing .gitignore loads empty")
        await checkAsync(await editor.save() == false, "unchanged .gitignore is not written")
        check(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".gitignore").path), "no file created without changes")


        editor.editor.text = "*.log\nThumbs.db"
        editor.addDefaultIgnores()
        let lines = editor.editor.text.components(separatedBy: "\n")
        check(lines.filter { $0 == "*.log" }.count == 1 && lines.filter { $0 == "Thumbs.db" }.count == 1 && lines.contains("packages/"),
              "default ignores are merged without duplicates")
        check(editor.editor.text.hasSuffix("packages/\n") && editor.hasUnsavedChanges, "defaults appended as an unsaved change")
        let text = editor.editor.text
        await checkAsync(await editor.save(), "changed .gitignore is saved")
        check(try fixture.read(".gitignore") == text && !editor.hasUnsavedChanges, "saved exactly with its final newline")
        editor.addDefaultIgnores()
        check(editor.editor.text == text, "no duplicate defaults when all are present")


        try fixture.write("build.log", "x\n")
        check(try fixture.git(["status", "--porcelain"]).contains("build.log") == false, "saved .gitignore takes effect")
        editor.showWindow(nil)
        editor.window?.performClose(nil)
        check(closed && editor.window?.isVisible == false, "unchanged editor closes")


        var patternParent: NSWindow?
        let withPattern = RepositoryFileEditorWindowController(kind: .gitIgnore, source: module, addPattern: { window in
            patternParent = window
            try? EditableFileIO.appendPatterns(["*.dll"], to: fixture.repo.appendingPathComponent(".gitignore"))
        }, onClose: {})
        await withPattern.load()
        withPattern.editor.replaceAll(with: withPattern.editor.text + "extra")
        withPattern.addPatternClicked()
        try await wait("pattern added and reloaded") { withPattern.editor.text.hasSuffix("extra\n*.dll\n") }
        check(patternParent === withPattern.window && !withPattern.hasUnsavedChanges, "Add pattern saves, opens over the editor and reloads")


        let infoDir = fixture.repo.appendingPathComponent(".git/info")
        try? FileManager.default.removeItem(at: infoDir)
        let exclude = RepositoryFileEditorWindowController(kind: .localExclude, source: module, onClose: {})
        await exclude.load()
        check(exclude.window?.title == "Edit .git/info/exclude" && exclude.editor.text.isEmpty, "exclude editor")
        exclude.editor.replaceAll(with: "local.tmp")
        await checkAsync(await exclude.save(), "exclude saved")
        check(try fixture.read(".git/info/exclude") == "local.tmp\n", "exclude written with newline, info/ created")
        try fixture.write("local.tmp", "x\n")
        check(!(try fixture.git(["status", "--porcelain"])).contains("local.tmp"), "saved exclude takes effect")


        exclude.showWindow(nil)
        exclude.editor.replaceAll(with: "changed")
        check(exclude.windowShouldClose(exclude.window!) == false, "unsaved changes block the close for the prompt")
        try await wait("save prompt") { exclude.window?.attachedSheet != nil }
        if let sheet = exclude.window?.attachedSheet { exclude.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        try await wait("No closes without saving") { exclude.window?.isVisible == false }
        check(try fixture.read(".git/info/exclude") == "local.tmp\n", "No discards the change")
    }

    private static func testAttributesAndMailMap() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n")
        try fixture.commitAll("base")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()

        let attributes = RepositoryFileEditorWindowController(kind: .gitAttributes, source: module, onClose: {})
        await attributes.load()
        check(attributes.window?.title == "Edit .gitattributes", "attributes title")

        await checkAsync(await attributes.save(), "attributes saved")
        check(try fixture.read(".gitattributes") == "\n", "unchanged missing attributes file is written")
        attributes.editor.replaceAll(with: "*.jpg binary")
        await checkAsync(await attributes.save(), "attributes saved again")
        check(try fixture.read(".gitattributes") == "*.jpg binary\n", "attributes content")
        check(try fixture.git(["check-attr", "binary", "--", "x.jpg"]).contains("binary: set"), "git applies the attributes")

        var notified = 0
        try fixture.write(".mailmap", "Old <old@example.com>\r\n")
        let mailMap = RepositoryFileEditorWindowController(kind: .mailMap, source: module, onSaved: { notified += 1 }, onClose: {})
        await mailMap.load()
        check(mailMap.editor.text == "Old <old@example.com>\r\n" && !mailMap.hasUnsavedChanges, "mailmap loaded with CR LF")
        mailMap.editor.replaceAll(with: "Fixture Person <fixture@example.com>")
        await checkAsync(await mailMap.save() && notified == 1, "mailmap save notifies repository change")
        check(try fixture.read(".mailmap") == "Fixture Person <fixture@example.com>\n", "mailmap content")
        check(try fixture.git(["log", "-1", "--format=%aN"]).trimmingCharacters(in: .whitespacesAndNewlines) == "Fixture Person", "git applies the mailmap")
    }

    private static func testAddToGitIgnore() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n")
        try fixture.commitAll("base")
        try fixture.write("build/out.o", "o\n")
        try fixture.write(".gitignore", "*.tmp")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }

        let dialog = AddToGitIgnoreWindowController(source: module, localExclude: false, patterns: ["/build/"])
        check(dialog.window?.title == "Add file(s) to .gitignore" && dialog.countLabel.stringValue == "Updating ..." && !dialog.isPreviewEnabled,
              "preview starts updating")
        var finished = false
        Task { @MainActor in await dialog.run(parent: parent); finished = true }
        try await wait("preview") { dialog.isPreviewEnabled }
        check(dialog.previewItems == ["build/out.o"] && dialog.countLabel.stringValue == "1 file(s) matched" && dialog.noMatchPanel.isHidden,
              "matched preview: \(dialog.previewItems)")
        dialog.patternView.replaceAll(with: "/nothing/")
        check(!dialog.isPreviewEnabled && dialog.countLabel.stringValue == "Updating ...", "typing shows Updating ...")
        try await wait("no-match preview") { dialog.isPreviewEnabled }
        check(dialog.previewItems.isEmpty && dialog.countLabel.stringValue == "0 file(s) matched" && !dialog.noMatchPanel.isHidden, "no-match panel")
        dialog.patternView.replaceAll(with: "/build/\n\n*.bak")
        dialog.ignoreClicked()
        try await wait("dialog closed") { finished }
        check(try fixture.read(".gitignore") == "*.tmp\n/build/\n*.bak\n", "patterns appended after a separator")
        check(!(try fixture.git(["status", "--porcelain", "--untracked-files=all"])).contains("build/"), "git ignores the folder")

        let local = AddToGitIgnoreWindowController(source: module, localExclude: true, patterns: ["/a.txt"])
        check(local.window?.title == "Add file(s) to .git/info/exclude", "exclude title")
        finished = false
        Task { @MainActor in await local.run(parent: parent); finished = true }
        try await wait("exclude sheet") { parent.attachedSheet === local.window }
        local.finish()
        try await wait("cancelled") { finished }
        check((try? fixture.read(".git/info/exclude"))?.contains("/a.txt") != true, "Cancel writes nothing")
    }

    private static func testFileEditor() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "one\ntwo\nthree\n")
        try fixture.commitAll("base")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        _ = try await module.loadRepositoryState()

        let config = try await module.editableFileURL(.gitConfig)
        let editor = FileEditorWindowController(fileURL: config, source: module, showWarning: true, onClose: {})
        try await editor.load()
        func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
        let views = subviews(editor.window!.contentView!)
        let save = views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "FileEditor.Save" }
        check(editor.window?.title == config.path && views.contains { $0.accessibilityIdentifier() == "FileEditor.Warning" }, "config editor with warning")
        check(editor.editor.text.contains("[core]") && !editor.hasChanges && save?.isEnabled == false, "config loaded, Save disabled")
        editor.editor.replaceAll(with: editor.editor.text + "[fixture]\n\tkey = value\n")
        check(editor.hasChanges && save?.isEnabled == true, "edit enables Save")
        try editor.saveChanges()
        check(try !editor.hasChanges && fixture.git(["config", "fixture.key"]).trimmingCharacters(in: .whitespacesAndNewlines) == "value", "config saved")


        let file = FileEditorWindowController(fileURL: fixture.repo.appendingPathComponent("a.txt"), source: module, showWarning: false, lineNumber: 3, onClose: {})
        try await file.load()
        check(!subviews(file.window!.contentView!).contains { $0.accessibilityIdentifier() == "FileEditor.Warning" }, "no warning for a working file")
        check(file.editor.textView.selectedRange().location == ("one\ntwo\n" as NSString).length, "caret on the requested line")
        file.showWindow(nil)
        file.editor.replaceAll(with: "changed\n")
        check(file.windowShouldClose(file.window!) == false, "unsaved edit prompts")
        try await wait("save prompt") { file.window?.attachedSheet != nil }
        if let sheet = file.window?.attachedSheet { file.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        try await wait("Yes saves and closes") { file.window?.isVisible == false }
        check(try fixture.read("a.txt") == "changed\n", "Yes saved the file")
    }

    private static func testBrowserEntryPoints() async throws {
        let fixture = try FileStatusFixture.make()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n")
        try fixture.commitAll("base")
        try fixture.write("new.txt", "n\n")
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
        let browser = RepositoryBrowserViewController(repositoryModule: module)
        let window = NSWindow(contentViewController: browser)
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await wait("browser loaded") { browser.repositoryIdentity != nil && browser.revisions.contains { !$0.isArtificial } }

        for (command, key, title) in [(BrowserCommand.editGitIgnore, "repository:.gitignore", "Edit .gitignore"),
                                      (.editGitInfoExclude, "repository:.git/info/exclude", "Edit .git/info/exclude"),
                                      (.editGitAttributes, "repository:.gitattributes", "Edit .gitattributes"),
                                      (.editMailMap, "repository:.mailmap", "Edit .mailmap")] {
            browser.performTopLevelCommand(command)
            try await wait(title) { browser.uiCommands.fileEditorWindows[key]?.window?.isVisible == true }
            let controller = browser.uiCommands.fileEditorWindows[key]!
            check(controller.window?.title == title, "\(title) window")
            browser.performTopLevelCommand(command)
            check(browser.uiCommands.fileEditorWindows.count == 1, "\(title): a second request focuses the open editor")
            controller.window?.performClose(nil)
            try await wait("\(title) closed") { browser.uiCommands.fileEditorWindows[key] == nil }
        }
        browser.performTopLevelCommand(.editGitConfig)
        let configKey = "file:" + fixture.repo.appendingPathComponent(".git/config").standardizedFileURL.path
        try await wait("config editor") { browser.uiCommands.fileEditorWindows[configKey]?.window?.isVisible == true }
        browser.uiCommands.fileEditorWindows[configKey]?.window?.performClose(nil)
        try await wait("config editor closed") { browser.uiCommands.fileEditorWindows.isEmpty }


        let item = FileStatusListItem(
            group: FileStatusGroup(first: .index, second: .workingDirectory, summary: "", files: []),
            file: ChangedFile(id: "new.txt", path: "new.txt", oldPath: nil, changeType: .added, additions: 1, deletions: 0))
        browser.uiCommands.performFileStatusCommand(FileStatusListCommand(identifier: "file.ignore.gitignore", items: [item], folder: nil,
                                                                          tool: nil, focused: nil, remembered: nil))
        try await wait("Add to .gitignore sheet") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let add = sheet.windowController as? AddToGitIgnoreWindowController
        check(add?.patternView.text == "/new.txt", "pattern for the selected file: \(add?.patternView.text ?? "nil")")
        add?.ignoreClicked()
        try await wait("appended") { (try? fixture.read(".gitignore")) == "/new.txt\n" }


        let bare = fixture.root.appendingPathComponent("bare.git", isDirectory: true)
        try fixture.git(["clone", "-q", "--bare", fixture.repo.path, bare.path])
        let bareBrowser = RepositoryBrowserViewController(repositoryModule: GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit()))
        let bareWindow = NSWindow(contentViewController: bareBrowser)
        bareWindow.makeKeyAndOrderFront(nil)
        defer { bareWindow.close() }
        try await wait("bare loaded") { bareBrowser.repositoryIdentity != nil }
        bareBrowser.performTopLevelCommand(.editGitInfoExclude)
        try await wait("no working directory") { bareWindow.attachedSheet != nil }
        let alert = bareWindow.attachedSheet!
        check(subviews(alert.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains(".git/info/exclude is only supported when there is a working directory."),
              "bare message")
        bareWindow.endSheet(alert)
        check(bareBrowser.uiCommands.fileEditorWindows.isEmpty, "no editor for a bare repository")
    }

    private static func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }

    private static func wait(_ message: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { preconditionFailure("RepositoryFileEditorTests: timed out waiting for \(message())") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? condition()) == true else { preconditionFailure("RepositoryFileEditorTests: \(message)") }
    }

    private static func checkAsync(_ condition: @autoclosure () async throws -> Bool, _ message: String) async {
        guard (try? await condition()) == true else { preconditionFailure("RepositoryFileEditorTests: \(message)") }
    }
}
