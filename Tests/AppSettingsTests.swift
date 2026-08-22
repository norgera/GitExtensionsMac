import Foundation

@MainActor
enum AppSettingsTests {
    static func run() {
        testPreferencesRoundTrip()
        testPullPreferencesRoundTrip()
        testPushPreferencesRoundTrip()
        testCommitPreferencesRoundTrip()
        testFileStatusListPreferencesRoundTrip()
        testCommitMessageRules()
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
