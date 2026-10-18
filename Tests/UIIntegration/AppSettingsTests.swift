import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("App settings")
    enum AppSettingsTests {

        @Test("Startup checklist preference") private static func testStartupChecklistPreference() {
            withStore { store, defaults in
                let existing = store.preferences
                #expect(store.checkSettingsAtStartup)
                store.checkSettingsAtStartup = false
                #expect(!AppSettingsStore(defaults: defaults).checkSettingsAtStartup)
                #expect(AppSettingsStore(defaults: defaults).preferences == existing)
                store.checkSettingsAtStartup = true
                #expect(AppSettingsStore(defaults: defaults).checkSettingsAtStartup)
                store.recordSettingsCheck(allValid: false)
                #expect(store.checkSettingsAtStartup)
                store.recordSettingsCheck(allValid: true)
                #expect(!AppSettingsStore(defaults: defaults).checkSettingsAtStartup)
                store.recordSettingsCheck(allValid: false)
                #expect(!store.checkSettingsAtStartup, "a later failure does not undo a user's disabled startup checks")
            }
        }

        @Test("Settings page layout") static func runSettingsPageLayout() throws {
            let suite = "GitExtensionsMac.SettingsLayoutTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let remembered = SettingsViewController.lastSelectedPage
            defer {
                SettingsViewController.lastSelectedPage = remembered
                defaults.removePersistentDomain(forName: suite)
            }
            let store = AppSettingsStore(defaults: defaults)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let controller = SettingsViewController(store: store, source: nil, initialPage: "general", repositoryChanged: {})
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let scroll = try #require(descendants(controller.view).compactMap { $0 as? NSScrollView }.first { $0.documentView is TopAlignedDocumentView })
            window.contentMaxSize = SettingsViewController.maximumContentSize
            window.setContentSize(NSSize(width: 4000, height: 3000))
            #expect(window.contentRect(forFrameRect: window.frame).size.width <= SettingsViewController.maximumContentSize.width + 0.5, "Settings has a defined maximum width")
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.fittingSize.width <= SettingsViewController.maximumContentSize.width, "maximum size accommodates the minimum layout")
            var checkedRows = 0
            for (width, page) in [CGFloat(1040), 0].flatMap({ width in controller.categoryIDs.filter { $0 != "application" }.map { (width, $0) } }) {
                window.setContentSize(NSSize(width: width, height: 720))
                controller.goToCategory(page)
                controller.view.layoutSubtreeIfNeeded()
                let document = try #require(scroll.documentView)
                let visible = descendants(document).filter { !$0.isHiddenOrHasHiddenAncestor }
                let rows = visible.compactMap { $0 as? SettingsFormRow }
                checkedRows += rows.count
                let columns = Dictionary(grouping: rows) { document.convert($0.label.bounds, from: $0.label).minX.rounded() }
                for (labelX, group) in columns {
                    let controlX = Set(group.map { document.convert($0.control.bounds, from: $0.control).minX.rounded() })
                    #expect(controlX.count == 1, "\(page): controls after labels at \(labelX) share one column \(controlX)")
                }
                let groups = visible.compactMap { $0 as? SettingsGroupBox }.filter { !($0.superview?.isDescendant(of: $0) ?? false) && !(($0.superview?.superview?.superview as? SettingsGroupBox) != nil) }
                #expect(Set(groups.map { $0.frame.width.rounded() }).count <= 1, "\(page): top-level groups share one width")
                let limit = scroll.contentView.bounds.width + 1
                #expect(scroll.contentView.bounds.width >= SettingsSourceHeader.minimumWidth + 36, "\(page) at \(window.frame.width): Settings source row fits on one line")
                let clipped = visible.compactMap { $0 as? NSControl }.filter { document.convert($0.bounds, from: $0).maxX > limit }
                #expect(clipped.isEmpty, "\(page) at \(window.frame.width): controls extend past the visible width \(clipped.map { ($0 as? NSButton)?.title ?? String(describing: type(of: $0)) })")
            }
            #expect(checkedRows > 20, "form rows were measured")
            let header = SettingsSourceHeader(options: DistributedSettingsScope.allCases.map { ($0.rawValue, $0.title) }, selected: "effective")
            #expect(header.radios.map(\.title) == ["Effective", "Local for current repository", "Distributed with current repository", "Global for all repositories"], "upstream source captions and order")
            let arrows = descendants(header).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "<<" }
            #expect(arrows.count == 3 && arrows.allSatisfy { $0.alphaValue == 1 }, "inheritance arrows shown for Effective")
            var chosen: [String] = []
            header.onChange = { chosen.append($0) }
            header.radios[3].performClick(nil)
            #expect(header.selectedID == "global" && chosen == ["global"] && header.radios.map(\.state) == [.off, .off, .off, .on], "radio selection")
            #expect(arrows.allSatisfy { $0.alphaValue == 0 }, "arrows hidden outside Effective")
            header.frame.size = header.fittingSize
            header.layoutSubtreeIfNeeded()
            #expect(Set(header.radios.map { header.convert($0.bounds, from: $0).minY.rounded() }).count == 1, "source options stay on one line")
        }

        @Test("Settings tree") static func runSettingsTree() async throws {
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
            #expect(controller.currentCategoryID == "application", "first opening selects Checklist")
            #expect(controller.rootCategoryIDs == ["application", "git", "plugins"])
            #expect(
                controller.categoryIDs == [
                    "application", "general", "appearance", "sorting", "colors", "fonts", "revision_links", "build_server", "scripts", "hotkeys", "advanced",
                    "confirmations", "detailed", "browse", "commit", "diff", "blame", "ssh", "git", "git_paths", "git_config", "git_advanced", "plugins",
                ], "tree order and omission of unavailable console/Shell extension")
            let deadline = ContinuousClock.now + .seconds(5)
            while controller.checklist.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(controller.checklist.first?.status == .invalid, "missing Git shown asynchronously")
            let repair = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "SettingsCheck.git" }
            #expect(repair != nil, "checklist diagnostic is actionable")
            #expect(repair?.imagePosition == .imageLeft && repair?.title.isEmpty == false, "diagnostic shows text alongside status icon")
            #expect(store.checkSettingsAtStartup, "invalid diagnostics do not disable startup checks")
            controller.goToCategory("git")
            let labels = descendants(controller.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
            #expect(labels.contains { $0.contains("Select one of the subnodes") }, "Git root is an introduction, not Paths")
            controller.goToCategory("fonts")
            let reopened = make()
            _ = reopened.view
            #expect(reopened.currentCategoryID == "fonts", "last page is remembered within the process")
            let explicit = make("general")
            _ = explicit.view
            #expect(explicit.currentCategoryID == "general", "explicit page overrides last page")
            controller.searchSettings("whitespace")
            #expect(controller.searchMatches.contains("diff") && controller.currentCategoryID == "fonts")
            let tree = descendants(controller.view).compactMap { $0 as? NSOutlineView }.first!
            #expect(tree.numberOfRows > 3 && tree.item(atRow: tree.numberOfRows - 1) is SettingsNode, "search preserves full tree")
            controller.selectNextSearchMatch()
            #expect(controller.searchMatches.contains(controller.currentCategoryID))
            let firstMatch = controller.currentCategoryID
            for _ in controller.searchMatches.indices { controller.selectNextSearchMatch() }
            #expect(controller.currentCategoryID == firstMatch, "Enter cycles search results")
            controller.searchSettings("whitespace encoding")
            #expect(controller.searchMatches.contains("diff"), "all words match page labels")
            controller.searchSettings("whitespace definitelynotasetting")
            #expect(controller.searchMatches.isEmpty, "all search words are required")
            controller.searchSettings("encoding")
            #expect(!controller.searchMatches.contains("detailed"), "unvisited Detailed page does not claim diff encoding")
            controller.searchSettings("")
            #expect(controller.searchMatches.isEmpty && controller.categoryIDs.count == 23)
            controller.goToCategory("removed-console")
            #expect(controller.currentCategoryID == "application", "stale page falls back to root")
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
            #expect(found.checklist.contains { $0.kind == .editor }, "editor check still evaluated")
            #expect(identifiers.contains("SettingsCheck.identity") && !identifiers.contains("SettingsCheck.editor"), "editor check has no row")
            found.view.layoutSubtreeIfNeeded()
            let checkWidths = Set(descendants(found.view).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("SettingsCheck.") }.map(\.frame.width))
            #expect(checkWidths.count == 1, "checklist boxes share one width")
            found.goToCategory("general")
        }

        @Test("Repository scopes") static func runRepositoryScopes() async throws {
            let first = try FileStatusFixture.make()
            let second = try FileStatusFixture.make()
            defer {
                first.remove()
                second.remove()
            }
            try first.write("a.txt", "base\n")
            try first.commitAll("base")
            try second.write("a.txt", "base\n")
            try second.commitAll("base")
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
                if let originalConfirmation {
                    UserDefaults.standard.set(originalConfirmation, forKey: confirmationKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: confirmationKey)
                }
            }
            let store = AppSettingsStore(defaults: defaults)
            let key = DistributedSettings.mergeLog
            let count = DistributedSettings.mergeLogCount
            func wait(_ message: String, _ predicate: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                #expect(predicate(), Comment(rawValue: message))
            }
            #expect(DistributedSettings.globalValues(store).isEmpty, "fresh explicit global scope is unset, not materialized defaults")

            var merge = store.mergePreferences
            merge.addLogMessages = true
            merge.logMessagesCount = 31
            store.saveMergePreferences(merge)
            #expect(DistributedSettings.globalValues(AppSettingsStore(defaults: defaults))[count] == "31", "legacy global count preserved")
            store.saveDetailedSetting(key, value: nil)
            store.saveDetailedSetting(count, value: nil)
            store.saveMergePreferences(store.mergePreferences)
            let relaunched = AppSettingsStore(defaults: defaults)
            #expect(
                DistributedSettings.globalValues(relaunched)[key] == nil && DistributedSettings.globalValues(relaunched)[count] == nil,
                "explicit global unset persists")
            #expect(
                try a.mergePreferences(relaunched).addLogMessages == false && a.mergePreferences(relaunched).logMessagesCount == 20, "unset effective defaults")
            store.saveDetailedSetting(key, value: "false")
            store.saveDetailedSetting(count, value: "31")
            try DistributedSettings.write([key: "true", count: "40", "unrelated": "keep"], to: a.distributedURL)
            try DistributedSettings.write([key: "false", count: "50"], to: a.localURL)
            try DistributedSettings.write([count: "60"], to: b.localURL)
            #expect(try a.values(.global, global: DistributedSettings.globalValues(store))[count] == "31", "explicit global does not inherit")
            #expect(try a.values(.distributed, global: DistributedSettings.globalValues(store))[count] == "40", "explicit distributed does not inherit")
            #expect(
                try a.mergePreferences(store).logMessagesCount == 50 && b.mergePreferences(store).logMessagesCount == 60,
                "repositories have isolated effective values")
            try DistributedSettings.write([count: nil], to: a.localURL)
            #expect(try a.mergePreferences(store).logMessagesCount == 40, "reset local reveals distributed")
            #expect(try a.effectiveWriteScope(key: count, value: "40", global: DistributedSettings.globalValues(store)) == nil, "unchanged effective no-op")
            #expect(
                try a.effectiveWriteScope(key: count, value: "41", global: DistributedSettings.globalValues(store)) == .local,
                "effective distributed override writes local")
            var scoped = try a.mergePreferences(store)
            scoped.logMessagesCount = 41
            try a.saveMergeLog(scoped, store: store)
            #expect(
                try DistributedSettings.read(a.distributedURL)[count] == "40" && DistributedSettings.read(a.localURL)[count] == "41",
                "workflow does not rewrite distributed settings")
            try DistributedSettings.write([count: nil], to: a.localURL)
            try DistributedSettings.write([count: nil], to: a.distributedURL)
            #expect(try a.mergePreferences(store).logMessagesCount == 31, "reset both overrides reveals global")
            #expect(
                try a.effectiveWriteScope(key: count, value: "32", global: DistributedSettings.globalValues(store)) == .global, "absent overrides write global")
            try DistributedSettings.write([count: "2147483648"], to: a.localURL)
            #expect(try a.mergePreferences(store).logMessagesCount == 20, "invalid scoped Int32 uses upstream default, not lower-priority value")
            try DistributedSettings.write([count: "50"], to: a.localURL)

            let linked = first.root.appendingPathComponent("linked worktree")
            try first.git(["worktree", "add", "-q", "--detach", linked.path])
            let linkedModule = GitRepositoryModule(repositoryURL: linked, git: FileStatusFixtureGit())
            _ = try await linkedModule.loadRepositoryState()
            let linkedSettings = try await DistributedSettings.loadLocations(from: linkedModule)
            #expect(linkedSettings.localURL == a.localURL && linkedSettings.distributedURL != a.distributedURL, "linked worktree scope locations")
            let bare = second.root.appendingPathComponent("bare.git")
            try second.git(["clone", "-q", "--bare", second.repo.path, bare.path])
            let bareModule = GitRepositoryModule(repositoryURL: bare, git: FileStatusFixtureGit())
            _ = try await bareModule.loadRepositoryState()
            let bareSettings = try await DistributedSettings.loadLocations(from: bareModule)
            #expect(
                bareSettings.localURL.deletingLastPathComponent().resolvingSymlinksInPath().path == bare.resolvingSymlinksInPath().path,
                "bare repository local settings: \(bareSettings.localURL.path), expected \(bare.path)")

            let buildA = BuildServerSettingsStore(locations: a, defaults: defaults)
            let buildB = BuildServerSettingsStore(locations: b, defaults: defaults)
            let buildKey = BuildServerSettingKeys.enabled
            #expect(try buildA.write([buildKey: "true"], scope: .global), "initial build global write")
            #expect(try !buildA.write([buildKey: "true"], scope: .global), "unchanged build settings no-op")
            try buildA.write([buildKey: "false"], scope: .local)
            #expect(try buildA.values(.effective)[buildKey] == "false" && buildB.values(.effective)[buildKey] == "true", "build scoped isolation")
            try buildA.write([buildKey: nil], scope: .local)
            #expect(try buildA.values(.effective)[buildKey] == "true", "build reset fallback")
            let pluginID = UUID()
            let pluginA = ApplicationPluginSettings(identifier: pluginID, legacyName: "Fixture.", locations: a, defaults: defaults)
            let pluginB = ApplicationPluginSettings(identifier: pluginID, legacyName: "Fixture.", locations: b, defaults: defaults)
            try pluginA.set("enabled", value: "global")
            try pluginA.set("enabled", value: "local", scope: .local)
            #expect(try pluginA.value("enabled") == "local" && pluginB.value("enabled") == "global", "plugin scoped isolation")
            try pluginA.set("enabled", value: nil, scope: .local)
            #expect(try pluginA.value("enabled") == "global", "plugin reset fallback")
            #expect(try DistributedSettings.read(a.distributedURL)["unrelated"] == "keep", "unrelated XML settings preserved")

            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func scopeControl(_ controller: SettingsViewController) -> SettingsSourceHeader? {
                descendants(controller.view).compactMap { $0 as? SettingsSourceHeader }.first { $0.accessibilityIdentifier() == "Settings.appScope" }
            }
            func field<T: NSControl>(_ controller: SettingsViewController, _ label: String, as type: T.Type) -> T {
                let title = descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == label }!
                return title.superview!.subviews.filter { $0 !== title }.compactMap { $0 as? T }.first!
            }
            func select(_ popup: NSPopUpButton, title: String) {
                popup.selectItem(withTitle: title)
                _ = popup.sendAction(popup.action!, to: popup.target)
            }
            func select(_ header: SettingsSourceHeader, title: String) {
                header.choose(DistributedSettingsScope.allCases.first { $0.title == title }!.rawValue)
            }
            try buildA.write([buildKey: "false"], scope: .local)
            let buildPage = BuildServerSettingsPageController(store: buildA, remoteURLs: [], workingDirectoryName: nil)
            let buildScope = descendants(buildPage.view).compactMap { $0 as? SettingsSourceHeader }.first!
            select(buildScope, title: DistributedSettingsScope.local.title)
            let enabled = descendants(buildPage.view).compactMap { $0 as? NSButton }.first { $0.title == "Enable build server integration" }!
            #expect(enabled.state == .off, "build local state")
            enabled.state = .mixed
            _ = enabled.sendAction(enabled.action!, to: enabled.target)
            select(buildScope, title: DistributedSettingsScope.effective.title)
            #expect(enabled.state == .on && !enabled.isEnabled, "removing local build draft immediately reveals global effective value")
            #expect(try buildPage.save(), "build scoped reset persisted")
            #expect(try !buildPage.save(), "repeated build save is a no-op")
            var notifications = 0
            let controller = SettingsViewController(
                store: store, source: firstModule, initialPage: "detailed", initialScope: .local, repositoryChanged: { notifications += 1 })
            let panel = NSPanel(contentViewController: controller)
            controller.panel = panel
            panel.setContentSize(NSSize(width: 1040, height: 720))
            panel.makeKeyAndOrderFront(nil)
            defer { panel.close() }
            try await wait("repository scope loaded") { scopeControl(controller) != nil }
            #expect(scopeControl(controller)?.selectedID == DistributedSettingsScope.local.rawValue, "repository entry selects local")
            #expect(field(controller, "Merge log messages count:", as: NSTextField.self).stringValue == "50", "local value in hosted UI")
            let graph = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Render graph with diagonals" }!
            #expect(!graph.isEnabled, "graph preferences are global-only")

            var number = field(controller, "Merge log messages count:", as: NSTextField.self)
            number.stringValue = "51"
            number.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: number))
            select(scopeControl(controller)!, title: DistributedSettingsScope.effective.title)
            number = field(controller, "Merge log messages count:", as: NSTextField.self)
            #expect(number.stringValue == "51" && !number.isEnabled, "effective sees unsaved local draft and is read-only")
            select(scopeControl(controller)!, title: DistributedSettingsScope.distributed.title)
            number = field(controller, "Merge log messages count:", as: NSTextField.self)
            #expect(number.stringValue.isEmpty && number.isEnabled, "explicit distributed missing stays unset")
            select(scopeControl(controller)!, title: DistributedSettingsScope.local.title)
            #expect(field(controller, "Merge log messages count:", as: NSTextField.self).stringValue == "51", "local draft survives scope changes")
            let apply = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
            apply.performClick(nil)
            try await wait("local Apply persisted and notified once") { notifications == 1 && apply.isEnabled }
            #expect(
                try DistributedSettings.read(a.localURL)[count] == "51" && b.mergePreferences(store).logMessagesCount == 60, "Apply isolated to current repo")
            apply.performClick(nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(notifications == 1, "unchanged Apply has no repository mutation notification")
            select(scopeControl(controller)!, title: DistributedSettingsScope.global.title)
            let globalGraph = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Render graph with diagonals" }!
            #expect(globalGraph.isEnabled, "graph editable globally")
            select(field(controller, "Add log messages:", as: NSPopUpButton.self), title: "Not set")
            descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!.performClick(nil)
            try await wait("global unset applied") { DistributedSettings.globalValues(AppSettingsStore(defaults: defaults))[key] == nil }
            controller.goToCategory("general")
            #expect(scopeControl(controller) == nil, "General remains upstream global-only")
            controller.goToCategory("fonts")
            #expect(scopeControl(controller) == nil, "fonts remain upstream global-only")
            controller.goToCategory("revision_links")
            #expect(
                scopeControl(controller)?.selectedID == DistributedSettingsScope.effective.rawValue,
                "Revision links starts at its own effective scope, not Detailed's global scope")
            select(scopeControl(controller)!, title: DistributedSettingsScope.effective.title)
            #expect(scopeControl(controller)!.radios.allSatisfy { $0.isEnabled }, "effective page leaves the scope selector enabled")
            let addLink = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Add" }!
            #expect(!addLink.isEnabled, "effective Revision links cannot silently add to another scope")
            select(scopeControl(controller)!, title: DistributedSettingsScope.local.title)
            #expect(
                descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Add" }!.isEnabled, "explicit Revision links scope is writable")
            controller.goToCategory("detailed")
            #expect(scopeControl(controller)?.selectedID == DistributedSettingsScope.global.rawValue, "each page retains its own chosen scope")
            controller.goToCategory("git_config")
            func gitScope() -> SettingsSourceHeader {
                descendants(controller.view).compactMap { $0 as? SettingsSourceHeader }.first { $0.accessibilityIdentifier() == "Settings.gitScope" }!
            }
            gitScope().choose(GitSettingsScope.global.rawValue)
            controller.goToCategory("git_advanced")
            #expect(gitScope().selectedID == GitSettingsScope.effective.rawValue, "Git Advanced has an independent initial scope")
            controller.goToCategory("git_config")
            #expect(gitScope().selectedID == GitSettingsScope.global.rawValue, "Git Config remembers its own scope")
            let other = SettingsViewController(store: store, source: secondModule, initialPage: "detailed", initialScope: .local, repositoryChanged: {})
            let otherPanel = NSPanel(contentViewController: other)
            other.panel = otherPanel
            otherPanel.makeKeyAndOrderFront(nil)
            defer { otherPanel.close() }
            try await wait("second repository scopes loaded") { scopeControl(other) != nil }
            #expect(
                field(other, "Merge log messages count:", as: NSTextField.self).stringValue == "60",
                "switching repository does not reuse first repository drafts")

            number = field(other, "Merge log messages count:", as: NSTextField.self)
            number.stringValue = "99"
            number.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: number))
            descendants(other.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
            #expect(try DistributedSettings.read(b.localURL)[count] == "60", "Cancel never saves scoped draft")
            let noRepository = SettingsViewController(store: store, source: nil, initialPage: "detailed", repositoryChanged: {})
            #expect(scopeControl(noRepository)?.optionIDs == [DistributedSettingsScope.global.rawValue], "no repository exposes global only")
        }

        @Test("Preferences round trip") private static func testPreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.preferences
                preferences.theme = .dark
                preferences.gitExecutablePath = "/opt/homebrew/bin/git"
                preferences.defaultSignOff = true
                preferences.mergeCommonParentLanes = false
                preferences.renderGraphWithDiagonals = false
                store.save(preferences)
                #expect(AppSettingsStore(defaults: defaults).preferences == preferences)
            }
        }

        @Test("Browse display preferences") private static func testBrowseDisplayPreferences() {
            withStore { store, defaults in
                var value = store.browseDisplayPreferences
                #expect(value.commitTitle(changedFiles: 3) == "Commit (3)")
                #expect(value.branchCounts(ahead: 2, behind: 1) == " ↑2 ↓1")
                #expect(value.branchCounts(ahead: 0, behind: 0).isEmpty)
                value.showChangedFilesOnCommitButton = false
                value.showAheadBehind = false
                value.showArtificialRevisionCounts = false
                value.showSubmoduleStatus = true
                value.quickSearchTimeoutMilliseconds = 7500
                value.maximumRevisionCount = 250
                store.saveBrowseDisplayPreferences(value)
                let restored = AppSettingsStore(defaults: defaults).browseDisplayPreferences
                #expect(restored == value)
                #expect(restored.commitTitle(changedFiles: 3) == "Commit")
                #expect(restored.branchCounts(ahead: 2, behind: 1).isEmpty)
                let inherited = try! JSONDecoder().decode(BrowseDisplayPreferences.self, from: Data("{}".utf8))
                #expect(inherited == BrowseDisplayPreferences())
                let item = SubmoduleTreeItem(
                    repositoryURL: URL(fileURLWithPath: "/fixture/module"),
                    parentURL: URL(fileURLWithPath: "/fixture"), path: "module", localPath: "module",
                    isCurrent: false, isTop: false, isInitialized: true, branch: "main",
                    commitID: nil, recordedID: nil, commitState: .ahead, addedCommits: 2, removedCommits: 0)
                #expect(SubmoduleTreePresentation.menuTitle(item, showsStatus: false) == "module (main)")
                #expect(SubmoduleTreePresentation.menuTitle(item, showsStatus: true) == "module (main) (+2-0)")
            }
        }

        @Test("Histogram preference") private static func testHistogramPreference() {
            withStore { store, defaults in
                let legacy = try! JSONDecoder().decode(FileViewerPreferences.self, from: Data("{\"whitespace\":\"endOfLine\",\"contextLines\":7}".utf8))
                #expect(!legacy.usesHistogram && legacy.whitespace == .endOfLine && legacy.contextLines == 7)
                var value = legacy
                value.usesHistogram = true
                store.applyFileViewerPreferences(value)
                let restored = AppSettingsStore(defaults: defaults)
                #expect(restored.fileViewerPreferences.usesHistogram)
                #expect(restored.preferencesForNewFileViewer().usesHistogram)
                #expect(value.diffOptions.gitArguments == ["--histogram", "--ignore-space-at-eol", "--unified=7"])
            }
        }

        @Test("Repository creation preferences round trip") private static func testRepositoryCreationPreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.repositoryCreationPreferences
                preferences.cloneDestinationPath = "/tmp/Clones"
                preferences.cloneWindowWidth = 720
                store.saveRepositoryCreationPreferences(preferences)
                store.recordCloneSource("ssh://example.test/repository.git")
                store.recordCloneSource("ssh://example.test/repository.git")
                let restored = AppSettingsStore(defaults: defaults).repositoryCreationPreferences
                #expect(restored.cloneDestinationPath == "/tmp/Clones")
                #expect(restored.cloneWindowWidth == 720)
                #expect(AppSettingsStore(defaults: defaults).remoteRepositoryHistory == ["ssh://example.test/repository.git"])
                let cloned = URL(fileURLWithPath: "/tmp/Clones/repository", isDirectory: true)
                store.recordRecentRepository(cloned)
                #expect(store.recentRepositories.first?.path == cloned.path)
                #expect(store.lastRepositoryPath == nil)
            }
        }

        @Test("Reset preferences round trip") private static func testResetPreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.resetPreferences
                #expect(preferences.checkoutOtherBranchAfterReset)
                preferences.checkoutOtherBranchAfterReset = false
                store.saveResetPreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).resetPreferences == preferences)
            }
        }

        @Test("Reflog references preference round trip") private static func testReflogReferencesPreferenceRoundTrip() {
            withStore { store, defaults in

                #expect(!store.showReflogReferences)
                store.saveShowReflogReferences(true)
                #expect(store.showReflogReferences)
                #expect(!AppSettingsStore(defaults: defaults).showReflogReferences)
                store.revisionGridRuntime.sortOrder = .topology
                store.saveCurrentViewSettingsAsDefault()
                let reloaded = AppSettingsStore(defaults: defaults)
                #expect(reloaded.showReflogReferences)
                #expect(reloaded.revisionGridRuntime.sortOrder == .topology)
            }
        }

        @Test("Tag preferences round trip") private static func testTagPreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.tagPreferences
                preferences.showTagsInRevisionGrid = false
                preferences.showTagsInRepositoryTree = false
                store.saveTagPreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).tagPreferences == preferences)
            }
        }

        @Test("Remote management preferences round trip") private static func testRemoteManagementPreferencesRoundTrip() {
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
                #expect(reloaded.showAdvancedOptions)
                #expect(reloaded.windowWidth == 1_080 && reloaded.windowHeight == 620)
                #expect(AppSettingsStore(defaults: defaults).remoteRepositoryHistory == ["/tmp/repository with spaces"])
            }
        }

        @Test("Repository tree preferences round trip") private static func testRepositoryTreePreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.repositoryTreePreferences
                preferences.visibleRoots.remove(.submodules)
                preferences.rootOrder = [.tags, .branches, .remotes, .worktrees, .submodules, .stashes]
                preferences.sortBy = .creatorDate
                preferences.sortOrder = .descending
                store.saveRepositoryTreePreferences(preferences)
                let restored = AppSettingsStore(defaults: defaults).repositoryTreePreferences
                #expect(restored == preferences)
            }

            var malformed = RepositoryTreePreferences()
            malformed.rootOrder = [.branches, .branches]
            malformed.visibleRoots.insert(.tags)
            malformed.normalize()
            #expect(malformed.rootOrder == RepositoryTreeRoot.allCases)
        }

        @Test("Remote management selection restoration") private static func testRemoteManagementSelectionRestoration() {
            let remotes = [
                RepositoryRemoteConfiguration(
                    name: "origin", fetchURL: "/tmp/origin", pushURL: nil,
                    puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: false
                ),
                RepositoryRemoteConfiguration(
                    name: "upstream", fetchURL: "/tmp/upstream", pushURL: nil,
                    puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: true
                ),
            ]
            #expect(RemoteManagementSelectionResolver.preferredRemoteName(configurations: remotes, requested: "upstream") == "upstream")
            #expect(RemoteManagementSelectionResolver.preferredRemoteName(configurations: remotes, requested: "deleted") == "origin")

            let tracking = [
                RepositoryBranchTrackingConfiguration(branchName: "main", remoteName: "origin", mergeBranch: "main"),
                RepositoryBranchTrackingConfiguration(branchName: "topic", remoteName: nil, mergeBranch: nil),
            ]
            #expect(RemoteManagementSelectionResolver.preferredLocalBranch(configurations: tracking, requested: "topic") == "topic")
            #expect(RemoteManagementSelectionResolver.preferredLocalBranch(configurations: tracking, requested: "deleted") == "main")
        }

        @Test("Recent repositories") private static func testRecentRepositories() {
            withStore { store, _ in
                var settings = store.recentRepositorySettings
                settings.historySize = 10
                store.saveRecentRepositorySettings(settings)
                for index in 0..<11 { store.recordOpenedRepository(URL(fileURLWithPath: "/tmp/recent\(index)", isDirectory: true)) }
                let temporaryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
                store.recordOpenedRepository(temporaryURL)
                #expect(store.recentRepositories.count == 10 && store.recentRepositories.first?.path == temporaryURL.path)
                #expect(store.lastRepositoryPath == temporaryURL.path)
                store.removeRecentRepository(path: temporaryURL.path)
                #expect(store.recentRepositories.first?.path == "/tmp/recent10")
                store.clearRecentRepositories()
                #expect(store.recentRepositories.isEmpty)
            }
        }

        @Test("Pull preferences round trip") private static func testPullPreferencesRoundTrip() {
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
                #expect(AppSettingsStore(defaults: defaults).pullPreferences == preferences)

                store.recordPullURL("ssh://example/repository")
                #expect(store.remoteRepositoryHistory.first == "ssh://example/repository")
                #expect(store.remoteRepositoryHistory.filter { $0 == "ssh://example/repository" }.count == 1)
            }
        }

        @Test("Push preferences round trip") private static func testPushPreferencesRoundTrip() {
            let suite = "GitExtensionsMacTests.push.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                Issue.record("Could not create defaults")
                return
            }
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
            #expect(AppSettingsStore(defaults: defaults).pushPreferences == preferences)

            store.recordPushURL("ssh://example/push-repository")
            store.recordPushURL("ssh://example/push-repository")
            #expect(store.remoteRepositoryHistory.first == "ssh://example/push-repository")
            #expect(store.remoteRepositoryHistory.filter { $0 == "ssh://example/push-repository" }.count == 1)
        }

        @Test("Merge preferences round trip") private static func testMergePreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.mergePreferences
                preferences.noCommit = true
                preferences.noFastForward = true
                preferences.addLogMessages = true
                preferences.logMessagesCount = 37
                preferences.helpExpanded = false
                preferences.closeProcessOnSuccess = true
                store.saveMergePreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).mergePreferences == preferences)
            }
        }

        @Test("Checkout branch preferences round trip") private static func testCheckoutBranchPreferencesRoundTrip() {
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
                #expect(AppSettingsStore(defaults: defaults).checkoutBranchPreferences == preferences)
            }
        }

        @Test("Rebase preferences round trip") private static func testRebasePreferencesRoundTrip() {
            withStore { store, defaults in
                var preferences = store.rebasePreferences
                preferences.helpExpanded = false
                store.saveRebasePreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).rebasePreferences == preferences)
            }
        }

        @Test("Stash preferences round trip") private static func testStashPreferencesRoundTrip() {
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
                #expect(AppSettingsStore(defaults: defaults).stashPreferences == preferences)
            }
        }

        @Test("Cherry pick preferences round trip") private static func testCherryPickPreferencesRoundTrip() {
            withStore { store, defaults in
                let preferences = CherryPickPreferences(
                    automaticallyCommit: true,
                    addReference: true
                )
                store.saveCherryPickPreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).cherryPickPreferences == preferences)
            }
        }

        @Test("Commit preferences round trip") private static func testCommitPreferencesRoundTrip() {
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
                preferences.templates = [
                    CommitMessageTemplate(
                        name: "Issue",
                        text: "fix: {{issue-(\\d+)}}[1]",
                        expandsBranchRegularExpressions: true
                    )
                ]
                preferences.validation.maximumSubjectLength = 72
                preferences.validation.regularExpression = #"^(feat|fix):"#
                preferences.windowWidth = 1040
                store.saveCommitPreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).commitPreferences == preferences)
                store.saveSplitterSetting(SplitterSetting(distance: 420, size: 900), for: "CommitDialog.splitMain")
                #expect(AppSettingsStore(defaults: defaults).splitterSetting("CommitDialog.splitMain") == SplitterSetting(distance: 420, size: 900))
            }
        }

        @Test("File status list preferences round trip") private static func testFileStatusListPreferencesRoundTrip() {
            withStore { store, defaults in
                let preferences = FileStatusListPreferences(
                    grouping: .status,
                    isTreeMode: false,
                    usesDenseTree: false,
                    showsGroupNodesInFlatList: true,
                    showsUntrackedFiles: false
                )
                store.saveFileStatusListPreferences(preferences)
                #expect(AppSettingsStore(defaults: defaults).fileStatusListPreferences == preferences)
            }
        }

        @Test("Viewer runtime defaults") private static func testViewerRuntimeDefaults() {
            withStore { store, defaults in
                var baseline = store.fileViewerPreferences
                baseline.whitespace = .endOfLine
                store.saveFileViewerPreferences(baseline)
                var runtime = baseline
                runtime.whitespace = .all
                runtime.showsEntireFile = true
                runtime.contextLines = 15
                store.updateFileViewerPreferences(runtime)
                #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences == baseline)
                let next = store.preferencesForNewFileViewer()
                #expect(next.whitespace == .all && !next.showsEntireFile && next.contextLines == 3)
                var remember = store.fileViewerRemember
                remember.whitespace = false
                remember.entireFile = true
                remember.contextLines = true
                store.saveFileViewerRemember(remember)
                store.updateFileViewerPreferences(runtime)
                #expect(store.preferencesForNewFileViewer().whitespace == .endOfLine)
                #expect(store.preferencesForNewFileViewer().showsEntireFile)
                runtime.contextLines = 16
                store.updateFileViewerPreferences(runtime)
                #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences.contextLines == 16)
                #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences.whitespace == .endOfLine)
                store.saveFileViewerPreferences(runtime)
                #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences == runtime)
                #expect(AppSettingsStore(defaults: defaults).fileViewerRemember == remember)
            }
        }

        @Test("Fonts round trip") private static func testFontsRoundTrip() {
            withStore { store, defaults in
                #expect(store.fontPreferences.fonts.isEmpty)
                let original = store.codeFont
                var fonts = store.fontPreferences
                fonts.fonts[.code] = StoredApplicationFont(NSFont.monospacedSystemFont(ofSize: 18, weight: .regular))
                fonts.fonts[.commit] = StoredApplicationFont(NSFont.systemFont(ofSize: 15))
                fonts.fonts[.application] = StoredApplicationFont(NSFont.systemFont(ofSize: 22))
                fonts.showEolMarkerAsGlyph = true
                store.saveFontPreferences(fonts)
                let reloaded = AppSettingsStore(defaults: defaults)
                #expect(reloaded.fontPreferences == fonts)
                let legacyFontData = try! JSONSerialization.data(withJSONObject: ["fonts": []])
                #expect(!(try! JSONDecoder().decode(ApplicationFontPreferences.self, from: legacyFontData)).showEolMarkerAsGlyph)
                #expect(FileViewerWhitespace.text("a\r\nb\nc\r", glyph: false) == "a\\r\\n\r\nb\\n\nc\\r\r")
                #expect(FileViewerWhitespace.text("a\r\nb\n", glyph: true) == "a¶\r\nb¶\n")
                #expect(FileViewerWhitespace.text("a\t b", glyph: true) == "a→·b")
                #expect(reloaded.codeFont.pointSize == 18 && reloaded.commitFont.pointSize == 15)
                #expect(reloaded.diffLineHeight >= 21)
                #expect(reloaded.applicationFont(size: 11).pointSize == 22)
                #expect(reloaded.applicationRowHeight(minimum: 18) > 22)
                let lines = [DiffLine(id: "line", oldLineNumber: 999, newLineNumber: 1000, kind: .context, text: "text")]
                let standardGutter = DiffGutterMetrics(lines: lines)
                let customGutter = DiffGutterMetrics(lines: lines, font: reloaded.diffGutterFont)
                #expect(customGutter.numberColumnWidth > standardGutter.numberColumnWidth)
                store.saveFontPreferences(ApplicationFontPreferences())
                #expect(store.codeFont == original)
                #expect(AppSettingsStore(defaults: defaults).fontPreferences.fonts.isEmpty)
                let japanese = RepositoryTextEncoding(ianaName: "shift_jis")!
                store.includedTextEncodings = [japanese]
                let encodings = AppSettingsStore(defaults: defaults).includedTextEncodings
                #expect(encodings.contains(japanese) && encodings.contains(.utf8))
                #expect(store.viewerEncodings(including: .windows1252).contains(.windows1252))
            }
        }

        @Test("Colors") private static func testColors() {
            do {
                let bundled = TestResources.themes
                let normal = try ApplicationThemeReader.load("invariant.css", colorblind: false, bundled: bundled)
                let accessible = try ApplicationThemeReader.load("invariant.css", colorblind: true, bundled: bundled)
                #expect(normal["RemoteBranch"] == 0x8B0009)
                #expect(accessible["RemoteBranch"] == 0x0600A8)
                #expect(normal["GraphBranch8"] == -1)
                let dark = try ApplicationThemeReader.load("dark+.css", colorblind: false, bundled: bundled)
                #expect(dark["GraphBranch1"] == 0xDB5B93)
                #expect(ApplicationThemeReader.parseColor("#abc") == 0xAABBCC)
                #expect(ApplicationThemeReader.parseColor("LightGoldenRodYellow") == 0xFAFAD2)
                #expect(ApplicationThemeReader.parseColor("rebeccapurple") == 0x663399)
                #expect(ApplicationThemeReader.parseColor("darkslategrey") == 0x2F4F4F)
                #expect(ApplicationThemeReader.parseColor("rgb(12, 34, 56)") == 0x0C2238)
                #expect(ApplicationThemeReader.parseColor("not a color") == nil)
                #expect(ApplicationThemeReader.parseColor("#-12345") == nil)
                #expect(ApplicationThemeReader.parseColor("rgb(12, bad, 34, 56)") == nil)
                #expect(ApplicationThemeReader.parseColor("rgb(12,,34)") == nil)
                #expect(ApplicationThemeReader.parseColor("rgb(100%, 0%, 50%)") == 0xFF0080)
                #expect(ApplicationThemeReader.parseColor("hsl(120, 100%, 50%)") == 0x00FF00)
                #expect(ApplicationThemeReader.parseColor("hsl(-120, 100%, 50%)") == 0x0000FF)
                #expect(ApplicationThemeReader.parseColor("hsl(nan, 100%, 50%)") == nil)
                withStore { _, defaults in
                    let store = AppSettingsStore(
                        defaults: defaults, bundledThemes: bundled, themeFailureReporter: { _ in Issue.record("Unexpected theme failure") })
                    var colors = store.colorPreferences
                    colors.themeFile = "dark.css"
                    colors.colorblind = true
                    colors.multicolorBranches = false
                    store.colorPreferences = colors
                    #expect(
                        AppSettingsStore(
                            defaults: defaults, bundledThemes: bundled, themeFailureReporter: { _ in Issue.record("Unexpected theme reload failure") }
                        ).colorPreferences == colors)
                }
            } catch { Issue.record("Theme fixture failed: \(error)") }
        }

        @Test("Shared viewer search") private static func testSharedViewerSearch() {
            let lines = ["first match", "middle", "last MATCH"].enumerated().map { index, text in
                DiffLine(id: String(index), oldLineNumber: index + 1, newLineNumber: index + 1, kind: .context, text: text)
            }
            #expect(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 0) == 2)
            #expect(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 2, forward: false) == 0)
            #expect(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 0, forward: false) == 2)
            #expect(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: -1, forward: false) == 2)
            #expect(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 2) == 0)
            #expect(FileViewerNavigationDialogs.matchingRow(lines: [], query: "match", after: 0) == nil)
            #expect(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "absent", after: 0) == nil)
        }

        @Test("Hotkeys") private static func testHotkeys() {
            withStore { store, defaults in
                let original = ApplicationHotkeys.chord("refresh", overrides: [:])
                #expect(original == ApplicationKeyChord("r", .command))
                store.hotkeyOverrides = ["refresh": .init("r", [.command, .shift]), "commit": .init("")]
                let saved = AppSettingsStore(defaults: defaults).hotkeyOverrides
                #expect(ApplicationHotkeys.chord("refresh", overrides: saved).title == "⇧⌘R")
                #expect(ApplicationHotkeys.chord("commit", overrides: saved).swiftUI == nil)
                #expect(ApplicationHotkeys.chord("createBranch", overrides: saved) == .init("b", .control))
                store.hotkeyOverrides = [:]
                #expect(ApplicationHotkeys.chord("refresh", overrides: store.hotkeyOverrides) == original)
                #expect(Set(ApplicationHotkeys.definitions.map(\.id)).count == ApplicationHotkeys.definitions.count)
                #expect(ApplicationHotkeys.matching(.init("n", .command), category: "Stash", overrides: [:]) == "stash.next")
                #expect(ApplicationHotkeys.matching(.init("3", .command), category: "Conflict resolver", overrides: [:]) == "conflict.base")
                let overrides: [String: ApplicationKeyChord] = ["conflict.base": .init("4", .command), "stash.next": .init("")]
                #expect(ApplicationHotkeys.matching(.init("3", .command), category: "Conflict resolver", overrides: overrides) == nil)
                #expect(ApplicationHotkeys.matching(.init("4", .command), category: "Conflict resolver", overrides: overrides) == "conflict.base")
                #expect(ApplicationHotkeys.matching(.init("n", .command), category: "Stash", overrides: overrides) == nil)
                #expect(ApplicationHotkeys.matching(.init("b"), category: "Stash", overrides: [:]) == nil)
                #expect(ApplicationHotkeys.matching(.init("\u{f705}"), category: "Repository tree", overrides: [:]) == "tree.rename")
                #expect(ApplicationHotkeys.matching(.init("\u{7f}"), category: "Repository tree", overrides: ["tree.delete": .init("")]) == nil)
                #expect(ApplicationHotkeys.matching(.init("\u{f703}", .option), category: "Commit", overrides: [:]) == "commit.nextFile.alternative")
                #expect(
                    ApplicationHotkeys.matching(.init("\u{f703}", .option), category: "Commit", overrides: ["commit.nextFile.alternative": .init("")]) == nil)
                #expect(ApplicationHotkeys.matching(.init("s"), category: "File status list", overrides: [:]) == "file.stage")
            }
        }

        @Test("Revision links") private static func testRevisionLinks() {
            var definition = RevisionLinkDefinition()
            definition.name = "Issues & reviews"
            definition.searchPattern = "issue (#[0-9]+,? ?)+"
            definition.nestedSearchPattern = "#([0-9]+)"
            definition.remoteSearchPattern = "https://([^/]+)/(.+)"
            definition.formats = [.init(caption: "Issue {2}", format: "https://{0}/{1}/issues/{2}?commit=%COMMIT_HASH%")]
            let xml = RevisionLinkDefinition.encode([definition])
            #expect(try! RevisionLinkDefinition.decode(xml) == [definition])
            let id = try! ObjectID(parsing: String(repeating: "a", count: 40))
            let links = definition.links(
                commitID: id, message: "Fix issue #12, #34", localRefs: [], remoteRefs: [],
                remotes: [
                    .init(name: "origin", url: "https://example.org/fork", pushURL: ""),
                    .init(name: "upstream", url: "https://example.org/project", pushURL: ""),
                ])
            #expect(links.map(\.caption) == ["Issue 12", "Issue 34"])
            #expect(links[0].destination == "https://example.org/project/issues/12?commit=\(id.string)")
            #expect(RevisionLinkDefinition.format("{{{0}}}", groups: ["value"]) == "{value}")
            #expect(RevisionLinkDefinition.format("[{0,7}] [{0,-7}]", groups: ["value"]) == "[  value] [value  ]")
            #expect(RevisionLinkDefinition.format("{0:ignored}", groups: ["value"]) == "value")
            #expect(RevisionLinkDefinition.format("{0,invalid}", groups: ["value"]) == nil)
            #expect(RevisionLinkDefinition.format("{3}", groups: []) == nil)
            definition.searchPattern = "["
            #expect(definition.links(commitID: id, message: "anything", localRefs: [], remoteRefs: [], remotes: []).isEmpty)
            withStore { store, defaults in
                store.revisionLinksXML = xml
                #expect(AppSettingsStore(defaults: defaults).revisionLinksXML == xml)
                store.revisionLinksXML = nil
                #expect(AppSettingsStore(defaults: defaults).revisionLinksXML == nil)
            }
        }

        @Test("Distributed settings") private static func testDistributedSettings() {
            #expect(DistributedSettings.normalizedMergeLogCount(" 0 ") == "0")
            #expect(DistributedSettings.normalizedMergeLogCount("-2") == "-2")
            #expect(DistributedSettings.normalizedMergeLogCount("invalid") == nil)
            #expect(DistributedSettings.normalizedMergeLogCount("2147483648") == nil)
            withStore { store, _ in
                do {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-SettingsXML-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let settings = DistributedSettings(
                        localURL: root.appendingPathComponent("local.settings"), distributedURL: root.appendingPathComponent("distributed.settings"))
                    let key = DistributedSettings.mergeLog
                    try DistributedSettings.write([key: "true", "unrelated": "Unicode é & <value>\nline"], to: settings.distributedURL)
                    try #require(try settings.mergePreferences(store).addLogMessages)
                    try DistributedSettings.write([key: "false"], to: settings.localURL)
                    try #require(try !settings.mergePreferences(store).addLogMessages)
                    try DistributedSettings.write([key: nil], to: settings.localURL)
                    try #require(try settings.mergePreferences(store).addLogMessages)
                    var preferences = try settings.mergePreferences(store)
                    preferences.addLogMessages = false
                    preferences.logMessagesCount = 42
                    try settings.saveMergeLog(preferences, store: store)
                    try #require(try DistributedSettings.read(settings.localURL)[key] == "false")
                    try #require(try DistributedSettings.read(settings.distributedURL)[key] == "true")
                    #expect(store.mergePreferences.logMessagesCount == 42)
                    try #require(try DistributedSettings.read(settings.distributedURL)["unrelated"] == "Unicode é & <value>\nline")
                    try Data("<not-a-dictionary/>".utf8).write(to: settings.localURL)
                    var rejected = false
                    do { try DistributedSettings.write([key: "true"], to: settings.localURL) } catch { rejected = true }
                    #expect(rejected)
                    try #require(try String(contentsOf: settings.localURL, encoding: .utf8) == "<not-a-dictionary/>")
                } catch { Issue.record("Distributed settings test failed: \(error)") }
            }
            withStore { _, defaults in
                var legacy = MergePreferences()
                legacy.addLogMessages = true
                legacy.logMessagesCount = 73
                defaults.set(try! JSONEncoder().encode(legacy), forKey: "GitExtensionsMac.mergePreferences.v1")
                defaults.removeObject(forKey: "GitExtensionsMac.detailedSettings.unset.v1")
                let migrated = AppSettingsStore(defaults: defaults)
                #expect(DistributedSettings.globalValues(migrated)[DistributedSettings.mergeLog] == "true")
                #expect(DistributedSettings.globalValues(migrated)[DistributedSettings.mergeLogCount] == "73")
            }
        }

        @Test("File viewer preferences round trip") private static func testFileViewerPreferencesRoundTrip() {
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
                #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences == preferences)
                var application = store.preferences
                application.reopenLastRepository.toggle()
                store.save(application)
                #expect(store.fileViewerPreferences == preferences, "Unrelated app settings must not collapse detailed whitespace modes")
                #expect(AppSettingsStore(defaults: defaults).fileViewerPreferences == preferences, "Detailed viewer defaults survive relaunch")
            }
        }

        @Test("Commit message rules") private static func testCommitMessageRules() {
            var validation = CommitValidationPreferences()
            validation.maximumSubjectLength = 8
            validation.maximumLineLength = 12
            validation.requireEmptySecondLine = true
            validation.regularExpression = #"^(feat|fix):"#
            let issues = CommitMessageValidator.issues(
                in: "not a valid subject\nbody without separator\ntail",
                preferences: validation
            )
            #expect(issues.contains(.subjectTooLong(actual: 19, maximum: 8)))
            #expect(issues.contains(.lineTooLong(line: 1, actual: 19, maximum: 12)))
            #expect(issues.contains(.lineTooLong(line: 2, actual: 22, maximum: 12)))
            #expect(issues.contains(.secondLineMustBeEmpty))
            #expect(issues.contains(.regularExpressionMismatch(#"^(feat|fix):"#)))

            validation.regularExpression = "["
            #expect(!CommitMessageValidator.issues(in: "feat: valid", preferences: validation).contains(.invalidRegularExpression("[")))
            #expect(
                CommitTemplateExpander.expand(
                    "fix: {{issue-(\\d+)}}[1]",
                    forBranch: "issue-428-polish",
                    enabled: true
                ) == "fix: 428")
            #expect(CommitTemplateExpander.expand("{{missing-(\\d+)}}[1]", forBranch: "main", enabled: true).isEmpty)

            var formatting = CommitValidationPreferences()
            formatting.maximumLineLength = 12
            formatting.requireEmptySecondLine = true
            formatting.indentAfterFirstLine = true
            formatting.autoWrap = true
            #expect(
                CommitMessageAutoFormatter.format(
                    "Subject\nbody words that wrap",
                    preferences: formatting
                ) == "Subject\n\n - body\nwords that\nwrap")
        }

        private static func withStore(_ body: (AppSettingsStore, UserDefaults) -> Void) {
            let suite = "GitExtensionsMac.AppSettingsTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                Issue.record("Could not create defaults suite")
                return
            }
            defaults.removePersistentDomain(forName: suite)
            body(AppSettingsStore(defaults: defaults), defaults)
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

typealias AppSettingsTests = UIIntegrationTests.AppSettingsTests
