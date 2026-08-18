import Foundation

@MainActor
enum AppSettingsTests {
    static func run() {
        testPreferencesRoundTrip()
        testPullPreferencesRoundTrip()
        testRecentRepositories()
        print("AppSettingsTests: passed")
    }

    private static func testPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.preferences
            preferences.theme = .dark
            preferences.gitExecutablePath = "/opt/homebrew/bin/git"
            preferences.defaultSignOff = true
            preferences.mergeCommonParentLanes = false
            store.save(preferences)
            precondition(AppSettingsStore(defaults: defaults).preferences == preferences)
        }
    }

    private static func testRecentRepositories() {
        withStore { store, _ in
            var preferences = store.preferences
            preferences.maximumRecentRepositories = 1
            store.save(preferences)
            store.recordOpenedRepository(URL(fileURLWithPath: "/", isDirectory: true))
            let temporaryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
            store.recordOpenedRepository(temporaryURL)
            precondition(store.recentRepositories.map(\.path) == [temporaryURL.path])
            precondition(store.lastRepositoryPath == temporaryURL.path)
            store.removeRecentRepository(path: temporaryURL.path)
            precondition(store.recentRepositories.isEmpty)
            store.recordOpenedRepository(URL(fileURLWithPath: "/", isDirectory: true))
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

    private static func withStore(_ body: (AppSettingsStore, UserDefaults) -> Void) {
        let suite = "GitExtensionsMac.AppSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Could not create defaults suite") }
        defaults.removePersistentDomain(forName: suite)
        body(AppSettingsStore(defaults: defaults), defaults)
        defaults.removePersistentDomain(forName: suite)
    }
}
