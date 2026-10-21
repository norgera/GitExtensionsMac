import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Dialog behavior")
    enum DialogBehaviorTests {
        @Test("Large file deletion decline") static func testLargeFileDeletionDecline() throws {
            let host = GitExtensionPluginHost(refresh: {}, navigate: { _ in }, readSetting: { _, _ in nil }, writeSetting: { _, _, _ in })
            let plugin = try #require(BuiltInPlugins.make().first { $0.kind == .largeFiles }, "large-file plugin")
            let controller = try BuiltInPluginDialog(plugin: plugin, host: host)
            controller.showWindow(nil)
            defer { controller.close() }
            let delete = try #require(
                allSubviews(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Delete" }, "large-file Delete")
            var acknowledged = false
            var exactPrompt = false
            let deadline = Date().addingTimeInterval(5)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let alert = NSApp.modalWindow else { return }
                    if Date() >= deadline {
                        NSApp.abortModal()
                        timer.invalidate()
                        return
                    }
                    let fields = allSubviews(alert.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
                    let buttons = allSubviews(alert.contentView!).compactMap { $0 as? NSButton }
                    guard let no = buttons.first(where: { $0.title == "No" }), let yes = buttons.first(where: { $0.title == "Yes" }) else { return }
                    exactPrompt =
                        fields.contains("Are you sure to delete the selected files?") && (alert.defaultButtonCell === yes.cell || yes.keyEquivalent == "\r")
                    acknowledged = true
                    no.performClick(nil)
                    timer.invalidate()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            delete.performClick(nil)
            try #require(
                acknowledged && exactPrompt && controller.window?.isVisible == false,
                "No acknowledges exact Yes-default confirmation and closes large-file dialog")
        }

        @Test("Empty submodule dialogs") static func testEmptySubmoduleDialogs() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try fixture.git(["commit", "--allow-empty", "-q", "-m", "base"])
            _ = try await module.loadRepositoryState()
            let before = try fixture.git(["status", "--porcelain=v2"])
            let context = try await module.loadSubmoduleContext()
            try #require(context.submodules.isEmpty, "real empty manager fixture")
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            var changed = false
            var pulledCurrent = false
            let manager = SubmoduleDialogs.manage(
                source: module, owner: owner, changed: { changed = true }, open: { _, _ in Issue.record("empty selection cannot open a submodule") },
                pullRepository: { pulledCurrent = true }, closed: {})
            defer { manager.close() }
            let window = manager.window!
            let buttons = allSubviews(window.contentView!).compactMap { $0 as? NSButton }
            for title in ["Update", "Synchronize", "Remove", "Pull"] {
                try #require(buttons.first { $0.title == title }?.isEnabled == true, Comment(rawValue: "empty manager retains enabled source action " + title))
            }
            buttons.first { $0.title == "Remove" }!.performClick(nil)
            try #require(window.attachedSheet == nil && !changed, "empty Remove is a no-op")
            buttons.first { $0.title == "Pull" }!.performClick(nil)
            try #require(pulledCurrent && !changed, "empty Pull routes to current repository workflow")
            manager.close()
            let add = Task { await SubmoduleDialogs.add(source: module, owner: owner, changed: { changed = true }) }
            try await RepositoryWorkflowTests.waitUntil("Add submodule sheet") { owner.attachedSheet != nil }
            let panel = owner.attachedSheet!
            let combos = allSubviews(panel.contentView!).compactMap { $0 as? NSComboBox }
            combos.first!.stringValue = ""
            let path = try #require(
                allSubviews(panel.contentView!).compactMap { $0 as? NSTextField }.first { !($0 is NSComboBox) && $0.isEditable }, "local submodule path")
            path.stringValue = ""
            let accept = try #require(allSubviews(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Add" }, "Add action")
            accept.performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("missing paths acknowledged modally") { panel.attachedSheet != nil }
            let alert = panel.attachedSheet!
            let fields = allSubviews(alert.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
            try #require(
                fields.contains("Add submodule") && fields.contains("A remote path and local path are required"),
                "exact pinned Add validation caption and message")
            allSubviews(alert.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("Add validation dismissed") { panel.attachedSheet == nil }
            try #require(
                panel.isVisible && owner.attachedSheet === panel && path.stringValue.isEmpty && combos.first!.stringValue.isEmpty && !changed,
                "Add acknowledgement preserves empty draft without Git mutation")
            allSubviews(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            await add.value
            let after = try fixture.git(["status", "--porcelain=v2"])
            try #require(before == after && !changed, "inspection leaves real index/worktree unchanged")
        }

        @Test("Creation dialog validation") static func testCreationDialogValidation() async throws {
            let store = AppSettingsStore.shared
            let saved = store.repositoryCreationPreferences
            defer { store.saveRepositoryCreationPreferences(saved) }
            var preferences = saved
            preferences.cloneDestinationPath = ""
            store.saveRepositoryCreationPreferences(preferences)
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let creator = GitRepositoryCreator(git: FileStatusFixtureGit())
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            var created = false
            func button(_ window: NSWindow, _ title: String) throws -> NSButton {
                try #require(allSubviews(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }, Comment(rawValue: title))
            }
            func acknowledge(_ panel: NSWindow, caption: String, message: String) async throws {
                try await RepositoryWorkflowTests.waitUntil("native validation sheet") { panel.attachedSheet != nil }
                let alert = panel.attachedSheet!
                let strings = allSubviews(alert.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
                try #require(strings.contains(caption) && strings.contains(message), "exact upstream validation caption/message: \(strings)")
                try button(alert, "OK").performClick(nil)
                try await RepositoryWorkflowTests.waitUntil("validation acknowledgement") { panel.attachedSheet == nil }
                try #require(panel.isVisible && owner.attachedSheet === panel && !created, "validation retains draft and never invokes creation")
            }
            GitUICommands.startCloneRepository(source: creator, owner: owner) { _ in created = true }
            let clone = try #require(owner.attachedSheet, "normal Clone entry point")
            let combos = allSubviews(clone.contentView!).compactMap { $0 as? NSComboBox }
            let source = combos[0]
            let destination = combos[1]
            let branch = combos[2]
            let subdirectory = try #require(
                allSubviews(clone.contentView!).compactMap { $0 as? NSTextField }.first { !($0 is NSComboBox) && $0.isEditable }, "subdirectory")
            let primary = try button(clone, "Clone")
            try #require(
                primary.isEnabled && (primary.keyEquivalent == "\r" || clone.defaultButtonCell === primary.cell) && destination.stringValue.isEmpty,
                "blank destination preserves enabled native default Clone")
            source.stringValue = ""
            primary.performClick(nil)
            try await acknowledge(clone, caption: "Clone Failed", message: "You need to specify destination folder.")
            destination.stringValue = "relative/path"
            primary.performClick(nil)
            try await acknowledge(clone, caption: "Clone Failed", message: "Destination folder must be an absolute path.")
            try #require(destination.stringValue == "relative/path", "invalid destination remains editable")
            let type = try #require(
                allSubviews(clone.contentView!).compactMap { $0 as? NSBox }.first { $0.title == "Repository type" }, "source repository-type group")
            let personal = try button(clone, "Personal repository")
            let bare = try button(clone, "Public repository, no working directory (--bare)")
            let recursive = try button(clone, "Initialize all submodules")
            let full = try button(clone, "Download full history")
            try #require(
                type.isDescendant(of: clone.contentView!) && personal.isDescendant(of: type) && bare.isDescendant(of: type),
                "repository kind controls belong to source group")
            clone.contentView!.layoutSubtreeIfNeeded()
            let typeRect = type.convert(type.bounds, to: clone.contentView)
            let recursiveRect = recursive.convert(recursive.bounds, to: clone.contentView)
            let fullRect = full.convert(full.bounds, to: clone.contentView)
            try #require(
                typeRect.minY >= recursiveRect.maxY && abs(recursiveRect.midY - fullRect.midY) < 1 && recursiveRect.maxX <= fullRect.minX,
                "repository type precedes horizontal submodule/full-history options")
            try #require(personal.state == .on && bare.state == .off && full.state == .on, "source Clone defaults")
            subdirectory.stringValue = "manual-name"
            source.stringValue = "https://example.invalid/new-source.git"
            source.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: source))
            try #require(subdirectory.stringValue == "new-source" && branch.indexOfSelectedItem == 0, "source edits recalculate manual name and reset branch")
            subdirectory.stringValue = "keep-on-empty"
            source.stringValue = ""
            source.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: source))
            try #require(subdirectory.stringValue == "keep-on-empty", "empty repository-name result preserves prior subdirectory upstream")
            source.addItem(withObjectValue: "https://example.invalid/history-choice.git")
            source.selectItem(withObjectValue: "https://example.invalid/history-choice.git")
            source.delegate?.comboBoxSelectionDidChange?(Notification(name: NSComboBox.selectionDidChangeNotification, object: source))
            try #require(subdirectory.stringValue == "history-choice", "history selection follows source text workflow")
            try button(clone, "Cancel").performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("Clone cancelled") { owner.attachedSheet == nil }
            GitUICommands.startInitializeRepository(source: creator, owner: owner) { _ in created = true }
            let initialize = try #require(owner.attachedSheet, "normal Initialize entry point")
            let directory = try #require(allSubviews(initialize.contentView!).compactMap { $0 as? NSComboBox }.first, "Initialize directory")
            let create = try button(initialize, "Create")
            try #require(
                directory.stringValue.isEmpty && create.isEnabled && (create.keyEquivalent == "\r" || initialize.defaultButtonCell === create.cell),
                "blank Init retains enabled default Create")
            for value in ["", "   ", "relative/path"] {
                directory.stringValue = value
                create.performClick(nil)
                try await acknowledge(initialize, caption: "Choose directory", message: "Please choose a directory.")
                try #require(directory.stringValue == value && create.isEnabled, "Initialize validation preserves input and enabled command")
            }
            let file = fixture.repo.appendingPathComponent("existing-file.txt")
            try Data("unchanged\n".utf8).write(to: file)
            directory.stringValue = file.path
            create.performClick(nil)
            try await acknowledge(initialize, caption: "Error", message: "Cannot initialize a new repository on a file.\nPlease choose a directory.")
            let unchanged = try Data(contentsOf: file)
            try #require(unchanged == Data("unchanged\n".utf8), "existing file remains byte-identical")
            try button(initialize, "Cancel").performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("Initialize cancelled") { owner.attachedSheet == nil }
            preferences.cloneDestinationPath = "/saved/parent"
            store.saveRepositoryCreationPreferences(preferences)
            GitUICommands.startInitializeRepository(source: creator, owner: owner, initialDirectory: fixture.repo) { _ in created = true }
            let supplied = try #require(owner.attachedSheet, "supplied Initialize path")
            let suppliedPath = allSubviews(supplied.contentView!).compactMap { $0 as? NSComboBox }.first!
            try #require(suppliedPath.stringValue == fixture.repo.path, "explicit/current repository directory takes precedence over saved default")
            try button(supplied, "Cancel").performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("supplied Initialize cancelled") { owner.attachedSheet == nil }
        }

        @Test("Filter toolbar sizing") static func testFilterToolbarSizing() throws {
            func filtersWithBundledIcon() throws -> RevisionFilterToolbar {
                let filters = RevisionFilterToolbar()
                let resource = TestResources.images.appendingPathComponent("EditFilter.png")
                let image = try #require(NSImage(contentsOf: resource), "type dropdown's real bundled icon is available to the CLI test fixture")
                image.size = NSSize(width: 16, height: 16)
                for button in [filters.branchType, filters.filterType] {
                    button.item(at: 0)?.image = image
                    button.image = image
                }
                return filters
            }
            func host(_ row: NSStackView) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                row.translatesAutoresizingMaskIntoConstraints = false
                window.contentView!.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 6),
                    row.trailingAnchor.constraint(lessThanOrEqualTo: window.contentView!.trailingAnchor, constant: -6),
                    row.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
                ])
                window.contentView!.layoutSubtreeIfNeeded()
                return window
            }
            func checkButtonLayout(_ buttons: [NSPopUpButton], row: NSStackView) throws {
                for button in buttons {
                    let nativeWidth = max(button.intrinsicContentSize.width, button.cell?.cellSize.width ?? 0)
                    try #require(button.frame.width >= nativeWidth - 1, "image/arrow bezel has its full native width \(button.frame.width) >= \(nativeWidth)")
                    try #require(button.frame.height >= button.intrinsicContentSize.height - 1, "type dropdown fits native vertical bezel")
                    let position = row.arrangedSubviews.firstIndex(of: button)!
                    if position + 1 < row.arrangedSubviews.count {
                        let next = row.arrangedSubviews[position + 1]
                        try #require(button.frame.maxX <= next.frame.minX, "type dropdown never overlaps its following control")
                    }
                    try #require(
                        button.imagePosition == .imageLeading && button.title.isEmpty && button.image != nil && !(button.toolTip ?? "").isEmpty,
                        "image type dropdown keeps its icon leading its arrow slot, with no caption, and its tooltip")
                }
            }
            let filters = try filtersWithBundledIcon()
            let row = NSStackView(views: filters.views)
            row.spacing = 4
            let window = host(row)
            defer { window.close() }
            try checkButtonLayout([filters.branchType, filters.filterType], row: row)
            try #require(
                filters.branchType.itemArray.dropFirst().map(\.title) == ["Local", "Remote", "Tag"]
                    && filters.filterType.itemArray.dropFirst().map(\.title) == ["Commit message", "Committer", "Author", "Diff contains (SLOW)"],
                "type menu contents/order remain source-defined")
            let overflowFilters = try filtersWithBundledIcon()
            let branchGroup = NSStackView(views: overflowFilters.overflowGroups[3])
            branchGroup.spacing = 4
            let branchWindow = host(branchGroup)
            defer { branchWindow.close() }
            try checkButtonLayout([overflowFilters.branchType], row: branchGroup)
            let textGroup = NSStackView(views: overflowFilters.overflowGroups[4])
            textGroup.spacing = 4
            let textWindow = host(textGroup)
            defer { textWindow.close() }
            try checkButtonLayout([overflowFilters.filterType], row: textGroup)
        }

        @Test("Shell providers") static func testShellProviders() async throws {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let applications = [
                "com.apple.Terminal": URL(fileURLWithPath: "/Applications/Terminal.app"),
                "com.googlecode.iterm2": URL(fileURLWithPath: "/Applications/iTerm.app"),
            ]
            var installed = applications
            var launches: [(URL, URL)] = []
            let provider = NativeShellProvider(resolve: { installed[$0] }, launch: { launches.append(($0, $1)) })
            try #require(
                provider.available.map(\.id) == ["terminal", "iterm2"] && provider.preferred("ITERM2")?.id == "iterm2",
                "available providers preserve fixed source ordering and case-insensitive default")
            try #require(provider.preferred("removed")?.id == "terminal", "missing configured provider falls back to first available")
            let directory = URL(fileURLWithPath: "/tmp/nested repository/é space/仓库", isDirectory: true)
            try await provider.open(provider.available[1], directory: directory)
            try #require(
                launches.last?.0 == applications["com.googlecode.iterm2"] && launches.last?.1 == directory,
                "native launcher preserves complete folder URL with spaces/Unicode without shell quoting")
            installed.removeValue(forKey: "com.googlecode.iterm2")
            provider.refresh()
            try #require(
                provider.available.map(\.id) == ["terminal"] && provider.preferred("iterm2")?.id == "terminal",
                "unavailable executable excluded from toolbar choices/default fallback")
            let selection = NativeShellSettingsControl(
                provider: provider, selected: "terminal", changed: { _ in Issue.record("unavailable shell must not update Settings draft") })
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.contentView!.addSubview(selection)
            selection.frame = NSRect(x: 20, y: 20, width: 180, height: 30)
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            selection.selectItem(at: 1)
            RepositoryWorkflowTests.click(selection)
            try await RepositoryWorkflowTests.waitUntil("unavailable shell error") { owner.attachedSheet != nil }
            try #require(selection.titleOfSelectedItem == "Terminal", "Settings rejects unavailable provider and restores previous selection")
            try #require(
                descendants(owner.attachedSheet!.contentView!).compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue == "The selected shell is not installed, or is not on your path."
                }, "source missing-shell error wording")
            descendants(owner.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("missing shell acknowledged") { owner.attachedSheet == nil }

            let store = AppSettingsStore.shared
            let saved = store.preferences
            defer { store.save(saved) }
            var preferences = saved
            preferences.defaultShell = "iterm2"
            store.save(preferences)
            installed = applications
            provider.refresh()
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("file", "base")
            try fixture.commitAll("base")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let browser = RepositoryBrowserViewController(repositoryModule: module)
            browser.shellProvider = provider
            let window = NSWindow(contentViewController: browser)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await RepositoryWorkflowTests.waitUntil("shell Browse repository loaded") { browser.repositoryIdentity != nil }
            try #require(
                browser.shellPopUp.itemArray.dropFirst().map(\.title) == ["Terminal", "iTerm2"] && browser.shellPopUp.toolTip == "iTerm2",
                "native split dropdown lists available providers and configured primary caption")
            let start = launches.count
            browser.shellPopUp.onPrimaryClick?()
            try await RepositoryWorkflowTests.waitUntil("primary shell consumer") { launches.count == start + 1 }
            try #require(
                launches.last?.0 == applications["com.googlecode.iterm2"] && launches.last?.1.path == browser.repositoryIdentity?.currentRepository.path,
                "actual primary workflow consumes persisted default and repository directory")
            browser.shellPopUp.selectItem(at: 1)
            RepositoryWorkflowTests.click(browser.shellPopUp)
            try await RepositoryWorkflowTests.waitUntil("one-shot dropdown shell") { launches.count == start + 2 }
            try #require(
                launches.last?.0 == applications["com.apple.Terminal"] && store.preferences.defaultShell == "iterm2" && browser.shellPopUp.toolTip == "iTerm2",
                "dropdown launches selected shell without changing configured default")
            installed.removeAll()
            preferences.defaultShell = "removed"
            store.save(preferences)
            try #require(browser.shellPopUp.isHidden && !browser.shellPopUp.isEnabled, "no available provider hides/disables shell control")
            let noShellCount = launches.count
            browser.uiCommands.openTerminal()
            try await Task.sleep(for: .milliseconds(30))
            try #require(launches.count == noShellCount, "no unavailable shell launch")

            let suite = "GitExtensionsMac.NativeShellSettings.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let isolated = AppSettingsStore(defaults: defaults)
            var original = isolated.preferences
            original.defaultShell = "iterm2"
            isolated.save(original)
            func settings() -> (SettingsViewController, NSWindow, NativeShellSettingsControl) {
                let controller = SettingsViewController(store: isolated, source: nil, initialPage: "browse", repositoryChanged: {})
                let panel = NSWindow(contentViewController: controller)
                panel.setContentSize(NSSize(width: 1040, height: 900))
                panel.makeKeyAndOrderFront(nil)
                let control = descendants(controller.view).compactMap { $0 as? NativeShellSettingsControl }.first!
                return (controller, panel, control)
            }
            let (canceled, canceledWindow, canceledControl) = settings()
            defer { canceledWindow.close() }
            canceledControl.selectItem(at: 0)
            RepositoryWorkflowTests.click(canceledControl)
            try #require(isolated.preferences.defaultShell == "iterm2", "Settings shell choice remains staged before Apply")
            descendants(canceled.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            try #require(isolated.preferences.defaultShell == "iterm2", "Settings Cancel discards shell draft")
            let (applied, appliedWindow, appliedControl) = settings()
            defer { appliedWindow.close() }
            appliedControl.selectItem(at: 0)
            RepositoryWorkflowTests.click(appliedControl)
            descendants(applied.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!.performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("shell Settings Apply persisted") { isolated.preferences.defaultShell == "terminal" }
            try #require(
                AppSettingsStore(defaults: defaults).preferences.defaultShell == "terminal",
                "shell default reloads from deterministic existing preferences store")
            descendants(applied.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
            let (_, reopenedWindow, reopened) = settings()
            defer { reopenedWindow.close() }
            try #require(reopened.titleOfSelectedItem == "Terminal", "Settings reopen restores saved shell default")
            let legacy = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
            try #require(legacy.defaultShell == "terminal", "existing preferences migrate to native default")
        }

        @Test("Compact commit picker") static func testCompactCommitPicker() async throws {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func button(_ window: NSWindow, _ title: String) -> NSButton {
                descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
            }
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("file.txt", "base\n")
            try fixture.commitAll("base")
            let baseID = try fixture.head()
            try fixture.write("file.txt", "head\n")
            try fixture.commitAll("head")
            let headID = try fixture.head()
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let state = try await module.loadRepositoryState()
            let base = try await module.comparisonTarget(baseID.string)
            let head = try await module.comparisonTarget("HEAD")
            let before = try fixture.git(["status", "--porcelain=v2"])
            let picker = CommitPickerSmallControl(source: module, revisions: [head, base], selected: base)
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.contentView!.addSubview(picker)
            picker.frame = NSRect(x: 20, y: 20, width: 380, height: 30)
            owner.makeKeyAndOrderFront(nil)
            defer {
                picker.cancel()
                owner.close()
            }
            try await RepositoryWorkflowTests.waitUntil("compact picker divergence") { !picker.count.stringValue.isEmpty }
            let expectedCount = try await module.comparisonCount(from: head.id, to: baseID.string, headID: headID)
            try #require(
                picker.field.stringValue == base.shortID && picker.count.stringValue == expectedCount, "compact hash and actual upstream divergence count")
            var selections: [RevisionID?] = []
            picker.onSelectionChanged = { selections.append($0?.id) }
            await picker.setSelectedCommitHash("HEAD~1")
            try #require(
                picker.selectedCommit?.id == base.id && picker.field.stringValue == base.shortID, "typed revision expression resolves to real identity")
            picker.pick.performClick(nil)
            var chooser: RevisionComparisonGridController?
            try await RepositoryWorkflowTests.waitUntil("compact picker opens shared chooser") {
                chooser = owner.attachedSheet?.contentViewController as? RevisionComparisonGridController
                return chooser?.isLoading == false && chooser?.grid.selectedCommits.first?.id == base.id
            }
            chooser!.grid.selectCommit(id: head.id)
            button(owner.attachedSheet!, "Cancel").performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("compact picker cancel") { owner.attachedSheet == nil }
            try #require(picker.selectedCommit?.id == base.id, "compact chooser cancel preserves old commit")
            picker.pick.performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("compact picker reopens") {
                chooser = owner.attachedSheet?.contentViewController as? RevisionComparisonGridController
                return chooser?.isLoading == false && chooser?.grid.selectedCommits.first?.id == base.id
            }
            chooser!.grid.selectCommit(id: head.id)
            button(owner.attachedSheet!, "OK").performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("compact picker accepts") {
                owner.attachedSheet == nil && picker.selectedCommit?.id == head.id && picker.count.stringValue == "="
            }
            let invalid = Task { await picker.setSelectedCommitHash("no-such-revision") }
            try await RepositoryWorkflowTests.waitUntil("invalid compact input acknowledged") { owner.attachedSheet != nil }
            try #require(
                descendants(owner.attachedSheet!.contentView!).compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue == "The given commit hash is not valid for this repository and was therefore discarded."
                }, "source invalid revision error is preserved")
            button(owner.attachedSheet!, "OK").performClick(nil)
            await invalid.value
            try #require(
                picker.selectedCommit?.id == head.id && picker.field.stringValue == head.shortID, "invalid input restores previous selected identity and hash")
            await picker.setSelectedCommitHash("HEAD")
            try #require(
                picker.selectedCommit?.id == head.id && picker.field.stringValue.isEmpty && picker.count.stringValue.isEmpty,
                "source HEAD special presentation hides hash/count")
            await picker.setSelectedCommitHash("")
            try #require(picker.selectedCommit == nil && selections.last! == nil, "empty input clears selected revision")
            picker.isEnabled = false
            try #require(!picker.field.isEnabled && !picker.pick.isEnabled, "compact picker disables input and chooser together")

            let branchPreferences = AppSettingsStore.shared.checkoutBranchPreferences
            defer { AppSettingsStore.shared.saveCheckoutBranchPreferences(branchPreferences) }
            let branch = Task {
                await CheckoutBranchDialogs.createBranch(
                    source: module, context: state.branchContext, revisions: [head, base], sourceRevision: base, suggestedPrefix: "draft-branch",
                    isUnbornRepository: false, updateSubmodules: false, owner: owner)
            }
            try await RepositoryWorkflowTests.waitUntil("Create Branch compact consumer") { owner.attachedSheet != nil }
            let branchWindow = owner.attachedSheet!
            let branchPicker = descendants(branchWindow.contentView!).compactMap { $0 as? CommitPickerSmallControl }.first!
            await branchPicker.setSelectedCommitHash("HEAD")
            let orphan = button(branchWindow, "Create orphan")
            orphan.performClick(nil)
            try #require(!branchPicker.isEnabled, "Create Branch orphan disables entire compact picker")
            orphan.performClick(nil)
            try #require(branchPicker.isEnabled, "normal branch restores compact picker")
            button(branchWindow, "Create branch").performClick(nil)
            let branchRequest = await branch.value
            try #require(
                branchRequest?.sourceRevision == headID.string && branchRequest?.name == "draft-branch",
                "Create Branch returns selected ObjectID without display-label parsing")
            let checkout = Task {
                await CheckoutBranchDialogs.checkoutRevision(commit: base, revisions: [head, base], source: module, updateSubmodules: false, owner: owner)
            }
            try await RepositoryWorkflowTests.waitUntil("Checkout compact consumer") { owner.attachedSheet != nil }
            let checkoutWindow = owner.attachedSheet!
            let checkoutPicker = descendants(checkoutWindow.contentView!).compactMap { $0 as? CommitPickerSmallControl }.first!
            await checkoutPicker.setSelectedCommitHash("HEAD~1")
            button(checkoutWindow, "Checkout").performClick(nil)
            let checkoutRequest = await checkout.value
            try #require(checkoutRequest?.target == .revision(baseID.string), "Checkout returns resolved compact-picker identity")
            let tag = Task {
                await TagDialogs.createTag(
                    initial: .init(name: "draft-tag", target: baseID.string), revisions: [head, base], remote: nil, source: module, window: owner)
            }
            try await RepositoryWorkflowTests.waitUntil("Tag compact consumer") { owner.attachedSheet != nil }
            let tagWindow = owner.attachedSheet!
            let tagPicker = descendants(tagWindow.contentView!).compactMap { $0 as? CommitPickerSmallControl }.first!
            await tagPicker.setSelectedCommitHash(headID.string)
            button(tagWindow, "Create").performClick(nil)
            let tagRequest = await tag.value
            try #require(tagRequest?.target == headID.string && tagRequest?.name == "draft-tag", "Create Tag returns resolved compact-picker identity")
            let cherry = Task {
                await CherryPickDialog.present(
                    commit: base, history: [head, base], options: .init(automaticallyCommit: true, addReference: false),
                    chooseCommit: { revision, owner in
                        await RevisionCommitChooser.choose(source: module, preselect: revision, owner: owner)
                    }, owner: owner)
            }
            try await RepositoryWorkflowTests.waitUntil("Cherry-pick shared chooser consumer") { owner.attachedSheet != nil }
            let cherryWindow = owner.attachedSheet!
            descendants(cherryWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.toolTip == "Choose another revision" }!.performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("Cherry-pick graph chooser preselection") {
                chooser = cherryWindow.attachedSheet?.contentViewController as? RevisionComparisonGridController
                return chooser?.isLoading == false && chooser?.grid.selectedCommits.first?.id == base.id
            }
            chooser!.grid.selectCommit(id: head.id)
            button(cherryWindow.attachedSheet!, "OK").performClick(nil)
            try await RepositoryWorkflowTests.waitUntil("Cherry-pick summary updates from shared chooser") {
                cherryWindow.attachedSheet == nil && descendants(cherryWindow.contentView!).compactMap { $0 as? CommitSummaryView }.first?.title == head.shortID
            }
            button(cherryWindow, "Abort").performClick(nil)
            let cherryResult = await cherry.value
            try #require(cherryResult == nil, "Cherry-pick draft cancellation remains non-mutating")
            let after = try fixture.git(["status", "--porcelain=v2"])
            let finalHead = try fixture.head()
            try #require(before == after && finalHead == headID, "picker and draft consumers do not mutate refs/index/worktree")
        }

        @Test("Picker related states") static func testPickerRelatedStates() async throws {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            var filter = RevisionGridFilter()
            filter.byDateFrom = true
            filter.dateFrom = Date(timeIntervalSince1970: 1_760_001_234)
            filter.dateTo = Date(timeIntervalSince1970: 1_760_101_234)
            var accepted: RevisionGridFilter?
            let dates = RevisionFilterDialogController(filter: filter, defaultLimit: 100) { accepted = $0 }
            let datesWindow = NSWindow(contentViewController: dates)
            datesWindow.isReleasedWhenClosed = false
            defer { datesWindow.close() }
            dates.view.layoutSubtreeIfNeeded()
            let pickers = descendants(dates.view).compactMap { $0 as? NSDatePicker }
            let filterControls = descendants(dates.view).filter { $0 is NSButton || $0 is NSTextField || $0 is NSDatePicker }
            try #require(
                filterControls.allSatisfy { dates.view.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: dates.view)) },
                "date-only filter native fitting size contains all controls")
            try #require(pickers.count == 2 && pickers.allSatisfy { $0.datePickerElements == [.yearMonthDay] }, "both filter inputs expose date only")
            try #require(pickers[0].isEnabled && !pickers[1].isEnabled, "date filter enabled state follows source toggles")
            let dateButtons = descendants(dates.view).compactMap { $0 as? NSButton }
            let untilToggle = dateButtons.first { $0.title == "Until" }!
            untilToggle.state = .on
            RepositoryWorkflowTests.click(untilToggle)
            try #require(pickers[1].isEnabled, "Until toggle enables its date picker")
            RepositoryWorkflowTests.click(dateButtons.first { $0.title == "OK" }!)
            try #require(
                accepted?.byDateFrom == true && accepted?.byDateTo == true && accepted?.dateFrom == filter.dateFrom && accepted?.dateTo == filter.dateTo,
                "date-only presentation preserves source dates, including saved time components")
            let canceled = RevisionFilterDialogController(filter: filter, defaultLimit: 100) { accepted = $0 }
            RepositoryWorkflowTests.click(descendants(canceled.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!)
            try #require(accepted == nil, "filter Cancel discards draft")

            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("tracked.txt", "initial\n")
            try fixture.commitAll("base")
            try fixture.write("tracked.txt", "modified\n")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            let state = try await module.loadRepositoryState()
            let before = try fixture.git(["status", "--porcelain=v2"])
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            let preferences = AppSettingsStore.shared.stashPreferences
            defer { AppSettingsStore.shared.saveStashPreferences(preferences) }
            var narrow = preferences
            narrow.dividerPosition = 170
            narrow.windowWidth = 900
            narrow.windowHeight = 600
            AppSettingsStore.shared.saveStashPreferences(narrow)
            let stash = Task {
                await StashDialog.present(
                    source: module, context: state.stashContext, manageStashes: false, initialStash: nil, owner: owner, openWithDifftool: nil,
                    resolveConflicts: { _ in false })
            }
            var window: NSWindow?
            var outline: NSOutlineView?
            try await RepositoryWorkflowTests.waitUntil("Stash working-directory groups load") {
                window = NSApp.windows.first { $0.title == "Stash" && $0.isVisible }
                outline = window?.contentView.map(descendants)?.compactMap { $0 as? NSOutlineView }.first
                guard let outline else { return false }
                return (0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? ChangedFileNode)?.title == "(0) Commit index" }
            }
            let groups = (0..<outline!.numberOfRows).compactMap { outline!.item(atRow: $0) as? ChangedFileNode }.filter { $0.file == nil }
            try #require(groups.map(\.title) == ["(1) Working directory", "(0) Commit index"], "empty index group remains after workspace, in source order")
            try #require(groups.last?.children.isEmpty == true, "empty index has no selectable phantom file")
            window!.contentView!.layoutSubtreeIfNeeded()
            let opened = descendants(window!.contentView!).compactMap { $0 as? NSButton }
            let openedKeep = try #require(opened.first { $0.title == "Keep index" })
            let openedUntracked = try #require(opened.first { $0.title == "Include untracked files" })
            let single = openedUntracked.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000))
            try #require(
                openedUntracked.bounds.width >= single.width - 0.5 && abs(openedUntracked.bounds.height - openedKeep.bounds.height) < 0.5,
                "the left pane opens at least as wide as the option row, so both check boxes fit on one line: \(openedUntracked.bounds.size) vs \(single)")
            window!.setFrame(NSRect(origin: window!.frame.origin, size: window!.minSize), display: true)
            try await Task.sleep(for: .milliseconds(150))
            window!.contentView!.layoutSubtreeIfNeeded()
            let checkboxes = descendants(window!.contentView!).compactMap { $0 as? NSButton }
            let keepIndex = try #require(checkboxes.first { $0.title == "Keep index" })
            let untracked = try #require(checkboxes.first { $0.title == "Include untracked files" })
            let row = try #require(untracked.superview)
            let needed = untracked.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: untracked.bounds.width, height: .greatestFiniteMagnitude))
            try #require(
                keepIndex.frame.minX == 0 && keepIndex.frame.maxX <= row.bounds.midX && untracked.frame.minX >= row.bounds.midX
                    && abs(untracked.frame.maxX - row.bounds.maxX) < 0.5,
                "Keep index and Include untracked files occupy the left/right halves, the latter anchored right")
            try #require(
                needed.width <= untracked.bounds.width + 0.5 && needed.height <= untracked.bounds.height + 0.5
                    && (untracked.bounds.width >= NSButton(checkboxWithTitle: untracked.title, target: nil, action: nil).fittingSize.width
                        || untracked.bounds.height > keepIndex.bounds.height),
                "Include untracked files wraps within its half at minimum size instead of truncating: needs \(needed), has \(untracked.bounds.size)")
            window!.performClose(nil)
            let result = await stash.value
            let after = try fixture.git(["status", "--porcelain=v2"])
            try #require(!result.repositoryChanged && after == before, "Stash inspection preserves index/worktree")
        }

        private struct ProcessFixtureGit: GitCommandRunning {
            let home: URL
            private var environment: [String: String] {
                ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
            }
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment supplied: [String: String]) async throws -> GitCommandResult {
                try await GitProcess().run(
                    arguments: arguments, in: directory, standardInput: standardInput, environment: supplied.merging(environment) { _, isolated in isolated })
            }
            func runStreaming(
                arguments: [String], in directory: URL, standardInput: Data?, environment supplied: [String: String], output: @escaping GitOutputHandler
            ) async throws -> GitCommandResult {
                try await GitProcess().runStreaming(
                    arguments: arguments, in: directory, standardInput: standardInput, environment: supplied.merging(environment) { _, isolated in isolated },
                    output: output)
            }
        }

        @Test("Shared process windows") static func testSharedProcessWindows() async throws {
            let root = try RepositoryWorkflowTests.temporaryDirectory("process-parity")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("home")
            let repository = root.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let environment = ["HOME": home.path, "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
            func git(_ args: [String]) throws -> String { try RepositoryWorkflowTests.git(args, in: repository, environment: environment) }
            _ = try git(["init", "-q", "-b", "main"])
            _ = try git(["config", "user.name", "Process Fixture"])
            _ = try git(["config", "user.email", "process@example.invalid"])
            try Data("seed\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
            _ = try git(["add", "tracked.txt"])
            _ = try git(["-c", "commit.gpgsign=false", "commit", "-qm", "seed"])
            try Data("untracked\n".utf8).write(to: repository.appendingPathComponent("untracked.txt"))
            let head = try git(["rev-parse", "HEAD"])
            let status = try git(["status", "--porcelain"])
            let source = GitRepositoryModule(repositoryURL: repository, git: ProcessFixtureGit(home: home))
            _ = try await source.loadRepositoryState()
            let preferences = AppSettingsStore.shared.pullPreferences
            defer { AppSettingsStore.shared.savePullPreferences(preferences) }
            func closeOnSuccess(_ value: Bool) {
                var updated = AppSettingsStore.shared.pullPreferences
                updated.closeProcessOnSuccess = value
                AppSettingsStore.shared.savePullPreferences(updated)
            }
            closeOnSuccess(false)
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            func button(_ window: NSWindow, _ title: String) -> NSButton {
                allSubviews(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
            }
            func done(_ window: NSWindow) -> Bool { button(window, "OK").isEnabled }
            func output(_ window: NSWindow) -> String {
                allSubviews(window.contentView!).compactMap { $0 as? NSTextView }.map(\.string).joined(separator: "\n")
            }
            CleanDialog.present(source: source, repositoryURL: repository, owner: owner, repositoryChanged: {}, statusChanged: { _ in })
            let cleanup = owner.attachedSheet!
            RepositoryWorkflowTests.click(button(cleanup, "Preview"))
            try await RepositoryWorkflowTests.waitUntil("cleanup process") { cleanup.attachedSheet != nil }
            let preview = cleanup.attachedSheet!
            try #require(preview.contentView!.bounds.size == NSSize(width: 549, height: 327), "pinned shared process client dimensions")
            try await RepositoryWorkflowTests.waitUntil("completed cleanup preview") { done(preview) && output(preview).contains("untracked.txt") }
            try #require(
                !button(preview, "Keep dialog open").isHidden && button(preview, "Abort").isEnabled == false && preview.isVisible,
                "completed read dialog retains Keep/OK/disabled Abort until acknowledgement")
            try #require(
                output(preview).contains("clean -x -d --dry-run"), "shared process prints the actual structured invocation like upstream plain-text console")
            try #require(!output(cleanup).contains("untracked.txt"), "Cleanup result waits for child-process acknowledgement")
            RepositoryWorkflowTests.click(button(preview, "OK"))
            try await RepositoryWorkflowTests.waitUntil("result copied after acknowledgement") {
                cleanup.attachedSheet == nil && output(cleanup).contains("untracked.txt")
            }
            let previewHead = try git(["rev-parse", "HEAD"])
            let previewStatus = try git(["status", "--porcelain"])
            try #require(previewHead == head && previewStatus == status, "preview preserves HEAD/index/worktree")
            RepositoryWorkflowTests.click(button(cleanup, "Close"))
            try await RepositoryWorkflowTests.waitUntil("cleanup closes") { owner.attachedSheet == nil }
            let bisect = Task { await BisectDialog.present(source: source, selectedRevisions: [], owner: owner, statusChanged: { _ in }) }
            try await RepositoryWorkflowTests.waitUntil("bisect loaded") { owner.attachedSheet.map { button($0, "Start bisect").isEnabled } == true }
            let dialog = owner.attachedSheet!
            RepositoryWorkflowTests.click(button(dialog, "Start bisect"))
            try await RepositoryWorkflowTests.waitUntil("start process") { dialog.attachedSheet != nil }
            let start = dialog.attachedSheet!
            try await RepositoryWorkflowTests.waitUntil("start completed") { done(start) }
            let started = try await source.loadBisectState()
            try #require(output(start).contains("bisect start"), "shared process identifies the actual bisect invocation")
            try #require(
                started.isActive && start.isVisible && !button(start, "Keep dialog open").isHidden,
                "range-less start executes real Git, remains acknowledged process, uses saved dialog setting")
            RepositoryWorkflowTests.click(button(start, "OK"))
            try await RepositoryWorkflowTests.waitUntil("start parent refresh") { dialog.attachedSheet == nil && button(dialog, "Stop bisect").isEnabled }
            closeOnSuccess(true)
            RepositoryWorkflowTests.click(button(dialog, "Stop bisect"))
            try await RepositoryWorkflowTests.waitUntil("stop process") { dialog.attachedSheet != nil }
            let stop = dialog.attachedSheet!
            try #require(stop.contentView!.bounds.size == NSSize(width: 549, height: 327), "pinned process client dimensions")
            try await RepositoryWorkflowTests.waitUntil("stop completed") { done(stop) }
            let stopped = try await source.loadBisectState()
            try #require(
                !stopped.isActive && stop.isVisible && button(stop, "Keep dialog open").isHidden && owner.attachedSheet === dialog,
                "Stop hides preference checkbox and requires acknowledgement even with auto-close enabled")
            RepositoryWorkflowTests.click(button(stop, "OK"))
            let bisectResult = await bisect.value
            try #require(bisectResult.repositoryChanged && owner.attachedSheet == nil, "parent closes/notifies after Stop acknowledgement")
            let restoredHead = try git(["rev-parse", "HEAD"])
            let restoredStatus = try git(["status", "--porcelain"])
            try #require(restoredHead == head && restoredStatus == status, "range-less Start/Stop restores real repository state")
            closeOnSuccess(false)
            let abort = Task {
                await HostingProcessDialog.runConfigured("Abort test", owner, true) { _ in
                    try await Task.sleep(for: .seconds(30))
                    return true
                }
            }
            try await RepositoryWorkflowTests.waitUntil("process abort running") { owner.attachedSheet != nil }
            let abortWindow = owner.attachedSheet!
            try #require(!done(abortWindow) && button(abortWindow, "Abort").isEnabled, "process initial running controls")
            RepositoryWorkflowTests.click(button(abortWindow, "Abort"))
            try await RepositoryWorkflowTests.waitUntil("process cancellation") { done(abortWindow) }
            try #require(output(abortWindow).contains("Aborted"), "process cancellation produces explicit aborted output")
            RepositoryWorkflowTests.click(button(abortWindow, "OK"))
            let aborted = await abort.value
            try #require(!aborted && owner.attachedSheet == nil, "aborted process acknowledgement closes once and returns failure")
            closeOnSuccess(true)
            let failure = Task {
                await HostingProcessDialog.runConfigured("Failure test", owner, true) { _ in throw PluginError.invalid("Fixture process failure") }
            }
            try await RepositoryWorkflowTests.waitUntil("process failure retained") { owner.attachedSheet.map(done) == true }
            let failed = owner.attachedSheet!
            try #require(
                output(failed).contains("Fixture process failure") && failed.isVisible, "process error remains visible despite automatic closing preference")
            RepositoryWorkflowTests.click(button(failed, "OK"))
            let failureResult = await failure.value
            try #require(!failureResult, "failed process returns failure after acknowledgement")
        }

        @Test("Commit summary references and date") private static func testCommitSummaryReferencesAndDate() throws {
            let date = Date(timeIntervalSince1970: 1_767_268_800)
            let commit = Commit(
                id: testRevisionID("a1"), shortID: "a1", subject: "Merge topic", body: "", authorName: "Parity", authorEmail: "p@example.invalid",
                authorDate: date, committerName: "Parity", committerEmail: "p@example.invalid",
                commitDate: date, parentIDs: [],
                references: [
                    RevisionReference(id: "refs/heads/feature/nested", name: "feature/nested", kind: .localBranch),
                    RevisionReference(id: "refs/remotes/origin/feature/nested", name: "origin/feature/nested", kind: .remoteBranch),
                    RevisionReference(id: "refs/tags/v1.0", name: "v1.0", kind: .tag),
                ], kind: .revision)
            let summary = CommitSummaryView()
            summary.apply(commit)
            let texts = allTextFields(in: summary).map(\.stringValue)
            try #require(texts.contains("feature/nested"), "local branch shown in Branch(es)")
            try #require(!texts.contains(where: { $0.contains("origin/feature/nested") }), "remote branches are excluded like upstream IsHead filtering")
            try #require(texts.contains("v1.0"), "tags unchanged")
            let expectedDate = CommitInfoPresentation.dateText(date, now: Date())
            try #require(
                texts.contains(expectedDate) && expectedDate.contains(" ago (") && expectedDate.hasSuffix(")"), "date shows relative time plus full local date")
        }

        @Test("Artificial child links") private static func testArtificialChildLinks() throws {
            let date = Date(timeIntervalSince1970: 1_767_268_800)
            let headID = testObjectID("head")
            func make(_ id: RevisionID, parents: [ObjectID], kind: Commit.Kind) -> Commit {
                Commit(
                    id: id, shortID: "", subject: "", body: "", authorName: "Parity", authorEmail: "p@example.invalid",
                    authorDate: date, committerName: "Parity", committerEmail: "p@example.invalid",
                    commitDate: date, parentIDs: parents, references: [], kind: kind)
            }
            let workTree = make(.workingDirectory, parents: [], kind: .workingDirectory)
            let index = make(.index, parents: [headID], kind: .index)
            let head = make(.object(headID), parents: [], kind: .revision)
            let history = [workTree, index, head]
            let headRelations = CommitRelationsResolver.resolve(commit: head, history: history)
            try #require(headRelations.childIDs == [.index], "HEAD child is the artificial index \(headRelations.childIDs)")
            let child = CommitInfoPresentation.header(head, children: headRelations.childIDs).first { $0.label == "Child" }
            try #require(
                child?.value == [CommitInfoPresentation.Run("Commit index", link: .commit(.index))], "Child: Commit index link \(String(describing: child))")
            try #require(CommitInfoPresentation.Link(url: CommitInfoPresentation.Link.commit(.index).url) == .commit(.index), "index link round trip")
            let indexRelations = CommitRelationsResolver.resolve(commit: index, history: history)
            try #require(indexRelations.childIDs == [.workingDirectory], "index child is the working directory")
            let controller = CommitDetailViewController()
            var navigated: [RevisionID] = []
            controller.onGoToRevision = { navigated.append($0) }
            controller.execute(CommitInfoPresentation.Link.commit(.index).url)
            try #require(navigated == [.index], "Commit index link navigates to the index row")
        }

        @Test("Repository tree visibility icons and remote order") private static func testRepositoryTreeVisibilityIconsAndRemoteOrder() throws {
            let mainID = testObjectID("main")
            let topicID = testObjectID("topic")
            func branch(_ name: String, _ id: ObjectID, remote: String? = nil, current: Bool = false) -> Branch {
                Branch(
                    id: (remote == nil ? "refs/heads/" : "refs/remotes/\(remote!)/") + name, name: name, commitID: id,
                    isCurrent: current, isRemote: remote != nil, remoteName: remote, ahead: 0, behind: 0)
            }
            let locals = [branch("feature/nested", topicID), branch("main", mainID, current: true), branch("topic", topicID)]
            let remotes = [
                Remote(
                    id: "origin", name: "origin", fetchURL: "https://example.invalid/origin.git",
                    branches: [
                        branch("feature/nested", topicID, remote: "origin"), branch("main", mainID, remote: "origin"),
                        branch("topic", topicID, remote: "origin"),
                    ])
            ]
            let roots = RepositoryTreeBuilder.build(
                references: RepositoryReferenceState(
                    branches: locals, tags: [Tag(id: "refs/tags/v1.0", name: "v1.0", commitID: mainID)], referencesByCommit: [:]),
                navigation: RepositoryNavigationState(remotes: remotes, stashes: [], worktrees: [], submodules: []),
                preferences: RepositoryTreePreferences())
            let localTitles = roots.first { $0.title == "Branches" }?.children.map(\.title)
            let origin = roots.first { $0.title == "Remotes" }?.children.first { $0.title == "origin" }
            try #require(localTitles == ["main", "feature", "topic"], "local order \(String(describing: localTitles))")
            try #require(
                origin?.children.map(\.title) == ["main", "feature", "topic"],
                "remote children follow prioritized branch order \(String(describing: origin?.children.map(\.title)))")

            let controller = RepositoryOutlineViewController()
            let outline = NSOutlineView()
            let tagNode = try #require(roots.first { $0.title == "Tags" }?.children.first, "tag node")
            let remoteMain = try #require(origin?.children.first, "origin/main node")
            let remoteTopic = try #require(origin?.children.last, "origin/topic node")
            remoteMain.isMerged = true
            let visibleCell = controller.outlineView(outline, viewFor: nil, item: tagNode) as? NSTableCellView
            try #require(visibleCell?.textField?.textColor == .labelColor, "visible tag is not greyed")
            let mergedCell = controller.outlineView(outline, viewFor: nil, item: remoteMain) as? NSTableCellView
            try #require(mergedCell?.textField?.textColor == .labelColor, "visible merged remote branch keeps normal text")
            try #require(
                mergedCell?.toolTip == "'main' is contained in the currently selected commit", "merged tooltip \(String(describing: mergedCell?.toolTip))")
            remoteTopic.isRevisionVisible = false
            let hiddenCell = controller.outlineView(outline, viewFor: nil, item: remoteTopic) as? NSTableCellView
            try #require(hiddenCell?.textField?.textColor == .tertiaryLabelColor, "hidden revision is greyed")
            try #require(hiddenCell?.toolTip == "'origin/topic' is not currently visible", "invisible tooltip \(String(describing: hiddenCell?.toolTip))")
        }

        @Test("Added file content routing and group caption") private static func testAddedFileContentRoutingAndGroupCaption() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            try fixture.write("source.swift", "one\n")
            try fixture.commitAll("Initial files")
            try fixture.write("source.swift", "one\ntwo\n")
            try fixture.write("topic.txt", "Topic branch\n")
            try fixture.commitAll("Add topic file")
            _ = try await module.loadRepositoryState()
            let revision = try await module.loadBlameRevision(nil)

            func outline(_ controller: NSViewController) -> NSOutlineView? {
                func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
                return walk(controller.view).compactMap { $0 as? NSOutlineView }.first { $0.accessibilityIdentifier() == "FileStatusList" }
            }
            func rows(_ list: NSOutlineView?) -> [ChangedFileNode] {
                guard let list else { return [] }
                return (0..<list.numberOfRows).compactMap { list.item(atRow: $0) as? ChangedFileNode }
            }
            func wait(_ label: @autoclosure () -> String, _ predicate: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(15)
                while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
                try #require(predicate(), Comment(rawValue: label()))
            }

            let browse = RevisionDiffViewController(mode: .diff)
            browse.fileStatusSource = module
            browse.repositoryURL = fixture.repo
            let window = NSWindow(contentViewController: browse)
            window.setContentSize(NSSize(width: 900, height: 600))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            browse.setDiffs(revisions: [revision], headID: revision.objectID)
            try await wait("browse files loaded") { browse.filesController.allItems.count == 2 }
            let parent = try #require(revision.parentIDs.first, "parent")
            let caption = rows(outline(browse)).first { $0.isDiffGroup }?.title ?? ""
            try #require(caption.contains("Diff with A \(parent.string.prefix(8))") && !caption.contains("Diff with A:"), "group caption \(caption)")
            browse.selectFileOrFolder("topic.txt")
            try await wait(
                "added file shows content shown=\(browse.isShowingFileContent) text=\(browse.displayedFileContentText) diff=\(browse.displayedDiffText.prefix(80))"
            ) {
                browse.isShowingFileContent && browse.displayedFileContentText.contains("Topic branch")
            }
            try #require(
                !browse.displayedFileContentText.contains("diff --git") && !browse.displayedFileContentText.contains("+Topic"),
                "no patch headers for added file")
            browse.selectFileOrFolder("source.swift")
            try await wait("modified file still shows the patch \(browse.displayedDiffText)") {
                !browse.isShowingFileContent && browse.displayedDiffText.contains("two")
            }
            try #require(
                RevisionDiffViewController.viewsAsFileContent(
                    .init(
                        group: FileStatusGroup(first: nil, second: revision.id, summary: "", files: []),
                        file: ChangedFile(id: "m", path: "a.txt", oldPath: nil, changeType: .modified, additions: 0, deletions: 0))),
                "root commit items view as content (zero first id)")
            try #require(
                !RevisionDiffViewController.viewsAsFileContent(
                    .init(
                        group: FileStatusGroup(first: .object(parent), second: revision.id, summary: "", files: []),
                        file: ChangedFile(id: "d", path: "a.png", oldPath: nil, changeType: .deleted, additions: 0, deletions: 0))),
                "deleted image keeps the diff path")

            let plain = RevisionDiffViewController(mode: .diff, groupsByRevision: false)
            plain.fileStatusSource = module
            let plainWindow = NSWindow(contentViewController: plain)
            plainWindow.setContentSize(NSSize(width: 900, height: 600))
            plainWindow.orderFront(nil)
            defer { plainWindow.orderOut(nil) }
            plain.setDiffs(revisions: [revision], headID: revision.objectID)
            try await wait("plain files loaded") { plain.filesController.allItems.count == 2 && rows(outline(plain)).contains { $0.file != nil } }
            try #require(
                !rows(outline(plain)).contains { $0.isDiffGroup },
                "single-group commit diff lists files without a group node \(rows(outline(plain)).map(\.title))")
        }

        @Test("Statistics presentation") private static func testStatisticsPresentation() throws {
            var values = CodeStatistics()
            values.total = 14
            values.blank = 2
            values.test = 7
            values.byExtension = [".cs": 12]
            values.contributors = [("Parity Fixture", 5)]
            let pages = StatisticsPresentation.pages(values)
            try #require(
                pages.map(\.heading) == ["5 Commits", "12 Lines of code", "12 Lines of code", "7 Lines of test code"],
                "upstream headings \(pages.map(\.heading))")
            try #require(pages[0].lines == ["5 Parity Fixture"], "contributors text \(pages[0].lines)")
            try #require(pages[1].lines == ["12 Lines of code in .cs files (100.0%)"], "language text \(pages[1].lines)")
            try #require(
                pages[2].lines == ["2 Blank lines (14.3%)", "0 Comment lines (0.0%)", "12 Lines of code (85.7%)", "0 Lines in designer files (0.0%)"],
                "type text \(pages[2].lines)")
            try #require(pages[3].lines == ["7 Lines of test code (58.3%)", "5 Lines of production code (41.7%)"], "test text \(pages[3].lines)")
            let empty = StatisticsPresentation.pages(CodeStatistics())
            try #require(empty[3].lines == ["0 Lines of test code (NaN)", "0 Lines of production code (NaN)"], "zero denominators show NaN \(empty[3].lines)")
            try #require(
                empty[3].heading == "0 Lines of test code" && empty[2].lines.allSatisfy { $0.hasSuffix("(NaN)") }, "empty type page NaN \(empty[2].lines)")
        }

        @Test("Sorting help and defaults") static func testSortingHelpAndDefaults() async throws {
            let decoded = try JSONDecoder().decode(RepositoryTreePreferences.self, from: Data("{}".utf8))
            try #require(
                decoded.sortOrder == .descending && RepositoryTreeSortOrder.allCases.map(\.settingsTitle) == ["A ↓ Z", "Z ↑ A"],
                "upstream descending default and exact enum descriptions")
            let suite = "GitExtensionsMac.SortingHelpTest.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            let controller = SettingsViewController(store: store, source: nil, initialPage: "sorting", repositoryChanged: {})
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            do {
                let views = allSubviews(controller.view)
                let apply = { RepositoryWorkflowTests.click(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Settings.Apply" }!) }
                let expected = [
                    ("RevisionHelp", "sorting-sort-author-date"), ("BranchesHelp", "sorting-sort-prioritized-branches"),
                    ("RemotesHelp", "sorting-sort-prioritized-remotes"),
                ]
                let buttons = views.compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("Settings.Sorting.") }
                try #require(
                    buttons.map { $0.accessibilityIdentifier() } == expected.map { "Settings.Sorting." + $0.0 }, "three source help actions in owning row order"
                )
                var destinations: [URL] = []
                controller.onOpenManual = { destinations.append($0) }
                for (button, vector) in zip(buttons, expected) {
                    try #require(
                        button.image != nil && !(button.toolTip ?? "").isEmpty && button.isEnabled,
                        "visible enabled native information control with source tooltip")
                    button.performClick(nil)
                    try #require(
                        destinations.last?.absoluteString == ApplicationShellLinks.documentationURL.absoluteString + "settings.html#" + vector.1,
                        "actual help action dispatches pinned StandardHtmlUserManual destination")
                }
                let orderRow = try #require(views.first { $0.subviews.contains { ($0 as? NSTextField)?.stringValue == "Order branches:" } }, "branch order row")
                let order = try #require(allSubviews(orderRow).compactMap { $0 as? NSPopUpButton }.first, "branch order popup")
                try #require(
                    order.title == "Z ↑ A" && store.repositoryTreePreferences.sortOrder == .descending, "fresh Settings presents source descending default")
                order.selectItem(withTitle: "A ↓ Z")
                RepositoryWorkflowTests.click(order)
                apply()
                try await RepositoryWorkflowTests.waitUntil("sorting Apply") { store.repositoryTreePreferences.sortOrder == .ascending }
                order.selectItem(withTitle: "Z ↑ A")
                RepositoryWorkflowTests.click(order)
                var response: NSApplication.ModalResponse?
                controller.onClose = { response = $0 }
                let cancel = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }, "Settings Cancel")
                cancel.performClick(nil)
                try #require(
                    response == .cancel && AppSettingsStore(defaults: defaults).repositoryTreePreferences.sortOrder == .ascending,
                    "Cancel preserves explicit saved ascending value")
                let reopened = SettingsViewController(store: store, source: nil, initialPage: "sorting", repositoryChanged: {})
                let reopenedWindow = NSWindow(contentViewController: reopened)
                defer { reopenedWindow.close() }
                let reopenedRow = try #require(
                    allSubviews(reopened.view).first { $0.subviews.contains { ($0 as? NSTextField)?.stringValue == "Order branches:" } },
                    "reopened branch order row")
                let restored = try #require(allSubviews(reopenedRow).compactMap { $0 as? NSPopUpButton }.first, "reopened branch order")
                try #require(restored.title == "A ↓ Z", "existing saved ascending selection is never reset to new default")
                restored.selectItem(withTitle: "Z ↑ A")
                RepositoryWorkflowTests.click(restored)
                reopened.onClose = { response = $0 }
                let okay = try #require(allSubviews(reopened.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }, "Settings OK")
                okay.performClick(nil)
                try await RepositoryWorkflowTests.waitUntil("sorting OK") { response == .OK && store.repositoryTreePreferences.sortOrder == .descending }
                reopened.goToCategory("appearance")
                reopened.onOpenManual = { destinations.append($0) }
                for (id, anchor) in [
                    ("Settings.AvatarProviderHelp", "author-images-avatar-provider"), ("Settings.AvatarFallbackHelp", "author-images-avatar-fallback"),
                ] {
                    let help = try #require(
                        allSubviews(reopened.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id }, "shared Appearance help")
                    help.performClick(nil)
                    try #require(
                        destinations.last == AppearanceSettingsPresentation.manualURL(anchor: anchor),
                        "existing Appearance consumer uses the same source-correct help dispatcher")
                }
            }
        }

        @Test("File tree find navigation") static func testFileTreeFindNavigation() async throws {
            let editor = EditableFileTextView()
            let ruler = editor.textView.enclosingScrollView!.verticalRulerView as! FileViewerLineNumberRuler
            let initialThickness = ruler.ruleThickness
            editor.text = String(repeating: "line\n", count: 1000)
            try #require(
                ruler.lineStarts.count == 1001 && ruler.ruleThickness == initialThickness,
                "text editing updates line offsets without re-entering text layout through ruleThickness")
            let rulerDeadline = ContinuousClock.now + .seconds(3)
            while ruler.ruleThickness == initialThickness, ContinuousClock.now < rulerDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(ruler.ruleThickness > initialThickness, "ruler applies its latest width after text-storage processing completes")
            let wideThickness = ruler.ruleThickness
            editor.text = "one\n"
            editor.text = "two\nthree\n"
            try #require(
                ruler.lineStarts == [0, 4, 10] && ruler.ruleThickness == wideThickness, "ruler coalesces edits without stale logical offsets or inline resize")
            while ruler.ruleThickness == wideThickness, ContinuousClock.now < rulerDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(
                ruler.ruleThickness < wideThickness && editor.text == "two\nthree\n", "deferred ruler width follows final content without modifying source")
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            for (path, text) in [
                ("a.txt", "first file\n"), ("b.txt", "second needle\n"), ("c.txt", "third file\n"),
                ("d-large.txt", String(repeating: "a", count: FilePreview<RepositoryFileContent>.threshold - 1)), ("e.txt", "last file\n"),
            ] {
                try fixture.write(path, text)
            }
            try fixture.commitAll("Search fixture")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let revision = try await module.loadBlameRevision(nil)
            let tree = RevisionDiffViewController(mode: .fileTree)
            tree.fileStatusSource = module
            tree.repositoryURL = fixture.repo
            let owner = NSWindow(contentViewController: tree)
            owner.setContentSize(NSSize(width: 900, height: 600))
            owner.makeKeyAndOrderFront(nil)
            defer {
                tree.cancelLoads()
                owner.orderOut(nil)
            }
            func wait(_ message: String, _ predicate: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                try #require(predicate(), Comment(rawValue: message))
            }
            func controllers(_ value: NSViewController) -> [NSViewController] { [value] + value.children.flatMap(controllers) }
            tree.setDiffs(revisions: [revision], headID: revision.objectID)
            try await wait("search tree files loaded") { tree.filesController.allItems.count == 5 }
            tree.selectFileOrFolder("a.txt")
            try await wait("first search file loaded") { tree.displayedFileContentText == "first file\n" }
            let viewer = try #require(controllers(tree).compactMap { $0 as? RevisionFileContentViewController }.first, "actual read-only content viewer")
            let menu = NSMenu()
            viewer.menuNeedsUpdate(menu)
            let find = try #require(menu.items.first { $0.title == "Find…" }, "actual Find action")
            try #require(NSApp.sendAction(find.action!, to: find.target, from: find), "Find menu opens owned panel")
            let panel = try #require(NSApp.windows.first { $0.title == "Find" && $0.isVisible }, "actual Find panel")
            defer {
                if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
                panel.windowController?.close()
            }
            let query = try #require(allSubviews(panel.contentView!).compactMap { $0 as? NSSearchField }.first, "Find query")
            let next = try #require(allSubviews(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Find next" }, "Find next")
            query.stringValue = "needle"
            next.performClick(nil)
            try await wait("cross-file find selects real match") { viewer.searchState.currentMatch != nil }
            try #require(
                tree.filesController.selectedItems().first?.file.path == "b.txt" && viewer.searchState.currentMatch == NSRange(location: 7, length: 6),
                "cross-file Find next selects b.txt and exact match")
            query.stringValue = "absent-in-all-files"
            next.performClick(nil)
            try await wait("exhausted cross-file search displays not-found acknowledgement") { panel.attachedSheet != nil }
            let sheet = panel.attachedSheet!
            try #require(
                allSubviews(sheet.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Text not found" },
                "source not-found wording after full traversal")
            let okay = try #require(allSubviews(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }, "not-found acknowledgement")
            okay.performClick(nil)
            try await wait("not-found acknowledgement dismissed") { panel.attachedSheet == nil }
            try #require(viewer.searchState.currentMatch == nil, "exhausted search has no stale active match")
        }

        @Test("Patch line numbers") static func testPatchLineNumbers() throws {
            let fixtures = TestResources.fixtures.appendingPathComponent("DiffAndFileTree")
            let sample = try String(contentsOf: fixtures.appendingPathComponent("Sample.diff"), encoding: .utf8)
            let lines = GitOutputParser.parseDiffLines(sample, fileID: "sample", numberUnprefixedContext: true)
            for row in [5, 17] {
                try #require(
                    lines[row - 1].kind == .hunk && lines[row - 1].oldLineNumber == nil && lines[row - 1].newLineNumber == nil,
                    "upstream CanGetHeaders row \(row)")
            }
            for (row, old, new) in [(6, 9, 9), (14, 15, 16), (18, 33, 34), (25, 39, 40)] {
                let line = lines[row - 1]
                try #require(line.kind == .context && line.oldLineNumber == old && line.newLineNumber == new, "upstream CanGetContextLines row \(row)")
            }
            for (row, old) in [(9, 12), (21, 36)] {
                let line = lines[row - 1]
                try #require(line.kind == .deletion && line.oldLineNumber == old && line.newLineNumber == nil, "upstream CanGetMinusLines row \(row)")
            }
            for (row, new) in [(12, 14), (13, 15), (22, 37)] {
                let line = lines[row - 1]
                try #require(line.kind == .addition && line.oldLineNumber == nil && line.newLineNumber == new, "upstream CanGetPlusLines row \(row)")
            }
            let combined = try String(contentsOf: fixtures.appendingPathComponent("SampleCombined.diff"), encoding: .utf8)
            let combinedLines = GitOutputParser.parseDiffLines(combined, fileID: "combined", numberUnprefixedContext: true)
            let vectors: [(Int, Int?, DiffLine.Kind)] = [
                (6, 70, .context), (9, 73, .addition), (19, 83, .addition), (34, 100, .context), (37, nil, .deletion), (38, 103, .addition),
            ]
            for (row, new, kind) in vectors {
                let line = combinedLines[row - 1]
                try #require(
                    line.kind == kind && line.oldLineNumber == nil && line.newLineNumber == new, "upstream CanGetLineNumbersForCombinedDiff row \(row)")
            }
            let header = "diff --git a/new.txt b/new.txt\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello\n\\ No newline at end of file\n-- \n2.45.2"
            for ending in ["", "\n", "\n\n"] {
                for separator in ["\n", "\r\n"] {
                    let source = (header + ending).replacingOccurrences(of: "\n", with: separator)
                    let preview = try PatchPreviewParser.parse(Data(source.utf8))
                    let file = try #require(preview.files.first, "mailbox file")
                    let diff = try #require(preview.diffs[file.id], "mailbox diff")
                    let version = try #require(diff.lines.first { $0.text == "2.45.2" || $0.text == "2.45.2\r" }, "mailbox version")
                    try #require(
                        version.kind == .context && version.oldLineNumber == 1 && version.newLineNumber == 2,
                        "version context numbering follows upstream, not hunk count exhaustion: \(version) separator \(separator.debugDescription)")
                    try #require(version.diffPrefix == "", "unprefixed context never adds a copy prefix")
                    let marker = try #require(diff.lines.first { $0.text.hasPrefix("\\ No newline") }, "newline marker")
                    try #require(marker.kind == .header && marker.oldLineNumber == nil && marker.newLineNumber == nil, "Git newline marker stays unnumbered")
                    try #require(
                        diff.lines.map(\.patchText).joined(separator: "\n") == source,
                        "numbering preserves original source/copy including CRLF and terminal newlines")
                    if ending == "\n\n" {
                        let blank = diff.lines[diff.lines.count - 2]
                        try #require(
                            blank.kind == .context && blank.oldLineNumber == 2 && blank.newLineNumber == 3,
                            "non-final empty physical line gets upstream context numbering")
                    }
                    if !ending.isEmpty {
                        try #require(diff.lines.last?.kind == .header && diff.lines.last?.newLineNumber == nil, "final empty marker remains unnumbered")
                    }
                    let ordinary = GitOutputParser.parseUnifiedDiff(text: source, files: [file], contentEncoding: .utf8)[file.id]
                    try #require(
                        ordinary?.lines.first { $0.text.hasPrefix("2.45.2") }?.kind == .header,
                        "mutation-capable repository diff parsing retains its existing semantics")
                }
            }
        }

        @Test("Mailbox patch trailer") private static func testMailboxPatchTrailer() throws {
            let patch =
                "From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001\nFrom: Parity <p@example.invalid>\nSubject: [PATCH] Add file\n\n---\n new.txt | 1 +\n\ndiff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0000000..3b18e51\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello\n-- \n2.45.2\n\n"
            let preview = try PatchPreviewParser.parse(Data(patch.utf8))
            let file = try #require(preview.files.first, "patch file")
            let text = (preview.diffs[file.id]?.lines ?? []).map(\.text)
            try #require(preview.files.count == 1 && file.additions == 1 && file.deletions == 0, "counts \(file)")
            try #require(
                text.contains("hello") && text.contains(where: { $0 == "-- " || $0 == "- " || $0 == "--" }) && text.contains("2.45.2"),
                "mailbox trailer retained after the added line \(text)")
        }

        @Test("File list user scripts") private static func testFileListUserScripts() throws {
            try #require(
                ChangedFilesViewController.userScriptItems([], target: nil, action: nil).isEmpty, "no enabled scripts adds no Run script host or separator")
            var direct = ScriptDefinition()
            direct.name = "&Direct"
            direct.onEvent = .showInFileList
            var hosted = ScriptDefinition()
            hosted.name = "Hosted"
            hosted.onEvent = .none
            let both = ChangedFilesViewController.userScriptItems([direct, hosted], target: nil, action: nil)
            try #require(
                both.map(\.title) == ["Run script", "Direct"] && both[0].submenu?.items.map(\.title) == ["Hosted"],
                "hosted scripts under Run script, file-list scripts direct \(both.map(\.title))")
            let onlyDirect = ChangedFilesViewController.userScriptItems([direct], target: nil, action: nil)
            try #require(onlyDirect.map(\.title) == ["Direct"], "empty host hidden like upstream Enable(false) \(onlyDirect.map(\.title))")
        }

        @Test("File tree folder blame enablement") private static func testFileTreeFolderBlameEnablement() async throws {
            let savedBlame = AppSettingsStore.shared.blamePreferences
            AppSettingsStore.shared.saveBlamePreferences(BlamePreferences())
            defer { AppSettingsStore.shared.saveBlamePreferences(savedBlame) }
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            try fixture.write("nested/inner/file.txt", "one\n")
            try fixture.write("nested/second.txt", "two\n")
            try fixture.commitAll("Initial files")
            _ = try await module.loadRepositoryState()
            let revision = try await module.loadBlameRevision(nil)
            let tree = RevisionDiffViewController(mode: .fileTree)
            tree.fileStatusSource = module
            tree.blameSource = module
            tree.repositoryURL = fixture.repo
            let window = NSWindow(contentViewController: tree)
            window.setContentSize(NSSize(width: 900, height: 600))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            tree.setDiffs(revisions: [revision], headID: revision.objectID)
            let deadline = ContinuousClock.now + .seconds(15)
            while tree.filesController.allItems.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            tree.selectFileOrFolder("nested")
            let menu = NSMenu()
            tree.filesController.menuNeedsUpdate(menu)
            func find(_ id: String, _ items: [NSMenuItem]) -> NSMenuItem? {
                for item in items {
                    if item.identifier?.rawValue == id { return item }
                    if let hit = find(id, item.submenu?.items ?? []) { return hit }
                }
                return nil
            }
            try #require(tree.filesController.selectedFolder != nil, "folder selected")
            let context = tree.filesController.menuContext()
            try #require(
                find("file.blame", menu.items)?.isEnabled == true,
                "File tree folder Blame enabled with inline blame handoff exists=\(find("file.blame", menu.items) != nil) canBlame=\(context.canBlame) display=\(context.isDisplayOnlyDiff) inTree=\(context.blameInFileTree) folder=\(String(describing: context.selectedFolder)) count=\(context.count) tracked=\(context.isAnyTracked)"
            )
        }

        @Test("Undo last commit suppression on no") private static func testUndoLastCommitSuppressionOnNo() throws {
            let key = GitUICommands.dontConfirmUndoLastCommitKey
            let saved = UserDefaults.standard.object(forKey: key)
            defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            UserDefaults.standard.removeObject(forKey: key)
            var prompts = 0
            let declined = GitUICommands.confirmUndoLastCommit { alert in
                prompts += 1
                alert.suppressionButton?.state = .on
                return .alertSecondButtonReturn
            }
            try #require(!declined && UserDefaults.standard.bool(forKey: key), "Don't show again is stored when answering No")
            let next = GitUICommands.confirmUndoLastCommit { _ in
                prompts += 1
                return .alertSecondButtonReturn
            }
            try #require(next && prompts == 1, "suppressed confirmation proceeds without prompting")
        }

        @Test("Remote save fetch remembers pull action") private static func testRemoteSaveFetchRemembersPullAction() throws {
            let saved = AppSettingsStore.shared.pullPreferences
            defer { AppSettingsStore.shared.savePullPreferences(saved) }
            var preferences = saved
            preferences.formAction = .merge
            preferences.autoStash = true
            AppSettingsStore.shared.savePullPreferences(preferences)
            GitUICommands.rememberFetchPullAction()
            let after = AppSettingsStore.shared.pullPreferences
            try #require(
                after.formAction == .fetch && after.autoStash, "remote-save fetch persists Fetch as the Pull dialog action and leaves AutoStash unchanged")
        }

        @Test("Git grep options persist on text change") private static func testGitGrepOptionsPersistOnTextChange() throws {
            let saved = AppSettingsStore.shared.fileStatusListPreferences
            defer { AppSettingsStore.shared.saveFileStatusListPreferences(saved) }
            var preferences = saved
            preferences.gitGrepUserArguments = ""
            AppSettingsStore.shared.saveFileStatusListPreferences(preferences)
            let controller = FindInCommitFilesGitGrepWindowController(locate: { _ in }, toggle: { _ in }, closed: {})
            func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
            let field = try #require(
                walk(controller.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "GitGrepOptions" },
                "options field")
            field.stringValue = "--fixed-strings"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            try #require(
                AppSettingsStore.shared.fileStatusListPreferences.gitGrepUserArguments == "--fixed-strings", "typed options are consumed before Enter or close")
            controller.window?.delegate = nil
        }

        @Test("Commit template slot title") private static func testCommitTemplateSlotTitle() throws {
            try #require(CommitTemplateSlotTitle.title(index: 0, name: "Audit template") == "1 : Audit template", "upstream slot caption format")
            try #require(CommitTemplateSlotTitle.title(index: 9, name: "") == "10 : <empty>", "empty slot caption")
            let long = String(repeating: "x", count: 60)
            try #require(CommitTemplateSlotTitle.title(index: 1, name: long) == "2 : " + String(repeating: "x", count: 47) + "...", "ShortenTo(50) caption")
        }

        @Test("Tag remote and sort defaults") private static func testTagRemoteAndSortDefaults() throws {
            let id = testObjectID("b8")
            let untracked = RepositoryReferenceState(
                branches: [Branch(id: "refs/heads/main", name: "main", commitID: id, isCurrent: true, isRemote: false, remoteName: nil, ahead: 0, behind: 0)],
                tags: [], referencesByCommit: [:])
            try #require(GitUICommands.currentRemote(references: untracked) == "", "untracked current branch gives an empty Delete tag remote")
            let tracked = RepositoryReferenceState(
                branches: [
                    Branch(id: "refs/heads/main", name: "main", commitID: id, isCurrent: true, isRemote: false, remoteName: "upstream", ahead: 0, behind: 0)
                ], tags: [], referencesByCommit: [:])
            try #require(GitUICommands.currentRemote(references: tracked) == "upstream", "tracked current branch remote")
            try #require(RepositoryTreePreferences().sortOrder == .descending, "branch sort order defaults to descending like RefsSortOrder")
            var result: String?? = .none
            let goTo = GoToCommitDialog(branches: ["feature/nested", "main"], tags: ["v1.0"], initialExpression: "", completion: { result = $0 })
            let view = goTo.view
            let combos = allSubviews(view).compactMap { $0 as? NSComboBox }
            try #require(
                combos.map(\.stringValue) == ["v1.0", "feature/nested"], "tag and branch combos show the first reference \(combos.map(\.stringValue))")
            let expression = allSubviews(view).compactMap { $0 as? NSTextField }.first { !($0 is NSComboBox) && $0.isEditable }
            try #require(expression?.stringValue == "" && result == nil, "default combo text does not commit a selection")
        }

        @Test("Go to commit reference choice accepts") private static func testGoToCommitReferenceChoiceAccepts() throws {
            var result: String?? = .none
            let goTo = GoToCommitDialog(branches: ["feature/nested", "main"], tags: ["v1.0"], initialExpression: "", completion: { result = $0 })
            let combos = allSubviews(goTo.view).compactMap { $0 as? NSComboBox }
            let tags = try #require(combos.first, "tag combo")
            tags.selectItem(at: 0)
            tags.delegate?.comboBoxSelectionDidChange?(Notification(name: NSComboBox.selectionDidChangeNotification, object: tags))
            try #require(result == .some("refs/tags/v1.0"), "choosing a tag accepts immediately \(String(describing: result))")
        }

        @Test("Contributors reopen defaults to developers") private static func testContributorsReopenDefaultsToDevelopers() throws {
            ContributorsWindowController.show(owner: nil, modal: false)
            ContributorsWindowController.selectTabForTesting(2)
            try #require(ContributorsWindowController.selectedTabForTesting == "Designers", "Designers selected")
            ContributorsWindowController.closeForTesting()
            ContributorsWindowController.show(owner: nil, modal: false)
            try #require(ContributorsWindowController.selectedTabForTesting == "Developers", "reopening Contributors starts on Developers")
            ContributorsWindowController.closeForTesting()
        }

        @Test("Build server settings enablement") private static func testBuildServerSettingsEnablement() throws {
            let check = InheritedValueCheckbox(checkboxWithTitle: "Test results", target: nil, action: nil)
            check.setInherited(nil)
            var states = [check.state]
            for _ in 0..<3 {
                check.setNextState()
                states.append(check.state)
            }
            try #require(states == [.mixed, .off, .on, .off], "inherited checkbox cycles Indeterminate -> Off -> On -> Off \(states.map(\.rawValue))")
            try #require(
                !BuildServerSettingsPageController.isAbsoluteURI("not-a-url") && BuildServerSettingsPageController.isAbsoluteURI("http://127.0.0.1:9")
                    && !BuildServerSettingsPageController.isAbsoluteURI(""), "GitLab links require an absolute URI after editing")
        }

        @Test("Toolbar overflow keeps clipped controls reachable") private static func testToolbarOverflowKeepsClippedControlsReachable() throws {
            func host(_ stack: NSStackView, width: CGFloat) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
                window.contentView = content
                stack.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
                    stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                    content.widthAnchor.constraint(equalToConstant: width),
                ])
                content.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                return window
            }
            let filters = RevisionFilterToolbar()
            let overflow = ToolStripOverflow()
            let filterStack = NSStackView(views: filters.views + [overflow.button])
            filterStack.orientation = .horizontal
            overflow.attach(to: filterStack, groups: filters.overflowGroups)
            let narrow = host(filterStack, width: 260)
            overflow.updateButton()
            let groups = overflow.overflowGroups
            try #require(!groups.isEmpty && !overflow.button.isHidden, "clipped filter controls expose the overflow button")
            try #require(
                groups.last?.contains(filters.firstParentButton) == true && groups.contains { $0.contains(filters.revisionCombo) },
                "overflow keeps the text filter and later controls reachable")
            try #require(!groups.contains { $0.contains(filters.advancedButton) }, "leading filter controls stay on the toolbar")
            narrow.close()
            let wideFilters = RevisionFilterToolbar()
            let wideStack = NSStackView(views: wideFilters.views)
            let wideOverflow = ToolStripOverflow()
            wideStack.addArrangedSubview(wideOverflow.button)
            wideOverflow.attach(to: wideStack, groups: wideFilters.overflowGroups)
            let wide = host(wideStack, width: 1400)
            wideOverflow.updateButton()
            try #require(wideOverflow.button.isHidden && wideOverflow.overflowGroups.isEmpty, "no overflow when the toolbar fits")
            wide.close()

            let commitOverflow = CommitToolbarOverflow()
            let message = NSPopUpButton(frame: .zero, pullsDown: true)
            message.addItem(withTitle: "Commit message")
            let templates = NSPopUpButton(frame: .zero, pullsDown: true)
            templates.addItems(withTitles: ["Commit templates", "Settings"])
            let create = NSButton(title: "Create branch", target: nil, action: nil)
            let options = NSPopUpButton(frame: .zero, pullsDown: true)
            options.addItem(withTitle: "Options")
            for control in [message, templates, create, options] { control.setContentCompressionResistancePriority(.required, for: .horizontal) }
            let commitStack = NSStackView(views: [message, templates, create, options, commitOverflow.button])
            commitOverflow.attach(to: commitStack, overflowing: [create, templates])
            let commitWindow = host(commitStack, width: 250)
            commitOverflow.updateButton()
            try #require(
                message.frame.width >= message.intrinsicContentSize.width && message.superview != nil,
                "Commit message label is not truncated")
            try #require(
                commitOverflow.overflowTitles.contains("Create branch") && !commitOverflow.button.isHidden,
                "Create branch remains available from the overflow \(commitOverflow.overflowTitles)")
            commitWindow.close()
        }

        private final class AutosizeSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            let rows: [[String: String]]
            init(rows: [[String: String]]) { self.rows = rows }
            func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                let field = NSTextField(labelWithString: rows[row][tableColumn?.identifier.rawValue ?? ""] ?? "")
                field.lineBreakMode = .byTruncatingTail
                return field
            }
        }

        @Test("Columns autosize to cell contents") private static func testColumnsAutosizeToCellContents() throws {
            let sha = String(repeating: "a", count: 40)
            let source = AutosizeSource(rows: [["sha": sha, "ref": "HEAD@{0}"], ["sha": "b", "ref": "HEAD@{12}"]])
            let table = NSTableView()
            for id in ["sha", "ref"] {
                let column = NSTableColumn(identifier: .init(id))
                column.title = id == "sha" ? "SHA-1" : "A very long header title"
                column.width = 50
                column.minWidth = 20
                table.addTableColumn(column)
            }
            table.dataSource = source
            table.delegate = source
            AppKitFactory.autosizeColumns(table, ["sha", "ref"])
            let shaWidth = NSTextField(labelWithString: sha).intrinsicContentSize.width
            let refWidth = NSTextField(labelWithString: "HEAD@{12}").intrinsicContentSize.width
            try #require(
                table.tableColumns[0].width >= shaWidth && table.tableColumns[0].width <= shaWidth + 12,
                "SHA column sizes to the full 40-character SHA \(table.tableColumns[0].width) vs \(shaWidth)")
            try #require(
                table.tableColumns[1].width >= refWidth && table.tableColumns[1].width < table.tableColumns[1].headerCell.cellSize.width,
                "AllCellsExceptHeader ignores the header width")
            AppKitFactory.autosizeColumns(table, ["ref"], includeHeader: true)
            try #require(table.tableColumns[1].width >= table.tableColumns[1].headerCell.cellSize.width, "AllCells includes the header width")
        }

        @Test("Owner relative placement") private static func testOwnerRelativePlacement() throws {
            let owner = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.orderFront(nil)
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            child.isReleasedWhenClosed = false
            OwnedModalWindow.center(child, over: owner)
            try #require(
                abs(child.frame.midX - owner.frame.midX) <= 1 && abs(child.frame.midY - owner.frame.midY) <= 1,
                "dialogs centre on their owner \(child.frame) over \(owner.frame)")
            let origin = FileViewerFindPanel.origin(ownerFrame: owner.frame)
            try #require(origin.x == owner.frame.minX + 100 && origin.y == owner.frame.maxY - 100, "Find opens at owner location plus (100,100)")
            owner.orderOut(nil)
            child.setFrameOrigin(.zero)
            OwnedModalWindow.center(child, over: owner, includingHiddenOwner: true)
            try #require(
                abs(child.frame.midX - owner.frame.midX) <= 1 && abs(child.frame.midY - owner.frame.midY) <= 1,
                "CLI read-only windows retain their launching owner's display/position after it is hidden")
            owner.close()
        }

        @MainActor
        @Test("General and browse settings") private static func testGeneralAndBrowseSettings() async throws {
            try await RepositoryWorkflowTests.hostedSettings("general") { controller, store, apply in
                let views = RepositoryWorkflowTests.settingsViews(controller)
                let groups = views.compactMap { $0 as? NSBox }.map(\.title)
                try #require(groups == ["Performance", "Behaviour"], "General groups follow upstream \(groups)")
                let titles = views.compactMap { ($0 as? NSButton)?.title }
                try #require(!titles.contains("Show file history in the main window"), "file-history location toggle lives on Browse repository window")
                let notice = views.first { $0.accessibilityIdentifier() == "Settings.InstantSaveNotice" }
                try #require(notice?.isHidden == true, "instant-save notice hidden on General")
                let limit = try #require(views.first { $0.accessibilityIdentifier() == "Settings.CommitsLimit" } as? NSButton, "commits limit checkbox")
                let field = try #require(views.first { $0.accessibilityIdentifier() == "Settings.MaxCommits" } as? NSTextField, "commits limit field")
                try #require(
                    limit.title == "Limit number of commits to be loaded" && (limit.state == .on) == field.isEnabled, "field enabled only while limited")
                if limit.state == .off {
                    limit.state = .on
                    NSApp.sendAction(limit.action!, to: limit.target, from: limit)
                }
                try #require(field.isEnabled, "checking the limit enables the field")
                limit.state = .off
                NSApp.sendAction(limit.action!, to: limit.target, from: limit)
                try #require(!field.isEnabled, "unchecking disables the field")
                apply()
                let deadline = Date().addingTimeInterval(5)
                while store.browseDisplayPreferences.maximumRevisionCount != 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                try #require(
                    store.browseDisplayPreferences.maximumRevisionCount == 0, "unchecked limit stores 0 \(store.browseDisplayPreferences.maximumRevisionCount)")
                let update = try #require(
                    views.compactMap { $0 as? NSButton }.first { $0.title == "Update submodules on checkout" }, "update submodules checkbox")
                try #require(update.allowsMixedState, "update submodules is a three-state checkbox")
                try #require(
                    views.contains { $0.accessibilityIdentifier() == "Settings.DefaultCloneDestination" }
                        && views.contains { $0.accessibilityIdentifier() == "Settings.DefaultCloneDestinationBrowse" },
                    "default clone destination has a history combo and Browse")
            }
            try #require(
                GeneralSettingsPresentation.cloneDestinationHistory(["/a/x", "/A/y", "/b/z", "/a/w"]) == ["/a", "/b"],
                "clone history uses distinct parent paths")
            try await RepositoryWorkflowTests.hostedSettings("application") { controller, _, _ in
                let notice =
                    RepositoryWorkflowTests.settingsViews(controller).first { $0.accessibilityIdentifier() == "Settings.InstantSaveNotice" } as? NSTextField
                try #require(
                    notice?.isHidden == false && notice?.stringValue == SettingsViewController.instantSaveNoticeText, "Checklist shows the instant-save notice")
            }
            try await RepositoryWorkflowTests.hostedSettings("browse") { controller, _, _ in
                let groups = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSBox }.map(\.title)
                try #require(Array(groups.prefix(2)) == ["General", "Tabs (restart required)"], "Browse repository window groups \(groups)")
            }
        }

        @MainActor
        @Test("Git advanced and other settings") private static func testGitAdvancedAndOtherSettings() async throws {
            try #require(
                GitAdvancedSettingsPresentation.title(key: "pull.rebase", description: "Rebase local branch when pulling (instead of merge)")
                    == "Rebase local branch when pulling (instead of merge) [pull.rebase]",
                "Git Advanced keeps the upstream description with the key suffix")
            try #require(
                GitAdvancedSettingsPresentation.settings.map(\.0) == [
                    "pull.rebase", "fetch.prune", "merge.autostash", "rebase.autostash", "rebase.autosquash", "rebase.updaterefs", "rerere.enabled",
                    "rerere.autoupdate",
                ],
                "Git Advanced order follows upstream positions")
            try #require(
                GitAdvancedSettingsPresentation.state(nil) == .mixed && GitAdvancedSettingsPresentation.state("yes") == .on
                    && GitAdvancedSettingsPresentation.state("") == .off
                    && GitAdvancedSettingsPresentation.state("merges") == .mixed && GitAdvancedSettingsPresentation.configValue(.mixed) == "",
                "three-state mapping matches upstream")
            try #require(
                SshSettingsPresentation.path(usesOther: false, otherPath: "/x/ssh") == ""
                    && SshSettingsPresentation.path(usesOther: true, otherPath: "/x/ssh") == "/x/ssh",
                "OpenSSH clears GIT_SSH; Other uses its path")
            GitSshEnvironment.apply("/usr/bin/ssh")
            try #require(ProcessInfo.processInfo.environment["GIT_SSH"] == "/usr/bin/ssh", "GIT_SSH applied to git processes")
            GitSshEnvironment.apply("")
            try #require(ProcessInfo.processInfo.environment["GIT_SSH"] == nil, "empty path unsets GIT_SSH")
            try #require(
                SettingsFilePickers.commitTemplateTitle == "Select file" && SettingsFilePickers.commitTemplateExtensions == ["txt"],
                "commit template picker purpose and filter")
            let filter = SettingsFilePickers.gitExecutableFilter
            try #require(
                filter.panel(NSObject(), shouldEnable: URL(fileURLWithPath: "/usr/bin/git"))
                    && !filter.panel(NSObject(), shouldEnable: URL(fileURLWithPath: "/usr/bin/env")),
                "Git executable picker enables only git")
            try #require(
                BuildServerType.allCases.map(\.rawValue) == [
                    "GitHub Actions", "Jenkins", "TeamCity", "Gitlab", "Azure DevOps and Team Foundation Server (since TFS2015)", "AppVeyor",
                ],
                "provider selector order follows the pinned plugin order")
            let mono = FontChooserDialog.families(fixedPitchOnly: true)
            try #require(!mono.isEmpty && mono.contains("Menlo") && !mono.contains("Helvetica"), "code font chooser lists fixed-pitch families only")
            let chooser = FontChooserViewController(font: NSFont(name: "Menlo-Bold", size: 13)!, fixedPitchOnly: true)
            _ = chooser.view
            try #require(
                chooser.family == "Menlo" && chooser.memberName == "Menlo-Bold" && chooser.size == 13,
                "chooser preselects the current font \(chooser.family) \(chooser.memberName)")
            let systemMono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let systemChooser = FontChooserViewController(font: systemMono, fixedPitchOnly: true)
            _ = systemChooser.view
            try #require(
                systemChooser.selectedFont?.fontName == systemMono.fontName && systemChooser.family == (systemMono.familyName ?? systemMono.fontName),
                "the default system monospace font is preselected")
            let well = RemoteColorWell()
            well.color = .clear
            try #require(well.isUnset, "unset remote color well seeds the theme colour")
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("settings-file-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            try #require(
                ClonePickerLocation.directory(for: temp.path)?.standardizedFileURL.path == temp.standardizedFileURL.path,
                "clone Browse opens at the current destination")
            try await RepositoryWorkflowTests.hostedSettings("detailed") { controller, _, _ in
                let deadline = Date().addingTimeInterval(5)
                while RepositoryWorkflowTests.settingsViews(controller).compactMap({ $0 as? NSBox }).count < 3 && Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let groups = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSBox }.map(\.title)
                try #require(groups == ["Revision graph", "Push window", "Merge window"], "Detailed groups follow upstream \(groups)")
            }
            try await RepositoryWorkflowTests.hostedSettings("appearance") { controller, _, _ in
                let views = RepositoryWorkflowTests.settingsViews(controller)
                let groups = views.compactMap { $0 as? NSBox }.map(\.title)
                try #require(groups == ["General", "Author images", "Language"], "Appearance groups follow upstream \(groups)")
                let provider = views.first { $0.accessibilityIdentifier() == "Settings.AvatarProviderHelp" } as? NSButton
                let fallback = views.first { $0.accessibilityIdentifier() == "Settings.AvatarFallbackHelp" } as? NSButton
                try #require(
                    provider?.toolTip == AppearanceSettingsPresentation.avatarProviderTooltip
                        && fallback?.toolTip == AppearanceSettingsPresentation.fallbackTooltip,
                    "avatar provider and fallback help actions carry upstream tooltips")
                try #require(
                    AppearanceSettingsPresentation.manualURL(anchor: "author-images-avatar-fallback").absoluteString.hasSuffix(
                        "/settings.html#author-images-avatar-fallback"), "help opens the source StandardHtmlUserManual settings anchor")
            }
            try await RepositoryWorkflowTests.hostedSettings("colors") { controller, _, _ in
                let views = RepositoryWorkflowTests.settingsViews(controller)
                let groups = views.compactMap { $0 as? NSBox }.map(\.title)
                try #require(groups == ["Revision graph", "Theme"], "Colors groups follow upstream \(groups)")
                let graph = views.compactMap { $0 as? NSButton }.map(\.title).filter {
                    [
                        "Multicolor branches", "Draw alternate background", "Draw non relatives graph gray", "Draw non relatives text gray",
                        "Highlight authored revisions", "Fill git ref labels",
                    ].contains($0)
                }
                try #require(
                    graph == [
                        "Multicolor branches", "Draw alternate background", "Draw non relatives graph gray", "Draw non relatives text gray",
                        "Highlight authored revisions", "Fill git ref labels",
                    ], "Revision graph order \(graph)")
                try #require(
                    (views.first { $0.accessibilityIdentifier() == "Settings.ColorsRestartNeeded" })?.isHidden == true, "restart notice hidden until modified")
            }
            try await RepositoryWorkflowTests.hostedSettings("commit") { controller, _, _ in
                let views = RepositoryWorkflowTests.settingsViews(controller)
                let titles = views.compactMap { ($0 as? NSButton)?.title }
                let expected = [
                    "Provide auto-completion in commit dialog", "Show errors when staging files", "Ensure the second line of commit message is empty",
                    "Compose commit messages in Commit dialog\n(otherwise the message will be requested during commit)",
                    "Remember 'Amend commit' checkbox on commit form close",
                    "Commit & Push", "Reset Unstaged Changes", "Reset All Changes",
                ]
                try #require(titles.filter(expected.contains) == expected, "Commit dialog Behaviour order follows upstream \(titles)")
                try #require(
                    views.compactMap { $0 as? NSBox }.map(\.title).prefix(2) == ["Behaviour", "Show additional buttons in commit button area"],
                    "Commit dialog groups")
            }
            try await RepositoryWorkflowTests.hostedSettings("diff") { controller, _, _ in
                let groups = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSBox }.map(\.title)
                try #require(Array(groups.prefix(2)) == ["General", "Diff coloring"], "Diff viewer groups \(groups)")
            }
            try await RepositoryWorkflowTests.hostedSettings("fonts") { controller, _, _ in
                let groups = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSBox }.map(\.title)
                try #require(groups.first == "Fonts (restart required)", "Fonts group title")
            }
        }

        @MainActor
        @Test("Patch dialogs") private static func testPatchDialogs() throws {
            let apply = PatchWindowController(
                mode: .apply, source: nil, revisions: [], selected: [], viewPatch: { _ in }, changed: {}, conflicts: { _ in false }, closed: {})
            guard let root = apply.window?.contentView else { throw DialogBehaviorFailure(message: "apply patch view") }
            let views = allSubviews(root)
            func view<T>(_ id: String, _ type: T.Type) throws -> T {
                try #require(views.first { $0.accessibilityIdentifier() == id } as? T, Comment(rawValue: id))
            }
            let file = try view("ApplyPatch.File", NSTextField.self)
            let directory = try view("ApplyPatch.Directory", NSTextField.self)
            let fileMode = try view("ApplyPatch.FileMode", NSButton.self)
            let directoryMode = try view("ApplyPatch.DirectoryMode", NSButton.self)
            try #require(
                views.contains { $0.accessibilityIdentifier() == "ApplyPatch.Top" } && views.contains { $0.accessibilityIdentifier() == "ApplyPatch.Actions" },
                "Apply patch keeps upstream top-right options and right-side action column")
            try #require(fileMode.state == .on && file.isEnabled && !directory.isEnabled, "file mode starts enabled")
            file.stringValue = "audit-file.patch"
            directoryMode.state = .on
            NSApp.sendAction(directoryMode.action!, to: directoryMode.target, from: directoryMode)
            try #require(fileMode.state == .off && !file.isEnabled && directory.isEnabled, "radio modes are exclusive")
            directory.stringValue = "audit-series"
            fileMode.state = .on
            NSApp.sendAction(fileMode.action!, to: fileMode.target, from: fileMode)
            try #require(
                file.stringValue == "audit-file.patch" && directory.stringValue == "audit-series" && file.isEnabled && !directory.isEnabled,
                "file and directory drafts stay independent")
            apply.window?.close()
            let viewer = PatchWindowController(
                mode: .view, source: nil, revisions: [], selected: [], viewPatch: { _ in }, changed: {}, conflicts: { _ in false }, closed: {})
            try #require(
                allSubviews(viewer.window!.contentView!).contains { ($0 as? NSSplitView)?.accessibilityIdentifier() == "ViewPatch.Split" },
                "View patch uses a resizable split")
            let split = allSubviews(viewer.window!.contentView!).compactMap { $0 as? NSSplitView }.first { $0.accessibilityIdentifier() == "ViewPatch.Split" }!
            try #require(split.arrangedSubviews.count == 2 && !split.arrangedSubviews[1].isHidden, "empty/loading standalone preview retains its split pane")
            viewer.window?.close()
            let format = PatchWindowController(
                mode: .format, source: nil, revisions: [], selected: [], currentBranch: "main", viewPatch: { _ in }, changed: {}, conflicts: { _ in false },
                closed: {})
            let bottom = allSubviews(format.window!.contentView!).first { $0.accessibilityIdentifier() == "FormatPatch.BottomRow" } as? NSStackView
            try #require(
                (bottom?.arrangedSubviews.last as? NSButton)?.title == "Create patch(es)"
                    && (bottom?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []).contains("main"),
                "current branch shares the bottom row with Create patch(es) at the right")
            try #require(!allSubviews(format.window!.contentView!).contains { ($0 as? NSButton)?.title == "Close" }, "Format patch has no added Close action")
            format.window?.close()
            try #require(
                DeleteObsoleteBranchesPresentation.confirmation(count: 2) == "Are you sure to delete 2 selected branches?"
                    && DeleteObsoleteBranchesPresentation.instruction(mergedInto: "HEAD")
                        == "Choose branches to delete. Only branches that are fully merged in 'HEAD' will be deleted."
                    && DeleteObsoleteBranchesPresentation.selection(selected: 2, total: 2) == "2/2 branches selected.", "upstream delete-branches wording")
            try #require(
                SubmodulesPresentation.detailFields.map(\.1) == ["Name", "Remote path", "Local path", "Commit", "Branch", "Status"],
                "six labelled detail fields")
            try #require(
                ReleaseNotesPresentation.copyActions.map(\.1) == ["original output", "as text table (tabs)", "as text table (spaces)", "as HTML table"],
                "upstream copy actions")
        }

        @MainActor
        @Test("Loaded patch viewer") private static func testLoadedPatchViewer() async throws {
            let originalPreferences = AppSettingsStore.shared.fileViewerPreferences
            var preferences = originalPreferences
            preferences.textEncoding = .automatic
            AppSettingsStore.shared.updateFileViewerPreferences(preferences)
            defer { AppSettingsStore.shared.updateFileViewerPreferences(originalPreferences) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FV-patch-viewer-" + UUID().uuidString + ".patch")
            try Data(
                "diff --git a/topic.txt b/topic.txt\nnew file mode 100644\n--- /dev/null\n+++ b/topic.txt\n@@ -0,0 +1 @@\n+Topic branch\ndiff --git a/second.txt b/second.txt\n--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old\n+second\n"
                    .utf8
            ).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let controller = PatchWindowController(
                mode: .view, source: nil, revisions: [], selected: [], initialFile: url, viewPatch: { _ in }, changed: {}, conflicts: { _ in false }, closed: {}
            )
            let window = controller.window!
            defer { controller.close() }
            controller.showWindow(nil)
            let root = window.contentView!
            let deadline = ContinuousClock.now + .seconds(5)
            while !allSubviews(root).compactMap({ $0 as? FileViewerTableView }).contains(where: { $0.numberOfRows > 0 }) {
                try #require(ContinuousClock.now < deadline, "loaded patch preview appears")
                try await Task.sleep(for: .milliseconds(20))
            }
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()
            let split = allSubviews(root).compactMap { $0 as? NSSplitView }.first { $0.accessibilityIdentifier() == "ViewPatch.Split" }!
            let header = allSubviews(root).first { $0.accessibilityIdentifier() == "ViewPatch.PathRow" }!
            let headerFrame = header.convert(header.bounds, to: root)
            try #require(headerFrame.height <= 40 && root.bounds.maxY - headerFrame.maxY <= 15, "patch path header stays compact at the top")
            try #require(split.frame.height >= root.bounds.height - 130, "file list and preview receive the available window height")
            try #require(!split.arrangedSubviews[1].isHidden && split.arrangedSubviews[1].frame.height >= 100, "loaded preview pane has real visible height")
            let toolbar = allSubviews(split.arrangedSubviews[1]).compactMap { $0 as? DiffViewerToolbar }.first!
            try #require(
                !toolbar.isHidden && allSubviews(toolbar).contains { ($0 as? NSPopUpButton)?.title == RepositoryTextEncoding.utf8.title },
                "actual loaded fixed patch exposes shared toolbar and decoded encoding")
            let files = allSubviews(root).compactMap { $0 as? NSTableView }.first { !($0 is FileViewerTableView) }!
            files.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let popup = allSubviews(toolbar).compactMap { $0 as? NSPopUpButton }.first!
            let encodingIndex = try #require(
                popup.itemArray.firstIndex { $0.representedObject as? String == RepositoryTextEncoding.windows1252.rawValue },
                "source-default Windows1252 offered for reload")
            popup.selectItem(at: encodingIndex)
            NSApp.sendAction(popup.action!, to: popup.target, from: popup)
            let reloadDeadline = ContinuousClock.now + .seconds(5)
            while files.numberOfRows != 2 || files.selectedRow != 1 {
                try #require(ContinuousClock.now < reloadDeadline, "encoding reload preserves actual selected patch file")
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(popup.title == RepositoryTextEncoding.windows1252.title, "selected encoding is consumed and remains selected after reload")
        }

        @MainActor
        @Test("Lost object shared viewer") private static func testLostObjectSharedViewer() throws {
            let text = "commit object\nAuthor: Parity\n\n    message\n\ndiff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3 +3 @@\n-old\n+new\n"
            let controller = ReadOnlyTextWindowController(title: "View", text: text, filename: "commit.patch", onClose: { _ in })
            defer { controller.close() }
            let table = allSubviews(controller.viewer.view).compactMap { $0 as? FileViewerTableView }.first!
            try #require(
                controller.sourceText == text && table.numberOfRows == FixedPatchLines.lines(text).count, "original object text uses shared fixed-patch parsing"
            )
            try #require(
                controller.viewer.showsLocalToolbar && controller.viewer.toolbarMode == .fixedDiff && controller.viewer.onLinePatch == nil,
                "read-only shared toolbar and hunk gutter")
            let large = String(repeating: "é", count: FilePreview<FileStatusContent>.threshold + 1)
            let deferred = ReadOnlyTextWindowController(title: "View", text: large, filename: "commit.patch", onClose: { _ in })
            let deferredTable = allSubviews(deferred.viewer.view).compactMap { $0 as? FileViewerTableView }.first!
            try #require(
                deferred.viewer.previewPresentation.state == .deferred && deferredTable.numberOfRows == 0,
                "large object parsing and rendering defer until confirmation")
            deferred.close()
            try #require(
                deferred.viewer.previewPresentation.state == .empty && deferred.sourceText == large, "close cancels the deferred preview without changing text")
        }

        @MainActor
        @Test("Script arguments help") private static func testScriptArgumentsHelp() async throws {
            let fixture = TestResources.fixtures.appendingPathComponent("ScriptArgumentsHelp.txt")
            let expected = try String(contentsOf: fixture, encoding: .utf8)
            try #require(
                expected.hasSuffix("\n") && ScriptArgumentsHelp.text == String(expected.dropLast()),
                "exact58-line pinned Arguments help text and token ordering")
            try await RepositoryWorkflowTests.hostedSettings("scripts") { controller, _, _ in
                let button = try #require(
                    RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSButton }.first {
                        $0.accessibilityIdentifier() == "Scripts.ArgumentsHelp"
                    }, "Settings Scripts help action")
                NSApp.sendAction(button.action!, to: button.target, from: button)
                let window = try #require(NSApp.windows.first { $0.title == "Arguments help" && $0.isVisible }, "modeless Arguments help opened")
                defer { window.close() }
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                let panel = try #require(window as? NSPanel, "native help panel")
                let text = try #require(allSubviews(window.contentView!).compactMap { $0 as? NSTextView }.first, "complete selectable help text")
                try #require(
                    panel.worksWhenModal && NSApp.modalWindow !== panel && window.parent === controller.view.window,
                    "owned modeless help remains usable beside Settings")
                try #require(
                    window.contentView!.bounds.size == NSSize(width: 299, height: 439) && !text.isEditable && text.string == ScriptArgumentsHelp.text,
                    "source-size read-only help with complete content")
                try #require(text.frame.width >= 280, "help text has a real readable viewport")
                NSApp.sendAction(button.action!, to: button.target, from: button)
                try #require(NSApp.windows.filter { $0.title == "Arguments help" && $0.isVisible }.count == 1, "repeated help brings the same window forward")
            }
            let suite = "GitExtensionsMac.ScriptHelp." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let scripts = try ScriptsWindowController(store: ApplicationScriptsStore(defaults: defaults), execute: { _, _ in }, cancel: {}, canExecute: false)
            defer { scripts.close() }
            scripts.showWindow(nil)
            let editorHelp = try #require(
                allSubviews(scripts.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Scripts.ArgumentsHelp" },
                "Arguments row exposes the same help action")
            NSApp.sendAction(editorHelp.action!, to: editorHelp.target, from: editorHelp)
            let editorWindow = try #require(NSApp.windows.first { $0.title == "Arguments help" && $0.isVisible }, "editor help opens")
            try #require(
                editorWindow.parent === scripts.window && defaults.data(forKey: "GitExtensionsMac.applicationScripts.v1") == nil,
                "opening help preserves script storage and editor ownership")
            scripts.close()
            try #require(!editorWindow.isVisible, "closing Scripts closes its owned help")
            let owner = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 500, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.orderFront(nil)
            let help = ScriptArgumentsHelpWindow(owner: owner)
            help.showWindow(nil)
            owner.close()
            try #require(help.window?.isVisible == false, "closing help owner closes owned modeless window")
        }

        @MainActor
        @Test("Available encodings dialog") private static func testAvailableEncodingsDialog() async throws {
            let suite = "GitExtensionsMac.Encodings." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            let ascii = RepositoryTextEncoding(ianaName: "us-ascii")!
            let oem = try #require(RepositoryTextEncoding(ianaName: "ibm437"), "native OEM437 encoding is supported")
            let baseline: [RepositoryTextEncoding] = [.utf8, ascii, .utf16LittleEndian, oem, .windows1252]
            try #require(store.includedTextEncodings == baseline, "pinned default selection order and set")
            let japanese = RepositoryTextEncoding(ianaName: "shift_jis")!
            var model = AvailableEncodingsSelection(selected: baseline + [.utf8], supported: baseline + [japanese, .automatic, japanese, .utf16BigEndian])
            try #require(model.selected == baseline && model.available.count == 2, "each encoding belongs to exactly one list; no automatic/duplicates")
            model.exclude(0)
            model.exclude(1)
            model.exclude(2)
            try #require(model.selected == baseline, "Unicode/default/ASCII cannot be removed")
            model.exclude(3)
            try #require(model.selected == Array(baseline.prefix(3)) + [.windows1252] && model.available.contains(oem), "optional encoding moves to Available")
            model.include(model.available.firstIndex(of: japanese)!)
            try #require(model.selected.last == japanese && !model.available.contains(japanese), "include appends in insertion order")
            let before = model.selected
            model.include(-1)
            model.exclude(999)
            try #require(model.selected == before, "empty selection is a no-op")
            defaults.set(
                [RepositoryTextEncoding.westernISO88591.rawValue, RepositoryTextEncoding.utf16BigEndian.rawValue],
                forKey: "GitExtensionsMac.availableEncodings.v1")
            let migrated = store.includedTextEncodings
            try #require(Array(migrated.prefix(2)) == [.westernISO88591, .utf16BigEndian], "existing custom saved order survives")
            store.updateAvailableTextEncodings(baseline + [japanese])
            try #require(
                store.includedTextEncodings.last == japanese && AppSettingsStore(defaults: defaults).includedTextEncodings == migrated,
                "chooser OK changes shared runtime list without persisting before Settings save")
            store.includedTextEncodings = store.includedTextEncodings
            try #require(AppSettingsStore(defaults: defaults).includedTextEncodings == baseline + [japanese], "Settings save persists exact list/order")
            let owner = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.orderFront(nil)
            defer { owner.close() }
            let editor = AvailableEncodingsDialog(selected: baseline)
            let task = Task { await editor.present(owner: owner) }
            try await RepositoryWorkflowTests.waitUntil("encoding modal") { editor.view.window?.isVisible == true && NSApp.modalWindow === editor.view.window }
            let window = editor.view.window!
            window.layoutIfNeeded()
            editor.view.layoutSubtreeIfNeeded()
            try #require(
                editor.view.bounds.size == NSSize(width: 605, height: 315) && editor.selectedList.frame.width > 240 && editor.availableList.frame.width > 240,
                "source client dimensions with readable simultaneous lists")
            try #require(
                !editor.excludeButton.isEnabled && !editor.includeButton.isEnabled && editor.selectedList.selectedRow == -1,
                "initial selection empty and both moves disabled")
            editor.selectedList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try #require(!editor.excludeButton.isEnabled, "selecting protected UTF8 keeps remove disabled")
            editor.selectedList.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
            try #require(editor.excludeButton.isEnabled, "optional encoding enables native remove")
            RepositoryWorkflowTests.click(editor.excludeButton)
            try #require(!editor.selection.selected.contains(.windows1252), "actual move action removes optional selection")
            let row = editor.selection.available.firstIndex(of: .windows1252)!
            editor.availableList.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            RepositoryWorkflowTests.click(editor.includeButton)
            try #require(editor.selection.selected == baseline, "native add restores source insertion order")
            let ok = allSubviews(editor.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!
            try #require(ok.keyEquivalent == "\r", "OK is default keyboard action")
            RepositoryWorkflowTests.click(ok)
            let result = await task.value
            try #require(result == baseline && !window.isVisible, "accepted selection returned and modal closed")
            let cancelled = AvailableEncodingsDialog(selected: baseline)
            let cancelTask = Task { await cancelled.present(owner: owner) }
            try await RepositoryWorkflowTests.waitUntil("encoding cancel modal") { cancelled.view.window?.isVisible == true }
            cancelled.selectedList.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
            RepositoryWorkflowTests.click(cancelled.excludeButton)
            let cancel = allSubviews(cancelled.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
            try #require(cancel.keyEquivalent == "\u{1b}", "Escape cancels")
            RepositoryWorkflowTests.click(cancel)
            let cancelledResult = await cancelTask.value
            try #require(cancelledResult == nil, "Cancel discards moved selections")
            try await RepositoryWorkflowTests.hostedSettings("git_config") { controller, sharedStore, _ in
                try await RepositoryWorkflowTests.waitUntil("Configure available encodings Settings action") {
                    RepositoryWorkflowTests.settingsViews(controller).contains { ($0 as? NSButton)?.accessibilityIdentifier() == "Settings.ConfigureEncodings" }
                }
                let configure = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSButton }.first {
                    $0.accessibilityIdentifier() == "Settings.ConfigureEncodings"
                }!
                let original = sharedStore.includedTextEncodings
                RepositoryWorkflowTests.click(configure)
                try await RepositoryWorkflowTests.waitUntil("Settings child encoding chooser") { NSApp.modalWindow?.title == "Configure available encodings" }
                let child = try #require(NSApp.modalWindow?.contentViewController as? AvailableEncodingsDialog, "Configure opens actual modal two-list editor")
                try #require(controller.currentCategoryID == "git_config", "parent remains on Git Config instead of replacing it with inline checklist")
                child.selectedList.selectRowIndexes(IndexSet(integer: original.firstIndex(of: .windows1252)!), byExtendingSelection: false)
                RepositoryWorkflowTests.click(child.excludeButton)
                child.cancelOperation(nil)
                try await RepositoryWorkflowTests.waitUntil("Settings child Cancel") { NSApp.modalWindow?.title != "Configure available encodings" }
                try #require(sharedStore.includedTextEncodings == original, "actual Settings child Cancel leaves shared list unchanged")
            }

        }

        @MainActor
        @Test("Revision links settings editor") static func testRevisionLinksSettingsEditor() async throws {
            let definition = RevisionLinkDefinition(
                name: "Issues", searchPattern: "#(\\d+)", formats: [.init(caption: "Issue {0}", format: "https://example.invalid/issues/{0}")])
            let menu = NSMenu()
            menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            for provider in RevisionLinkTemplates.allCases {
                let item = NSMenuItem(title: provider.actionTitle, action: nil, keyEquivalent: "")
                let resource = TestResources.images.appendingPathComponent("" + provider.imageName + ".png")
                item.image = NSImage(contentsOf: resource)
                menu.addItem(item)
            }
            let editor = RevisionLinksSettingsEditor(
                definitions: [definition, RevisionLinkDefinition(name: "Second")], selected: 0, editable: true, menu: menu)
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 780, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            editor.layoutSubtreeIfNeeded()
            try #require(
                editor.categories.numberOfRows == 2 && editor.categories.selectedRow == 0 && editor.split.arrangedSubviews[0].frame.width == 192,
                "simultaneous category list and source initial splitter/selection")
            try #require(
                editor.links.tableColumns.map(\.title) == ["Caption", "URI"] && editor.links.tableColumns[0].width == 150 && editor.links.numberOfRows == 2,
                "editable Caption/URI grid plus new blank row")
            let detailFields = allSubviews(editor).compactMap { $0 as? NSTextField }.filter {
                $0.accessibilityIdentifier().hasPrefix("RevisionLinks.") && !$0.accessibilityIdentifier().contains("Format.")
            }
            try #require(
                detailFields.count == 5 && detailFields.allSatisfy { $0.frame.height >= 24 },
                "every native detail field remains readable including empty search patterns")
            let groups = allSubviews(editor).compactMap { $0 as? NSBox }.filter { $0.boxType != .separator }
            try #require(groups.map(\.title) == ["Remote data", "Revision data"], "exact pinned group order")
            let rowCaptions = allSubviews(editor).compactMap { $0 as? NSTextField }.filter {
                ["Search in", "Search pattern", "Nested pattern", "Use remotes"].contains($0.stringValue)
            }
            try #require(
                rowCaptions.count == 6
                    && rowCaptions.allSatisfy { $0.frame.height >= $0.intrinsicContentSize.height && $0.frame.width >= $0.intrinsicContentSize.width },
                "all six source row captions stay visible and untruncated: \(rowCaptions.map { ($0.stringValue, $0.frame.size, $0.intrinsicContentSize) })")
            try #require(editor.links.enclosingScrollView!.frame.height >= 100 && editor.links.frame.width > 400, "grid has a readable visible viewport")
            try #require(
                editor.templates.menu?.items.dropFirst().map(\.title) == ["Add GitHub templates", "Add Azure DevOps templates"]
                    && editor.templates.menu!.items.dropFirst().allSatisfy { $0.image != nil }, "attached Add arrow/provider choices, order and icons")
            try #require(
                editor.help.isEnabled && RevisionLinksSettingsEditor.helpURL.path.hasSuffix("settings.html")
                    && RevisionLinksSettingsEditor.helpURL.fragment == "revision-links", "source manual Help destination")
            window.setContentSize(NSSize(width: 600, height: 550))
            for _ in 0..<4 {
                editor.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let revisionOptions = allSubviews(editor).compactMap { $0 as? NSButton }.filter {
                ["Message", "Local branch name", "Remote branch name"].contains($0.title)
            }
            try #require(
                revisionOptions.count == 3
                    && revisionOptions.allSatisfy { !$0.isHidden && $0.frame.width >= $0.intrinsicContentSize.width && $0.superview!.bounds.contains($0.frame) },
                "narrow editor wraps every revision option without clipping/detaching")
            window.setContentSize(NSSize(width: 780, height: 550))
            for _ in 0..<4 {
                editor.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            var updates: [RevisionLinkDefinition] = []
            editor.onChange = { _, value in updates.append(value) }
            let caption = editor.tableView(editor.links, viewFor: editor.links.tableColumns[0], row: 1) as! NSTextField
            caption.stringValue = "New link"
            caption.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: caption))
            let uri = editor.tableView(editor.links, viewFor: editor.links.tableColumns[1], row: 1) as! NSTextField
            uri.stringValue = "https://example.invalid/%COMMIT_HASH%"
            uri.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: uri))
            try #require(
                updates.last?.formats.last == .init(caption: "New link", format: uri.stringValue) && editor.links.numberOfRows == 3,
                "editable blank row enters shared model and exposes next row")
            editor.links.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            editor.links.onDelete?()
            try #require(editor.definitions[0].formats == definition.formats, "Delete removes selected link row only")
            editor.categories.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let name = allSubviews(editor).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "RevisionLinks.Name" }!
            try #require(name.stringValue == "Second" && editor.links.numberOfRows == 1, "category switching replaces detail/formats without stale values")
            let many = RevisionLinksSettingsEditor(
                definitions: (0...120).map { RevisionLinkDefinition(name: "Category \($0)") }, selected: 120, editable: true, menu: NSMenu())
            window.contentView = many
            for _ in 0..<4 {
                many.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            try #require(many.categories.visibleRect.intersects(many.categories.rect(ofRow: 120)), "newly selected category is revealed below a long list")
            let remotes = allSubviews(many).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "RevisionLinks.UseRemotes" }!
            remotes.stringValue = "  origin|upstream  "
            remotes.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: remotes))
            try #require(many.definitions[120].useRemotesPattern == "origin|upstream", "source Leave trims remote matching expression")
            let readonly = RevisionLinksSettingsEditor(definitions: [definition], selected: 0, editable: false, menu: NSMenu())
            try #require(
                !readonly.addButton.isEnabled && !readonly.removeButton.isEnabled && readonly.categories.isEnabled && !readonly.links.isEnabled,
                "effective categories navigable while all mutation controls disabled")
            let empty = RevisionLinksSettingsEditor(definitions: [], selected: -1, editable: true, menu: NSMenu())
            try #require(
                empty.addButton.isEnabled && !empty.removeButton.isEnabled && !empty.help.isEnabled && empty.links.numberOfRows == 0,
                "no-selection detail disabled/blank while Add remains available")
            try await RepositoryWorkflowTests.hostedSettings("revision_links") { controller, store, apply in
                @MainActor func current() -> RevisionLinksSettingsEditor {
                    RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? RevisionLinksSettingsEditor }.first!
                }
                try #require(current().definitions.isEmpty, "empty Settings starts without a definition")
                RepositoryWorkflowTests.click(current().addButton)
                try #require(
                    current().definitions.count == 1 && current().selectedIndex == 0 && store.revisionLinksXML == nil,
                    "primary Add selects unsaved new category")
                RepositoryWorkflowTests.click(current().addButton)
                try #require(
                    current().definitions.count == 1 && current().selectedIndex == -1,
                    "duplicate new definition skipped; uninserted object has no selection like upstream")
                current().categories.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let github = current().templates.menu!.items.first { $0.title == "Add GitHub templates" }!
                NSApp.sendAction(github.action!, to: github.target, from: github)
                try await RepositoryWorkflowTests.waitUntil("templates with previous new category") { current().definitions.count == 4 }
                try #require(
                    current().selectedIndex == 1 && current().definitions[current().selectedIndex].name == "GitHub - Code",
                    "first inserted template selected instead of previous new definition")
                for _ in 0..<3 { RepositoryWorkflowTests.click(current().removeButton) }
                current().categories.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let field = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSTextField }.first {
                    $0.accessibilityIdentifier() == "RevisionLinks.Name"
                }!
                field.stringValue = "Saved category"
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                apply()
                try await RepositoryWorkflowTests.waitUntil("revision category persisted") { store.revisionLinksXML != nil }
                let persisted = try RevisionLinkDefinition.decode(store.revisionLinksXML)
                try #require(persisted.first?.name == "Saved category", "grid/category editor uses existing Settings persistence")
                RepositoryWorkflowTests.click(current().removeButton)
                try #require(current().definitions.isEmpty && current().selectedIndex == -1, "deleting last category blanks and disables detail")
            }
        }

        @MainActor
        @Test("Hotkeys settings editor") static func testHotkeysSettingsEditor() async throws {
            let editor = HotkeysSettingsEditor(overrides: [:])
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 730, height: 525), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            editor.layoutSubtreeIfNeeded()
            try #require(
                editor.categories.numberOfRows > 1 && editor.categories.selectedRow == -1 && editor.commands.numberOfRows == 0
                    && editor.recorder.title == "None", "initial category/command selections empty and recorder None")
            try #require(
                editor.categories.enclosingScrollView!.frame.width == 232 && editor.commands.tableColumns.map(\.title) == ["Command", "Key"]
                    && editor.commands.tableColumns[0].width == 222, "source category/table structure and column sizing")
            try #require(
                editor.commands.enclosingScrollView!.frame.height > 350 && editor.recorder.frame.width > 300,
                "lists and hotkey field have real usable dimensions: table=\(editor.commands.enclosingScrollView!.frame), recorder=\(editor.recorder.frame)")
            editor.categories.selectRowIndexes(IndexSet(integer: editor.categoryNames.firstIndex(of: "Browse")!), byExtendingSelection: false)
            let browse = editor.displayedCommands
            try #require(
                editor.selectedCategory == "Browse" && editor.commands.numberOfRows == browse.count && editor.selectedCommand == nil,
                "category exposes all simultaneous bindings without auto-selecting command")
            try #require(
                Array(browse.prefix(4).map(\.id)) == ["addNotes", "checkoutBranch", "closeToDashboard", "commit"], "command rows follow pinned manager order")
            try #require(
                browse.contains { $0.id == "focus.tree" } && !editor.categoryNames.contains("Browse panes"),
                "Browse focus commands remain in their source owning category")
            let openRow = browse.firstIndex { $0.id == "openRepository" }!
            editor.commands.selectRowIndexes(IndexSet(integer: openRow), byExtendingSelection: false)
            let custom = ApplicationKeyChord("k", [.command, .control, .shift, .option])
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: custom.modifiers), timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
            editor.recorder.keyDown(with: event)
            try #require(editor.pendingChord == custom && editor.overrides.isEmpty, "recording is pending until per-binding Apply")
            RepositoryWorkflowTests.click(editor.applyBinding)
            try #require(
                editor.overrides["openRepository"] == custom && editor.commands.selectedRow == -1 && editor.recorder.title == "None",
                "binding Apply updates row model then clears command selection")
            let refreshRow = browse.firstIndex { $0.id == "refresh" }!
            editor.commands.selectRowIndexes(IndexSet(integer: refreshRow), byExtendingSelection: false)
            editor.recorder.keyDown(with: event)
            RepositoryWorkflowTests.click(editor.applyBinding)
            try #require(
                editor.overrides["refresh"] == custom && editor.overrides["openRepository"] == custom,
                "upstream permits duplicate assignments without rejecting or overwriting other binding")
            editor.commands.selectRowIndexes(IndexSet(integer: openRow), byExtendingSelection: false)
            RepositoryWorkflowTests.click(editor.clearBinding)
            try #require(
                editor.overrides["openRepository"] == .init("") && editor.selectedCommand == nil,
                "Clear immediately sets selected binding None and clears selection")
            try #require(
                Array(editor.categoryNames.prefix(7)) == [
                    "Commit", "Browse", "Repository tree", "Revision grid", "File viewer", "Conflict resolver", "File status list",
                ], "category presentation follows pinned manager order with native names")
            let savedEditor = HotkeysSettingsEditor(overrides: ["openRepository": custom])
            savedEditor.recorder.onRecord?(custom)
            let savedColor = savedEditor.recorder.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            try #require(savedColor == .systemRed, "duplicate warning observes loaded override keys, not only default keys")
            let defaults = ApplicationHotkeys.definitions.first { !$0.defaultChord.key.isEmpty }!.defaultChord
            editor.recorder.onRecord?(defaults)
            let color = editor.recorder.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            try #require(color == .systemRed, "already-used default key receives source duplicate warning color")
            RepositoryWorkflowTests.click(editor.reset)
            try #require(
                editor.overrides.isEmpty && editor.selectedCategory == nil && editor.commands.numberOfRows == 0 && editor.recorder.title == "None",
                "Reset all restores defaults with no category/command selection")
            try #require(
                ApplicationKeyChord("\t").title == "Tab" && ApplicationKeyChord("\u{f70f}").title == "F12"
                    && ApplicationKeyChord("\u{f72c}").title == "Page Up", "captured function/navigation keys have readable native names")
            try await RepositoryWorkflowTests.hostedSettings("hotkeys") { controller, store, apply in
                @MainActor func current() -> HotkeysSettingsEditor {
                    RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? HotkeysSettingsEditor }.first!
                }
                current().categories.selectRowIndexes(IndexSet(integer: current().categoryNames.firstIndex(of: "Browse")!), byExtendingSelection: false)
                current().commands.selectRowIndexes(IndexSet(integer: openRow), byExtendingSelection: false)
                current().recorder.onRecord?(custom)
                apply()
                try await RepositoryWorkflowTests.waitUntil("root hotkeys Apply pending") {
                    RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "Settings.Apply" }!
                        .isEnabled
                }
                try #require(store.hotkeyOverrides.isEmpty, "outer Apply does not implicitly assign recorder draft")
                current().commands.selectRowIndexes(IndexSet(integer: openRow), byExtendingSelection: false)
                current().recorder.onRecord?(custom)
                RepositoryWorkflowTests.click(current().applyBinding)
                try #require(store.hotkeyOverrides.isEmpty, "binding Apply remains unsaved application draft")
                apply()
                try await RepositoryWorkflowTests.waitUntil("root hotkeys persistence") { store.hotkeyOverrides["openRepository"] == custom }
                RepositoryWorkflowTests.click(current().reset)
                try #require(store.hotkeyOverrides["openRepository"] == custom, "unsaved Reset does not alter persisted binding")
                let cancel = RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
                RepositoryWorkflowTests.click(cancel)
                try #require(store.hotkeyOverrides["openRepository"] == custom, "Cancel preserves last applied binding")
            }
        }

        @MainActor
        @Test("Commit template settings tabs and validation") private static func testCommitTemplateSettingsTabsAndValidation() throws {
            let store = AppSettingsStore.shared
            let saved = store.commitPreferences
            var initial = saved
            initial.templates = [CommitMessageTemplate()]
            initial.validation.maximumSubjectLength = 50
            initial.validation.maximumLineLength = 72
            initial.ensureSecondLineEmpty = true
            store.saveCommitPreferences(initial)
            defer { store.saveCommitPreferences(saved) }
            let controller = CommitTemplateSettingsViewController()
            let window = NSPanel(contentViewController: controller)
            window.setContentSize(NSSize(width: 698, height: 361))
            controller.panel = window
            defer { window.close() }
            let tabs = try #require(allSubviews(controller.view).compactMap { $0 as? NSTabView }.first, "settings tabs")
            try #require(
                tabs.tabViewItems.map(\.label) == ["Commit templates", "Commit validation"] && tabs.selectedTabViewItem === tabs.tabViewItems[0],
                "upstream tab order and initial page")
            let templateViews = allSubviews(tabs.tabViewItems[0].view!)
            let labels = templateViews.compactMap { ($0 as? NSTextField)?.stringValue }
            try #require(labels.contains("Name:") && labels.contains("Commit template:"), "dedicated template field captions")
            let regex = try #require(templateViews.compactMap { $0 as? NSButton }.first { $0.title == "Enable regex" }, "regex checkbox")
            try #require(
                regex.toolTip == CommitTemplateSettingsPresentation.regexHelp && regex.toolTip!.contains("Group number is optional, default is 1")
                    && regex.toolTip!.contains("Name: commitMessageRegex, issue: ABC-4587"), "complete upstream regex tooltip examples")
            tabs.selectTabViewItem(at: 1)
            let validationViews = allSubviews(tabs.tabViewItems[1].view!)
            let grid = try #require(validationViews.compactMap { $0 as? NSGridView }.first, "validation grid")
            try #require(
                (0..<grid.numberOfRows).compactMap { (grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue } == [
                    "Maximum number of characters in the first line (0 = check disabled):", "Maximum number of characters per line (0 = check disabled):",
                    "Auto-wrap commit message (except subject line)", "Commit must match following RegEx (Empty = check disabled):",
                    "Indent lines after the first line:", "Second line must be empty:",
                ], "exact validation row order and labels")
            let subject = try #require(
                validationViews.first { $0.accessibilityIdentifier() == "CommitValidation.SubjectLength" } as? NSTextField, "subject input")
            let line = try #require(validationViews.first { $0.accessibilityIdentifier() == "CommitValidation.LineLength" } as? NSTextField, "line input")
            let steppers = validationViews.compactMap { $0 as? NSStepper }
            try #require(
                steppers.count == 2 && steppers.allSatisfy { $0.minValue == 0 && $0.maxValue == 100 && $0.increment == 1 && !$0.valueWraps },
                "upstream NumericUpDown default bounds and increment")
            let step = try #require(steppers.first { $0.tag == 0 }, "subject stepper")
            step.integerValue = 51
            NSApp.sendAction(step.action!, to: step.target, from: step)
            try #require(subject.integerValue == 51, "stepper updates numeric field")
            for field in [subject, line] {
                let formatter = try #require(field.formatter as? NumberFormatter, "integer formatter")
                try #require(!formatter.allowsFloats && formatter.minimum == 0 && formatter.maximum == 100, "formatted integer bounds")
            }
            for text in ["", "abc", "1.5", "-1", "101"] {
                try #require(CommitTemplateSettingsPresentation.validatedLength(text) == nil, "rejects invalid numeric value \(text)")
            }
            for value in [0, 1, 50, 99, 100] {
                try #require(CommitTemplateSettingsPresentation.validatedLength(String(value)) == value, "accepted boundary \(value)")
            }
            var results: [Bool] = []
            controller.onFinish = { results.append($0) }
            let ok = try #require(allSubviews(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }, "settings OK")
            subject.stringValue = "invalid"
            NSApp.sendAction(ok.action!, to: ok.target, from: ok)
            try #require(results.isEmpty && store.commitPreferences == initial, "invalid draft is not coerced or persisted")
            subject.stringValue = "60"
            line.stringValue = "80"
            NSApp.sendAction(ok.action!, to: ok.target, from: ok)
            try #require(
                results == [true] && store.commitPreferences.validation.maximumSubjectLength == 60 && store.commitPreferences.validation.maximumLineLength == 80
                    && store.commitPreferences.ensureSecondLineEmpty,
                "accepted settings persist without changing unrelated writing preference")
            let persisted = store.commitPreferences
            let cancelController = CommitTemplateSettingsViewController()
            _ = cancelController.view
            let cancelTabs = allSubviews(cancelController.view).compactMap { $0 as? NSTabView }.first!
            let name = allSubviews(cancelTabs.tabViewItems[0].view!).first { $0.accessibilityIdentifier() == "CommitTemplate.Name" } as! NSTextField
            name.stringValue = "Unsaved"
            let cancel = allSubviews(cancelController.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
            NSApp.sendAction(cancel.action!, to: cancel.target, from: cancel)
            try #require(store.commitPreferences == persisted, "Cancel keeps saved settings unchanged")
        }

        @MainActor
        @Test("Menu icons and keyboard controls") private static func testMenuIconsAndKeyboardControls() throws {
            let menuItem = NSMenuItem(title: "Clear all recent repositories", action: nil, keyEquivalent: "")
            AppKitFactory.setMenuImage("CleanupRepo", for: menuItem)
            if #available(macOS 27.0, *) {
                try #require(menuItem.preferredImageVisibility == .visible, "explicit upstream menu icons remain visible under native automatic image policy")
            }
            for key: UInt16 in [0, 1, 51, 123, 124, 125, 126] {
                try #require(ResetBranchDropdown.opensAfterKeyUp(key, isOpen: false), "typing/navigation reopens closed branch choices")
                try #require(!ResetBranchDropdown.opensAfterKeyUp(key, isOpen: true), "open branch dropdown is retained")
            }
            for key: UInt16 in [36, 53, 58, 61, 76] {
                try #require(!ResetBranchDropdown.opensAfterKeyUp(key, isOpen: false), "Return, Escape and Option do not reopen branch choices")
            }
            let combo = NSComboBox()
            combo.addItems(withObjectValues: ["feature/nested", "topic"])
            combo.stringValue = "main"
            let comboWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            comboWindow.isReleasedWhenClosed = false
            combo.frame = NSRect(x: 10, y: 40, width: 280, height: 26)
            comboWindow.contentView!.addSubview(combo)
            comboWindow.makeKeyAndOrderFront(nil)
            comboWindow.makeFirstResponder(combo)
            defer { comboWindow.close() }
            var dropdownOpened = false
            let observer = NotificationCenter.default.addObserver(forName: NSComboBox.willPopUpNotification, object: combo, queue: nil) { _ in
                MainActor.assumeIsolated { dropdownOpened = true }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try #require(ResetBranchDropdown.open(combo), "native combo arrow is invoked")
            try #require(dropdownOpened, "actual combo popup notification is delivered")
            try #require(combo.stringValue == "main", "native popup preserves excluded typed text")
            let controller = DashboardCategoryTitleDialog(existing: ["Existing"], originalName: "Original")
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 410, height: 90))
            window.contentView?.layoutSubtreeIfNeeded()
            defer { window.close() }
            let fields = allSubviews(controller.view).compactMap { $0 as? NSTextField }
            let label = try #require(fields.first { !$0.isEditable && $0.stringValue == "Category name" }, "category label")
            let field = try #require(fields.first { $0.isEditable }, "category field")
            let labelFrame = label.convert(label.bounds, to: controller.view)
            let fieldFrame = field.convert(field.bounds, to: controller.view)
            try #require(
                abs(labelFrame.midY - fieldFrame.midY) < 1 && labelFrame.maxX < fieldFrame.minX && fieldFrame.maxX <= controller.view.bounds.maxX - 7,
                "label beside full-width category field")
            let buttons = allSubviews(controller.view).compactMap { $0 as? NSButton }
            let ok = buttons.first { $0.title == "OK" }!
            let cancel = buttons.first { $0.title == "Cancel" }!
            let okFrame = ok.convert(ok.bounds, to: controller.view)
            let cancelFrame = cancel.convert(cancel.bounds, to: controller.view)
            try #require(
                okFrame.minX > cancelFrame.maxX && okFrame.maxX >= controller.view.bounds.maxX - 16 && ok.keyEquivalent == "\r"
                    && cancel.keyEquivalent == "\u{1b}", "native right-aligned default/escape actions")
            try #require(!ok.isEnabled && field.stringValue == "Original", "unchanged rename is disabled")
            field.stringValue = "Changed"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            try #require(ok.isEnabled, "changed caption enables OK")
        }

        @Test("Remote branch delete controls") private static func testRemoteBranchDeleteControls() async throws {
            let fixture = try PullGitFixture.make()
            defer { fixture.remove() }
            let repository = try fixture.clone(named: "Remote branch controls")
            try fixture.git(["branch", "--set-upstream-to=origin/main", "main"], in: repository)
            let source = GitRepositoryModule(repositoryURL: repository)
            _ = try await source.loadRepositoryState()
            let state = try await source.loadPushState()
            let controller = RemoteBranchDeleteViewController(
                source: source, initialRemote: "origin", initialBranch: "main", onRepositoryChanged: { _ in }, onClose: {})
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            controller.window = window
            window.setContentSize(NSSize(width: 440, height: 139))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let combo = allSubviews(controller.view).compactMap { $0 as? NSComboBox }.first!
            for _ in 0..<250 {
                if combo.numberOfItems == state.remoteBranches.count { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try #require(
                combo.numberOfItems == state.remoteBranches.count && combo.isEditable && combo.stringValue == "origin/main",
                "editable remote branch field loads and preselects the branch")
            let buttons = allSubviews(controller.view).compactMap { $0 as? NSButton }
            let multiple = buttons.first { $0.toolTip == "Select multiple branches" }!
            let remote = buttons.first { $0.title == "Delete branch(es) from remote repository" }!
            let tracking = buttons.first { $0.title == "Delete local tracking branch (if available)" }!
            let delete = buttons.first { $0.title == "Delete" }!
            try #require(
                tracking.isEnabled && !delete.isEnabled && delete.keyEquivalent == "\r", "preselected tracking candidate and unchecked Delete enablement")
            remote.state = .on
            NSApp.sendAction(remote.action!, to: remote.target, from: remote)
            try #require(delete.isEnabled, "source checkbox enables Delete")
            window.contentView?.layoutSubtreeIfNeeded()
            let label = allTextFields(in: controller.view).first { $0.stringValue == "Select branches" }!
            let labelRect = label.convert(label.bounds, to: controller.view)
            let comboRect = combo.convert(combo.bounds, to: controller.view)
            try #require(
                labelRect.maxX < comboRect.minX && label.frame.width >= label.intrinsicContentSize.width && comboRect.maxX < controller.view.bounds.maxX,
                "branch caption and editable field do not overlap or clip")
            try #require(
                !allTextFields(in: controller.view).contains { $0.stringValue == "Ready" } && buttons.contains { $0.bezelStyle == .helpButton }
                    && RemoteBranchDeleteViewController.helpURL.absoluteString.hasSuffix("branches#delete-branch"),
                "no Ready footer; native Help uses the exact manual section")
            NSApp.sendAction(multiple.action!, to: multiple.target, from: multiple)
            let child = try #require(window.attachedSheet, "existing multiple-branch chooser opens")
            let chooser = try #require(child.contentViewController as? MultipleBranchSelectionViewController, "shared chooser")
            try #require(
                chooser.selected == ["origin/main"] && chooser.branches.map(\.name) == state.remoteBranches.map { "\($0.remote)/\($0.name)" },
                "chooser preserves source order and existing selections")
            chooser.selected = Set(chooser.branches.map(\.name))
            chooser.cancelOperation(nil)
            try #require(
                combo.stringValue == chooser.branches.map(\.name).joined(separator: " "), "closing chooser returns current checked items like upstream")
            combo.stringValue = "missing origin/main"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
            try #require(tracking.isEnabled, "editable field resolves exact known names among space-delimited selections")
            combo.stringValue = "missing"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
            try #require(
                !tracking.isEnabled && tracking.state == .off && delete.isEnabled,
                "unknown typed name supplies no tracking candidate; source Delete checkbox remains authoritative")
            let finalStatus = try fixture.git(["status", "--porcelain"], in: repository)
            try #require(finalStatus.isEmpty, "inspecting controls never deletes or mutates the fixture")
        }

        @Test("Add files tool window") private static func testAddFilesToolWindow() async throws {
            let fixture = try PullGitFixture.make()
            defer { fixture.remove() }
            let repository = try fixture.clone(named: "Add files controls")
            let source = GitRepositoryModule(repositoryURL: repository)
            _ = try await source.loadRepositoryState()
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            let presentation = CommandLinePresentation(owner: owner)
            presentation.hidesOwner = true
            defer { presentation.finish() }
            let controller = CommandLineAddFilesWindow(source: source, paths: [], changed: {})
            let window = controller.window!
            defer { window.close() }
            let completion = Task { try await presentation.wait() }
            defer { completion.cancel() }
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            try #require(
                presentation.presented && window.isVisible && !owner.isVisible && window.canBecomeMain,
                "standalone Add files stays visible when command presentation hides Browse")
            window.contentView?.layoutSubtreeIfNeeded()
            let view = window.contentView!
            let controls = allSubviews(view)
            let fields = controls.compactMap { $0 as? NSTextField }
            let label = fields.first { $0.stringValue == "Filter" }!
            let field = fields.first { $0.isEditable }!
            let buttons = controls.compactMap { $0 as? NSButton }
            let force = buttons.first { $0.title == "Force" }!
            let preview = buttons.first { $0.title == "Show files" }!
            let add = buttons.first { $0.title == "Add files" }!
            let rectangles = [label, field, preview, add].map { $0.convert($0.bounds, to: view) }
            try #require(
                !(window is NSPanel) && !window.styleMask.contains(.miniaturizable) && window.contentLayoutRect.size == NSSize(width: 552, height: 73),
                "compact native tool window")
            try #require(
                rectangles.dropFirst().allSatisfy { abs($0.midY - rectangles[0].midY) < 2 }
                    && zip(rectangles, rectangles.dropFirst()).allSatisfy { $0.maxX < $1.minX }, "Filter field and actions share one ordered row")
            try #require(
                field.stringValue == "." && force.state == .off && !buttons.contains { $0.title == "Cancel" },
                "original defaults and no additional Cancel action")
            try #require(
                force.convert(force.bounds, to: view).minX == field.convert(field.bounds, to: view).minX
                    && view.bounds.contains(force.convert(force.bounds, to: view)), "source Force row aligns under field without Windows DPI clipping")
            try #require(window.contentMinSize.height == window.contentMaxSize.height && window.contentMinSize.width == 552, "horizontal resize only")
            let before = try fixture.git(["status", "--porcelain"], in: repository)
            try #require(before.isEmpty, "inspecting Add files never stages files")
            window.close()
            let result = try await completion.value
            try #require(!result, "closing without Add returns no mutation")
        }

        @MainActor
        @Test("Menu icon resources") private static func testMenuIconResources() throws {
            let resources = TestResources.images
            for name in [
                "Stage", "FileHistory", "Blame", "BranchCheckout", "BranchCreate", "ResetCurrentBranchToHere", "TagCreate", "SaveAs", "RecentRepositories",
                "ResetWorkingDirChanges", "EditFile", "DeleteFile", "AddToGitIgnore", "StopTrackingFile", "EditGitIgnore", "UiScrollBar", "Preview",
                "EditColor", "VisualStudioTeamServices", "GitHub", "CopyPaths",
            ] {
                let image = NSImage(contentsOf: resources.appendingPathComponent(name + ".png"))
                try #require(image != nil && image!.size.width > 0, "referenced source menu asset must exist and decode: \(name)")
            }
            try #require(NSImage(contentsOf: resources.appendingPathComponent("Difftastic.ico")) != nil, "pinned ICO resource decodes natively")
            let filter = RevisionFilterToolbar()
            try #require(filter.branchesMode.item(at: 0)?.title == "All branches", "initial mode remains discoverable on the actual toolbar")
            for (index, id) in ["revision.branches.all", "revision.branches.current", "revision.branches.filtered"].enumerated() {
                let item = filter.branchesMode.item(at: index + 1)!
                let chord = ApplicationHotkeys.shared.chord(for: id)!
                try #require(
                    item.keyEquivalent == chord.key && item.keyEquivalentModifierMask.rawValue == chord.modifiers, "branch mode cue uses shared shortcut")
                if #available(macOS 27.0, *) { try #require(item.preferredImageVisibility == .visible, "native mode icon visibility") }
            }
            var state = RevisionGridFilter()
            state.showCurrentBranchOnly = true
            filter.filterChanged(state)
            try #require(
                filter.branchesMode.item(at: 0)?.title == "Current branch only" && filter.branchesMode.item(at: 2)?.state == .on,
                "current caption/check update together")
            state.showCurrentBranchOnly = false
            state.byBranchFilter = true
            filter.filterChanged(state)
            try #require(
                filter.branchesMode.item(at: 0)?.title == "Filtered branches" && filter.branchesMode.item(at: 3)?.state == .on,
                "filtered caption/check update together")
            filter.filterChanged(RevisionGridFilter())
            try #require(filter.branchesMode.item(at: 0)?.title == "All branches", "resetting filter restores caption")
            let avatar = AuthorAvatarView(frame: .init(x: 0, y: 0, width: 80, height: 80))
            avatar.commitInfoMode = true
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1,
                pressure: 1)!
            let menu = avatar.menu(for: event)!
            try #require(menu.items.first?.title == "Clear image cache", "existing avatar action ordering retained")
            if #available(macOS 27.0, *) { try #require(menu.items.first?.preferredImageVisibility == .visible, "cache icon visible") }
            try #require(RevisionLinkTemplates.allCases.map(\.imageName) == ["GitHub", "VisualStudioTeamServices"], "exact upstream provider image identities")
        }

        @Test("Submodule menus and text") private static func testSubmoduleMenusAndText() throws {

            func item(_ path: String, parent: String, current: Bool, top: Bool) -> SubmoduleTreeItem {
                SubmoduleTreeItem(
                    repositoryURL: URL(fileURLWithPath: path), parentURL: URL(fileURLWithPath: parent), path: path, localPath: path,
                    isCurrent: current, isTop: top, isInitialized: true, branch: "main", commitID: nil, recordedID: nil, commitState: .same,
                    addedCommits: nil, removedCommits: nil, isDirty: false)
            }
            let lone = item("/r", parent: "/r", current: true, top: true)
            try #require(
                SubmoduleMenuPlan.entries([lone]) == [.noSubmodules, .separator, .updateAll], "no submodules shows No submodules, separator, Update all")
            let child = item("/r/c", parent: "/r", current: false, top: false)
            try #require(
                SubmoduleMenuPlan.entries([lone, child]) == [.module(child, "%@"), .separator, .updateAll],
                "own submodules listed, current repository not listed")
            let topItem = item("/r", parent: "/r", current: false, top: true)
            let inside = item("/r/c", parent: "/r", current: true, top: false)
            try #require(
                SubmoduleMenuPlan.entries([topItem, inside]) == [
                    .noSubmodules, .separator, .module(topItem, "Superproject: %@"), .module(inside, "%@"), .separator, .updateAll, .updateCurrent,
                ],
                "nested repository lists superproject, all submodules and update current")
            let middle = item("/r/c", parent: "/r", current: false, top: false)
            let nested = item("/r/c/d", parent: "/r/c", current: true, top: false)
            try #require(
                SubmoduleMenuPlan.entries([topItem, middle, nested]) == [
                    .noSubmodules, .separator, .module(topItem, "Top project: %@"), .module(middle, "Superproject: %@"), .module(middle, "%@"),
                    .module(nested, "%@"), .separator, .updateAll, .updateCurrent,
                ], "distinct top and superproject source groups with current update")
            let filters = RevisionFilterToolbar()
            let menu = filters.advancedMenu(RevisionGridFilter())
            try #require(
                menu.items.map(\.title) == ["Reset path filter", "Reset revision filters", "", "Advanced filter"] && !menu.items[0].isEnabled
                    && !menu.items[1].isEnabled && menu.items[3].isEnabled,
                "advanced filter arrow menu exists with disabled resets when unfiltered")
            try #require(filters.views.contains(filters.advancedArrow), "independent arrow is on the toolbar")
            for (index, id) in [(0, "revision.filter.resetPath"), (1, "revision.filter.reset"), (3, "revision.filter.advanced")] {
                let chord = ApplicationHotkeys.shared.chord(for: id)!
                try #require(
                    menu.items[index].keyEquivalent == chord.key && menu.items[index].keyEquivalentModifierMask.rawValue == chord.modifiers,
                    "filter menu uses the shared configured shortcut for \(id)")
            }
            try #require(
                FindInCommitFilesGitGrepWindowController.helpURL.absoluteString.hasSuffix("browse_repository#diff"),
                "git-grep help opens browse_repository#diff")
            let grep = FindInCommitFilesGitGrepWindowController(locate: { _ in }, toggle: { _ in }, closed: {})
            let combos = allSubviews(grep.window!.contentView!).compactMap { $0 as? NSComboBox }
            try #require(combos.first?.placeholderString == "git-grep regular expression...", "query watermark")
            grep.window?.contentView?.layoutSubtreeIfNeeded()
            let root = grep.window!.contentView!
            let checks = allSubviews(root).compactMap { $0 as? NSButton }
            let matchCase = checks.first { $0.title == "Match case" }!
            let wholeWord = checks.first { $0.title == "Match whole word" }!
            let show = checks.first { $0.title.hasPrefix("Show '") }!
            let fieldRect = combos[0].convert(combos[0].bounds, to: root)
            let rectangles = [matchCase, wholeWord, show].map { $0.convert($0.bounds, to: root) }
            try #require(
                rectangles.allSatisfy { abs($0.minX - fieldRect.minX) < 1 } && abs(rectangles[0].midY - rectangles[1].midY) >= 18,
                "separate case/whole-word rows and Show search align with query")
            try #require(
                checks.allSatisfy {
                    let rect = $0.convert($0.bounds, to: root)
                    return rect.minY >= 0 && rect.maxY <= root.bounds.maxY && rect.maxX <= root.bounds.maxX
                },
                "grep actions remain within the native panel")
            try #require(
                checks.contains { $0.bezelStyle == .helpButton && $0.accessibilityIdentifier() == "GitGrepHelp" }, "contextual native Help action is present")
            grep.window?.close()
        }

        static func allSubviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allSubviews) }

        static func allTextFields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                (sub as? NSTextField).map { [$0] } ?? [] + allTextFields(in: sub)
            }
        }

    }
}

typealias DialogBehaviorTests = UIIntegrationTests.DialogBehaviorTests

struct DialogBehaviorFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "DialogBehaviorTests: \(message)" }
}
