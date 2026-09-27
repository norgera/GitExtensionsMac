@testable import GitUI
@testable import GitCommands
@testable import GitExtensionsCore
import AppKit

@MainActor
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

    static func run() async throws {
        precondition(ApplicationPluginRegistry.scriptPluginName("{plugin:Fixture}") == "Fixture")
        precondition(ApplicationPluginRegistry.scriptPluginName("{plugin=Fixture}") == "Fixture")
        precondition(ApplicationPluginRegistry.scriptPluginName("plugin:Fixture") == "Fixture")
        precondition(ApplicationPluginRegistry.scriptPluginName("/usr/bin/git") == nil)
        precondition(GitExtensionPluginSetting.textValue(" \n") == nil)
        precondition(GitExtensionPluginSetting.textValue("<empty string>") == "")
        precondition(GitExtensionPluginSetting.textValue(" value λ ") == "value λ")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if ProcessInfo.processInfo.environment["PLUGINS_TEST_KEEP_FIXTURE"] == "1" { print("Plugin fixture: \(root.path)") }
            else { try? FileManager.default.removeItem(at: root) }
        }
        for path in ["GitExtensions.Root.bundle", "group/GitExtensions.Child.bundle",
                     "group/deeper/GitExtensions.TooDeep.bundle", "Ignored.bundle"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let candidates = try ApplicationPluginRegistry.candidates(in: [root, root])
        precondition(candidates.count == 2)
        let registry = ApplicationPluginRegistry()
        registry.load(directories: [root])
        precondition(registry.entries.isEmpty && registry.failures.count == 2)
        registry.load(directories: [root])
        precondition(registry.failures.count == 2)
        let first = Fixture()
        try registry.add(first)
        let duplicate = Fixture(); duplicate.identifier = first.identifier
        do { try registry.add(duplicate); preconditionFailure("Duplicate ID accepted") }
        catch PluginError.invalid { }

        let suite = "GitExtensionsMac.PluginsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let locations = DistributedSettings(localURL: root.appendingPathComponent("local.xml"),
            distributedURL: root.appendingPathComponent("shared.xml"))
        let settings = ApplicationPluginSettings(identifier: first.identifier, legacyName: "OldFixture",
            locations: locations, defaults: defaults)
        defaults.set(["OldFixturecolor": "legacy"], forKey: "GitExtensionsMac.plugins.settings.v1")
        let legacy = try settings.value("color"); precondition(legacy == "legacy")
        try settings.set("color", value: "global")
        try settings.set("color", value: "shared", scope: .distributed)
        try settings.set("color", value: "local", scope: .local)
        let effective = try settings.value("color"); precondition(effective == "local")
        let global = try settings.value("color", scope: .global); precondition(global == "global")
        try settings.set("color", value: nil, scope: .local)
        let inherited = try settings.value("color"); precondition(inherited == "shared")
        try settings.set("color", value: "effective edit", scope: .effective)
        let localOverride = try settings.value("color", scope: .local); precondition(localOverride == "effective edit")
        let sharedUnchanged = try settings.value("color", scope: .distributed); precondition(sharedUnchanged == "shared")
        try settings.set("new", value: "global fallback", scope: .effective)
        let globalFallback = try settings.value("new", scope: .global); precondition(globalFallback == "global fallback")
        let other = ApplicationPluginSettings(identifier: UUID(), legacyName: "Other", locations: locations, defaults: defaults)
        let absent = try other.value("color"); precondition(absent == nil)
        let number = GitExtensionPluginSetting(name: "count", caption: "Count", defaultValue: "2", kind: .number(minimum: 1, maximum: 10))
        try number.validate("3")
        do { try number.validate("11"); preconditionFailure() } catch PluginError.invalid { }
        let choice = GitExtensionPluginSetting(name: "mode", caption: "Mode", defaultValue: "one", kind: .choice(["one", "two"]))
        try choice.validate("two")
        do { try choice.validate("three"); preconditionFailure() } catch PluginError.invalid { }
        defaults.set(["invalid": 12], forKey: "GitExtensionsMac.plugins.settings.v1")
        do { try settings.set("color", value: "overwrite"); preconditionFailure() } catch PluginError.invalid { }
        precondition((defaults.dictionary(forKey: "GitExtensionsMac.plugins.settings.v1")?["invalid"] as? Int) == 12)
        defaults.removeObject(forKey: "GitExtensionsMac.plugins.settings.v1")

        var refreshes = 0
        var selected = ""
        let host = GitExtensionPluginHost(refresh: { refreshes += 1 }, navigate: { selected = $0 },
            readSetting: { name, scope in try settings.value(name, scope: DistributedSettingsScope(rawValue: scope.rawValue)!) },
            writeSetting: { name, value, scope in try settings.set(name, value: value, scope: DistributedSettingsScope(rawValue: scope.rawValue)!) })
        host.update(context: ["WorkingDir": [root.path]], owner: nil)
        let selection: [RevisionID] = [.workingDirectory, .index, .object(testObjectID("plugin-selection"))]
        host.updateSelection(selection)
        precondition(host.selectedRevisions == selection && host.selectedRevisions[0].objectID == nil)
        precondition(host.context["WorkingDir"] == [root.path])
        host.requestRepositoryRefresh(); precondition(refreshes == 1)
        let notifier = RepositoryChangedNotifier { refreshes += 1 }
        notifier.lock()
        notifier.notify()
        notifier.notify()
        precondition(refreshes == 1)
        notifier.unlock(requestNotify: false)
        precondition(refreshes == 2, "Compound plugin refresh requests must coalesce")
        try await host.selectRevision("HEAD~2"); precondition(selected == "HEAD~2")
        var events: [Int] = []
        host.observe("PreCommit") { _ in events.append(1); return true }
        let veto = host.observe("PreCommit") { _ in events.append(2); return false }
        host.observe("PreCommit") { _ in events.append(3); return true }
        let allowed = try host.dispatch("PreCommit"); precondition(!allowed && events == [1, 2])
        host.removeObserver(veto); events = []
        let continued = try host.dispatch("PreCommit"); precondition(continued && events == [1, 3])
        let session = ApplicationPluginSession()
        session.register(first, host: host); session.register(first, host: host)
        precondition(first.registrations == 1)
        let failing = Fixture(); failing.failRegistration = true
        session.register(failing, host: host)
        precondition(session.failures.count == 1 && failing.unregistrations == 1)
        session.close(); session.close()
        precondition(first.unregistrations == 1)
        events = []
        _ = try host.dispatch("PreCommit")
        precondition(events.isEmpty, "Closed sessions must release event handlers and their captured context")
        let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
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
        let plist: [String: Any] = ["CFBundleExecutable": "Loadable", "CFBundlePackageType": "BNDL",
            "CFBundleIdentifier": "org.example.GitExtensions.PluginFixture", "CFBundleVersion": "1",
            "NSPrincipalClass": "PluginFixture.LoadablePlugin", "GitExtensionsPluginAPIVersion": 1]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-emit-library", "-module-cache-path", root.appendingPathComponent("ModuleCache").path,
            "-module-name", "PluginFixture", "-F", products.path,
            "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "GitUI",
            "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "GitCommands",
            "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "GitExtensionsCore",
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            source.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        precondition(compiler.terminationStatus == 0, "Public plugin SDK fixture did not compile")
        let loadable = ApplicationPluginRegistry()
        loadable.load(directories: [root])
        guard let instance = loadable.entries.first?.plugin else {
            preconditionFailure("Native bundle did not load: \(loadable.failures)")
        }
        precondition(instance.name == "Loadable fixture")
        let refresh = try await instance.execute(in: host); precondition(refresh)
        let executed = try settings.value("executed"); precondition(executed == "yes")
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let git = GitProcess()
        let initialized = try await git.run(GitCommand(arguments: ["init", "--initial-branch=main"],
            accessesRemote: false, changesRepositoryState: true), in: repository)
        precondition(initialized.succeeded)
        let module = GitRepositoryModule(repositoryURL: repository, git: git)
        _ = try await module.loadRepositoryState()
        let changed = try await module.executePluginCommand(GitCommand(arguments: ["config", "plugin.fixture", "λ value"],
            accessesRemote: false, changesRepositoryState: true), standardInput: nil)
        precondition(changed.succeeded)
        let read = try await module.executePluginCommand(GitCommand(arguments: ["config", "--get", "plugin.fixture"],
            accessesRemote: false, changesRepositoryState: false), standardInput: nil)
        precondition(read.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "λ value")
        print("ApplicationPluginsTests: passed")
    }
}
