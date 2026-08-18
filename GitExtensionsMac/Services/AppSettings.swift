import AppKit
import Foundation

enum ApplicationTheme: String, Codable, CaseIterable, Sendable {
    case system = "System default"
    case light = "Light"
    case dark = "Dark"
}

struct AppPreferences: Codable, Equatable, Sendable {
    var reopenLastRepository = true
    var maximumRecentRepositories = 20
    var theme: ApplicationTheme = .system
    var mergeCommonParentLanes = true
    var straightenGraphDiagonals = true
    var diffContextLines = 3
    var ignoreWhitespace = false
    var defaultSignOff = false
    var defaultAllowEmpty = false
    var autoStashDuringRebase = false
    var gitExecutablePath = "/usr/bin/git"
    var editorPath = ""
    var shellPath = "/bin/zsh"
    var externalDiffToolPath = ""
    var externalMergeToolPath = ""
    var signingKey = ""
}

enum PullActionPreference: String, Codable, CaseIterable, Sendable {
    case openDialog
    case merge
    case rebase
    case fetch
    case fetchAll
    case fetchPruneAll
}

enum PullAutoPopPreference: String, Codable, CaseIterable, Sendable {
    case ask
    case always
    case never
}

struct PullPreferences: Codable, Equatable, Sendable {
    var defaultAction: PullActionPreference = .merge
    var formAction: PullActionPreference = .merge
    var autoStash = false
    var autoPopStash: PullAutoPopPreference = .ask
    var includeUntrackedInAutoStash = false
    var recentURLs: [String] = []
    var helpExpanded = true
    var closeProcessOnSuccess = false
    var confirmFetchAndPruneAll = true
    var updateSubmodulesAfterPull: Bool? = nil
}

enum PushRejectedActionPreference: String, Codable, CaseIterable, Sendable {
    case ask
    case none
    case defaultPull
    case rebase
    case merge
}

struct PushPreferences: Codable, Equatable, Sendable {
    var recursiveSubmodules: RepositoryPushSubmoduleMode = .check
    var recentURLs: [String] = []
    var showAdvancedOptions = false
    var confirmNewBranch = true
    var confirmAddTrackingReference = true
    var rejectedAction: PushRejectedActionPreference = .ask
    var loadRemoteBranchesDirectly = false
}

struct RecentRepository: Codable, Equatable, Sendable {
    let path: String
    var lastOpened: Date
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private enum Key {
        static let preferences = "GitExtensionsMac.preferences.v1"
        static let recentRepositories = "GitExtensionsMac.recentRepositories.v1"
        static let lastRepository = "GitExtensionsMac.lastRepository"
        static let pullPreferences = "GitExtensionsMac.pullPreferences.v1"
        static let pushPreferences = "GitExtensionsMac.pushPreferences.v1"
    }

    private let defaults: UserDefaults
    private(set) var preferences: AppPreferences
    private(set) var recentRepositories: [RecentRepository]
    private(set) var pullPreferences: PullPreferences
    private(set) var pushPreferences: PushPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        preferences = defaults.data(forKey: Key.preferences)
            .flatMap { try? decoder.decode(AppPreferences.self, from: $0) }
            ?? AppPreferences()
        recentRepositories = defaults.data(forKey: Key.recentRepositories)
            .flatMap { try? decoder.decode([RecentRepository].self, from: $0) }
            ?? []
        pullPreferences = defaults.data(forKey: Key.pullPreferences)
            .flatMap { try? decoder.decode(PullPreferences.self, from: $0) }
            ?? PullPreferences()
        pushPreferences = defaults.data(forKey: Key.pushPreferences)
            .flatMap { try? decoder.decode(PushPreferences.self, from: $0) }
            ?? PushPreferences()
        recentRepositories.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        applyAppearance()
    }

    var lastRepositoryPath: String? {
        defaults.string(forKey: Key.lastRepository)
    }

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.preferences)
        trimRecentRepositories()
        applyAppearance()
        NotificationCenter.default.post(name: .appPreferencesDidChange, object: self)
    }

    func savePullPreferences(_ preferences: PullPreferences) {
        pullPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.pullPreferences)
        NotificationCenter.default.post(name: .pullPreferencesDidChange, object: self)
    }

    func savePushPreferences(_ preferences: PushPreferences) {
        pushPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.pushPreferences)
        NotificationCenter.default.post(name: .pushPreferencesDidChange, object: self)
    }

    func recordPullURL(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var preferences = pullPreferences
        preferences.recentURLs.removeAll { $0 == value }
        preferences.recentURLs.insert(value, at: 0)
        preferences.recentURLs = Array(preferences.recentURLs.prefix(20))
        savePullPreferences(preferences)
    }

    func recordPushURL(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var preferences = pushPreferences
        preferences.recentURLs.removeAll { $0 == value }
        preferences.recentURLs.insert(value, at: 0)
        preferences.recentURLs = Array(preferences.recentURLs.prefix(20))
        savePushPreferences(preferences)
    }

    func recordOpenedRepository(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentRepositories.removeAll { $0.path == path }
        recentRepositories.insert(RecentRepository(path: path, lastOpened: Date()), at: 0)
        defaults.set(path, forKey: Key.lastRepository)
        trimRecentRepositories()
    }

    func removeRecentRepository(path: String) {
        recentRepositories.removeAll { $0.path == path }
        persistRecentRepositories()
    }

    func clearRecentRepositories() {
        recentRepositories.removeAll()
        persistRecentRepositories()
    }

    private func trimRecentRepositories() {
        recentRepositories = Array(recentRepositories.prefix(max(1, preferences.maximumRecentRepositories)))
        persistRecentRepositories()
    }

    private func persistRecentRepositories() {
        defaults.set(try? JSONEncoder().encode(recentRepositories), forKey: Key.recentRepositories)
    }

    private func applyAppearance() {
        guard let application = NSApp else { return }
        switch preferences.theme {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Notification.Name {
    static let appPreferencesDidChange = Notification.Name("GitExtensionsMac.appPreferencesDidChange")
    static let pullPreferencesDidChange = Notification.Name("GitExtensionsMac.pullPreferencesDidChange")
    static let pushPreferencesDidChange = Notification.Name("GitExtensionsMac.pushPreferencesDidChange")
}
