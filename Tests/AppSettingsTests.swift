@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation
import AppKit

@MainActor
enum AppSettingsTests {
    static func run() {
        testPreferencesRoundTrip()
        testBrowseDisplayPreferences()
        testHistogramPreference()
        testPullPreferencesRoundTrip()
        testRepositoryCreationPreferencesRoundTrip()
        testResetPreferencesRoundTrip()
        testReflogReferencesPreferenceRoundTrip()
        testRebasePreferencesRoundTrip()
        testCherryPickPreferencesRoundTrip()
        testPushPreferencesRoundTrip()
        testStashPreferencesRoundTrip()
        testTagPreferencesRoundTrip()
        testRemoteManagementPreferencesRoundTrip()
        testRemoteManagementSelectionRestoration()
        testRepositoryTreePreferencesRoundTrip()
        testMergePreferencesRoundTrip()
        testCheckoutBranchPreferencesRoundTrip()
        testCommitPreferencesRoundTrip()
        testFileStatusListPreferencesRoundTrip()
        testFileViewerPreferencesRoundTrip()
        testViewerRuntimeDefaults()
        testFontsRoundTrip()
        testDistributedSettings()
        testRevisionLinks()
        testHotkeys()
        testSharedViewerSearch()
        testColors()
        testCommitMessageRules()
        testRecentRepositories()
        testStartupChecklistPreference()
        print("AppSettingsTests: passed")
    }

    private static func testStartupChecklistPreference() {
        withStore { store, defaults in
            let existing = store.preferences
            precondition(store.checkSettingsAtStartup)
            store.checkSettingsAtStartup = false
            precondition(!AppSettingsStore(defaults: defaults).checkSettingsAtStartup)
            precondition(AppSettingsStore(defaults: defaults).preferences == existing)
            store.checkSettingsAtStartup = true
            precondition(AppSettingsStore(defaults: defaults).checkSettingsAtStartup)
            store.recordSettingsCheck(allValid: false)
            precondition(store.checkSettingsAtStartup)
            store.recordSettingsCheck(allValid: true)
            precondition(!AppSettingsStore(defaults: defaults).checkSettingsAtStartup)
            store.recordSettingsCheck(allValid: false)
            precondition(!store.checkSettingsAtStartup, "a later failure does not undo a user's disabled startup checks")
        }
    }

    static func runSettingsTree() async throws {
        _ = NSApplication.shared
        let suite = "GitExtensionsMac.SettingsTreeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let remembered = SettingsViewController.lastSelectedPage
        defer {
            SettingsViewController.lastSelectedPage = remembered
            defaults.removePersistentDomain(forName: suite)
        }
        let store = AppSettingsStore(defaults: defaults)
        var preferences = store.preferences
        preferences.gitExecutablePath = "/nonexistent/settings-checklist-test-git"
        store.save(preferences)
        SettingsViewController.lastSelectedPage = nil
        func make(_ page: String? = nil) -> SettingsViewController {
            SettingsViewController(store: store, source: nil, initialPage: page, repositoryChanged: {})
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controller = make()
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        precondition(controller.currentCategoryID == "application", "first opening selects Checklist")
        precondition(controller.rootCategoryIDs == ["application", "git", "plugins"])
        precondition(controller.categoryIDs == ["application", "general", "appearance", "sorting", "colors", "fonts", "revision_links", "build_server", "scripts", "hotkeys", "advanced", "confirmations", "detailed", "browse", "commit", "diff", "blame", "ssh", "git", "git_paths", "git_config", "git_advanced", "plugins"], "tree order and omission of unavailable console/Shell extension")
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.checklist.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(controller.checklist.first?.status == .invalid, "missing Git shown asynchronously")
        let repair = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "SettingsCheck.git" }
        precondition(repair != nil, "checklist diagnostic is actionable")
        precondition(repair?.imagePosition == .imageLeft && repair?.title.isEmpty == false, "diagnostic shows text alongside status icon")
        precondition(store.checkSettingsAtStartup, "invalid diagnostics do not disable startup checks")
        controller.goToCategory("git")
        let labels = descendants(controller.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(labels.contains { $0.contains("Select one of the subnodes") }, "Git root is an introduction, not Paths")
        controller.goToCategory("fonts")
        let reopened = make()
        _ = reopened.view
        precondition(reopened.currentCategoryID == "fonts", "last page is remembered within the process")
        let explicit = make("general")
        _ = explicit.view
        precondition(explicit.currentCategoryID == "general", "explicit page overrides last page")
        controller.searchSettings("whitespace")
        precondition(controller.searchMatches.contains("diff") && controller.currentCategoryID == "fonts")
        let tree = descendants(controller.view).compactMap { $0 as? NSOutlineView }.first!
        precondition(tree.numberOfRows > 3 && tree.item(atRow: tree.numberOfRows - 1) is SettingsNode, "search preserves full tree")
        controller.selectNextSearchMatch()
        precondition(controller.searchMatches.contains(controller.currentCategoryID))
        let firstMatch = controller.currentCategoryID
        for _ in controller.searchMatches.indices { controller.selectNextSearchMatch() }
        precondition(controller.currentCategoryID == firstMatch, "Enter cycles search results")
        controller.searchSettings("whitespace encoding")
        precondition(controller.searchMatches.contains("diff"), "all words match page labels")
        controller.searchSettings("whitespace definitelynotasetting")
        precondition(controller.searchMatches.isEmpty, "all search words are required")
        controller.searchSettings("encoding")
        precondition(!controller.searchMatches.contains("detailed"), "unvisited Detailed page does not claim diff encoding")
        controller.searchSettings("")
        precondition(controller.searchMatches.isEmpty && controller.categoryIDs.count == 23)
        controller.goToCategory("removed-console")
        precondition(controller.currentCategoryID == "application", "stale page falls back to root")
        controller.goToCategory("general")


        preferences.gitExecutablePath = "/usr/bin/git"
        store.save(preferences)
        let found = make("application")
        let foundWindow = NSWindow(contentViewController: found)
        foundWindow.makeKeyAndOrderFront(nil)
        defer { foundWindow.close() }
        let foundDeadline = ContinuousClock.now + .seconds(10)
        while found.checklist.count < 2 && ContinuousClock.now < foundDeadline { try await Task.sleep(for: .milliseconds(20)) }
        let identifiers = descendants(found.view).compactMap { ($0 as? NSButton)?.accessibilityIdentifier() }
        precondition(found.checklist.contains { $0.kind == .editor }, "editor check still evaluated")
        precondition(identifiers.contains("SettingsCheck.identity") && !identifiers.contains("SettingsCheck.editor"), "editor check has no row")
        found.goToCategory("general")
        print("SettingsTreeTests: passed")
    }

    static func runRepositoryScopes() async throws {
        _ = NSApplication.shared
        let first = try FileStatusFixture.make(), second = try FileStatusFixture.make()
        defer { first.remove(); second.remove() }
        try first.write("a.txt", "base\n"); try first.commitAll("base")
        try second.write("a.txt", "base\n"); try second.commitAll("base")
        let firstModule = GitRepositoryModule(repositoryURL: first.repo, git: FileStatusFixtureGit())
        let secondModule = GitRepositoryModule(repositoryURL: second.repo, git: FileStatusFixtureGit())
        _ = try await firstModule.loadRepositoryState()
        _ = try await secondModule.loadRepositoryState()
        let a = try await DistributedSettings.loadLocations(from: firstModule)
        let b = try await DistributedSettings.loadLocations(from: secondModule)
        let suite = "GitExtensionsMac.RepositoryScopes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let remembered = SettingsViewController.lastSelectedPage
        let confirmationKey = GitUICommands.dontConfirmUndoLastCommitKey
        let originalConfirmation = UserDefaults.standard.object(forKey: confirmationKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            SettingsViewController.lastSelectedPage = remembered
            if let originalConfirmation { UserDefaults.standard.set(originalConfirmation, forKey: confirmationKey) }
            else { UserDefaults.standard.removeObject(forKey: confirmationKey) }
        }
        let store = AppSettingsStore(defaults: defaults)
        let key = DistributedSettings.mergeLog, count = DistributedSettings.mergeLogCount
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "RepositoryScopes", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ message: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try check(predicate(), message)
        }
        try check(DistributedSettings.globalValues(store).isEmpty, "fresh explicit global scope is unset, not materialized defaults")


        var merge = store.mergePreferences
        merge.addLogMessages = true; merge.logMessagesCount = 31
        store.saveMergePreferences(merge)
        try check(DistributedSettings.globalValues(AppSettingsStore(defaults: defaults))[count] == "31", "legacy global count preserved")
        store.saveDetailedSetting(key, value: nil); store.saveDetailedSetting(count, value: nil)
        store.saveMergePreferences(store.mergePreferences)
        let relaunched = AppSettingsStore(defaults: defaults)
        try check(DistributedSettings.globalValues(relaunched)[key] == nil && DistributedSettings.globalValues(relaunched)[count] == nil, "explicit global unset persists")
        try check(try a.mergePreferences(relaunched).addLogMessages == false && a.mergePreferences(relaunched).logMessagesCount == 20, "unset effective defaults")
        store.saveDetailedSetting(key, value: "false"); store.saveDetailedSetting(count, value: "31")
        try DistributedSettings.write([key: "true", count: "40", "unrelated": "keep"], to: a.distributedURL)
        try DistributedSettings.write([key: "false", count: "50"], to: a.localURL)
        try DistributedSettings.write([count: "60"], to: b.localURL)
        try check(try a.values(.global, global: DistributedSettings.globalValues(store))[count] == "31", "explicit global does not inherit")
        try check(try a.values(.distributed, global: DistributedSettings.globalValues(store))[count] == "40", "explicit distributed does not inherit")
        try check(try a.mergePreferences(store).logMessagesCount == 50 && b.mergePreferences(store).logMessagesCount == 60, "repositories have isolated effective values")
        try DistributedSettings.write([count: nil], to: a.localURL)
        try check(try a.mergePreferences(store).logMessagesCount == 40, "reset local reveals distributed")
        try check(try a.effectiveWriteScope(key: count, value: "40", global: DistributedSettings.globalValues(store)) == nil, "unchanged effective no-op")
        try check(try a.effectiveWriteScope(key: count, value: "41", global: DistributedSettings.globalValues(store)) == .local, "effective distributed override writes local")
        var scoped = try a.mergePreferences(store); scoped.logMessagesCount = 41
        try a.saveMergeLog(scoped, store: store)
        try check(try DistributedSettings.read(a.distributedURL)[count] == "40" && DistributedSettings.read(a.localURL)[count] == "41", "workflow does not rewrite distributed settings")
        try DistributedSettings.write([count: nil], to: a.localURL)
        try DistributedSettings.write([count: nil], to: a.distributedURL)
        try check(try a.mergePreferences(store).logMessagesCount == 31, "reset both overrides reveals global")
        try check(try a.effectiveWriteScope(key: count, value: "32", global: DistributedSettings.globalValues(store)) == .global, "absent overrides write global")
        try DistributedSettings.write([count: "2147483648"], to: a.localURL)
        try check(try a.mergePreferences(store).logMessagesCount == 20, "invalid scoped Int32 uses upstream default, not lower-priority value")
        try DistributedSettings.write([count: "50"], to: a.localURL)



        let linked = first.root.appendingPathComponent("linked worktree")
        try first.git(["worktree", "add", "-q", "--detach", linked.path])
        let linkedModule = GitRepositoryModule(repositoryURL: linked, git: FileStatusFixtureGit())
        _ = try await linkedModule.loadRepositoryState()
        let linkedSettings = try await DistributedSettings.loadLocations(from: linkedModule)
        try check(linkedSettings.localURL == a.localURL && linkedSettings.distributedURL != a.distributedURL, "linked worktree scope locations")
        let bare = second.root.appendingPathComponent("bare.git")
        try second.git(["clone", "-q", "--bare", second.repo.path, bare.path])
        let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
        _ = try await bareModule.loadRepositoryState()
        let bareSettings = try await DistributedSettings.loadLocations(from: bareModule)
        try check(bareSettings.localURL.deletingLastPathComponent().resolvingSymlinksInPath().path == bare.resolvingSymlinksInPath().path, "bare repository local settings: \(bareSettings.localURL.path), expected \(bare.path)")


        let buildA = BuildServerSettingsStore(locations: a, defaults: defaults)
        let buildB = BuildServerSettingsStore(locations: b, defaults: defaults)
        let buildKey = BuildServerSettingKeys.enabled
        try check(try buildA.write([buildKey: "true"], scope: .global), "initial build global write")
        try check(try !buildA.write([buildKey: "true"], scope: .global), "unchanged build settings no-op")
        try buildA.write([buildKey: "false"], scope: .local)
        try check(try buildA.values(.effective)[buildKey] == "false" && buildB.values(.effective)[buildKey] == "true", "build scoped isolation")
        try buildA.write([buildKey: nil], scope: .local)
        try check(try buildA.values(.effective)[buildKey] == "true", "build reset fallback")
        let pluginID = UUID()
        let pluginA = ApplicationPluginSettings(identifier: pluginID, legacyName: "Fixture.", locations: a, defaults: defaults)
        let pluginB = ApplicationPluginSettings(identifier: pluginID, legacyName: "Fixture.", locations: b, defaults: defaults)
        try pluginA.set("enabled", value: "global")
        try pluginA.set("enabled", value: "local", scope: .local)
        try check(try pluginA.value("enabled") == "local" && pluginB.value("enabled") == "global", "plugin scoped isolation")
        try pluginA.set("enabled", value: nil, scope: .local)
        try check(try pluginA.value("enabled") == "global", "plugin reset fallback")
        try check(try DistributedSettings.read(a.distributedURL)["unrelated"] == "keep", "unrelated XML settings preserved")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func scopeControl(_ controller: SettingsViewController) -> NSPopUpButton? {
            descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "Settings.appScope" }
        }
        func field<T: NSControl>(_ controller: SettingsViewController, _ label: String, as type: T.Type) -> T {
            let title = descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == label }!
            return title.superview!.subviews.filter { $0 !== title }.compactMap { $0 as? T }.first!
        }
        func select(_ popup: NSPopUpButton, title: String) {
            popup.selectItem(withTitle: title); _ = popup.sendAction(popup.action!, to: popup.target)
        }
        try buildA.write([buildKey: "false"], scope: .local)
        let buildPage = BuildServerSettingsPageController(store: buildA, remoteURLs: [], workingDirectoryName: nil)
        let buildScope = descendants(buildPage.view).compactMap { $0 as? NSPopUpButton }.first!
        select(buildScope, title: DistributedSettingsScope.local.title)
        let enabled = descendants(buildPage.view).compactMap { $0 as? NSButton }.first { $0.title == "Enable build server integration" }!
        try check(enabled.state == .off, "build local state")
        enabled.state = .mixed; _ = enabled.sendAction(enabled.action!, to: enabled.target)
        select(buildScope, title: DistributedSettingsScope.effective.title)
        try check(enabled.state == .on && !enabled.isEnabled, "removing local build draft immediately reveals global effective value")
        try check(try buildPage.save(), "build scoped reset persisted")
        try check(try !buildPage.save(), "repeated build save is a no-op")
        var notifications = 0
        let controller = SettingsViewController(store: store, source: firstModule, initialPage: "detailed", initialScope: .local, repositoryChanged: { notifications += 1 })
        let panel = NSPanel(contentViewController: controller); controller.panel = panel
        panel.setContentSize(NSSize(width: 1040, height: 720)); panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await wait("repository scope loaded") { scopeControl(controller) != nil }
        try check(scopeControl(controller)?.titleOfSelectedItem == DistributedSettingsScope.local.title, "repository entry selects local")
        try check(field(controller, "Merge log messages count:", as: NSTextField.self).stringValue == "50", "local value in hosted UI")
        let graph = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Render graph with diagonals" }!
        try check(!graph.isEnabled, "graph preferences are global-only")

        var number = field(controller, "Merge log messages count:", as: NSTextField.self)
        number.stringValue = "51"
        (number.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: number))
        select(scopeControl(controller)!, title: DistributedSettingsScope.effective.title)
        number = field(controller, "Merge log messages count:", as: NSTextField.self)
        try check(number.stringValue == "51" && !number.isEnabled, "effective sees unsaved local draft and is read-only")
        select(scopeControl(controller)!, title: DistributedSettingsScope.distributed.title)
        number = field(controller, "Merge log messages count:", as: NSTextField.self)
        try check(number.stringValue.isEmpty && number.isEnabled, "explicit distributed missing stays unset")
        select(scopeControl(controller)!, title: DistributedSettingsScope.local.title)
        try check(field(controller, "Merge log messages count:", as: NSTextField.self).stringValue == "51", "local draft survives scope changes")
        let apply = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
        apply.performClick(nil)
        try await wait("local Apply persisted and notified once") { notifications == 1 && apply.isEnabled }
        try check(try DistributedSettings.read(a.localURL)[count] == "51" && b.mergePreferences(store).logMessagesCount == 60, "Apply isolated to current repo")
        apply.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        try check(notifications == 1, "unchanged Apply has no repository mutation notification")
        select(scopeControl(controller)!, title: DistributedSettingsScope.global.title)
        let globalGraph = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Render graph with diagonals" }!
        try check(globalGraph.isEnabled, "graph editable globally")
        select(field(controller, "Add merge log messages:", as: NSPopUpButton.self), title: "Not set")
        descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!.performClick(nil)
        try await wait("global unset applied") { DistributedSettings.globalValues(AppSettingsStore(defaults: defaults))[key] == nil }
        controller.goToCategory("general")
        try check(scopeControl(controller) == nil, "General remains upstream global-only")
        controller.goToCategory("fonts")
        try check(scopeControl(controller) == nil, "fonts remain upstream global-only")
        controller.goToCategory("revision_links")
        try check(scopeControl(controller)?.titleOfSelectedItem == DistributedSettingsScope.effective.title,
                  "Revision links starts at its own effective scope, not Detailed's global scope")
        select(scopeControl(controller)!, title: DistributedSettingsScope.effective.title)
        try check(scopeControl(controller)!.isEnabled, "effective page leaves the scope selector enabled")
        let addLink = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Add" }!
        try check(!addLink.isEnabled, "effective Revision links cannot silently add to another scope")
        select(scopeControl(controller)!, title: DistributedSettingsScope.local.title)
        try check(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Add" }!.isEnabled, "explicit Revision links scope is writable")
        controller.goToCategory("detailed")
        try check(scopeControl(controller)?.titleOfSelectedItem == DistributedSettingsScope.global.title, "each page retains its own chosen scope")
        controller.goToCategory("git_config")
        func gitScope() -> NSPopUpButton {
            descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first!
        }
        select(gitScope(), title: GitSettingsScope.global.rawValue)
        controller.goToCategory("git_advanced")
        try check(gitScope().titleOfSelectedItem == GitSettingsScope.effective.rawValue, "Git Advanced has an independent initial scope")
        controller.goToCategory("git_config")
        try check(gitScope().titleOfSelectedItem == GitSettingsScope.global.rawValue, "Git Config remembers its own scope")
        let other = SettingsViewController(store: store, source: secondModule, initialPage: "detailed", initialScope: .local, repositoryChanged: {})
        let otherPanel = NSPanel(contentViewController: other); other.panel = otherPanel
        otherPanel.makeKeyAndOrderFront(nil)
        defer { otherPanel.close() }
        try await wait("second repository scopes loaded") { scopeControl(other) != nil }
        try check(field(other, "Merge log messages count:", as: NSTextField.self).stringValue == "60", "switching repository does not reuse first repository drafts")

        number = field(other, "Merge log messages count:", as: NSTextField.self); number.stringValue = "99"
        (number.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: number))
        descendants(other.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        try check(try DistributedSettings.read(b.localURL)[count] == "60", "Cancel never saves scoped draft")
        let noRepository = SettingsViewController(store: store, source: nil, initialPage: "detailed", repositoryChanged: {})
        try check(scopeControl(noRepository)?.itemTitles == [DistributedSettingsScope.global.title], "no repository exposes global only")
        print("RepositoryScopedSettingsTests: passed")
    }

    private static func testPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.preferences
            preferences.theme = .dark
            preferences.gitExecutablePath = "/opt/homebrew/bin/git"
            preferences.defaultSignOff = true
            preferences.mergeCommonParentLanes = false
            preferences.renderGraphWithDiagonals = false
            store.save(preferences)
            precondition(AppSettingsStore(defaults: defaults).preferences == preferences)
        }
    }

    private static func testBrowseDisplayPreferences() {
        withStore { store, defaults in
            var value = store.browseDisplayPreferences
            precondition(value.commitTitle(changedFiles: 3) == "Commit (3)")
            precondition(value.branchCounts(ahead: 2, behind: 1) == " ↑2 ↓1")
            precondition(value.branchCounts(ahead: 0, behind: 0).isEmpty)
            value.showChangedFilesOnCommitButton = false
            value.showAheadBehind = false
            value.showArtificialRevisionCounts = false
            value.showSubmoduleStatus = true
            value.quickSearchTimeoutMilliseconds = 7500
            value.maximumRevisionCount = 250
            store.saveBrowseDisplayPreferences(value)
            let restored = AppSettingsStore(defaults: defaults).browseDisplayPreferences
            precondition(restored == value)
            precondition(restored.commitTitle(changedFiles: 3) == "Commit")
            precondition(restored.branchCounts(ahead: 2, behind: 1).isEmpty)
            let inherited = try! JSONDecoder().decode(BrowseDisplayPreferences.self, from: Data("{}".utf8))
            precondition(inherited == BrowseDisplayPreferences())
            let item = SubmoduleTreeItem(repositoryURL: URL(fileURLWithPath: "/fixture/module"),
                parentURL: URL(fileURLWithPath: "/fixture"), path: "module", localPath: "module",
                isCurrent: false, isTop: false, isInitialized: true, branch: "main",
                commitID: nil, recordedID: nil, commitState: .ahead, addedCommits: 2, removedCommits: 0)
            precondition(SubmoduleTreePresentation.menuTitle(item, showsStatus: false) == "module (main)")
            precondition(SubmoduleTreePresentation.menuTitle(item, showsStatus: true) == "module (main) (+2-0)")
        }
    }

    private static func testHistogramPreference() {
        withStore { store, defaults in
            let legacy = try! JSONDecoder().decode(FileViewerPreferences.self, from: Data("{\"whitespace\":\"endOfLine\",\"contextLines\":7}".utf8))
            precondition(!legacy.usesHistogram && legacy.whitespace == .endOfLine && legacy.contextLines == 7)
            var value = legacy
            value.usesHistogram = true
            store.applyFileViewerPreferences(value)
            let restored = AppSettingsStore(defaults: defaults)
            precondition(restored.fileViewerPreferences.usesHistogram)
            precondition(restored.preferencesForNewFileViewer().usesHistogram)
            precondition(value.diffOptions.gitArguments == ["--histogram", "--ignore-space-at-eol", "--unified=7"])
        }
    }

    private static func testRepositoryCreationPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.repositoryCreationPreferences
            preferences.cloneDestinationPath = "/tmp/Clones"
            preferences.cloneWindowWidth = 720
            store.saveRepositoryCreationPreferences(preferences)
            store.recordCloneSource("ssh://example.test/repository.git")
            store.recordCloneSource("ssh://example.test/repository.git")
            let restored = AppSettingsStore(defaults: defaults).repositoryCreationPreferences
            precondition(restored.cloneDestinationPath == "/tmp/Clones")
            precondition(restored.cloneWindowWidth == 720)
            precondition(restored.recentSources == ["ssh://example.test/repository.git"])
            let cloned = URL(fileURLWithPath: "/tmp/Clones/repository", isDirectory: true)
            store.recordRecentRepository(cloned)
            precondition(store.recentRepositories.first?.path == cloned.path)
            precondition(store.lastRepositoryPath == nil)
        }
    }

    private static func testResetPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.resetPreferences
            precondition(preferences.checkoutOtherBranchAfterReset)
            preferences.checkoutOtherBranchAfterReset = false
            store.saveResetPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).resetPreferences == preferences)
        }
    }

    private static func testReflogReferencesPreferenceRoundTrip() {
        withStore { store, defaults in

            precondition(!store.showReflogReferences)
            store.saveShowReflogReferences(true)
            precondition(store.showReflogReferences)
            precondition(!AppSettingsStore(defaults: defaults).showReflogReferences)
            store.revisionGridRuntime.sortOrder = .topology
            store.saveCurrentViewSettingsAsDefault()
            let reloaded = AppSettingsStore(defaults: defaults)
            precondition(reloaded.showReflogReferences)
            precondition(reloaded.revisionGridRuntime.sortOrder == .topology)
        }
    }

    private static func testTagPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.tagPreferences
            preferences.showTagsInRevisionGrid = false
            preferences.showTagsInRepositoryTree = false
            store.saveTagPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).tagPreferences == preferences)
        }
    }

    private static func testRemoteManagementPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.remoteManagementPreferences
            preferences.showAdvancedOptions = true
            preferences.windowWidth = 1_080
            preferences.windowHeight = 620
            store.saveRemoteManagementPreferences(preferences)
            store.recordRemoteURL("ssh://example/repository")
            store.recordRemoteURL("ssh://example/repository")
            store.replaceRemoteURLHistory("ssh://example/repository", with: "/tmp/repository with spaces")
            let reloaded = AppSettingsStore(defaults: defaults).remoteManagementPreferences
            precondition(reloaded.showAdvancedOptions)
            precondition(reloaded.windowWidth == 1_080 && reloaded.windowHeight == 620)
            precondition(reloaded.recentURLs == ["/tmp/repository with spaces"])
        }
    }

    private static func testRepositoryTreePreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.repositoryTreePreferences
            preferences.visibleRoots.remove(.submodules)
            preferences.rootOrder = [.tags, .branches, .remotes, .worktrees, .submodules, .stashes]
            preferences.sortBy = .creatorDate
            preferences.sortOrder = .descending
            store.saveRepositoryTreePreferences(preferences)
            let restored = AppSettingsStore(defaults: defaults).repositoryTreePreferences
            precondition(restored == preferences)
        }

        var malformed = RepositoryTreePreferences()
        malformed.rootOrder = [.branches, .branches]
        malformed.visibleRoots.insert(.tags)
        malformed.normalize()
        precondition(malformed.rootOrder == RepositoryTreeRoot.allCases)
    }

    private static func testRemoteManagementSelectionRestoration() {
        let remotes = [
            RepositoryRemoteConfiguration(
                name: "origin", fetchURL: "/tmp/origin", pushURL: nil,
                puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: false
            ),
            RepositoryRemoteConfiguration(
                name: "upstream", fetchURL: "/tmp/upstream", pushURL: nil,
                puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: true
            )
        ]
        precondition(RemoteManagementSelectionResolver.preferredRemoteName(configurations: remotes, requested: "upstream") == "upstream")
        precondition(RemoteManagementSelectionResolver.preferredRemoteName(configurations: remotes, requested: "deleted") == "origin")

        let tracking = [
            RepositoryBranchTrackingConfiguration(branchName: "main", remoteName: "origin", mergeBranch: "main"),
            RepositoryBranchTrackingConfiguration(branchName: "topic", remoteName: nil, mergeBranch: nil)
        ]
        precondition(RemoteManagementSelectionResolver.preferredLocalBranch(configurations: tracking, requested: "topic") == "topic")
        precondition(RemoteManagementSelectionResolver.preferredLocalBranch(configurations: tracking, requested: "deleted") == "main")
    }

    private static func testRecentRepositories() {
        withStore { store, _ in
            var settings = store.recentRepositorySettings
            settings.historySize = 10
            store.saveRecentRepositorySettings(settings)
            for index in 0..<11 { store.recordOpenedRepository(URL(fileURLWithPath: "/tmp/recent\(index)", isDirectory: true)) }
            let temporaryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
            store.recordOpenedRepository(temporaryURL)
            precondition(store.recentRepositories.count == 10 && store.recentRepositories.first?.path == temporaryURL.path)
            precondition(store.lastRepositoryPath == temporaryURL.path)
            store.removeRecentRepository(path: temporaryURL.path)
            precondition(store.recentRepositories.first?.path == "/tmp/recent10")
            store.clearRecentRepositories()
            precondition(store.recentRepositories.isEmpty)
        }
    }

    private static func testPullPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.pullPreferences
            preferences.defaultAction = .fetchPruneAll
            preferences.formAction = .rebase
            preferences.autoStash = true
            preferences.autoPopStash = .never
            preferences.includeUntrackedInAutoStash = true
            preferences.recentURLs = ["/tmp/repository with spaces", "ssh://example/repository"]
            preferences.helpExpanded = false
            preferences.closeProcessOnSuccess = true
            preferences.confirmFetchAndPruneAll = false
            preferences.updateSubmodulesAfterPull = true
            store.savePullPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).pullPreferences == preferences)

            store.recordPullURL("ssh://example/repository")
            precondition(store.pullPreferences.recentURLs.first == "ssh://example/repository")
            precondition(store.pullPreferences.recentURLs.filter { $0 == "ssh://example/repository" }.count == 1)
        }
    }

    private static func testPushPreferencesRoundTrip() {
        let suite = "GitExtensionsMacTests.push.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Could not create defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        var preferences = store.pushPreferences
        preferences.recursiveSubmodules = .onDemand
        preferences.showAdvancedOptions = true
        preferences.confirmNewBranch = false
        preferences.confirmAddTrackingReference = false
        preferences.rejectedAction = .rebase
        preferences.loadRemoteBranchesDirectly = true
        store.savePushPreferences(preferences)
        precondition(AppSettingsStore(defaults: defaults).pushPreferences == preferences)

        store.recordPushURL("ssh://example/push-repository")
        store.recordPushURL("ssh://example/push-repository")
        precondition(store.pushPreferences.recentURLs.first == "ssh://example/push-repository")
        precondition(store.pushPreferences.recentURLs.filter { $0 == "ssh://example/push-repository" }.count == 1)
    }

    private static func testMergePreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.mergePreferences
            preferences.noCommit = true
            preferences.noFastForward = true
            preferences.addLogMessages = true
            preferences.logMessagesCount = 37
            preferences.helpExpanded = false
            preferences.closeProcessOnSuccess = true
            store.saveMergePreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).mergePreferences == preferences)
        }
    }

    private static func testCheckoutBranchPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.checkoutBranchPreferences
            preferences.checkForUncommittedChanges = false
            preferences.alwaysShowDialog = true
            preferences.localChangesAction = .stash
            preferences.useDefaultLocalChangesAction = true
            preferences.createLocalBranchForRemote = true
            preferences.autoPopStash = .always
            preferences.confirmDirectCheckout = true
            preferences.dontConfirmDeleteUnmerged = true
            preferences.autoNormaliseBranchName = true
            preferences.branchNameReplacement = "-"
            preferences.updateSubmodulesOnCheckout = false
            preferences.checkoutWindowWidth = 720
            preferences.createWindowWidth = 640
            preferences.deleteWindowWidth = 560
            preferences.renameWindowWidth = 520
            store.saveCheckoutBranchPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).checkoutBranchPreferences == preferences)
        }
    }

    private static func testRebasePreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.rebasePreferences
            preferences.helpExpanded = false
            store.saveRebasePreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).rebasePreferences == preferences)
        }
    }

    private static func testStashPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.stashPreferences
            preferences.keepIndex = true
            preferences.includeUntracked = true
            preferences.dontConfirmDrop = true
            preferences.showStashCount = true
            preferences.showStashesInRepositoryTree = false
            preferences.windowWidth = 812
            preferences.windowHeight = 601
            preferences.dividerPosition = 312
            store.saveStashPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).stashPreferences == preferences)
        }
    }

    private static func testCherryPickPreferencesRoundTrip() {
        withStore { store, defaults in
            let preferences = CherryPickPreferences(
                automaticallyCommit: true,
                addReference: true
            )
            store.saveCherryPickPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).cherryPickPreferences == preferences)
        }
    }

    private static func testCommitPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.commitPreferences
            preferences.historyLimit = 12
            preferences.showOnlyMyMessages = true
            preferences.ensureSecondLineEmpty = false
            preferences.rememberAmendState = false
            preferences.closeAfterCommit = false
            preferences.refreshOnFocus = true
            preferences.confirmAmend = false
            preferences.forceWithLeaseAfterAmend = true
            preferences.lastCommitMessage = "Remembered message"
            preferences.templates = [CommitMessageTemplate(
                name: "Issue",
                text: "fix: {{issue-(\\d+)}}[1]",
                expandsBranchRegularExpressions: true
            )]
            preferences.validation.maximumSubjectLength = 72
            preferences.validation.regularExpression = #"^(feat|fix):"#
            preferences.windowWidth = 1040
            preferences.mainDivider = 420
            store.saveCommitPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).commitPreferences == preferences)
        }
    }

    private static func testFileStatusListPreferencesRoundTrip() {
        withStore { store, defaults in
            let preferences = FileStatusListPreferences(
                grouping: .status,
                isTreeMode: false,
                usesDenseTree: false,
                showsGroupNodesInFlatList: true,
                showsUntrackedFiles: false
            )
            store.saveFileStatusListPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).fileStatusListPreferences == preferences)
        }
    }

    private static func testViewerRuntimeDefaults() {
        withStore { store, defaults in
            var baseline = store.fileViewerPreferences
            baseline.whitespace = .endOfLine
            store.saveFileViewerPreferences(baseline)
            var runtime = baseline
            runtime.whitespace = .all
            runtime.showsEntireFile = true
            runtime.contextLines = 15
            store.updateFileViewerPreferences(runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == baseline)
            let next = store.preferencesForNewFileViewer()
            precondition(next.whitespace == .all && !next.showsEntireFile && next.contextLines == 3)
            var remember = store.fileViewerRemember
            remember.whitespace = false
            remember.entireFile = true
            remember.contextLines = true
            store.saveFileViewerRemember(remember)
            store.updateFileViewerPreferences(runtime)
            precondition(store.preferencesForNewFileViewer().whitespace == .endOfLine)
            precondition(store.preferencesForNewFileViewer().showsEntireFile)
            runtime.contextLines = 16
            store.updateFileViewerPreferences(runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences.contextLines == 16)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences.whitespace == .endOfLine)
            store.saveFileViewerPreferences(runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerRemember == remember)
        }
    }

    private static func testFontsRoundTrip() {
        withStore { store, defaults in
            precondition(store.fontPreferences.fonts.isEmpty)
            let original = store.codeFont
            var fonts = store.fontPreferences
            fonts.fonts[.code] = StoredApplicationFont(NSFont.monospacedSystemFont(ofSize: 18, weight: .regular))
            fonts.fonts[.commit] = StoredApplicationFont(NSFont.systemFont(ofSize: 15))
            fonts.fonts[.application] = StoredApplicationFont(NSFont.systemFont(ofSize: 22))
            fonts.showEolMarkerAsGlyph = true
            store.saveFontPreferences(fonts)
            let reloaded = AppSettingsStore(defaults: defaults)
            precondition(reloaded.fontPreferences == fonts)
            let legacyFontData = try! JSONSerialization.data(withJSONObject: ["fonts": []])
            precondition(!(try! JSONDecoder().decode(ApplicationFontPreferences.self, from: legacyFontData)).showEolMarkerAsGlyph)
            precondition(FileViewerWhitespace.text("a\r\nb\nc\r", glyph: false) == "a\\r\\n\r\nb\\n\nc\\r\r")
            precondition(FileViewerWhitespace.text("a\r\nb\n", glyph: true) == "a¶\r\nb¶\n")
            precondition(FileViewerWhitespace.text("a\t b", glyph: true) == "a→·b")
            precondition(reloaded.codeFont.pointSize == 18 && reloaded.commitFont.pointSize == 15)
            precondition(reloaded.diffLineHeight >= 21)
            precondition(reloaded.applicationFont(size: 11).pointSize == 22)
            precondition(reloaded.applicationRowHeight(minimum: 18) > 22)
            let lines = [DiffLine(id: "line", oldLineNumber: 999, newLineNumber: 1000, kind: .context, text: "text")]
            let standardGutter = DiffGutterMetrics(lines: lines)
            let customGutter = DiffGutterMetrics(lines: lines, font: reloaded.diffGutterFont)
            precondition(customGutter.numberColumnWidth > standardGutter.numberColumnWidth)
            store.saveFontPreferences(ApplicationFontPreferences())
            precondition(store.codeFont == original)
            precondition(AppSettingsStore(defaults: defaults).fontPreferences.fonts.isEmpty)
            let japanese = RepositoryTextEncoding(ianaName: "shift_jis")!
            store.includedTextEncodings = [japanese]
            let encodings = AppSettingsStore(defaults: defaults).includedTextEncodings
            precondition(encodings.contains(japanese) && encodings.contains(.utf8))
            precondition(store.viewerEncodings(including: .windows1252).contains(.windows1252))
        }
    }

    private static func testColors() {
        do {
            let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GitExtensionsMac/UI/Themes")
            let normal = try ApplicationThemeReader.load("invariant.css", colorblind: false, bundled: bundled)
            let accessible = try ApplicationThemeReader.load("invariant.css", colorblind: true, bundled: bundled)
            precondition(normal["RemoteBranch"] == 0x8B0009)
            precondition(accessible["RemoteBranch"] == 0x0600A8)
            precondition(normal["GraphBranch8"] == -1)
            let dark = try ApplicationThemeReader.load("dark+.css", colorblind: false, bundled: bundled)
            precondition(dark["GraphBranch1"] == 0xDB5B93)
            precondition(ApplicationThemeReader.parseColor("#abc") == 0xAABBCC)
            precondition(ApplicationThemeReader.parseColor("LightGoldenRodYellow") == 0xFAFAD2)
            precondition(ApplicationThemeReader.parseColor("rebeccapurple") == 0x663399)
            precondition(ApplicationThemeReader.parseColor("darkslategrey") == 0x2F4F4F)
            precondition(ApplicationThemeReader.parseColor("rgb(12, 34, 56)") == 0x0C2238)
            precondition(ApplicationThemeReader.parseColor("not a color") == nil)
            precondition(ApplicationThemeReader.parseColor("#-12345") == nil)
            precondition(ApplicationThemeReader.parseColor("rgb(12, bad, 34, 56)") == nil)
            precondition(ApplicationThemeReader.parseColor("rgb(12,,34)") == nil)
            precondition(ApplicationThemeReader.parseColor("rgb(100%, 0%, 50%)") == 0xFF0080)
            precondition(ApplicationThemeReader.parseColor("hsl(120, 100%, 50%)") == 0x00FF00)
            precondition(ApplicationThemeReader.parseColor("hsl(-120, 100%, 50%)") == 0x0000FF)
            precondition(ApplicationThemeReader.parseColor("hsl(nan, 100%, 50%)") == nil)
            withStore { store, defaults in
                var colors = store.colorPreferences
                colors.themeFile = "dark.css"; colors.colorblind = true; colors.multicolorBranches = false
                store.colorPreferences = colors
                precondition(AppSettingsStore(defaults: defaults).colorPreferences == colors)
            }
        } catch { preconditionFailure("Theme fixture failed: \(error)") }
    }

    private static func testSharedViewerSearch() {
        let lines = ["first match", "middle", "last MATCH"].enumerated().map { index, text in
            DiffLine(id: String(index), oldLineNumber: index + 1, newLineNumber: index + 1, kind: .context, text: text)
        }
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 0) == 2)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 2, forward: false) == 0)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 0, forward: false) == 2)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: -1, forward: false) == 2)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 2) == 0)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: [], query: "match", after: 0) == nil)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "absent", after: 0) == nil)
    }

    private static func testHotkeys() {
        withStore { store, defaults in
            let original = ApplicationHotkeys.chord("refresh", overrides: [:])
            precondition(original == ApplicationKeyChord("r", .command))
            store.hotkeyOverrides = ["refresh": .init("r", [.command, .shift]), "commit": .init("")]
            let saved = AppSettingsStore(defaults: defaults).hotkeyOverrides
            precondition(ApplicationHotkeys.chord("refresh", overrides: saved).title == "⇧⌘R")
            precondition(ApplicationHotkeys.chord("commit", overrides: saved).swiftUI == nil)
            precondition(ApplicationHotkeys.chord("createBranch", overrides: saved) == .init("b", .control))
            store.hotkeyOverrides = [:]
            precondition(ApplicationHotkeys.chord("refresh", overrides: store.hotkeyOverrides) == original)
            precondition(Set(ApplicationHotkeys.definitions.map(\.id)).count == ApplicationHotkeys.definitions.count)
            precondition(ApplicationHotkeys.matching(.init("n", .command), category: "Stash", overrides: [:]) == "stash.next")
            precondition(ApplicationHotkeys.matching(.init("b"), category: "Conflict resolver", overrides: [:]) == "conflict.base")
            let overrides: [String: ApplicationKeyChord] = ["conflict.base": .init("1", .command), "stash.next": .init("")]
            precondition(ApplicationHotkeys.matching(.init("b"), category: "Conflict resolver", overrides: overrides) == nil)
            precondition(ApplicationHotkeys.matching(.init("1", .command), category: "Conflict resolver", overrides: overrides) == "conflict.base")
            precondition(ApplicationHotkeys.matching(.init("n", .command), category: "Stash", overrides: overrides) == nil)
            precondition(ApplicationHotkeys.matching(.init("b"), category: "Stash", overrides: [:]) == nil)
            precondition(ApplicationHotkeys.matching(.init("\u{f705}"), category: "Repository tree", overrides: [:]) == "tree.rename")
            precondition(ApplicationHotkeys.matching(.init("\u{7f}"), category: "Repository tree", overrides: ["tree.delete": .init("")]) == nil)
            precondition(ApplicationHotkeys.matching(.init("\u{f703}", .option), category: "Commit", overrides: [:]) == "commit.nextFile.alternative")
            precondition(ApplicationHotkeys.matching(.init("\u{f703}", .option), category: "Commit", overrides: ["commit.nextFile.alternative": .init("")]) == nil)
            precondition(ApplicationHotkeys.matching(.init("s"), category: "File status list", overrides: [:]) == "file.stage")
        }
    }

    private static func testRevisionLinks() {
        var definition = RevisionLinkDefinition()
        definition.name = "Issues & reviews"
        definition.searchPattern = "issue (#[0-9]+,? ?)+"
        definition.nestedSearchPattern = "#([0-9]+)"
        definition.remoteSearchPattern = "https://([^/]+)/(.+)"
        definition.formats = [.init(caption: "Issue {2}", format: "https://{0}/{1}/issues/{2}?commit=%COMMIT_HASH%")]
        let xml = RevisionLinkDefinition.encode([definition])
        precondition(try! RevisionLinkDefinition.decode(xml) == [definition])
        let id = try! ObjectID(parsing: String(repeating: "a", count: 40))
        let links = definition.links(commitID: id, message: "Fix issue #12, #34", localRefs: [], remoteRefs: [], remotes: [
            .init(name: "origin", url: "https://example.org/fork", pushURL: ""),
            .init(name: "upstream", url: "https://example.org/project", pushURL: "")
        ])
        precondition(links.map(\.caption) == ["Issue 12", "Issue 34"])
        precondition(links[0].destination == "https://example.org/project/issues/12?commit=\(id.string)")
        precondition(RevisionLinkDefinition.format("{{{0}}}", groups: ["value"]) == "{value}")
        precondition(RevisionLinkDefinition.format("[{0,7}] [{0,-7}]", groups: ["value"]) == "[  value] [value  ]")
        precondition(RevisionLinkDefinition.format("{0:ignored}", groups: ["value"]) == "value")
        precondition(RevisionLinkDefinition.format("{0,invalid}", groups: ["value"]) == nil)
        precondition(RevisionLinkDefinition.format("{3}", groups: []) == nil)
        definition.searchPattern = "["
        precondition(definition.links(commitID: id, message: "anything", localRefs: [], remoteRefs: [], remotes: []).isEmpty)
        withStore { store, defaults in
            store.revisionLinksXML = xml
            precondition(AppSettingsStore(defaults: defaults).revisionLinksXML == xml)
            store.revisionLinksXML = nil
            precondition(AppSettingsStore(defaults: defaults).revisionLinksXML == nil)
        }
    }

    private static func testDistributedSettings() {
        precondition(DistributedSettings.normalizedMergeLogCount(" 0 ") == "0")
        precondition(DistributedSettings.normalizedMergeLogCount("-2") == "-2")
        precondition(DistributedSettings.normalizedMergeLogCount("invalid") == nil)
        precondition(DistributedSettings.normalizedMergeLogCount("2147483648") == nil)
        func require(_ condition: Bool) { precondition(condition) }
        withStore { store, _ in
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-SettingsXML-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let settings = DistributedSettings(localURL: root.appendingPathComponent("local.settings"), distributedURL: root.appendingPathComponent("distributed.settings"))
                let key = DistributedSettings.mergeLog
                try DistributedSettings.write([key: "true", "unrelated": "Unicode é & <value>\nline"], to: settings.distributedURL)
                require(try settings.mergePreferences(store).addLogMessages)
                try DistributedSettings.write([key: "false"], to: settings.localURL)
                require(try !settings.mergePreferences(store).addLogMessages)
                try DistributedSettings.write([key: nil], to: settings.localURL)
                require(try settings.mergePreferences(store).addLogMessages)
                var preferences = try settings.mergePreferences(store)
                preferences.addLogMessages = false
                preferences.logMessagesCount = 42
                try settings.saveMergeLog(preferences, store: store)
                require(try DistributedSettings.read(settings.localURL)[key] == "false")
                require(try DistributedSettings.read(settings.distributedURL)[key] == "true")
                precondition(store.mergePreferences.logMessagesCount == 42)
                require(try DistributedSettings.read(settings.distributedURL)["unrelated"] == "Unicode é & <value>\nline")
                try Data("<not-a-dictionary/>".utf8).write(to: settings.localURL)
                var rejected = false
                do { try DistributedSettings.write([key: "true"], to: settings.localURL) } catch { rejected = true }
                precondition(rejected)
                require(try String(contentsOf: settings.localURL, encoding: .utf8) == "<not-a-dictionary/>")
            } catch { preconditionFailure("Distributed settings test failed: \(error)") }
        }
        withStore { _, defaults in
            var legacy = MergePreferences(); legacy.addLogMessages = true; legacy.logMessagesCount = 73
            defaults.set(try! JSONEncoder().encode(legacy), forKey: "GitExtensionsMac.mergePreferences.v1")
            defaults.removeObject(forKey: "GitExtensionsMac.detailedSettings.unset.v1")
            let migrated = AppSettingsStore(defaults: defaults)
            precondition(DistributedSettings.globalValues(migrated)[DistributedSettings.mergeLog] == "true")
            precondition(DistributedSettings.globalValues(migrated)[DistributedSettings.mergeLogCount] == "73")
        }
    }

    private static func testFileViewerPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.fileViewerPreferences
            preferences.whitespace = .changes
            preferences.contextLines = 8
            preferences.showsEntireFile = true
            preferences.treatsAllFilesAsText = true
            preferences.showsNonPrintingCharacters = true
            preferences.showsSyntaxHighlighting = false
            preferences.textEncoding = .windows1252
            store.saveFileViewerPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == preferences)
            var application = store.preferences
            application.reopenLastRepository.toggle()
            store.save(application)
            precondition(store.fileViewerPreferences == preferences, "Unrelated app settings must not collapse detailed whitespace modes")
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == preferences, "Detailed viewer defaults survive relaunch")
        }
    }

    private static func testCommitMessageRules() {
        var validation = CommitValidationPreferences()
        validation.maximumSubjectLength = 8
        validation.maximumLineLength = 12
        validation.requireEmptySecondLine = true
        validation.regularExpression = #"^(feat|fix):"#
        let issues = CommitMessageValidator.issues(
            in: "not a valid subject\nbody without separator\ntail",
            preferences: validation
        )
        precondition(issues.contains(.subjectTooLong(actual: 19, maximum: 8)))
        precondition(issues.contains(.lineTooLong(line: 1, actual: 19, maximum: 12)))
        precondition(issues.contains(.lineTooLong(line: 2, actual: 22, maximum: 12)))
        precondition(issues.contains(.secondLineMustBeEmpty))
        precondition(issues.contains(.regularExpressionMismatch(#"^(feat|fix):"#)))

        validation.regularExpression = "["
        precondition(!CommitMessageValidator.issues(in: "feat: valid", preferences: validation).contains(.invalidRegularExpression("[")))
        precondition(CommitTemplateExpander.expand(
            "fix: {{issue-(\\d+)}}[1]",
            forBranch: "issue-428-polish",
            enabled: true
        ) == "fix: 428")
        precondition(CommitTemplateExpander.expand("{{missing-(\\d+)}}[1]", forBranch: "main", enabled: true).isEmpty)

        var formatting = CommitValidationPreferences()
        formatting.maximumLineLength = 12
        formatting.requireEmptySecondLine = true
        formatting.indentAfterFirstLine = true
        formatting.autoWrap = true
        precondition(CommitMessageAutoFormatter.format(
            "Subject\nbody words that wrap",
            preferences: formatting
        ) == "Subject\n\n - body\nwords that\nwrap")
    }

    private static func withStore(_ body: (AppSettingsStore, UserDefaults) -> Void) {
        let suite = "GitExtensionsMac.AppSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Could not create defaults suite") }
        defaults.removePersistentDomain(forName: suite)
        body(AppSettingsStore(defaults: defaults), defaults)
        defaults.removePersistentDomain(forName: suite)
    }
}
