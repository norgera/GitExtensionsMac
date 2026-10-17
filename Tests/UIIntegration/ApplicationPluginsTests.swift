import AppKit
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Application plugins")
    enum ApplicationPluginsTests {
        private final class Fixture: NSObject, GitExtensionPlugin {
            var identifier = UUID()
            var name = "Fixture"
            var pluginDescription = "Fixture settings"
            var registrations = 0
            var unregistrations = 0
            var failRegistration = false
            override required init() { super.init() }
            func register(with host: GitExtensionPluginHost) throws {
                if failRegistration { throw PluginError.invalid("Fixture registration failure") }
                registrations += 1
            }
            func unregister(from host: GitExtensionPluginHost) { unregistrations += 1 }
            func execute(in host: GitExtensionPluginHost) async throws -> Bool { true }
        }

        private static func integerSettingsControls() throws {
            let settings =
                BuiltInPlugins.make().filter { $0.kind == .backgroundFetch || $0.kind == .deleteBranches }
                .flatMap(\.settings).filter {
                    if case .number = $0.kind { return true }
                    return false
                }
                + GitHubRepositoryPlugin().settings.filter {
                    if case .number = $0.kind { return true }
                    return false
                }
            #expect(settings.count == 3)
            var saved: [String: String] = [:]
            var writes = 0
            let host = GitExtensionPluginHost(
                refresh: {}, navigate: { _ in },
                readSetting: { name, _ in saved[name] },
                writeSetting: { name, value, scope in
                    #expect(scope == .global)
                    saved[name] = value
                    writes += 1
                })
            host.update(context: ["WorkingDir": ["/fixture"]], owner: nil)
            let controller = PluginSettingsViewController(settings: settings, host: host)
            _ = controller.view
            #expect(controller.fields.map { $0.1.stringValue } == settings.map(\.defaultValue), "effective integer defaults")
            for (_, control) in controller.fields {
                let number = control as! PluginIntegerControl
                let accessible = number.accessibilityChildren()!
                #expect(
                    !number.isAccessibilityElement() && accessible.count == 2 && accessible[0] is NSTextFieldCell && accessible[1] is NSStepperCell,
                    "native integer entry and incrementor proxies are separately accessible")
                #expect(!number.isEnabled && !number.field.isEnabled && !number.stepper.isEnabled, "effective scope is read-only")
                #expect(
                    number.stepper.minValue == 0 && number.stepper.maxValue == Double(Int32.max) && !number.stepper.valueWraps,
                    "pinned integer numeric binding range and no wrap")
            }
            controller.scope.selectItem(withTitle: "global")
            NSApp.sendAction(controller.scope.action!, to: controller.scope.target, from: controller.scope)
            for (index, pair) in controller.fields.enumerated() {
                let number = pair.1 as! PluginIntegerControl
                #expect(number.stringValue.isEmpty && number.field.isEnabled && number.stepper.isEnabled, "unset explicit integer remains blank")
                number.stringValue = String(index + 40)
                #expect(number.stepper.integerValue == index + 40, "typed integer updates increment base")
                number.stepper.integerValue += 1
                NSApp.sendAction(number.stepper.action!, to: number.stepper.target, from: number.stepper)
                #expect(number.stringValue == String(index + 41), "increment updates saved field")
                number.stepper.integerValue -= 1
                NSApp.sendAction(number.stepper.action!, to: number.stepper.target, from: number.stepper)
                #expect(number.stringValue == String(index + 40), "decrement updates saved field")
                let formatter = number.field.formatter as! NumberFormatter
                #expect(!formatter.allowsFloats && formatter.minimum?.intValue == 0 && formatter.maximum?.intValue == Int(Int32.max))
            }
            NSApp.sendAction(controller.apply.action!, to: controller.apply.target, from: controller.apply)
            #expect(
                writes == 3 && settings.enumerated().allSatisfy { saved[$0.element.name] == String($0.offset + 40) },
                "existing shared persistence consumes stepped integer values")
            NSApp.sendAction(controller.reset.action!, to: controller.reset.target, from: controller.reset)
            #expect(
                controller.fields.allSatisfy { !$0.1.isEnabled && !($0.1 as! PluginIntegerControl).stepper.isEnabled },
                "reset disables field and stepper together")
            NSApp.sendAction(controller.apply.action!, to: controller.apply.target, from: controller.apply)
            #expect(saved.isEmpty, "reset persists inherited/unset semantics")
            let cancelled = PluginSettingsViewController(settings: settings, host: host)
            let panel = NSPanel(contentViewController: cancelled)
            cancelled.scope.selectItem(withTitle: "global")
            NSApp.sendAction(cancelled.scope.action!, to: cancelled.scope.target, from: cancelled.scope)
            cancelled.fields[0].1.stringValue = "99"
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let cancel = descendants(cancelled.view).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
            NSApp.sendAction(cancel.action!, to: cancel.target, from: cancel)
            #expect(saved.isEmpty && !panel.isVisible, "Cancel does not persist edited integers")
        }

        static func sharedSettingsPages() async throws {
            func checkpoint(_ value: String) { FileHandle.standardError.write(Data(("SharedPluginSettingsTests: " + value + "\n").utf8)) }
            checkpoint("start")
            let suite = "GitExtensionsMac.SharedPluginPages.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedPluginPages-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let remembered = SettingsViewController.lastSelectedPage
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
                SettingsViewController.lastSelectedPage = remembered
            }
            let locations = DistributedSettings(localURL: root.appendingPathComponent("local.xml"), distributedURL: root.appendingPathComponent("shared.xml"))
            let plugins: [any GitExtensionPlugin] = [BackgroundFetchPlugin(), DeleteUnusedBranchesPlugin(), GitHubRepositoryPlugin(), Fixture()]
            var changes = 0
            let entries = plugins.map { plugin in
                let storage = ApplicationPluginSettings(
                    identifier: plugin.identifier, legacyName: plugin.pluginDescription, locations: locations, defaults: defaults)
                let host = GitExtensionPluginHost(
                    refresh: {}, navigate: { _ in },
                    readSetting: { name, scope in
                        try storage.value(name, scope: DistributedSettingsScope(rawValue: scope.rawValue)!)
                    },
                    writeSetting: { name, value, scope in
                        try storage.set(name, value: value, scope: DistributedSettingsScope(rawValue: scope.rawValue)!)
                    }, settingsChanged: { changes += 1 })
                host.update(context: ["WorkingDir": [root.path]], owner: nil)
                return (plugin, host)
            }
            let pages = PluginSettingsPageEntry.pages(entries)
            #expect(
                pages.count == 3
                    && pages.map { $0.plugin.name } == plugins.prefix(3).map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                "only plugins with declared settings, in source case-insensitive order")
            let store = AppSettingsStore(defaults: defaults)
            func make() -> (SettingsViewController, NSPanel) {
                let controller = SettingsViewController(store: store, source: nil, initialPage: pages[0].id, pluginPages: pages, repositoryChanged: {})
                let panel = NSPanel(contentViewController: controller)
                panel.setContentSize(NSSize(width: 1040, height: 720))
                controller.panel = panel
                panel.makeKeyAndOrderFront(nil)
                return (controller, panel)
            }
            func editor(_ controller: SettingsViewController) -> PluginSettingsViewController {
                controller.children.compactMap { $0 as? PluginSettingsViewController }.first { $0.view.superview != nil }!
            }
            func scope(_ editor: PluginSettingsViewController, _ title: String) {
                editor.scope.selectItem(withTitle: title)
                NSApp.sendAction(editor.scope.action!, to: editor.scope.target, from: editor.scope)
            }
            func button(_ controller: SettingsViewController, _ title: String) -> NSButton {
                RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSButton }.first { $0.title == title }!
            }
            checkpoint("open initial page")
            let (controller, panel) = make()
            defer { panel.close() }
            #expect(Array(controller.categoryIDs.suffix(4)) == ["plugins"] + pages.map(\.id), "simultaneous direct plugin subpages in shared tree")
            let first = editor(controller)
            #expect(first.scope.titleOfSelectedItem == "effective" && first.fields.allSatisfy { !$0.1.isEnabled }, "effective read-only initial state")
            #expect(
                RepositoryWorkflowTests.settingsViews(controller).compactMap { $0 as? NSButton }.filter { $0.title == "Apply" }.count == 1,
                "plugin pages share root Apply/OK/Cancel")
            controller.searchSettings("Maximum number of issues")
            #expect(
                controller.searchMatches.contains(pages.first { $0.plugin is GitHubRepositoryPlugin }!.id),
                "plugin captions participate in shared Settings search")
            scope(first, "global")
            let number = first.fields.first {
                if case .number = $0.0.kind { return true }
                return false
            }!
            number.1.stringValue = "123"
            controller.goToCategory(pages[1].id)
            let credentialPage = editor(controller)
            let credential = credentialPage.children.compactMap { $0 as? GitHubAccountSettingsController }.first!
            let outerStack = credentialPage.view as! NSStackView
            #expect(
                outerStack.arrangedSubviews.firstIndex(of: credentialPage.scope)! < outerStack.arrangedSubviews.firstIndex(of: credential.view)!,
                "source header precedes credential controls inside the same plugin page")
            scope(credentialPage, "distributed")
            let secondField = editor(controller).fields.first {
                if case .number = $0.0.kind { return true }
                return false
            }!
            secondField.1.stringValue = "456"
            controller.goToCategory(pages[0].id)
            #expect(
                editor(controller) === first && first.fields.first { $0.0.name == number.0.name }!.1.stringValue == "123",
                "switching pages preserves the same editor and draft")
            let initial1 = try pages[0].host.setting(number.0.name, scope: .global)
            let initial2 = try pages[1].host.setting(secondField.0.name, scope: .distributed)
            #expect(initial1 == nil && initial2 == nil, "page/scope navigation does not write")
            scope(first, "effective")
            scope(first, "global")
            #expect(first.fields.first { $0.0.name == number.0.name }!.1.stringValue == "123", "read-only effective scope does not overwrite explicit draft")
            first.fields.first { $0.0.name == number.0.name }!.1.stringValue = "not a number"
            do {
                try first.validateDrafts()
                Issue.record("Invalid plugin draft accepted")
            } catch PluginError.invalid {}
            first.fields.first { $0.0.name == number.0.name }!.1.stringValue = "123"
            checkpoint("apply all pages")
            RepositoryWorkflowTests.click(button(controller, "Apply"))
            try await RepositoryWorkflowTests.waitUntil("shared plugin pages Apply") { changes == 2 }
            let value1 = try pages[0].host.setting(number.0.name, scope: .global)
            let value2 = try pages[1].host.setting(secondField.0.name, scope: .distributed)
            #expect(value1 == "123" && value2 == "456", "root Apply saves all visited pages across scopes through existing persistence")
            first.fields.first { $0.0.name == number.0.name }!.1.stringValue = "789"
            controller.goToCategory(pages[1].id)
            editor(controller).fields.first { $0.0.name == secondField.0.name }!.1.stringValue = "999"
            var response: NSApplication.ModalResponse?
            controller.onClose = { response = $0 }
            RepositoryWorkflowTests.click(button(controller, "Cancel"))
            #expect(response == .cancel)
            let unchanged1 = try pages[0].host.setting(number.0.name, scope: .global)
            let unchanged2 = try pages[1].host.setting(secondField.0.name, scope: .distributed)
            #expect(unchanged1 == "123" && unchanged2 == "456", "Cancel discards edits on multiple pages and preserves last Apply")
            panel.close()
            checkpoint("reopen after Cancel")
            let (reopened, secondPanel) = make()
            defer { secondPanel.close() }
            scope(editor(reopened), "global")
            #expect(editor(reopened).fields.first { $0.0.name == number.0.name }!.1.stringValue == "123", "reopened page restores saved scoped settings")
            editor(reopened).fields.first { $0.0.name == number.0.name }!.1.stringValue = "321"
            reopened.onClose = { response = $0 }
            checkpoint("accept with OK")
            RepositoryWorkflowTests.click(button(reopened, "OK"))
            try await RepositoryWorkflowTests.waitUntil("shared plugin pages OK") { response == .OK }
            let accepted = try pages[0].host.setting(number.0.name, scope: .global)
            #expect(accepted == "321")
            checkpoint("global pages")
            let global = GitUICommands.globalPluginSettingsPages(owner: nil)
            #expect(
                global.contains { $0.plugin is GitHubRepositoryPlugin } && global.contains { $0.plugin is BackgroundFetchPlugin },
                "Settings without a repository still exposes plugin declarations")
            let page = global.first { $0.plugin is BackgroundFetchPlugin }!
            let standalone = PluginSettingsViewController(settings: page.plugin.settings, host: page.host, embedded: true)
            _ = standalone.view
            #expect(standalone.scope.itemTitles == ["global"], "no-repository plugin pages offer global scope only")
        }

        @Test("Scenarios") static func run() async throws {
            try await sharedSettingsPages()
            try integerSettingsControls()
            #expect(ApplicationPluginRegistry.scriptPluginName("{plugin:Fixture}") == "Fixture")
            #expect(ApplicationPluginRegistry.scriptPluginName("{plugin=Fixture}") == "Fixture")
            #expect(ApplicationPluginRegistry.scriptPluginName("plugin:Fixture") == "Fixture")
            #expect(ApplicationPluginRegistry.scriptPluginName("/usr/bin/git") == nil)
            #expect(GitExtensionPluginSetting.textValue(" \n") == nil)
            #expect(GitExtensionPluginSetting.textValue("<empty string>") == "")
            #expect(GitExtensionPluginSetting.textValue(" value λ ") == "value λ")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginsTests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                if ProcessInfo.processInfo.environment["PLUGINS_TEST_KEEP_FIXTURE"] == "1" {
                    print("Plugin fixture: \(root.path)")
                } else {
                    try? FileManager.default.removeItem(at: root)
                }
            }
            for path in [
                "GitExtensions.Root.bundle", "group/GitExtensions.Child.bundle",
                "group/deeper/GitExtensions.TooDeep.bundle", "Ignored.bundle",
            ] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            let candidates = try ApplicationPluginRegistry.candidates(in: [root, root])
            #expect(candidates.count == 2)
            let registry = ApplicationPluginRegistry()
            registry.load(directories: [root])
            #expect(registry.entries.isEmpty && registry.failures.count == 2)
            registry.load(directories: [root])
            #expect(registry.failures.count == 2)
            let first = Fixture()
            try registry.add(first)
            let duplicate = Fixture()
            duplicate.identifier = first.identifier
            do {
                try registry.add(duplicate)
                Issue.record("Duplicate ID accepted")
            } catch PluginError.invalid {}

            let suite = "GitExtensionsMac.PluginsTests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let locations = DistributedSettings(
                localURL: root.appendingPathComponent("local.xml"),
                distributedURL: root.appendingPathComponent("shared.xml"))
            let settings = ApplicationPluginSettings(
                identifier: first.identifier, legacyName: "OldFixture",
                locations: locations, defaults: defaults)
            defaults.set(["OldFixturecolor": "legacy"], forKey: "GitExtensionsMac.plugins.settings.v1")
            let legacy = try settings.value("color")
            #expect(legacy == "legacy")
            try settings.set("color", value: "global")
            try settings.set("color", value: "shared", scope: .distributed)
            try settings.set("color", value: "local", scope: .local)
            let effective = try settings.value("color")
            #expect(effective == "local")
            let global = try settings.value("color", scope: .global)
            #expect(global == "global")
            try settings.set("color", value: nil, scope: .local)
            let inherited = try settings.value("color")
            #expect(inherited == "shared")
            try settings.set("color", value: "effective edit", scope: .effective)
            let localOverride = try settings.value("color", scope: .local)
            #expect(localOverride == "effective edit")
            let sharedUnchanged = try settings.value("color", scope: .distributed)
            #expect(sharedUnchanged == "shared")
            try settings.set("new", value: "global fallback", scope: .effective)
            let globalFallback = try settings.value("new", scope: .global)
            #expect(globalFallback == "global fallback")
            let other = ApplicationPluginSettings(identifier: UUID(), legacyName: "Other", locations: locations, defaults: defaults)
            let absent = try other.value("color")
            #expect(absent == nil)
            let number = GitExtensionPluginSetting(name: "count", caption: "Count", defaultValue: "2", kind: .number(minimum: 1, maximum: 10))
            try number.validate("3")
            do {
                try number.validate("11")
                Issue.record("Unexpected success")
            } catch PluginError.invalid {}
            let choice = GitExtensionPluginSetting(name: "mode", caption: "Mode", defaultValue: "one", kind: .choice(["one", "two"]))
            try choice.validate("two")
            do {
                try choice.validate("three")
                Issue.record("Unexpected success")
            } catch PluginError.invalid {}
            defaults.set(["invalid": 12], forKey: "GitExtensionsMac.plugins.settings.v1")
            do {
                try settings.set("color", value: "overwrite")
                Issue.record("Unexpected success")
            } catch PluginError.invalid {}
            #expect((defaults.dictionary(forKey: "GitExtensionsMac.plugins.settings.v1")?["invalid"] as? Int) == 12)
            defaults.removeObject(forKey: "GitExtensionsMac.plugins.settings.v1")

            var refreshes = 0
            var selected = ""
            let host = GitExtensionPluginHost(
                refresh: { refreshes += 1 }, navigate: { selected = $0 },
                readSetting: { name, scope in try settings.value(name, scope: DistributedSettingsScope(rawValue: scope.rawValue)!) },
                writeSetting: { name, value, scope in try settings.set(name, value: value, scope: DistributedSettingsScope(rawValue: scope.rawValue)!) })
            host.update(context: ["WorkingDir": [root.path]], owner: nil)
            let selection: [RevisionID] = [.workingDirectory, .index, .object(testObjectID("plugin-selection"))]
            host.updateSelection(selection)
            #expect(host.selectedRevisions == selection && host.selectedRevisions[0].objectID == nil)
            #expect(host.context["WorkingDir"] == [root.path])
            host.requestRepositoryRefresh()
            #expect(refreshes == 1)
            let notifier = RepositoryChangedNotifier { refreshes += 1 }
            notifier.lock()
            notifier.notify()
            notifier.notify()
            #expect(refreshes == 1)
            notifier.unlock(requestNotify: false)
            #expect(refreshes == 2, "Compound plugin refresh requests must coalesce")
            try await host.selectRevision("HEAD~2")
            #expect(selected == "HEAD~2")
            var events: [Int] = []
            host.observe("PreCommit") { _ in
                events.append(1)
                return true
            }
            let veto = host.observe("PreCommit") { _ in
                events.append(2)
                return false
            }
            host.observe("PreCommit") { _ in
                events.append(3)
                return true
            }
            let allowed = try host.dispatch("PreCommit")
            #expect(!allowed && events == [1, 2])
            host.removeObserver(veto)
            events = []
            let continued = try host.dispatch("PreCommit")
            #expect(continued && events == [1, 3])
            let session = ApplicationPluginSession()
            session.register(first, host: host)
            session.register(first, host: host)
            #expect(first.registrations == 1)
            let failing = Fixture()
            failing.failRegistration = true
            session.register(failing, host: host)
            #expect(session.failures.count == 1 && failing.unregistrations == 1)
            session.close()
            session.close()
            #expect(first.unregistrations == 1)
            events = []
            _ = try host.dispatch("PreCommit")
            #expect(events.isEmpty, "Closed sessions must release event handlers and their captured context")
            let products = Bundle(for: GitUICommands.self).bundleURL.deletingLastPathComponent()
            let bundle = root.appendingPathComponent("GitExtensions.Loadable.bundle")
            let contents = bundle.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/Loadable")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = root.appendingPathComponent("Loadable.swift")
            try """
            import AppKit
            import GitUI
            @MainActor final class LoadablePlugin: NSObject, GitExtensionPlugin {
                override required init() { super.init() }
                let identifier = UUID(uuidString: "960AEF06-304C-45A4-9263-BA6F13B9C942")!
                let name = "Loadable fixture"
                let pluginDescription = "Disposable native plugin"
                var settings: [GitExtensionPluginSetting] { [
                    .init(name: "greeting", caption: "Greeting", defaultValue: "Hello"),
                    .init(name: "enabled", caption: "Enabled", defaultValue: "true", kind: .boolean),
                    .init(name: "mode", caption: "Mode", defaultValue: "one", kind: .choice(["one", "two"])),
                    .init(name: "count", caption: "Count", defaultValue: "2", kind: .number(minimum: 1, maximum: 10))
                ] }
                func register(with host: GitExtensionPluginHost) throws {
                    host.observe("PreCommit") { _ in
                        try host.setSetting("lastEvent", value: "PreCommit")
                        return try host.setting("blockCommit") != "true"
                    }
                    host.observe("PostRepositoryChanged") { _ in
                        try host.setSetting("lastEvent", value: "PostRepositoryChanged"); return true
                    }
                }
                func unregister(from host: GitExtensionPluginHost) {
                    try? host.setSetting("lastEvent", value: "Unregister")
                }
                func execute(in host: GitExtensionPluginHost) async throws -> Bool {
                    try host.setSetting("executed", value: "yes")
                    return true
                }
            }
            """.write(to: source, atomically: true, encoding: .utf8)
            let plist: [String: Any] = [
                "CFBundleExecutable": "Loadable", "CFBundlePackageType": "BNDL",
                "CFBundleIdentifier": "org.example.GitExtensions.PluginFixture", "CFBundleVersion": "1",
                "NSPrincipalClass": "PluginFixture.LoadablePlugin", "GitExtensionsPluginAPIVersion": 1,
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let compiler = FixtureProcess()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = [
                "swiftc", "-emit-library", "-module-cache-path", root.appendingPathComponent("ModuleCache").path,
                "-module-name", "PluginFixture", "-F", products.path,
                "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "GitUI",
                "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "GitCommands",
                "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "GitExtensionsCore",
                "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                source.path, "-o", executable.path,
            ]
            try compiler.run()
            compiler.waitUntilExit()
            #expect(compiler.terminationStatus == 0, "Public plugin SDK fixture did not compile")
            let loadable = ApplicationPluginRegistry()
            loadable.load(directories: [root])
            guard let instance = loadable.entries.first?.plugin else {
                throw TestFailure(description: "Native bundle did not load: \(loadable.failures)")
            }
            #expect(instance.name == "Loadable fixture")
            let refresh = try await instance.execute(in: host)
            #expect(refresh)
            let executed = try settings.value("executed")
            #expect(executed == "yes")
            let repository = root.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let git = GitProcess()
            let initialized = try await git.run(
                GitCommand(
                    arguments: ["init", "--initial-branch=main"],
                    accessesRemote: false, changesRepositoryState: true), in: repository)
            #expect(initialized.succeeded)
            let module = GitRepositoryModule(repositoryURL: repository, git: git)
            _ = try await module.loadRepositoryState()
            let changed = try await module.executePluginCommand(
                GitCommand(
                    arguments: ["config", "plugin.fixture", "λ value"],
                    accessesRemote: false, changesRepositoryState: true), standardInput: nil)
            #expect(changed.succeeded)
            let read = try await module.executePluginCommand(
                GitCommand(
                    arguments: ["config", "--get", "plugin.fixture"],
                    accessesRemote: false, changesRepositoryState: false), standardInput: nil)
            #expect(read.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "λ value")
        }
    }
}

typealias ApplicationPluginsTests = UIIntegrationTests.ApplicationPluginsTests
