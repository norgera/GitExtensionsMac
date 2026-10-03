import AppKit
import GitCommands
import GitExtensionsCore

enum BuiltInPluginKind: CaseIterable {
    case backgroundFetch, createBranches, deleteBranches, largeFiles, proxy, releaseNotes, statistics, gource, compileSubmodules

    var identity: (String, String) {
        switch self {
        case .backgroundFetch: ("D19A7905-8AAD-4271-ACA9-817669B94A1D", "Periodic background fetch")
        case .createBranches: ("BE7BEE10-21B5-489F-9664-957945C203DC", "Create local tracking branches")
        case .deleteBranches: ("DC3CA904-B9A5-4FE8-BF63-5B8EE9C2DDAC", "Delete obsolete branches")
        case .largeFiles: ("5AE20AB1-D677-46C5-ABDB-7874FF5A9296", "Find large files")
        case .proxy: ("C2A1C7A4-D519-4BD1-859B-6CE7DB9325FB", "Proxy Switcher")
        case .releaseNotes: ("49E7F2D6-AD79-489E-80A4-5CD212AE6DF3", "Release Notes Generator")
        case .statistics: ("17D1507D-C00D-4A10-AB75-DECB2EA5FCBF", "Statistics")
        case .gource: ("F0A6A769-6DCC-4452-9A43-343347015EEC", "Gource")
        case .compileSubmodules: ("D4D1ACB7-0B6B-4A3C-B0DB-A25056A277D9", "Auto compile submodules")
        }
    }

    var settings: [GitExtensionPluginSetting] {
        func value(_ name: String, _ defaultValue: String = "", _ kind: GitExtensionPluginSettingKind = .text) -> GitExtensionPluginSetting {
            .init(name: name, caption: name, defaultValue: defaultValue, kind: kind)
        }
        switch self {
        case .backgroundFetch:
            return [value("Arguments of git command to run", "fetch --all"),
                value("Fetch every (seconds) - set to 0 to disable", "0", .number(minimum: 0, maximum: Int.max)),
                value("Refresh view after fetch", "false", .boolean), value("Fetch all submodules", "false", .boolean),
                value("Fetch immediately on repository opening", "false", .boolean),
                .init(name: "Warning", caption: "Background fetch updates remote refs. Without refreshing, force-with-lease may overwrite remote changes you have not reviewed.", kind: .information)]
        case .deleteBranches:
            return [value("Delete obsolete branches older than (days)", "30", .number(minimum: 0, maximum: Int.max)),
                value("Branch where all branches should be merged in", "HEAD"),
                value("Delete obsolete branches from remote", "false", .boolean),
                value("Remote name obsoleted branches should be deleted from", "origin"),
                value("Use regex to filter branches to delete", "false", .boolean), value("Regex to filter branches to delete", "/(feature|develop)/"),
                value("Is regex filter case insensitive?", "false", .boolean), value("Search branches that does not match regex", "false", .boolean),
                value("Delete unmerged branches", "false", .boolean)]
        case .largeFiles: return [value("Find large files bigger than (Mb)", "1", .decimal(minimum: 0, maximum: Double(Float.greatestFiniteMagnitude)))]
        case .proxy: return [value("Username"), value("Password", "", .password), value("HTTP proxy"), value("HTTP proxy port", "8080")]
        case .statistics:
            return [value("Code files", "*.c;*.cpp;*.cc;*.cxx;*.h;*.hpp;*.hxx;*.inl;*.idl;*.asm;*.inc;*.cs;*.xsd;*.wsdl;*.xml;*.htm;*.html;*.css;*.vbs;*.vb;*.fs;*.fsx;*.sql;*.aspx;*.asp;*.php;*.nav;*.pas;*.py;*.rb;*.js;*.jsm;*.ts;*.mk;*.java;*.os;*.bsl"),
                value("Directories to ignore (EndsWith)", "\\Debug;\\Release;\\obj;\\bin;\\lib"), value("Ignore submodules", "true", .boolean)]
        case .gource: return [value("Path to Gource", "", .path), value("Arguments", "--hide filenames --user-image-dir \"$(AVATARS)\"")]
        case .compileSubmodules: return [value("Enabled", "false", .boolean),
            .init(name: "Path to msbuild.exe", caption: "Path to MSBuild", kind: .path),
            .init(name: "msbuild.exe arguments", caption: "MSBuild arguments", defaultValue: "/p:Configuration=Debug")]
        case .createBranches, .releaseNotes: return []
        }
    }
}

@MainActor
enum BuiltInPlugins {
    static func make() -> [BuiltInPlugin] {
        [BackgroundFetchPlugin(), CreateLocalBranchesPlugin(), DeleteUnusedBranchesPlugin(), FindLargeFilesPlugin(),
         ProxySwitcherPlugin(), ReleaseNotesPlugin(), StatisticsPlugin(), GourcePlugin(), AutoCompileSubmodulesPlugin()]
    }
}

@MainActor
class BuiltInPlugin: GitExtensionPlugin {
    required init() {}
    var kind: BuiltInPluginKind { .createBranches }
    var identifier: UUID { UUID(uuidString: kind.identity.0)! }
    var name: String { kind.identity.1 }
    var pluginDescription: String { name }
    var requiresRepository: Bool { kind != .proxy }
    var settings: [GitExtensionPluginSetting] { kind.settings }
    var icon: NSImage? { NSImage(systemSymbolName: kind == .statistics ? "chart.pie" : "puzzlepiece.extension", accessibilityDescription: name) }

    func value(_ name: String, in host: GitExtensionPluginHost) throws -> String {
        try host.setting(name) ?? settings.first { $0.name == name }?.defaultValue ?? ""
    }
    func flag(_ name: String, in host: GitExtensionPluginHost) throws -> Bool {
        try value(name, in: host).lowercased() == "true"
    }
    func register(with host: GitExtensionPluginHost) throws {}
    func unregister(from host: GitExtensionPluginHost) {}
    func execute(in host: GitExtensionPluginHost) async throws -> Bool {
        try await BuiltInPluginDialog.present(plugin: self, host: host)
    }
    func settingsController(in host: GitExtensionPluginHost) throws -> NSViewController? {
        settings.isEmpty ? nil : PluginSettingsViewController(settings: settings, host: host)
    }
}

@MainActor
final class BackgroundFetchPlugin: BuiltInPlugin {
    override var kind: BuiltInPluginKind { .backgroundFetch }
    private var task: Task<Void, Never>?
    private var observer: UUID?
    override func register(with host: GitExtensionPluginHost) throws {
        observer = host.observe("PostSettings") { [weak self, weak host] _ in
            if let self, let host { try restart(host) }; return true
        }
        try restart(host)
    }
    override func unregister(from host: GitExtensionPluginHost) {
        task?.cancel(); task = nil
        if let observer { host.removeObserver(observer) }; observer = nil
    }
    private func restart(_ host: GitExtensionPluginHost) throws {
        task?.cancel(); task = nil
        let interval = Int(try value("Fetch every (seconds) - set to 0 to disable", in: host)) ?? 0
        let immediate = try flag("Fetch immediately on repository opening", in: host)
        guard interval > 0 || immediate, let source = host.builtInRepository else { return }
        let refresh = try flag("Refresh view after fetch", in: host)
        let submodules = try flag("Fetch all submodules", in: host)
        let command = BuiltInPluginCommands.backgroundFetch(try value("Arguments of git command to run", in: host))
        task = Task { [weak host] in
            var first = true
            repeat {
                do {
                    try await Task.sleep(for: first && immediate ? .milliseconds(10) : .seconds(max(5, interval)))
                    while CommandLog.shared.snapshot().contains(where: { $0.isGit && $0.duration == nil && $0.directory == host?.repositoryURL?.path }) {
                        try await Task.sleep(for: .seconds(1))
                    }
                    try Task.checkCancellation()
                    if submodules { _ = try? await source.executePluginCommand(BuiltInPluginCommands.backgroundFetch("", submodules: true), standardInput: nil) }
                    try Task.checkCancellation()
                    let result = try await source.executePluginCommand(command, standardInput: nil)
                    try Task.checkCancellation()
                    if refresh, BuiltInPluginCommands.shouldRefreshAfterFetch(command, result: result) { host?.requestRepositoryRefresh() }
                } catch is CancellationError { return }
                catch {}
                first = false
            } while interval > 0 && !Task.isCancelled
        }
    }
}

@MainActor final class CreateLocalBranchesPlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .createBranches } }
@MainActor final class DeleteUnusedBranchesPlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .deleteBranches } }
@MainActor final class FindLargeFilesPlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .largeFiles } }
@MainActor final class ProxySwitcherPlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .proxy } }
@MainActor final class ReleaseNotesPlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .releaseNotes } }
@MainActor final class StatisticsPlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .statistics } }
@MainActor final class GourcePlugin: BuiltInPlugin { override var kind: BuiltInPluginKind { .gource } }

@MainActor
final class AutoCompileSubmodulesPlugin: BuiltInPlugin {
    override var kind: BuiltInPluginKind { .compileSubmodules }
    private var observer: UUID?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    override func register(with host: GitExtensionPluginHost) throws {
        observer = host.observe("PostUpdateSubmodules") { [weak self, weak host] succeeded in
            guard let self, let host, succeeded == true, try flag("Enabled", in: host) else { return true }
            let id = UUID()
            tasks[id] = Task { [weak self, weak host] in
                defer { self?.tasks[id] = nil }
                guard let self, let host else { return }
                do { _ = try await execute(in: host) }
                catch is CancellationError {}
                catch { NSAlert(error: error).runModal() }
            }
            return true
        }
    }
    override func unregister(from host: GitExtensionPluginHost) {
        if let observer { host.removeObserver(observer) }; observer = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
    }
}
